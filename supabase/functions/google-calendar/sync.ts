// Google Calendar sync engine (GitHub #160, C3). Pure logic: everything that touches the
// network or the database comes in through the GoogleApi and Db interfaces so the engine can
// be exercised with in-memory fakes. index.ts wires the real ones.
//
// Model
//   * One "Truffl" calendar per carer, created by us in their Google account. Every job and
//     every confirmed booking in the 30-days-back / 90-days-ahead window is mirrored there as
//     an event carrying extendedProperties.private.truffl_kind / truffl_id.
//   * Events the carer creates in that calendar (or, if they opt in, on their main calendar)
//     come back as jobs. Bookings are mirrored read-only.
//   * calendar_event_links remembers, per Truffl row, the Google event id, the etag we last
//     saw and a hash of the content we last synced. Pull skips an event whose etag has not
//     moved; push skips a row whose hash has not moved. That is the whole loop-breaker.
//   * Google's incremental sync tokens keep the poll cheap; a 410 means the token expired
//     and we re-list the window. A full re-list also happens weekly so new instances of
//     unbounded recurring events keep arriving.

export type Kind = 'job' | 'booking';

export type Row = {
  kind: Kind;
  id: string;
  summary: string | null;
  description: string | null;
  location: string | null;
  starts_at: string;
  ends_at: string;
  status: 'CONFIRMED' | 'TENTATIVE' | 'CANCELLED';
  updated_at: string;
  content_hash: string;
};

export type Link = {
  id: string;
  provider_user_id: string;
  kind: Kind;
  row_id: string;
  google_calendar_id: string;
  google_event_id: string;
  google_etag: string | null;
  content_hash: string | null;
  origin: 'truffl' | 'google';
  last_pushed_at: string | null;
  last_pulled_at: string | null;
};

export type Connection = {
  provider_user_id: string;
  google_email: string | null;
  truffl_calendar_id: string | null;
  read_primary: boolean;
  scopes: string;
  status: 'connected' | 'error';
  last_error: string | null;
  last_synced_at: string | null;
  last_full_sync_at: string | null;
  sync_token_truffl: string | null;
  sync_token_primary: string | null;
};

export type GEventTime = { dateTime?: string; date?: string; timeZone?: string };
export type GEvent = {
  id: string;
  etag?: string;
  status?: string;
  summary?: string;
  description?: string;
  location?: string;
  start?: GEventTime;
  end?: GEventTime;
  updated?: string;
  iCalUID?: string;
  extendedProperties?: { private?: Record<string, string> };
};

export type ListParams = {
  syncToken?: string;
  pageToken?: string;
  timeMin?: string;
  timeMax?: string;
};
export type ListResult = { items: GEvent[]; nextPageToken?: string; nextSyncToken?: string };

export class GoogleError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}
// Thrown when the carer has to go through OAuth again (refresh token revoked or expired,
// or a scope we need was never granted). The caller marks the connection status 'error'.
export class ReconnectError extends Error {}

export interface GoogleApi {
  listEvents(calendarId: string, params: ListParams): Promise<ListResult>;
  insertEvent(calendarId: string, body: Record<string, unknown>): Promise<GEvent>;
  patchEvent(calendarId: string, eventId: string, body: Record<string, unknown>): Promise<GEvent>;
  /** Resolves on 404/410 as well: an already-gone event is fine. */
  deleteEvent(calendarId: string, eventId: string): Promise<void>;
  createCalendar(summary: string, description: string, timeZone: string): Promise<{ id: string }>;
  calendarExists(calendarId: string): Promise<boolean>;
}

export type ApplyResult = { action: string; job_id?: string; reason?: string };

export interface Db {
  getConnection(userId: string): Promise<Connection | null>;
  updateConnection(userId: string, patch: Partial<Connection>): Promise<void>;
  syncRows(userId: string): Promise<Row[]>;
  listLinks(userId: string): Promise<Link[]>;
  upsertLink(link: Omit<Link, 'id'>): Promise<void>;
  updateLink(id: string, patch: Partial<Link>): Promise<void>;
  deleteLink(id: string): Promise<void>;
  deleteLinksForCalendar(userId: string, calendarId: string): Promise<void>;
  orphanLinks(userId: string): Promise<Link[]>;
  applyEvent(userId: string, calendarId: string, ev: GEvent): Promise<ApplyResult>;
}

export const SCOPE_APP_CREATED = 'https://www.googleapis.com/auth/calendar.app.created';
export const SCOPE_EVENTS_READONLY = 'https://www.googleapis.com/auth/calendar.events.readonly';
export const TIME_ZONE = 'Australia/Sydney';
export const SITE = 'https://trufflpets.com';
export const TRUFFL_CALENDAR_SUMMARY = 'Truffl';
export const TRUFFL_CALENDAR_DESCRIPTION =
  'Your Truffl schedule: own-client jobs and Truffl bookings. Add a walk here and it appears in Truffl within ten minutes.';

const DAY_MS = 86_400_000;
export const PULL_WINDOW_BACK_DAYS = 30;
export const PULL_WINDOW_AHEAD_DAYS = 120;
export const FULL_RESYNC_EVERY_DAYS = 7;

export type SyncSummary = {
  pulled: { created: number; updated: number; cancelled: number; linked: number; skipped: number };
  pushed: { created: number; updated: number; deleted: number };
  fullSync: boolean;
  primary: boolean;
};

export function hasScope(conn: Connection, scope: string): boolean {
  return (conn.scopes || '').split(/\s+/).includes(scope);
}

export function eventBodyFor(row: Row): Record<string, unknown> {
  const day = row.starts_at.slice(0, 10);
  return {
    summary: row.summary || 'Truffl',
    description: row.description || '',
    location: row.location || '',
    start: { dateTime: row.starts_at, timeZone: TIME_ZONE },
    end: { dateTime: row.ends_at, timeZone: TIME_ZONE },
    extendedProperties: { private: { truffl_kind: row.kind, truffl_id: row.id } },
    source: { title: 'Truffl', url: `${SITE}/schedule/?d=${day}` },
  };
}

function eventStart(ev: GEvent): number | null {
  const s = ev.start?.dateTime || ev.start?.date;
  if (!s) return null;
  const t = Date.parse(s);
  return Number.isNaN(t) ? null : t;
}

type Ctx = { google: GoogleApi; db: Db; userId: string; now: Date; conn: Connection };

async function ensureTrufflCalendar(ctx: Ctx): Promise<string> {
  const { google, db, userId, conn } = ctx;
  if (conn.truffl_calendar_id && (await google.calendarExists(conn.truffl_calendar_id))) {
    return conn.truffl_calendar_id;
  }
  // First connection, or the carer deleted the calendar in Google: make a new one and forget
  // every link that pointed at the old one (the push pass recreates the events).
  const created = await google.createCalendar(TRUFFL_CALENDAR_SUMMARY, TRUFFL_CALENDAR_DESCRIPTION, TIME_ZONE);
  if (conn.truffl_calendar_id) await db.deleteLinksForCalendar(userId, conn.truffl_calendar_id);
  conn.truffl_calendar_id = created.id;
  conn.sync_token_truffl = null;
  conn.last_full_sync_at = null;
  await db.updateConnection(userId, { truffl_calendar_id: created.id, sync_token_truffl: null, last_full_sync_at: null });
  return created.id;
}

async function pullCalendar(
  ctx: Ctx,
  calendarId: string,
  tokenField: 'sync_token_truffl' | 'sync_token_primary',
  forceFull: boolean,
  summary: SyncSummary,
): Promise<boolean> {
  const { google, db, userId, conn, now } = ctx;
  let syncToken: string | undefined = forceFull ? undefined : (conn[tokenField] || undefined);
  let pageToken: string | undefined;
  let full = !syncToken;
  const windowMin = now.getTime() - PULL_WINDOW_BACK_DAYS * DAY_MS;
  const windowMax = now.getTime() + PULL_WINDOW_AHEAD_DAYS * DAY_MS;
  let newToken: string | undefined;

  for (let guard = 0; guard < 50; guard++) {
    let res: ListResult;
    try {
      res = await google.listEvents(
        calendarId,
        syncToken
          ? { syncToken, pageToken }
          : { timeMin: new Date(windowMin).toISOString(), timeMax: new Date(windowMax).toISOString(), pageToken },
      );
    } catch (e) {
      // 410 Gone: the sync token expired. Start over with a full list of the window.
      if (e instanceof GoogleError && e.status === 410 && syncToken) {
        syncToken = undefined;
        pageToken = undefined;
        full = true;
        continue;
      }
      throw e;
    }
    for (const ev of res.items || []) {
      if (!ev.id) continue;
      // Anything outside the window is left alone (an incremental token can carry changes to
      // events years away).
      const t = eventStart(ev);
      if (ev.status !== 'cancelled' && t !== null && (t < windowMin || t > windowMax)) {
        summary.pulled.skipped++;
        continue;
      }
      const r = await db.applyEvent(userId, calendarId, ev);
      switch (r.action) {
        case 'duplicate':
          // A second Google event for a row we already mirror (a copy made in Google, or two
          // syncs racing on first push). Only ever on our own calendar; remove it.
          if (ev.status !== 'cancelled') await google.deleteEvent(calendarId, ev.id);
          summary.pulled.skipped++;
          break;
        case 'created': summary.pulled.created++; break;
        case 'updated': summary.pulled.updated++; break;
        case 'cancelled': summary.pulled.cancelled++; break;
        case 'linked': summary.pulled.linked++; break;
        default: summary.pulled.skipped++;
      }
    }
    if (res.nextPageToken) {
      pageToken = res.nextPageToken;
      continue;
    }
    newToken = res.nextSyncToken;
    break;
  }
  if (newToken) {
    conn[tokenField] = newToken;
    await db.updateConnection(userId, { [tokenField]: newToken } as Partial<Connection>);
  }
  return full;
}

/** Push one Truffl row to the Truffl calendar. Returns what happened, for the summary. */
async function pushRow(
  ctx: Ctx,
  calendarId: string,
  row: Row,
  link: Link | undefined,
): Promise<'created' | 'updated' | 'deleted' | 'skipped'> {
  const { google, db, userId, now } = ctx;
  const active = row.status === 'CONFIRMED';

  // Events pulled from the carer's main calendar are read-only copies (we only hold a
  // read scope there), so Truffl edits to those jobs stay in Truffl.
  if (link && link.google_calendar_id !== calendarId) return 'skipped';

  if (!active) {
    if (!link) return 'skipped';
    await google.deleteEvent(calendarId, link.google_event_id);
    await db.deleteLink(link.id);
    return 'deleted';
  }

  const body = eventBodyFor(row);
  if (link) {
    if (link.content_hash === row.content_hash) return 'skipped';
    try {
      const ev = await google.patchEvent(calendarId, link.google_event_id, body);
      await db.updateLink(link.id, { google_etag: ev.etag ?? null, content_hash: row.content_hash, last_pushed_at: now.toISOString() });
      return 'updated';
    } catch (e) {
      // The event vanished on the Google side without us hearing about it: make a new one.
      if (!(e instanceof GoogleError) || (e.status !== 404 && e.status !== 410)) throw e;
    }
  }
  const ev = await google.insertEvent(calendarId, body);
  await db.upsertLink({
    provider_user_id: userId,
    kind: row.kind,
    row_id: row.id,
    google_calendar_id: calendarId,
    google_event_id: ev.id,
    google_etag: ev.etag ?? null,
    content_hash: row.content_hash,
    origin: link?.origin ?? 'truffl',
    last_pushed_at: now.toISOString(),
    last_pulled_at: link?.last_pulled_at ?? null,
  });
  return 'created';
}

function linkKey(kind: Kind, rowId: string): string {
  return `${kind}:${rowId}`;
}

async function pushAll(ctx: Ctx, calendarId: string, summary: SyncSummary): Promise<void> {
  const { db, userId, google } = ctx;
  const rows = await db.syncRows(userId);
  const links = await db.listLinks(userId);
  const byKey = new Map(links.map((l) => [linkKey(l.kind, l.row_id), l]));
  for (const row of rows) {
    const outcome = await pushRow(ctx, calendarId, row, byKey.get(linkKey(row.kind, row.id)));
    if (outcome !== 'skipped') summary.pushed[outcome]++;
  }
  // Rows that were hard-deleted (a one-off job the carer removed) leave a link behind.
  for (const l of await db.orphanLinks(userId)) {
    if (l.google_calendar_id === calendarId) await google.deleteEvent(calendarId, l.google_event_id);
    await db.deleteLink(l.id);
    summary.pushed.deleted++;
  }
}

function emptySummary(): SyncSummary {
  return {
    pulled: { created: 0, updated: 0, cancelled: 0, linked: 0, skipped: 0 },
    pushed: { created: 0, updated: 0, deleted: 0 },
    fullSync: false,
    primary: false,
  };
}

/** Full two-way sync for one carer. Returns null when they are not connected. */
export async function syncUser(google: GoogleApi, db: Db, userId: string, now = new Date()): Promise<SyncSummary | null> {
  const conn = await db.getConnection(userId);
  if (!conn) return null;
  const ctx: Ctx = { google, db, userId, now, conn };
  const summary = emptySummary();

  const calendarId = await ensureTrufflCalendar(ctx);

  const lastFull = conn.last_full_sync_at ? Date.parse(conn.last_full_sync_at) : 0;
  const forceFull = !lastFull || now.getTime() - lastFull > FULL_RESYNC_EVERY_DAYS * DAY_MS;

  // Pull first so a Google-side edit lands before the push pass compares hashes.
  const wasFull = await pullCalendar(ctx, calendarId, 'sync_token_truffl', forceFull, summary);
  summary.fullSync = wasFull;

  if (conn.read_primary) {
    if (!hasScope(conn, SCOPE_EVENTS_READONLY)) {
      throw new ReconnectError('Truffl needs permission to read your main calendar. Reconnect Google to allow it.');
    }
    await pullCalendar(ctx, 'primary', 'sync_token_primary', forceFull, summary);
    summary.primary = true;
  }

  await pushAll(ctx, calendarId, summary);

  await db.updateConnection(userId, {
    status: 'connected',
    last_error: null,
    last_synced_at: now.toISOString(),
    ...(wasFull ? { last_full_sync_at: now.toISOString() } : {}),
  });
  return summary;
}

export type PushItem = { kind: Kind; row_id: string; deleted?: boolean };

/** Targeted push after a Truffl-side change (the DB trigger path). */
export async function pushItems(google: GoogleApi, db: Db, userId: string, items: PushItem[], now = new Date()): Promise<SyncSummary | null> {
  const conn = await db.getConnection(userId);
  if (!conn) return null;
  // Not set up yet (the callback is still running the first sync): let the poll catch it.
  if (!conn.truffl_calendar_id) return null;
  const ctx: Ctx = { google, db, userId, now, conn };
  const calendarId = conn.truffl_calendar_id;
  const summary = emptySummary();
  const rows = await db.syncRows(userId);
  const links = await db.listLinks(userId);
  const rowByKey = new Map(rows.map((r) => [linkKey(r.kind, r.id), r]));
  const linkByKey = new Map(links.map((l) => [linkKey(l.kind, l.row_id), l]));
  for (const item of items) {
    if (item.kind !== 'job' && item.kind !== 'booking') continue;
    const key = linkKey(item.kind, item.row_id);
    const link = linkByKey.get(key);
    const row = rowByKey.get(key);
    if (item.deleted || !row) {
      // Gone, or outside the sync window: nothing to mirror. Only a hard delete removes the
      // Google event; a row that merely aged out of the window keeps its history.
      if (link && item.deleted && link.google_calendar_id === calendarId) {
        await google.deleteEvent(calendarId, link.google_event_id);
        await db.deleteLink(link.id);
        summary.pushed.deleted++;
      }
      continue;
    }
    const outcome = await pushRow(ctx, calendarId, row, link);
    if (outcome !== 'skipped') summary.pushed[outcome]++;
  }
  return summary;
}
