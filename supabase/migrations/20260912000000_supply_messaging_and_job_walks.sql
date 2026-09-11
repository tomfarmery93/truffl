-- Supply-side Phase 2, daily messaging (GitHub #162 D1, #163 D2, #157 B6).
--
--   B6  Walk sessions can belong to an own-client job as well as to a marketplace booking.
--       walk_sessions.job_id (exactly one of booking_id / job_id), the carer path on the GPS
--       read policy (it only had the booking path), and the walk emails skip job sessions
--       (there is no Truffl owner to email; the carer shares the report themselves).
--   D2  Shareable walk report: jobs.share_token, a carer-only RPC to create / rotate / revoke
--       it, and public.walk_report(token), an anon-callable definer RPC that returns the job,
--       pets, session, route and updates for a live token and nothing otherwise. Photos are
--       in the existing public walk-photos bucket (the owner-facing /track/ page already
--       serves them that way), so the token gates the listing, not the objects.
--   D1  message_templates (per-carer overrides and custom templates) and message_log (what
--       was sent, through which app). Deep links only; nothing is sent server-side.
--
-- Also: walk_updates now cascades from walk_sessions so deleting a job (and with it a
-- job-backed session) cannot fail on its updates, and the deletion sweep purges the
-- carer's templates and log.

-- ── 1. Walk sessions from jobs (B6) ──────────────────────────────────────────
alter table public.walk_sessions
  add column if not exists job_id uuid references public.jobs(id) on delete cascade;
alter table public.walk_sessions alter column booking_id drop not null;
alter table public.walk_sessions drop constraint if exists walk_sessions_one_subject;
alter table public.walk_sessions add constraint walk_sessions_one_subject
  check (((booking_id is not null)::int + (job_id is not null)::int) = 1);
create unique index if not exists idx_walk_sessions_job on public.walk_sessions (job_id) where job_id is not null;

alter table public.walk_updates drop constraint if exists walk_updates_walk_session_id_fkey;
alter table public.walk_updates add constraint walk_updates_walk_session_id_fkey
  foreign key (walk_session_id) references public.walk_sessions(id) on delete cascade;

-- The carer who owns the session reads its pings (job-backed sessions have no booking).
drop policy if exists gps_pings_parties_read on public.gps_pings;
create policy gps_pings_parties_read on public.gps_pings
  for select using (
    walk_session_id in (
      select ws.id
      from public.walk_sessions ws
      left join public.bookings b on b.id = ws.booking_id
      left join public.customer_profiles cp on cp.id = b.customer_id
      where ws.provider_id = (select auth.uid()) or cp.user_id = (select auth.uid())
    )
  );

-- Walk emails go to a Truffl owner; a job-backed session has none.
create or replace function private.tg_walk_started() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if NEW.status = 'active' and NEW.booking_id is not null then
    begin perform private.notify_email(jsonb_build_object('type','walk_started','walk_session_id',NEW.id));
    exception when others then null; end;
  end if;
  return NEW;
end; $$;
create or replace function private.tg_walk_completed() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if NEW.status = 'completed' and OLD.status is distinct from 'completed' and NEW.booking_id is not null then
    begin perform private.notify_email(jsonb_build_object('type','walk_completed','walk_session_id',NEW.id));
    exception when others then null; end;
  end if;
  return NEW;
end; $$;

-- ── 2. Shareable walk report (D2) ─────────────────────────────────────────────
alter table public.jobs
  add column if not exists share_token text,
  add column if not exists share_revoked_at timestamptz;
create unique index if not exists idx_jobs_share_token on public.jobs (share_token) where share_token is not null;

-- ensure: return the live token, minting one if needed. rotate: mint a new one (old links
-- stop working). revoke: turn the link off. Carer-only.
create or replace function public.job_share_link(p_job_id uuid, p_action text default 'ensure')
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner   uuid;
  v_token   text;
  v_revoked timestamptz;
begin
  select provider_user_id, share_token, share_revoked_at into v_owner, v_token, v_revoked
    from public.jobs where id = p_job_id;
  if v_owner is null or auth.uid() is null or v_owner <> auth.uid() then
    raise exception 'Not your job';
  end if;
  if p_action = 'revoke' then
    update public.jobs set share_revoked_at = now() where id = p_job_id;
    return null;
  end if;
  if p_action = 'rotate' or v_token is null or v_revoked is not null then
    v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
    update public.jobs set share_token = v_token, share_revoked_at = null where id = p_job_id;
  end if;
  return v_token;
end;
$$;
revoke all on function public.job_share_link(uuid, text) from public, anon;
grant execute on function public.job_share_link(uuid, text) to authenticated;

-- The report itself. Anon-callable by design: the token is the credential (same shape as
-- the calendar feed). Null for an unknown, malformed or revoked token.
create or replace function public.walk_report(p_token text)
returns jsonb
language sql
security definer
stable
set search_path = ''
as $$
  with j as (
    select j.*
      from public.jobs j
     where p_token is not null and length(p_token) >= 32
       and j.share_token = p_token and j.share_revoked_at is null
  ),
  ws as (
    select ws.* from public.walk_sessions ws, j
     where ws.job_id = j.id
     order by ws.created_at desc limit 1
  )
  select jsonb_build_object(
    'job', jsonb_build_object('id', j.id, 'starts_at', j.starts_at, 'ends_at', j.ends_at,
                              'service_type', j.service_type, 'status', j.status, 'notes', j.notes),
    'client_first', c.first_name,
    'carer_first', u.first_name,
    'pets', coalesce((select jsonb_agg(cp.name order by cp.name)
                        from public.job_pets jp join public.client_pets cp on cp.id = jp.client_pet_id
                       where jp.job_id = j.id), '[]'::jsonb),
    'session', (select jsonb_build_object('id', ws.id, 'status', ws.status, 'started_at', ws.started_at,
                                          'ended_at', ws.ended_at, 'distance_metres', ws.distance_metres,
                                          'duration_seconds', ws.duration_seconds) from ws),
    'pings', coalesce((select jsonb_agg(jsonb_build_object('lat', g.lat, 'lng', g.lng, 't', g.recorded_at) order by g.recorded_at)
                         from public.gps_pings g, ws where g.walk_session_id = ws.id), '[]'::jsonb),
    'updates', coalesce((select jsonb_agg(jsonb_build_object('update_type', wu.update_type, 'message', wu.message,
                                                             'photo_url', wu.photo_url, 'created_at', wu.created_at) order by wu.created_at)
                           from public.walk_updates wu, ws where wu.walk_session_id = ws.id), '[]'::jsonb)
  )
  from j
  left join public.clients c on c.id = j.client_id
  join public.users u on u.id = j.provider_user_id;
$$;
revoke all on function public.walk_report(text) from public;
grant execute on function public.walk_report(text) to anon, authenticated;

-- ── 3. Message templates and send log (D1) ────────────────────────────────────
create table if not exists public.message_templates (
  id                uuid primary key default gen_random_uuid(),
  provider_user_id  uuid not null references public.users(id) on delete cascade,
  key               text not null,
  label             text,
  body              text not null,
  sort_order        integer not null default 100,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint message_templates_provider_key unique (provider_user_id, key)
);
create table if not exists public.message_log (
  id                uuid primary key default gen_random_uuid(),
  provider_user_id  uuid not null references public.users(id) on delete cascade,
  client_id         uuid references public.clients(id) on delete set null,
  job_id            uuid references public.jobs(id) on delete set null,
  channel           text not null check (channel in ('whatsapp','sms','email','copy')),
  template_key      text,
  body              text,
  created_at        timestamptz not null default now()
);
create index if not exists idx_message_log_provider on public.message_log (provider_user_id, created_at desc);
create index if not exists idx_message_log_client on public.message_log (client_id);
create index if not exists idx_message_log_job on public.message_log (job_id);

drop trigger if exists set_message_templates_updated_at on public.message_templates;
create trigger set_message_templates_updated_at before update on public.message_templates
  for each row execute function public.set_updated_at();

alter table public.message_templates enable row level security;
alter table public.message_log enable row level security;

drop policy if exists message_templates_owner on public.message_templates;
create policy message_templates_owner on public.message_templates
  for all to authenticated
  using (provider_user_id = (select auth.uid()))
  with check (provider_user_id = (select auth.uid()));

drop policy if exists message_log_owner on public.message_log;
create policy message_log_owner on public.message_log
  for all to authenticated
  using (provider_user_id = (select auth.uid()))
  with check (provider_user_id = (select auth.uid()));

grant select, insert, update, delete on public.message_templates, public.message_log to authenticated, service_role;

-- ── 4. provider_schedule: walk status per row (appended column) ──────────────
create or replace view public.provider_schedule as
  select
    'job'::text                                   as kind,
    j.id,
    j.series_id,
    j.client_id,
    coalesce(
      nullif(btrim(concat_ws(' ', c.first_name, c.last_name)), ''),
      nullif(btrim(j.title), ''),
      'Job'
    )                                             as client_name,
    nullif(btrim(j.title), '')                    as title,
    (select string_agg(cp.name, ', ' order by cp.name)
       from public.job_pets jp join public.client_pets cp on cp.id = jp.client_pet_id
      where jp.job_id = j.id)                     as pet_names,
    j.service_type,
    j.starts_at,
    j.ends_at,
    j.status,
    j.price_cents,
    (j.paid_at is not null)                       as is_paid,
    j.payment_method,
    j.notes,
    j.source,
    false                                         as is_meet_and_greet,
    c.suburb,
    c.phone                                       as client_phone,
    j.updated_at,
    (select ws.status from public.walk_sessions ws where ws.job_id = j.id order by ws.created_at desc limit 1) as walk_status
  from public.jobs j
  left join public.clients c on c.id = j.client_id
  where j.provider_user_id = auth.uid()

  union all

  select
    'booking'::text                               as kind,
    b.id,
    b.series_id,
    cl.id                                         as client_id,
    nullif(btrim(concat_ws(' ', cu.first_name, cu.last_name)), '') as client_name,
    null::text                                    as title,
    coalesce(
      (select string_agg(p.name, ', ' order by p.name)
         from public.booking_pets bp join public.pets p on p.id = bp.pet_id
        where bp.booking_id = b.id),
      (select p.name from public.pets p where p.id = b.pet_id)
    )                                             as pet_names,
    coalesce(ps.service_type, 'dog_walking')      as service_type,
    b.scheduled_at                                as starts_at,
    coalesce(b.ends_at, b.window_end_at,
             b.scheduled_at + make_interval(mins => coalesce(b.duration_mins, ps.duration_mins, 60))) as ends_at,
    b.status,
    b.total_cents                                 as price_cents,
    (b.payment_status = 'paid')                   as is_paid,
    null::text                                    as payment_method,
    b.customer_notes                              as notes,
    'truffl'::text                                as source,
    b.is_meet_and_greet,
    cp.suburb,
    case when b.status in ('confirmed','in_progress','completed') then cu.phone end as client_phone,
    b.updated_at,
    (select ws.status from public.walk_sessions ws where ws.booking_id = b.id order by ws.created_at desc limit 1) as walk_status
  from public.bookings b
  join public.provider_profiles pp on pp.id = b.provider_id
  join public.customer_profiles cp on cp.id = b.customer_id
  join public.users cu on cu.id = cp.user_id
  left join public.provider_services ps on ps.id = b.service_id
  left join public.clients cl on cl.provider_user_id = pp.user_id and cl.linked_customer_id = cp.id
  where pp.user_id = auth.uid();

revoke all on public.provider_schedule from public, anon;
grant select on public.provider_schedule to authenticated, service_role;

-- ── 5. Deletion sweep: templates and log go with the carer ───────────────────
-- Full replacement of admin_delete_account (last changed in 20260911000000); the only new
-- lines are the two deletes marked "D1" in the supply-side block.
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
