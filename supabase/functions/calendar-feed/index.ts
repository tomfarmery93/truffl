// Calendar feed (GitHub #158): a private ICS subscription URL per carer.
//
//   GET /functions/v1/calendar-feed?token=<provider_profiles.calendar_token>
//
// Google Calendar, Apple Calendar and Outlook poll this on their own schedule with no
// auth header, so verify_jwt is DISABLED for this function (like stripe-api / geo-api) and
// the token IS the credential: 64 hex chars, unique per carer, rotatable from /schedule/.
// Data comes through public.calendar_feed_events(p_token), a SECURITY DEFINER function
// whose EXECUTE is granted to service_role only, so the browser can never call it and an
// unknown token simply yields an empty calendar (no enumeration signal beyond "empty").
//
// Output is RFC 5545: UTC timestamps, CRLF line endings, 75-octet folding, escaped text.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const sb = createClient(SUPABASE_URL, SERVICE_ROLE);

type FeedRow = {
  uid: string;
  kind: 'job' | 'booking';
  summary: string | null;
  description: string | null;
  location: string | null;
  starts_at: string;
  ends_at: string;
  status: 'CONFIRMED' | 'TENTATIVE' | 'CANCELLED';
  updated_at: string | null;
};

const TOKEN_RE = /^[0-9a-f]{32,128}$/i;

function icsDate(iso: string): string {
  // 20260911T013000Z
  return new Date(iso).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
}

function icsText(s: string | null | undefined): string {
  return (s ?? '')
    .replace(/\\/g, '\\\\')
    .replace(/\r?\n/g, '\\n')
    .replace(/;/g, '\;')
    .replace(/,/g, '\\,');
}

// RFC 5545 3.1: lines longer than 75 octets are folded with CRLF + one space. Fold on
// UTF-8 byte length so multi-byte characters are never split.
function fold(line: string): string {
  const enc = new TextEncoder();
  if (enc.encode(line).length <= 75) return line;
  const out: string[] = [];
  let cur = '';
  for (const ch of line) {
    const next = cur + ch;
    const limit = out.length === 0 ? 75 : 74; // continuation lines start with a space
    if (enc.encode(next).length > limit) {
      out.push(cur);
      cur = ch;
    } else {
      cur = next;
    }
  }
  if (cur) out.push(cur);
  return out.join('\r\n ');
}

function buildCalendar(rows: FeedRow[]): string {
  const now = icsDate(new Date().toISOString());
  const lines: string[] = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Truffl Pets//Carer schedule//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'X-WR-CALNAME:Truffl schedule',
    'X-WR-TIMEZONE:Australia/Sydney',
    // Hint to clients that poll the feed: refresh every 30 minutes.
    'REFRESH-INTERVAL;VALUE=DURATION:PT30M',
    'X-PUBLISHED-TTL:PT30M',
  ];
  for (const r of rows) {
    lines.push('BEGIN:VEVENT');
    lines.push(`UID:${r.uid}@trufflpets.com`);
    lines.push(`DTSTAMP:${now}`);
    lines.push(`DTSTART:${icsDate(r.starts_at)}`);
    lines.push(`DTEND:${icsDate(r.ends_at)}`);
    lines.push(`SUMMARY:${icsText(r.summary || 'Truffl')}`);
    if (r.description) lines.push(`DESCRIPTION:${icsText(r.description)}`);
    if (r.location) lines.push(`LOCATION:${icsText(r.location)}`);
    lines.push(`STATUS:${r.status}`);
    if (r.updated_at) lines.push(`LAST-MODIFIED:${icsDate(r.updated_at)}`);
    lines.push(`URL:https://trufflpets.com/schedule/?d=${r.starts_at.slice(0, 10)}`);
    lines.push(`CATEGORIES:${r.kind === 'booking' ? 'Truffl booking' : 'Own client'}`);
    lines.push('END:VEVENT');
  }
  lines.push('END:VCALENDAR');
  return lines.map(fold).join('\r\n') + '\r\n';
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET, OPTIONS' } });
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return new Response('Method not allowed', { status: 405 });
  }

  const url = new URL(req.url);
  const token = (url.searchParams.get('token') || '').trim();
  if (!TOKEN_RE.test(token)) {
    return new Response('Missing or malformed token', { status: 400 });
  }

  const { data, error } = await sb.rpc('calendar_feed_events', { p_token: token });
  if (error) {
    console.error('calendar_feed_events', error.message);
    return new Response('Feed unavailable', { status: 500 });
  }

  const body = buildCalendar((data ?? []) as FeedRow[]);
  return new Response(req.method === 'HEAD' ? null : body, {
    status: 200,
    headers: {
      'Content-Type': 'text/calendar; charset=utf-8',
      'Content-Disposition': 'inline; filename="truffl.ics"',
      'Cache-Control': 'private, max-age=300',
      'Access-Control-Allow-Origin': '*',
    },
  });
});
