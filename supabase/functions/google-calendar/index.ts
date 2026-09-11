// Google Calendar two-way sync (GitHub #160, C3). HTTP surface for sync.ts.
//
// verify_jwt is DISABLED (see supabase/config.toml): Google's OAuth redirect and the DB's
// pg_net calls carry no Supabase JWT, and the browser's CORS preflight never does. Each route
// authenticates itself instead:
//
//   GET  /google-calendar/callback?code&state     Google redirects here after consent. The
//                                                 HMAC-signed state names the carer; on
//                                                 success we redirect to /schedule/?google=connected.
//   POST {action}  with the carer's Supabase JWT  (Authorization: Bearer <jwt>)
//        connect          {read_primary?}  -> {url}     the Google consent URL to send them to
//        disconnect                        -> {ok}      revoke, forget tokens, links and connection
//        sync_now                          -> {summary, connection}
//        set_read_primary {value}          -> {ok} | {needs_consent, url}
//   POST {action}  with x-webhook-secret          (from pg_net in the DB)
//        push  {provider_user_id, items:[{kind,row_id,deleted}]}   a Truffl-side change
//        poll                                                        every ten minutes (pg_cron)
//
// Required function secrets (Supabase -> Edge Functions -> Secrets):
//   GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET   the OAuth client (docs/google-calendar-setup.md)
//   WEBHOOK_SECRET                           shared with private.stripe_config (already set)
//   (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically)
//
// Scopes: calendar.app.created (create and fully manage calendars this app created: the
// "Truffl" calendar) is all the Truffl-only mode needs, and Google classes it non-sensitive.
// Reading the carer's main calendar adds calendar.events.readonly (sensitive), requested only
// when they opt in, via incremental consent.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';
import { timingSafeEqual } from '../_shared/secret.ts';
import {
  type ApplyResult, type Connection, type Db, type GEvent, type GoogleApi, type Link, type ListParams,
  type ListResult, type PushItem, type Row, GoogleError, ReconnectError, SCOPE_APP_CREATED,
  SCOPE_EVENTS_READONLY, SITE, hasScope, pushItems, syncUser,
} from './sync.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WEBHOOK_SECRET = Deno.env.get('WEBHOOK_SECRET') ?? '';
const GOOGLE_CLIENT_ID = Deno.env.get('GOOGLE_CLIENT_ID') ?? '';
const GOOGLE_CLIENT_SECRET = Deno.env.get('GOOGLE_CLIENT_SECRET') ?? '';
const REDIRECT_URI = `${SUPABASE_URL}/functions/v1/google-calendar/callback`;
const CAL_API = 'https://www.googleapis.com/calendar/v3';
const STATE_TTL_MS = 15 * 60 * 1000;
const POLL_BUDGET_MS = 100_000;

const sb = createClient(SUPABASE_URL, SERVICE_ROLE);

// ── OAuth state: uid.ts.rp.sig, signed with the webhook secret ──────────────
async function hmac(msg: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(WEBHOOK_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(msg));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, '0')).join('');
}
async function makeState(uid: string, readPrimary: boolean): Promise<string> {
  const body = `${uid}.${Date.now()}.${readPrimary ? 1 : 0}`;
  return `${body}.${await hmac(body)}`;
}
async function readState(state: string): Promise<{ uid: string; readPrimary: boolean } | null> {
  const parts = state.split('.');
  if (parts.length !== 4) return null;
  const [uid, ts, rp, sig] = parts;
  const expected = await hmac(`${uid}.${ts}.${rp}`);
  if (!timingSafeEqual(sig, expected)) return null;
  if (!/^[0-9a-f-]{36}$/.test(uid)) return null;
  if (Date.now() - Number(ts) > STATE_TTL_MS) return null;
  return { uid, readPrimary: rp === '1' };
}

function consentUrl(state: string, readPrimary: boolean): string {
  const scopes = ['openid', 'email', SCOPE_APP_CREATED];
  if (readPrimary) scopes.push(SCOPE_EVENTS_READONLY);
  const q = new URLSearchParams({
    client_id: GOOGLE_CLIENT_ID,
    redirect_uri: REDIRECT_URI,
    response_type: 'code',
    scope: scopes.join(' '),
    access_type: 'offline',
    prompt: 'consent',            // always hand back a refresh token, including on reconnect
    include_granted_scopes: 'true',
    state,
  });
  return `https://accounts.google.com/o/oauth2/v2/auth?${q.toString()}`;
}

// ── Tokens ──────────────────────────────────────────────────────────────────
type TokenRow = { refresh_token: string; access_token: string | null; access_expires_at: string | null };

async function tokenRequest(params: Record<string, string>): Promise<Record<string, unknown>> {
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: GOOGLE_CLIENT_ID, client_secret: GOOGLE_CLIENT_SECRET, ...params }).toString(),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = String((data as Record<string, unknown>).error || res.status);
    if (err === 'invalid_grant') throw new ReconnectError('Google has disconnected Truffl. Reconnect to keep syncing.');
    throw new GoogleError(res.status, `token: ${err}`);
  }
  return data as Record<string, unknown>;
}

async function accessTokenFor(userId: string): Promise<string> {
  const { data, error } = await sb.rpc('google_tokens_get', { p_user: userId });
  if (error) throw new Error(`google_tokens_get: ${error.message}`);
  const t = data as TokenRow | null;
  if (!t?.refresh_token) throw new ReconnectError('Google is not connected.');
  if (t.access_token && t.access_expires_at && Date.parse(t.access_expires_at) - Date.now() > 60_000) return t.access_token;
  const fresh = await tokenRequest({ grant_type: 'refresh_token', refresh_token: t.refresh_token });
  const access = String(fresh.access_token);
  const expires = new Date(Date.now() + Number(fresh.expires_in || 3600) * 1000).toISOString();
  await sb.rpc('google_tokens_set', { p_user: userId, p_refresh_token: '', p_access_token: access, p_access_expires_at: expires });
  return access;
}

// ── Google Calendar client (per carer) ──────────────────────────────────────
function makeGoogle(userId: string): GoogleApi {
  let token: string | null = null;
  async function call(path: string, init: RequestInit = {}, retry = true): Promise<Response> {
    token = token ?? await accessTokenFor(userId);
    const res = await fetch(`${CAL_API}${path}`, {
      ...init,
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(init.headers || {}) },
    });
    if (res.status === 401 && retry) {
      // Token revoked or expired early: refresh once, then give up.
      await sb.rpc('google_tokens_set', { p_user: userId, p_refresh_token: '', p_access_token: null, p_access_expires_at: null });
      token = null;
      return call(path, init, false);
    }
    if (res.status === 401) throw new ReconnectError('Google has disconnected Truffl. Reconnect to keep syncing.');
    if (res.status === 403) {
      const body = await res.text();
      if (/insufficient|ACCESS_TOKEN_SCOPE_INSUFFICIENT|PERMISSION_DENIED/i.test(body)) {
        throw new ReconnectError('Truffl needs more calendar permission than Google granted. Reconnect Google to allow it.');
      }
      throw new GoogleError(403, body.slice(0, 200));
    }
    return res;
  }
  async function json<T>(res: Response): Promise<T> {
    if (!res.ok) throw new GoogleError(res.status, (await res.text()).slice(0, 300));
    return await res.json() as T;
  }
  const enc = encodeURIComponent;
  return {
    async listEvents(calendarId: string, params: ListParams): Promise<ListResult> {
      const q = new URLSearchParams({ singleEvents: 'true', showDeleted: 'true', maxResults: '250' });
      if (params.syncToken) q.set('syncToken', params.syncToken);
      else { if (params.timeMin) q.set('timeMin', params.timeMin); if (params.timeMax) q.set('timeMax', params.timeMax); }
      if (params.pageToken) q.set('pageToken', params.pageToken);
      return await json<ListResult>(await call(`/calendars/${enc(calendarId)}/events?${q}`));
    },
    async insertEvent(calendarId, body) {
      return await json<GEvent>(await call(`/calendars/${enc(calendarId)}/events`, { method: 'POST', body: JSON.stringify(body) }));
    },
    async patchEvent(calendarId, eventId, body) {
      return await json<GEvent>(await call(`/calendars/${enc(calendarId)}/events/${enc(eventId)}`, { method: 'PATCH', body: JSON.stringify(body) }));
    },
    async deleteEvent(calendarId, eventId) {
      const res = await call(`/calendars/${enc(calendarId)}/events/${enc(eventId)}`, { method: 'DELETE' });
      if (res.ok || res.status === 404 || res.status === 410) return;
      throw new GoogleError(res.status, (await res.text()).slice(0, 300));
    },
    async createCalendar(summary, description, timeZone) {
      return await json<{ id: string }>(await call('/calendars', { method: 'POST', body: JSON.stringify({ summary, description, timeZone }) }));
    },
    async calendarExists(calendarId) {
      const res = await call(`/calendars/${enc(calendarId)}`);
      if (res.status === 404 || res.status === 410) return false;
      if (!res.ok) throw new GoogleError(res.status, (await res.text()).slice(0, 300));
      return true;
    },
  };
}

// ── Database adapter ────────────────────────────────────────────────────────
const db: Db = {
  async getConnection(userId) {
    const { data, error } = await sb.from('google_calendar_connections').select('*').eq('provider_user_id', userId).maybeSingle();
    if (error) throw new Error(`connection: ${error.message}`);
    return (data as Connection | null) ?? null;
  },
  async updateConnection(userId, patch) {
    const { error } = await sb.from('google_calendar_connections').update(patch).eq('provider_user_id', userId);
    if (error) throw new Error(`connection update: ${error.message}`);
  },
  async syncRows(userId) {
    const { data, error } = await sb.rpc('google_sync_rows', { p_user: userId });
    if (error) throw new Error(`google_sync_rows: ${error.message}`);
    return (data ?? []) as Row[];
  },
  async listLinks(userId) {
    const { data, error } = await sb.from('calendar_event_links').select('*').eq('provider_user_id', userId);
    if (error) throw new Error(`links: ${error.message}`);
    return (data ?? []) as Link[];
  },
  async upsertLink(link) {
    const { error } = await sb.from('calendar_event_links').upsert(link, { onConflict: 'provider_user_id,kind,row_id' });
    if (error) throw new Error(`link upsert: ${error.message}`);
  },
  async updateLink(id, patch) {
    const { error } = await sb.from('calendar_event_links').update(patch).eq('id', id);
    if (error) throw new Error(`link update: ${error.message}`);
  },
  async deleteLink(id) {
    const { error } = await sb.from('calendar_event_links').delete().eq('id', id);
    if (error) throw new Error(`link delete: ${error.message}`);
  },
  async deleteLinksForCalendar(userId, calendarId) {
    const { error } = await sb.from('calendar_event_links').delete().eq('provider_user_id', userId).eq('google_calendar_id', calendarId);
    if (error) throw new Error(`links delete: ${error.message}`);
  },
  async orphanLinks(userId) {
    const { data, error } = await sb.rpc('google_orphan_links', { p_user: userId });
    if (error) throw new Error(`google_orphan_links: ${error.message}`);
    return (data ?? []) as Link[];
  },
  async applyEvent(userId, calendarId, ev) {
    const { data, error } = await sb.rpc('google_apply_event', { p_user: userId, p_calendar_id: calendarId, p_event: ev });
    if (error) throw new Error(`google_apply_event: ${error.message}`);
    return (data ?? { action: 'skipped' }) as ApplyResult;
  },
};

// Run a sync for one carer, recording the outcome on their connection row.
async function runSync(userId: string) {
  try {
    return await syncUser(makeGoogle(userId), db, userId);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error('sync', userId, msg);
    await db.updateConnection(userId, e instanceof ReconnectError
      ? { status: 'error', last_error: msg }
      : { last_error: `Sync failed: ${msg.slice(0, 200)}` }).catch(() => {});
    throw e;
  }
}

async function publicConnection(userId: string) {
  const c = await db.getConnection(userId);
  if (!c) return null;
  return {
    google_email: c.google_email, read_primary: c.read_primary, status: c.status, last_error: c.last_error,
    last_synced_at: c.last_synced_at, can_read_primary: hasScope(c, SCOPE_EVENTS_READONLY),
  };
}

function decodeJwtEmail(idToken: unknown): string | null {
  try {
    const payload = String(idToken).split('.')[1];
    const json = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(payload.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0))));
    return typeof json.email === 'string' ? json.email : null;
  } catch {
    return null;
  }
}

// ── OAuth callback ──────────────────────────────────────────────────────────
async function handleCallback(url: URL): Promise<Response> {
  const back = (q: string) => Response.redirect(`${SITE}/schedule/?google=${q}`, 302);
  const state = url.searchParams.get('state') || '';
  const parsed = await readState(state);
  if (!parsed) return back('error&reason=state');
  if (url.searchParams.get('error')) return back(`error&reason=${encodeURIComponent(url.searchParams.get('error')!)}`);
  const code = url.searchParams.get('code') || '';
  if (!code) return back('error&reason=code');

  let tok: Record<string, unknown>;
  try {
    tok = await tokenRequest({ grant_type: 'authorization_code', code, redirect_uri: REDIRECT_URI });
  } catch (e) {
    console.error('token exchange', e instanceof Error ? e.message : e);
    return back('error&reason=exchange');
  }
  const scopes = String(tok.scope || '');
  if (!scopes.split(/\s+/).includes(SCOPE_APP_CREATED)) return back('error&reason=scope');

  const existing = await db.getConnection(parsed.uid);
  const refresh = typeof tok.refresh_token === 'string' ? tok.refresh_token : '';
  if (!refresh && !existing) return back('error&reason=no_refresh_token');
  const expires = new Date(Date.now() + Number(tok.expires_in || 3600) * 1000).toISOString();
  const { error: terr } = await sb.rpc('google_tokens_set', {
    p_user: parsed.uid, p_refresh_token: refresh, p_access_token: String(tok.access_token || ''), p_access_expires_at: expires,
  });
  if (terr) { console.error('google_tokens_set', terr.message); return back('error&reason=store'); }

  const email = decodeJwtEmail(tok.id_token) ?? existing?.google_email ?? null;
  const readPrimary = parsed.readPrimary && scopes.split(/\s+/).includes(SCOPE_EVENTS_READONLY);
  const row = {
    provider_user_id: parsed.uid,
    google_email: email,
    scopes,
    read_primary: readPrimary || (existing?.read_primary && scopes.split(/\s+/).includes(SCOPE_EVENTS_READONLY)) || false,
    status: 'connected',
    last_error: null,
    // A fresh consent may be a different Google account: check the calendar still exists
    // (ensureTrufflCalendar does) rather than trusting the old id blindly.
    sync_token_primary: null,
  };
  const { error: cerr } = await sb.from('google_calendar_connections').upsert(row, { onConflict: 'provider_user_id' });
  if (cerr) { console.error('connection upsert', cerr.message); return back('error&reason=store'); }

  try {
    await runSync(parsed.uid);
  } catch (e) {
    // The connection is saved; the poll retries. Tell the carer anyway.
    return back(`connected&sync=${encodeURIComponent(e instanceof Error ? e.message.slice(0, 120) : 'failed')}`);
  }
  return back('connected');
}

// ── HTTP ────────────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (req.method === 'GET' && url.pathname.endsWith('/callback')) return await handleCallback(url);

  const CORS = corsHeaders(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  if (!GOOGLE_CLIENT_ID || !GOOGLE_CLIENT_SECRET) return json({ error: 'Google sync is not configured yet' }, 503);

  let payload: Record<string, unknown> = {};
  try { payload = await req.json(); } catch { /* empty body ok */ }
  const action = String(payload.action || '');

  // Server-to-server (pg_net): the shared secret is the credential.
  const secret = req.headers.get('x-webhook-secret');
  if (secret !== null) {
    if (!WEBHOOK_SECRET || !timingSafeEqual(secret, WEBHOOK_SECRET)) return json({ error: 'Unauthorized' }, 401);
    try {
      if (action === 'push') {
        const userId = String(payload.provider_user_id || '');
        const items = Array.isArray(payload.items) ? payload.items as PushItem[] : [];
        if (!userId || !items.length) return json({ error: 'Missing provider_user_id or items' }, 400);
        try {
          const summary = await pushItems(makeGoogle(userId), db, userId, items);
          return json({ ok: true, summary });
        } catch (e) {
          const msg = e instanceof Error ? e.message : String(e);
          await db.updateConnection(userId, e instanceof ReconnectError ? { status: 'error', last_error: msg } : { last_error: `Push failed: ${msg.slice(0, 200)}` }).catch(() => {});
          return json({ ok: false, error: msg }, 500);
        }
      }
      if (action === 'poll') {
        const started = Date.now();
        const { data, error } = await sb.from('google_calendar_connections').select('provider_user_id')
          .eq('status', 'connected').order('last_synced_at', { ascending: true, nullsFirst: true }).limit(200);
        if (error) return json({ error: error.message }, 500);
        let synced = 0, failed = 0, skipped = 0;
        for (const c of data ?? []) {
          if (Date.now() - started > POLL_BUDGET_MS) { skipped++; continue; }
          try { await runSync(c.provider_user_id); synced++; } catch { failed++; }
        }
        return json({ ok: true, synced, failed, skipped });
      }
      return json({ error: 'Unknown action' }, 400);
    } catch (e) {
      return json({ error: e instanceof Error ? e.message : String(e) }, 500);
    }
  }

  // Browser: the carer's Supabase JWT (users.id === auth.uid()).
  const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: { user }, error: uerr } = await sb.auth.getUser(jwt);
  if (uerr || !user) return json({ error: 'Not authenticated' }, 401);
  const userId = user.id;

  try {
    if (action === 'connect') {
      const readPrimary = payload.read_primary === true;
      const state = await makeState(userId, readPrimary);
      return json({ url: consentUrl(state, readPrimary) });
    }
    if (action === 'status') {
      return json({ connection: await publicConnection(userId) });
    }
    if (action === 'disconnect') {
      const { data: tok } = await sb.rpc('google_tokens_get', { p_user: userId });
      const refresh = (tok as TokenRow | null)?.refresh_token;
      if (refresh) {
        // Best effort: Google forgets the grant, so the carer's account page stops listing us.
        await fetch(`https://oauth2.googleapis.com/revoke?token=${encodeURIComponent(refresh)}`, { method: 'POST' }).catch(() => {});
      }
      await sb.rpc('google_tokens_delete', { p_user: userId });
      await sb.from('calendar_event_links').delete().eq('provider_user_id', userId);
      await sb.from('google_calendar_connections').delete().eq('provider_user_id', userId);
      return json({ ok: true });
    }
    if (action === 'sync_now') {
      const conn = await db.getConnection(userId);
      if (!conn) return json({ error: 'Google is not connected' }, 400);
      try {
        const summary = await runSync(userId);
        return json({ ok: true, summary, connection: await publicConnection(userId) });
      } catch (e) {
        return json({ ok: false, error: e instanceof Error ? e.message : String(e), connection: await publicConnection(userId) }, 502);
      }
    }
    if (action === 'set_read_primary') {
      const conn = await db.getConnection(userId);
      if (!conn) return json({ error: 'Google is not connected' }, 400);
      const value = payload.value === true;
      if (value && !hasScope(conn, SCOPE_EVENTS_READONLY)) {
        const state = await makeState(userId, true);
        return json({ needs_consent: true, url: consentUrl(state, true) });
      }
      await db.updateConnection(userId, { read_primary: value, sync_token_primary: null });
      if (value) { try { await runSync(userId); } catch { /* recorded on the connection */ } }
      return json({ ok: true, connection: await publicConnection(userId) });
    }
    return json({ error: 'Unknown action' }, 400);
  } catch (e) {
    console.error(action, e instanceof Error ? e.message : e);
    return json({ error: e instanceof Error ? e.message : 'Request failed' }, 500);
  }
});
