-- Supply-side Phase 2, Google Calendar two-way sync (GitHub #160, C3).
--
-- Shape:
--   * google_calendar_connections  one row per connected carer: which Google account, the id
--                                  of the "Truffl" calendar we created in it, whether they also
--                                  want events from their main calendar pulled in, sync tokens,
--                                  status. Owner-readable, never contains a credential.
--   * private.google_tokens        the OAuth refresh/access tokens. Not exposed to PostgREST;
--                                  the edge function reaches them through service_role RPCs.
--   * calendar_event_links         the mapping between a Truffl row (job or booking) and the
--                                  Google event that mirrors it, with the etag we last saw and
--                                  a hash of the content we last synced. Both are what stops
--                                  the two sides ping-ponging the same edit forever.
--   * push triggers                a job or booking change POSTs to the google-calendar edge
--                                  function (pg_net, fire-and-forget, same plumbing as the
--                                  charge-on-completion trigger) so Truffl edits land in Google
--                                  within seconds. Google edits come back on a ten-minute
--                                  pg_cron poll that also reconciles anything a push missed.
--   * service RPCs                 google_sync_rows (what to push), google_apply_event (write a
--                                  Google event into the job book), google_orphan_links,
--                                  google_tokens_*. All service_role only.
--
-- Conflict rule (ticket): the most recently edited side wins; cancellations propagate.
-- Bookings are mirrored read-only: a booking's Google event is overwritten from Truffl on the
-- next sync, and editing it in Google changes nothing on the marketplace side.

-- ── 1. Jobs can originate in Google ─────────────────────────────────────────
alter table public.jobs drop constraint if exists jobs_source_check;
alter table public.jobs add constraint jobs_source_check
  check (source in ('manual','series','import','google'));

-- ── 2. Connections ──────────────────────────────────────────────────────────
create table if not exists public.google_calendar_connections (
  provider_user_id    uuid primary key references public.users(id) on delete cascade,
  google_email        text,
  truffl_calendar_id  text,
  read_primary        boolean not null default false,   -- also pull the carer's main calendar
  scopes              text not null default '',         -- space-separated, as granted by Google
  status              text not null default 'connected' check (status in ('connected','error')),
  last_error          text,
  last_synced_at      timestamptz,
  last_full_sync_at   timestamptz,
  sync_token_truffl   text,                             -- Google incremental sync tokens
  sync_token_primary  text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

drop trigger if exists set_google_calendar_connections_updated_at on public.google_calendar_connections;
create trigger set_google_calendar_connections_updated_at before update on public.google_calendar_connections
  for each row execute function public.set_updated_at();

alter table public.google_calendar_connections enable row level security;
drop policy if exists google_calendar_connections_owner_select on public.google_calendar_connections;
create policy google_calendar_connections_owner_select on public.google_calendar_connections
  for select using (provider_user_id = (select auth.uid()));
-- No insert/update/delete policies for users: every write goes through the edge function.
revoke all on public.google_calendar_connections from public, anon;
grant select on public.google_calendar_connections to authenticated;
grant select, insert, update, delete on public.google_calendar_connections to service_role;

-- ── 3. Tokens, out of PostgREST's reach ─────────────────────────────────────
create schema if not exists private;

create table if not exists private.google_tokens (
  provider_user_id   uuid primary key references public.users(id) on delete cascade,
  refresh_token      text not null,
  access_token       text,
  access_expires_at  timestamptz,
  updated_at         timestamptz not null default now()
);
alter table private.google_tokens enable row level security;
-- no policies: only the definer functions below touch it.

create or replace function public.google_tokens_get(p_user uuid)
returns jsonb
language sql
security definer
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'refresh_token', t.refresh_token,
    'access_token', t.access_token,
    'access_expires_at', t.access_expires_at)
  from private.google_tokens t
  where t.provider_user_id = p_user;
$$;

create or replace function public.google_tokens_set(
  p_user uuid, p_refresh_token text, p_access_token text, p_access_expires_at timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.google_tokens (provider_user_id, refresh_token, access_token, access_expires_at)
  values (p_user, p_refresh_token, p_access_token, p_access_expires_at)
  on conflict (provider_user_id) do update
    set refresh_token     = coalesce(nullif(excluded.refresh_token, ''), private.google_tokens.refresh_token),
        access_token      = excluded.access_token,
        access_expires_at = excluded.access_expires_at,
        updated_at        = now();
end;
$$;

create or replace function public.google_tokens_delete(p_user uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from private.google_tokens where provider_user_id = p_user;
$$;

revoke all on function public.google_tokens_get(uuid) from public, anon, authenticated;
revoke all on function public.google_tokens_set(uuid, text, text, timestamptz) from public, anon, authenticated;
revoke all on function public.google_tokens_delete(uuid) from public, anon, authenticated;
grant execute on function public.google_tokens_get(uuid) to service_role;
grant execute on function public.google_tokens_set(uuid, text, text, timestamptz) to service_role;
grant execute on function public.google_tokens_delete(uuid) to service_role;

-- ── 4. Event links ──────────────────────────────────────────────────────────
create table if not exists public.calendar_event_links (
  id                  uuid primary key default gen_random_uuid(),
  provider_user_id    uuid not null references public.users(id) on delete cascade,
  kind                text not null check (kind in ('job','booking')),
  row_id              uuid not null,
  google_calendar_id  text not null,
  google_event_id     text not null,
  google_etag         text,
  content_hash        text,
  origin              text not null default 'truffl' check (origin in ('truffl','google')),
  last_pushed_at      timestamptz,
  last_pulled_at      timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (provider_user_id, kind, row_id),
  unique (provider_user_id, google_event_id)
);
create index if not exists idx_calendar_event_links_row on public.calendar_event_links (kind, row_id);

drop trigger if exists set_calendar_event_links_updated_at on public.calendar_event_links;
create trigger set_calendar_event_links_updated_at before update on public.calendar_event_links
  for each row execute function public.set_updated_at();

alter table public.calendar_event_links enable row level security;
drop policy if exists calendar_event_links_owner_select on public.calendar_event_links;
create policy calendar_event_links_owner_select on public.calendar_event_links
  for select using (provider_user_id = (select auth.uid()));
revoke all on public.calendar_event_links from public, anon;
grant select on public.calendar_event_links to authenticated;
grant select, insert, update, delete on public.calendar_event_links to service_role;

-- ── 5. One feed query for the ICS feed and the Google push ──────────────────
-- The ICS feed's row query, lifted out of calendar_feed_events so the Google sync pushes
-- exactly what the feed publishes. Two additions: the row id, and content_hash, a digest of
-- the fields that reach Google. A job that came from Google keeps its own title as the
-- summary (the carer typed it there; rewriting it as "Walk <title>" would be rude).
create or replace function private.feed_rows(p_user_id uuid)
returns table (
  uid          text,
  kind         text,
  id           uuid,
  summary      text,
  description  text,
  location     text,
  starts_at    timestamptz,
  ends_at      timestamptz,
  status       text,
  updated_at   timestamptz,
  content_hash text
)
language sql
security definer
stable
set search_path = ''
as $$
  with rows as (
    select
      'job-' || j.id::text                                                as uid,
      'job'::text                                                         as kind,
      j.id,
      case when j.source = 'google' and nullif(btrim(j.title), '') is not null then btrim(j.title) else
        concat_ws(' ',
          case j.service_type when 'dog_walking' then 'Walk' when 'dog_sitting' then 'Sitting'
                              when 'dog_boarding' then 'Boarding' when 'pet_sitting' then 'Visit' else 'Job' end,
          coalesce(nullif(btrim(concat_ws(' ', c.first_name, c.last_name)), ''), nullif(btrim(j.title), '')),
          case when pn.names is not null then '(' || pn.names || ')' end)
      end                                                                 as summary,
      j.notes                                                             as description,
      concat_ws(', ', c.address, c.suburb, c.postcode)                    as location,
      j.starts_at, j.ends_at,
      case j.status when 'cancelled' then 'CANCELLED' else 'CONFIRMED' end as status,
      j.updated_at
    from public.jobs j
    left join public.clients c on c.id = j.client_id
    left join lateral (
      select string_agg(cp.name, ', ' order by cp.name) as names
        from public.job_pets jp join public.client_pets cp on cp.id = jp.client_pet_id
       where jp.job_id = j.id
    ) pn on true
    where j.provider_user_id = p_user_id
      and j.starts_at between now() - interval '30 days' and now() + interval '90 days'

    union all

    select
      'booking-' || b.id::text,
      'booking',
      b.id,
      concat_ws(' ',
        case when b.is_meet_and_greet then 'Meet & greet' else
          case coalesce(ps.service_type, 'dog_walking')
            when 'dog_walking' then 'Walk' when 'dog_sitting' then 'Sitting'
            when 'dog_boarding' then 'Boarding' when 'pet_sitting' then 'Visit' else 'Booking' end
        end,
        nullif(btrim(concat_ws(' ', cu.first_name, cu.last_name)), ''),
        case when pn.names is not null then '(' || pn.names || ')' end,
        case when b.status = 'pending' then '[request]' end,
        '· Truffl'),
      b.customer_notes,
      case when b.status in ('confirmed','in_progress','completed')
           then concat_ws(', ', cp.address, cp.suburb, cp.postcode)
           else cp.suburb end,
      b.scheduled_at,
      coalesce(b.ends_at, b.window_end_at,
               b.scheduled_at + make_interval(mins => coalesce(b.duration_mins, ps.duration_mins, 60))),
      case b.status when 'cancelled' then 'CANCELLED' when 'pending' then 'TENTATIVE' else 'CONFIRMED' end,
      b.updated_at
    from public.provider_profiles pp
    join public.bookings b on b.provider_id = pp.id
    join public.customer_profiles cp on cp.id = b.customer_id
    join public.users cu on cu.id = cp.user_id
    left join public.provider_services ps on ps.id = b.service_id
    left join lateral (
      select coalesce(
        (select string_agg(p.name, ', ' order by p.name)
           from public.booking_pets bp join public.pets p on p.id = bp.pet_id where bp.booking_id = b.id),
        (select p.name from public.pets p where p.id = b.pet_id)) as names
    ) pn on true
    where pp.user_id = p_user_id
      and b.scheduled_at between now() - interval '30 days' and now() + interval '90 days'
  )
  select r.uid, r.kind, r.id, r.summary, r.description, r.location, r.starts_at, r.ends_at, r.status, r.updated_at,
         md5(concat_ws('|', r.summary, r.description, r.location,
                       to_char(r.starts_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                       to_char(r.ends_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                       r.status)) as content_hash
  from rows r;
$$;

-- Same signature and output as before; only the body moved.
create or replace function public.calendar_feed_events(p_token text)
returns table (
  uid          text,
  kind         text,
  summary      text,
  description  text,
  location     text,
  starts_at    timestamptz,
  ends_at      timestamptz,
  status       text,
  updated_at   timestamptz
)
language sql
security definer
stable
set search_path = ''
as $$
  select r.uid, r.kind, r.summary, r.description, r.location, r.starts_at, r.ends_at, r.status, r.updated_at
    from public.provider_profiles pp
    cross join lateral private.feed_rows(pp.user_id) r
   where p_token is not null and length(p_token) >= 32 and pp.calendar_token = p_token;
$$;
revoke all on function public.calendar_feed_events(text) from public, anon, authenticated;
grant execute on function public.calendar_feed_events(text) to service_role;

-- What the sync pushes for one carer. service_role only (the edge function).
create or replace function public.google_sync_rows(p_user uuid)
returns table (
  kind         text,
  id           uuid,
  summary      text,
  description  text,
  location     text,
  starts_at    timestamptz,
  ends_at      timestamptz,
  status       text,
  updated_at   timestamptz,
  content_hash text
)
language sql
security definer
stable
set search_path = ''
as $$
  select r.kind, r.id, r.summary, r.description, r.location, r.starts_at, r.ends_at, r.status, r.updated_at, r.content_hash
    from private.feed_rows(p_user) r;
$$;
revoke all on function public.google_sync_rows(uuid) from public, anon, authenticated;
grant execute on function public.google_sync_rows(uuid) to service_role;

-- Links whose Truffl row no longer exists (the job was hard-deleted): the sync deletes the
-- Google event and then the link.
create or replace function public.google_orphan_links(p_user uuid)
returns setof public.calendar_event_links
language sql
security definer
stable
set search_path = ''
as $$
  select l.* from public.calendar_event_links l
   where l.provider_user_id = p_user
     and ((l.kind = 'job'     and not exists (select 1 from public.jobs j     where j.id = l.row_id))
       or (l.kind = 'booking' and not exists (select 1 from public.bookings b where b.id = l.row_id)));
$$;
revoke all on function public.google_orphan_links(uuid) from public, anon, authenticated;
grant execute on function public.google_orphan_links(uuid) to service_role;

-- ── 6. A Google event lands in the job book ─────────────────────────────────
-- Called once per event the poll receives. Returns {action, job_id}:
--   skipped     not ours to change (a booking mirror, an unchanged etag, a Truffl edit that is
--               newer than the Google one, a cancelled event we never had)
--   linked      a Truffl event whose link row was lost; re-attached, nothing else changed
--   duplicate   a Truffl event whose row is already linked to another event; the caller
--               deletes it from Google
--   created     a new job (source 'google'), client matched by name where possible
--   updated     times / notes (and the title for Google-born jobs) copied onto the job
--   cancelled   the job is cancelled because the event was deleted in Google
create or replace function public.google_apply_event(p_user uuid, p_calendar_id text, p_event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_eid        text := p_event->>'id';
  v_etag       text := p_event->>'etag';
  v_status     text := coalesce(p_event->>'status', 'confirmed');
  v_summary    text := nullif(btrim(coalesce(p_event->>'summary', '')), '');
  v_desc       text := nullif(btrim(coalesce(p_event->>'description', '')), '');
  v_ical       text := p_event->>'iCalUID';
  v_updated    timestamptz := nullif(p_event->>'updated', '')::timestamptz;
  v_t_kind     text := p_event->'extendedProperties'->'private'->>'truffl_kind';
  v_t_id       uuid;
  v_starts     timestamptz;
  v_ends       timestamptz;
  v_link       public.calendar_event_links;
  v_job        public.jobs;
  v_client_id  uuid;
  v_service    text;
  v_hash       text;
  v_now        timestamptz := now();
begin
  if v_eid is null then return jsonb_build_object('action', 'skipped', 'reason', 'no id'); end if;

  -- Times. Timed events carry dateTime (with offset); all-day events carry date, which we
  -- read as Sydney-local midnight to the (exclusive) end date.
  if p_event->'start'->>'dateTime' is not null then
    v_starts := (p_event->'start'->>'dateTime')::timestamptz;
    v_ends   := (p_event->'end'->>'dateTime')::timestamptz;
  elsif p_event->'start'->>'date' is not null then
    v_starts := ((p_event->'start'->>'date')::date::timestamp) at time zone 'Australia/Sydney';
    v_ends   := (coalesce((p_event->'end'->>'date')::date, (p_event->'start'->>'date')::date + 1)::timestamp) at time zone 'Australia/Sydney';
  end if;
  if v_ends is not null and v_starts is not null and v_ends <= v_starts then
    v_ends := v_starts + interval '1 hour';
  end if;

  begin v_t_id := (p_event->'extendedProperties'->'private'->>'truffl_id')::uuid; exception when others then v_t_id := null; end;

  select * into v_link from public.calendar_event_links
   where provider_user_id = p_user and google_event_id = v_eid;

  -- A Truffl-born event whose link row is gone: re-attach rather than duplicate. If the row
  -- is already linked to a different event (a copy made in Google, or two syncs racing), the
  -- caller deletes this one.
  if v_link.id is null and v_t_kind in ('job','booking') and v_t_id is not null then
    if exists (select 1 from public.calendar_event_links
                where provider_user_id = p_user and kind = v_t_kind and row_id = v_t_id and google_event_id <> v_eid) then
      return jsonb_build_object('action', 'duplicate', 'event_id', v_eid);
    end if;
    if (v_t_kind = 'job' and exists (select 1 from public.jobs where id = v_t_id and provider_user_id = p_user))
       or (v_t_kind = 'booking' and exists (
             select 1 from public.bookings b join public.provider_profiles pp on pp.id = b.provider_id
              where b.id = v_t_id and pp.user_id = p_user)) then
      insert into public.calendar_event_links (provider_user_id, kind, row_id, google_calendar_id, google_event_id, google_etag, origin, last_pulled_at)
      values (p_user, v_t_kind, v_t_id, p_calendar_id, v_eid, v_etag, 'truffl', v_now)
      on conflict (provider_user_id, kind, row_id) do update
        set google_event_id = excluded.google_event_id, google_calendar_id = excluded.google_calendar_id,
            google_etag = excluded.google_etag, last_pulled_at = excluded.last_pulled_at
      returning * into v_link;
      -- Fall through only for a cancellation; a live event is reconciled by the push pass.
      if v_status <> 'cancelled' then return jsonb_build_object('action', 'linked', 'job_id', v_t_id); end if;
    else
      return jsonb_build_object('action', 'skipped', 'reason', 'truffl row gone');
    end if;
  end if;

  -- Bookings are mirrored one way. The push pass restores anything edited in Google.
  if v_link.kind = 'booking' then
    return jsonb_build_object('action', 'skipped', 'reason', 'booking');
  end if;

  -- Deleted in Google.
  if v_status = 'cancelled' then
    if v_link.id is null then return jsonb_build_object('action', 'skipped', 'reason', 'unknown cancelled'); end if;
    update public.jobs set status = 'cancelled'
     where id = v_link.row_id and provider_user_id = p_user and status <> 'cancelled';
    select r.content_hash into v_hash from private.feed_rows(p_user) r where r.kind = 'job' and r.id = v_link.row_id;
    update public.calendar_event_links
       set google_etag = v_etag, content_hash = v_hash, last_pulled_at = v_now
     where id = v_link.id;
    return jsonb_build_object('action', 'cancelled', 'job_id', v_link.row_id);
  end if;

  if v_starts is null or v_ends is null then
    return jsonb_build_object('action', 'skipped', 'reason', 'no times');
  end if;

  -- Known event.
  if v_link.id is not null then
    if v_link.google_etag is not distinct from v_etag then
      return jsonb_build_object('action', 'skipped', 'reason', 'unchanged');
    end if;
    select * into v_job from public.jobs where id = v_link.row_id and provider_user_id = p_user;
    if v_job.id is null then
      delete from public.calendar_event_links where id = v_link.id;
      return jsonb_build_object('action', 'skipped', 'reason', 'job gone');
    end if;
    -- Most recent edit wins: a Truffl change newer than both the last sync and the Google
    -- edit stays, and the push pass overwrites Google.
    if v_job.updated_at > coalesce(greatest(v_link.last_pulled_at, v_link.last_pushed_at), '-infinity'::timestamptz)
       and v_updated is not null and v_job.updated_at > v_updated then
      return jsonb_build_object('action', 'skipped', 'reason', 'truffl newer');
    end if;
    update public.jobs
       set starts_at = v_starts,
           ends_at   = v_ends,
           notes     = case when v_link.origin = 'google' or v_desc is not null then v_desc else notes end,
           title     = case when v_link.origin = 'google' then coalesce(v_summary, title) else title end,
           status    = case when status = 'cancelled' then 'scheduled' else status end
     where id = v_job.id;
    select r.content_hash into v_hash from private.feed_rows(p_user) r where r.kind = 'job' and r.id = v_job.id;
    update public.calendar_event_links
       set google_etag = v_etag, content_hash = v_hash, last_pulled_at = v_now
     where id = v_link.id;
    return jsonb_build_object('action', 'updated', 'job_id', v_job.id);
  end if;

  -- New event. First, was it already imported from an .ics export of the same calendar?
  -- The import keys jobs on the ICS UID (plus a recurrence stamp for instances).
  if v_ical is not null then
    select * into v_job from public.jobs
     where provider_user_id = p_user
       and (external_uid = v_ical or (external_uid like v_ical || ':%' and abs(extract(epoch from (starts_at - v_starts))) < 120))
     order by abs(extract(epoch from (starts_at - v_starts))) limit 1;
  end if;

  if v_job.id is null then
    -- Client by name: the longest client name (or first name, at least three letters) that
    -- appears in the title wins. Same rule as the .ics import in /schedule/.
    select c.id into v_client_id
      from public.clients c
     where c.provider_user_id = p_user and c.is_archived = false and v_summary is not null
       and (
         (length(btrim(concat_ws(' ', c.first_name, c.last_name))) >= 3
          and position(lower(btrim(concat_ws(' ', c.first_name, c.last_name))) in lower(v_summary)) > 0)
         or (length(coalesce(c.first_name, '')) >= 3 and position(lower(c.first_name) in lower(v_summary)) > 0)
         or exists (select 1 from public.client_pets cp where cp.client_id = c.id and cp.is_active
                      and length(cp.name) >= 3 and position(lower(cp.name) in lower(v_summary)) > 0))
     order by length(btrim(concat_ws(' ', c.first_name, c.last_name))) desc
     limit 1;

    v_service := case
      when lower(coalesce(v_summary, '')) ~ '(board|overnight|stay)' then 'dog_boarding'
      when lower(coalesce(v_summary, '')) ~ '(sit|visit|drop.?in|feed)' then 'dog_sitting'
      else 'dog_walking' end;

    insert into public.jobs (provider_user_id, client_id, title, service_type, starts_at, ends_at, notes, source, external_uid)
    values (p_user, v_client_id, coalesce(v_summary, 'Google Calendar event'), v_service, v_starts, v_ends, v_desc, 'google', null)
    returning * into v_job;

    if v_client_id is not null then
      insert into public.job_pets (job_id, client_pet_id)
      select v_job.id, cp.id from public.client_pets cp where cp.client_id = v_client_id and cp.is_active
      on conflict do nothing;
    end if;
  end if;

  select r.content_hash into v_hash from private.feed_rows(p_user) r where r.kind = 'job' and r.id = v_job.id;
  insert into public.calendar_event_links (provider_user_id, kind, row_id, google_calendar_id, google_event_id, google_etag, content_hash, origin, last_pulled_at)
  values (p_user, 'job', v_job.id, p_calendar_id, v_eid, v_etag, v_hash, 'google', v_now)
  on conflict (provider_user_id, kind, row_id) do update
    set google_event_id = excluded.google_event_id, google_calendar_id = excluded.google_calendar_id,
        google_etag = excluded.google_etag, content_hash = excluded.content_hash, last_pulled_at = excluded.last_pulled_at;
  return jsonb_build_object('action', 'created', 'job_id', v_job.id);
end;
$$;
revoke all on function public.google_apply_event(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.google_apply_event(uuid, text, jsonb) to service_role;

-- ── 7. Push: Truffl changes reach Google within seconds ─────────────────────
-- Reuses private.stripe_config (function_base_url + shared webhook_secret) exactly like
-- private.charge_booking. Nothing is posted for carers without a live connection.
create or replace function private.google_calendar_push(p_user uuid, p_kind text, p_row_id uuid, p_deleted boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare cfg private.stripe_config;
begin
  if p_user is null then return; end if;
  if not exists (select 1 from public.google_calendar_connections
                  where provider_user_id = p_user and status = 'connected') then
    return;
  end if;
  select * into cfg from private.stripe_config where id = 1 and enabled = true;
  if cfg.function_base_url is null then return; end if;
  perform net.http_post(
    url := cfg.function_base_url || '/google-calendar',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', cfg.webhook_secret),
    body := jsonb_build_object('action', 'push', 'provider_user_id', p_user,
                               'items', jsonb_build_array(jsonb_build_object('kind', p_kind, 'row_id', p_row_id, 'deleted', p_deleted)))
  );
end;
$$;

create or replace function private.tg_google_push_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if TG_OP = 'DELETE' then
    begin perform private.google_calendar_push(OLD.provider_user_id, 'job', OLD.id, true);
    exception when others then null; end;
    return OLD;
  end if;
  if TG_OP = 'UPDATE'
     and (OLD.title, OLD.client_id, OLD.service_type, OLD.starts_at, OLD.ends_at, OLD.status, OLD.notes)
         is not distinct from
         (NEW.title, NEW.client_id, NEW.service_type, NEW.starts_at, NEW.ends_at, NEW.status, NEW.notes) then
    return NEW;   -- a paid_at / share_token / completed_at change does not reach the calendar
  end if;
  begin perform private.google_calendar_push(NEW.provider_user_id, 'job', NEW.id, false);
  exception when others then null; end;
  return NEW;
end;
$$;
drop trigger if exists trg_google_push_job on public.jobs;
create trigger trg_google_push_job after insert or update or delete on public.jobs
  for each row execute function private.tg_google_push_job();

create or replace function private.tg_google_push_booking()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_user uuid;
begin
  if TG_OP = 'DELETE' then
    select user_id into v_user from public.provider_profiles where id = OLD.provider_id;
    begin perform private.google_calendar_push(v_user, 'booking', OLD.id, true);
    exception when others then null; end;
    return OLD;
  end if;
  if TG_OP = 'UPDATE'
     and (OLD.status, OLD.scheduled_at, OLD.ends_at, OLD.window_end_at, OLD.duration_mins, OLD.customer_notes, OLD.provider_id)
         is not distinct from
         (NEW.status, NEW.scheduled_at, NEW.ends_at, NEW.window_end_at, NEW.duration_mins, NEW.customer_notes, NEW.provider_id) then
    return NEW;
  end if;
  select user_id into v_user from public.provider_profiles where id = NEW.provider_id;
  begin perform private.google_calendar_push(v_user, 'booking', NEW.id, false);
  exception when others then null; end;
  return NEW;
end;
$$;
drop trigger if exists trg_google_push_booking on public.bookings;
create trigger trg_google_push_booking after insert or update or delete on public.bookings
  for each row execute function private.tg_google_push_booking();

-- ── 8. Poll: Google changes reach Truffl within ten minutes ─────────────────
create or replace function private.google_calendar_poll()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare cfg private.stripe_config;
begin
  if not exists (select 1 from public.google_calendar_connections where status = 'connected') then return; end if;
  select * into cfg from private.stripe_config where id = 1 and enabled = true;
  if cfg.function_base_url is null then return; end if;
  perform net.http_post(
    url := cfg.function_base_url || '/google-calendar',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', cfg.webhook_secret),
    body := jsonb_build_object('action', 'poll')
  );
end;
$$;

do $$
begin
  perform cron.unschedule('google-calendar-poll')
  where exists (select 1 from cron.job where jobname = 'google-calendar-poll');
end $$;
select cron.schedule('google-calendar-poll', '*/10 * * * *', $$select private.google_calendar_poll();$$);

-- ── 9. Account deletion: the connection goes too ────────────────────────────
-- google_calendar_connections, calendar_event_links and private.google_tokens all cascade from
-- public.users, but the sweep anonymises the user row rather than deleting it, so the three
-- rows are removed explicitly. The Google-side calendar is the carer's own and is left alone.
-- Full replacement of admin_delete_account (last changed in 20260912000000); the only new
-- lines are the three deletes marked "C3".
create or replace function public.admin_delete_account(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cp_id  uuid;
  v_pp_id  uuid;
  v_email  text;
  v_future integer;
  v_owed   integer;
  v_tag    text := replace(p_user_id::text, '-', '');
  v_pings  integer := 0;
  v_msgs   integer := 0;
  v_sessions uuid[];
  v_clients integer := 0;
begin
  select email into v_email from public.users where id = p_user_id;
  if v_email is null then
    raise exception 'No such user: %', p_user_id;
  end if;

  select id into v_cp_id from public.customer_profiles where user_id = p_user_id;
  select id into v_pp_id from public.provider_profiles where user_id = p_user_id;

  select count(*) into v_future
  from public.bookings b
  where b.status in ('pending', 'confirmed')
    and coalesce(b.ends_at, b.scheduled_at) > now()
    and ( (v_cp_id is not null and b.customer_id = v_cp_id)
       or (v_pp_id is not null and b.provider_id = v_pp_id) );
  if v_future > 0 then
    raise exception 'Cannot delete: % future booking(s) still scheduled', v_future;
  end if;

  select count(*) into v_owed
  from public.bookings b
  where b.status = 'completed'
    and coalesce(b.payment_status, 'unpaid') in ('unpaid', 'failed', 'processing')
    and ( (v_cp_id is not null and b.customer_id = v_cp_id)
       or (v_pp_id is not null and b.provider_id = v_pp_id) );
  if v_owed > 0 then
    raise exception 'Cannot delete: % completed booking(s) not yet settled', v_owed;
  end if;

  -- Delist first.
  if v_pp_id is not null then
    update public.provider_profiles
       set is_active = false, updated_at = now()
     where id = v_pp_id;
    update public.provider_services set is_available = false where provider_id = p_user_id;
  end if;

  -- PURGE: the trail.
  select array_agg(ws.id) into v_sessions
    from public.walk_sessions ws
    left join public.bookings b on b.id = ws.booking_id
   where ws.provider_id = p_user_id
      or (v_cp_id is not null and b.customer_id = v_cp_id)
      or (v_pp_id is not null and b.provider_id = v_pp_id);

  delete from public.gps_pings where walk_session_id = any(v_sessions);
  get diagnostics v_pings = row_count;

  update public.messages set body = '[deleted]' where sender_id = p_user_id;
  get diagnostics v_msgs = row_count;

  update public.walk_updates
     set message = null, photo_url = null
   where provider_id = p_user_id
      or walk_session_id = any(v_sessions);

  delete from public.booking_updates bu
   where bu.provider_user_id = p_user_id
      or (v_cp_id is not null and bu.booking_id in (select id from public.bookings where customer_id = v_cp_id));

  delete from public.notifications  where user_id = p_user_id;
  delete from public.system_messages where recipient_user_id = p_user_id;

  if v_cp_id is not null then
    delete from private.backup_access where customer_id = v_cp_id;
  end if;

  update public.search_misses set customer_id = null where customer_id = v_cp_id;

  -- Supply-side additions. A leaving carer's client book, series, jobs (and with them any
  -- job-backed walk sessions), templates and send log are deleted outright. A leaving owner
  -- is scrubbed from every carer's book where Truffl created the record.
  delete from private.google_tokens              where provider_user_id = p_user_id;  -- C3
  delete from public.calendar_event_links         where provider_user_id = p_user_id;  -- C3
  delete from public.google_calendar_connections  where provider_user_id = p_user_id;  -- C3
  delete from public.message_log       where provider_user_id = p_user_id;  -- D1
  delete from public.message_templates where provider_user_id = p_user_id;  -- D1
  delete from public.jobs        where provider_user_id = p_user_id;
  delete from public.job_series  where provider_user_id = p_user_id;
  delete from public.clients     where provider_user_id = p_user_id;
  get diagnostics v_clients = row_count;

  if v_cp_id is not null then
    update public.client_pets
       set name = 'Pet', breed = null, dob = null, weight_kg = null,
           behaviour_notes = null, medical_notes = null, vet_name = null, vet_phone = null,
           photo_url = null, is_active = false, linked_pet_id = null
     where client_id in (select id from public.clients where linked_customer_id = v_cp_id and source = 'truffl');
    update public.clients
       set first_name = 'Deleted', last_name = 'user', phone = null, email = null,
           address = null, suburb = null, postcode = null, notes = null, tags = '{}',
           is_archived = true, linked_customer_id = null
     where linked_customer_id = v_cp_id and source = 'truffl';
    update public.clients set linked_customer_id = null where linked_customer_id = v_cp_id;
  end if;

  -- ANONYMISE: the identity.
  if v_cp_id is not null then
    update public.customer_profiles
       set address = null, suburb = null, postcode = null,
           emergency_contact = null, emergency_phone = null,
           location = null,
           backup_cover_enabled = false,
           updated_at = now()
     where id = v_cp_id;

    update public.pets
       set name = 'Pet', breed = null, microchip_no = null,
           vet_name = null, vet_phone = null,
           medical_notes = null, behaviour_notes = null,
           photo_url = null, is_active = false
     where customer_id = v_cp_id;
  end if;

  if v_pp_id is not null then
    update public.provider_profiles
       set bio = null, suburb = null, postcode = null, abn = null,
           location = null, service_area = null,
           updated_at = now()
     where id = v_pp_id;
  end if;

  update public.carer_requests
     set contact_name = 'Deleted user', contact_email = null, contact_phone = null,
         note = null, dog_name = null, dog_breed = null, dog_temperament_note = null,
         search_params = null
   where (v_cp_id is not null and (customer_id = v_cp_id or converted_customer_id = v_cp_id))
      or lower(contact_email) = lower(v_email);

  update public.users
     set first_name = 'Deleted',
         last_name  = 'user',
         email      = 'deleted+' || v_tag || '@trufflpets.com',
         phone      = null,
         avatar_url = null,
         is_active  = false,
         is_admin   = false,
         updated_at = now()
   where id = p_user_id;

  return jsonb_build_object(
    'user_id',              p_user_id,
    'gps_pings_deleted',    v_pings,
    'messages_redacted',    v_msgs,
    'clients_deleted',      v_clients,
    'had_customer_profile', v_cp_id is not null,
    'had_provider_profile', v_pp_id is not null
  );
end;
$$;
revoke all on function public.admin_delete_account(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_account(uuid) to service_role;
