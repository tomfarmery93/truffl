-- Supply-side foundation: the carer's client book and schedule (GitHub #146, #152, #158, #165).
--
-- Truffl is repositioning from "marketplace" to "the tool a carer runs their whole business
-- on, with Truffl leads on top" (docs/supply-side-scope.md). This migration lays the data
-- foundation for that:
--
--   * clients / client_pets      the carer's own people and dogs, independent of Truffl
--                                accounts. An owner who books through the marketplace is
--                                linked in automatically the first time a booking with that
--                                carer is confirmed, so the book is complete from day one.
--   * jobs / job_series / *_pets own-client work. Jobs live BESIDE marketplace bookings, not
--                                inside them: bookings are coupled to customer_profiles, the
--                                TRU-171 price guards, the TRU-146 charge trigger and the
--                                meet-and-greet gate. Nothing here ever reaches Stripe.
--   * provider_schedule          one definer view uniting jobs and bookings for the calendar.
--   * calendar_token             a per-carer secret for the ICS feed (calendar-feed edge fn).
--   * admin_delete_account       extended so a carer's client book is purged when they leave
--                                and a deleted owner is scrubbed from every carer's book.
--
-- Conventions carried over: RLS keyed on (select auth.uid()) (TRU-142), every definer
-- function pins search_path (TRU-153/198), nothing new is granted to anon.
--
-- Id spaces: clients/jobs key the carer by public.users.id (= auth.uid()), like
-- provider_services and walk_sessions, so RLS is a plain column compare. Bookings key the
-- carer by provider_profiles.id, so the view maps through provider_profiles.user_id.

-- ── 1. Client book ────────────────────────────────────────────────────────────
create table if not exists public.clients (
  id                  uuid primary key default gen_random_uuid(),
  provider_user_id    uuid not null references public.users(id) on delete cascade,
  first_name          text not null,
  last_name           text,
  phone               text,
  email               text,
  address             text,
  suburb              text,
  postcode            text,
  notes               text,
  tags                text[] not null default '{}',
  source              text not null default 'manual'
                        check (source in ('manual','truffl','import')),
  linked_customer_id  uuid references public.customer_profiles(id) on delete set null,
  is_archived         boolean not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists idx_clients_provider on public.clients (provider_user_id, is_archived);
create unique index if not exists idx_clients_provider_customer
  on public.clients (provider_user_id, linked_customer_id) where linked_customer_id is not null;

create table if not exists public.client_pets (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid not null references public.clients(id) on delete cascade,
  name             text not null,
  species          text not null default 'dog' check (species in ('dog','cat','other')),
  breed            text,
  sex              text check (sex is null or sex in ('male','female','unknown')),
  dob              date,
  weight_kg        numeric(5,2),
  behaviour_notes  text,
  medical_notes    text,
  vet_name         text,
  vet_phone        text,
  photo_url        text,
  linked_pet_id    uuid references public.pets(id) on delete set null,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists idx_client_pets_client on public.client_pets (client_id);
create unique index if not exists idx_client_pets_linked
  on public.client_pets (client_id, linked_pet_id) where linked_pet_id is not null;

-- ── 2. Schedule: series and jobs ──────────────────────────────────────────────
create table if not exists public.job_series (
  id                uuid primary key default gen_random_uuid(),
  provider_user_id  uuid not null references public.users(id) on delete cascade,
  client_id         uuid references public.clients(id) on delete set null,
  title             text,
  service_type      text not null default 'dog_walking',
  duration_mins     integer not null default 60 check (duration_mins between 5 and 1440),
  frequency_type    public.series_frequency not null,
  days_of_week      integer[] not null default '{}',      -- ISO: 1 = Monday .. 7 = Sunday
  time_of_day       time without time zone not null,      -- Australia/Sydney local
  start_date        date not null,
  end_date          date,
  price_cents       integer check (price_cents is null or price_cents >= 0),
  notes             text,
  status            text not null default 'active' check (status in ('active','paused','ended')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index if not exists idx_job_series_provider on public.job_series (provider_user_id, status);
create index if not exists idx_job_series_client on public.job_series (client_id);

create table if not exists public.job_series_pets (
  series_id      uuid not null references public.job_series(id) on delete cascade,
  client_pet_id  uuid not null references public.client_pets(id) on delete cascade,
  primary key (series_id, client_pet_id)
);
create index if not exists idx_job_series_pets_pet on public.job_series_pets (client_pet_id);

create table if not exists public.jobs (
  id                uuid primary key default gen_random_uuid(),
  provider_user_id  uuid not null references public.users(id) on delete cascade,
  client_id         uuid references public.clients(id) on delete set null,
  series_id         uuid references public.job_series(id) on delete set null,
  title             text,                                  -- imports and client-less events
  service_type      text not null default 'dog_walking',
  starts_at         timestamptz not null,
  ends_at           timestamptz not null,
  status            text not null default 'scheduled' check (status in ('scheduled','completed','cancelled')),
  price_cents       integer check (price_cents is null or price_cents >= 0),
  paid_at           timestamptz,
  payment_method    text check (payment_method is null or payment_method in ('cash','bank_transfer','card','other')),
  notes             text,
  source            text not null default 'manual' check (source in ('manual','series','import')),
  external_uid      text,                                  -- ICS UID etc, for re-import dedupe
  assigned_user_id  uuid references public.users(id) on delete set null,  -- reserved for teams (Epic F)
  completed_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint jobs_time_order check (ends_at > starts_at)
);
create index if not exists idx_jobs_provider_starts on public.jobs (provider_user_id, starts_at);
create index if not exists idx_jobs_client on public.jobs (client_id);
create index if not exists idx_jobs_series on public.jobs (series_id);
create index if not exists idx_jobs_assigned on public.jobs (assigned_user_id) where assigned_user_id is not null;
create unique index if not exists idx_jobs_provider_external_uid
  on public.jobs (provider_user_id, external_uid) where external_uid is not null;

create table if not exists public.job_pets (
  job_id         uuid not null references public.jobs(id) on delete cascade,
  client_pet_id  uuid not null references public.client_pets(id) on delete cascade,
  primary key (job_id, client_pet_id)
);
create index if not exists idx_job_pets_pet on public.job_pets (client_pet_id);

-- updated_at bookkeeping (public.set_updated_at exists since the baseline)
drop trigger if exists set_clients_updated_at on public.clients;
create trigger set_clients_updated_at before update on public.clients
  for each row execute function public.set_updated_at();
drop trigger if exists set_client_pets_updated_at on public.client_pets;
create trigger set_client_pets_updated_at before update on public.client_pets
  for each row execute function public.set_updated_at();
drop trigger if exists set_job_series_updated_at on public.job_series;
create trigger set_job_series_updated_at before update on public.job_series
  for each row execute function public.set_updated_at();
drop trigger if exists set_jobs_updated_at on public.jobs;
create trigger set_jobs_updated_at before update on public.jobs
  for each row execute function public.set_updated_at();

-- ── 3. Row level security: the owning carer only ──────────────────────────────
alter table public.clients          enable row level security;
alter table public.client_pets      enable row level security;
alter table public.job_series       enable row level security;
alter table public.job_series_pets  enable row level security;
alter table public.jobs             enable row level security;
alter table public.job_pets         enable row level security;

drop policy if exists clients_owner on public.clients;
create policy clients_owner on public.clients
  for all to authenticated
  using (provider_user_id = (select auth.uid()))
  with check (provider_user_id = (select auth.uid()));

drop policy if exists client_pets_owner on public.client_pets;
create policy client_pets_owner on public.client_pets
  for all to authenticated
  using (exists (select 1 from public.clients c where c.id = client_pets.client_id and c.provider_user_id = (select auth.uid())))
  with check (exists (select 1 from public.clients c where c.id = client_pets.client_id and c.provider_user_id = (select auth.uid())));

drop policy if exists job_series_owner on public.job_series;
create policy job_series_owner on public.job_series
  for all to authenticated
  using (provider_user_id = (select auth.uid()))
  with check (provider_user_id = (select auth.uid()));

drop policy if exists job_series_pets_owner on public.job_series_pets;
create policy job_series_pets_owner on public.job_series_pets
  for all to authenticated
  using (exists (select 1 from public.job_series s where s.id = job_series_pets.series_id and s.provider_user_id = (select auth.uid())))
  with check (exists (select 1 from public.job_series s where s.id = job_series_pets.series_id and s.provider_user_id = (select auth.uid())));

drop policy if exists jobs_owner on public.jobs;
create policy jobs_owner on public.jobs
  for all to authenticated
  using (provider_user_id = (select auth.uid()))
  with check (provider_user_id = (select auth.uid()));

drop policy if exists job_pets_owner on public.job_pets;
create policy job_pets_owner on public.job_pets
  for all to authenticated
  using (exists (select 1 from public.jobs j where j.id = job_pets.job_id and j.provider_user_id = (select auth.uid())))
  with check (exists (select 1 from public.jobs j where j.id = job_pets.job_id and j.provider_user_id = (select auth.uid())));

-- Deliberately no anon grant: these tables are private to a signed-in carer.
grant select, insert, update, delete on
  public.clients, public.client_pets, public.job_series, public.job_series_pets,
  public.jobs, public.job_pets
  to authenticated, service_role;

-- ── 4. Recurrence: materialise job occurrences like booking_series ────────────
-- Mirrors public.generate_series_bookings: Sydney-local dates, ISO day-of-week, one job per
-- series per calendar day. Cancelled occurrences count as present, so cancelling a single
-- walk does not resurrect it on the next nightly roll (the page cancels rather than deletes
-- for series occurrences for exactly this reason).
create or replace function public.generate_job_occurrences(p_series_id uuid, p_weeks_ahead integer default 4)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  s        public.job_series%rowtype;
  d        date;
  horizon  date;
  dow      integer;
  want     boolean;
  starts   timestamptz;
  created  integer := 0;
  v_job_id uuid;
begin
  select * into s from public.job_series where id = p_series_id;
  if not found then return 0; end if;
  -- Client calls (PostgREST) may only roll their own series; the nightly cron (no JWT) rolls all.
  if auth.uid() is not null and s.provider_user_id <> auth.uid() then
    raise exception 'Not your series';
  end if;
  if s.status <> 'active' then return 0; end if;

  horizon := least(coalesce(s.end_date, current_date + (p_weeks_ahead * 7)), current_date + (p_weeks_ahead * 7));
  d := greatest(s.start_date, current_date);

  while d <= horizon loop
    dow := extract(isodow from d);
    want := case s.frequency_type
      when 'daily'         then true
      when 'weekdays'      then dow between 1 and 5
      when 'specific_days' then dow = any(s.days_of_week)
      else false
    end;

    if want and not exists (
      select 1 from public.jobs j
      where j.series_id = p_series_id
        and (j.starts_at at time zone 'Australia/Sydney')::date = d
    ) then
      starts := (d::timestamp + s.time_of_day) at time zone 'Australia/Sydney';
      insert into public.jobs (provider_user_id, client_id, series_id, title, service_type,
                               starts_at, ends_at, price_cents, notes, source)
      values (s.provider_user_id, s.client_id, s.id, s.title, s.service_type,
              starts, starts + make_interval(mins => s.duration_mins), s.price_cents, s.notes, 'series')
      returning id into v_job_id;

      insert into public.job_pets (job_id, client_pet_id)
      select v_job_id, sp.client_pet_id from public.job_series_pets sp where sp.series_id = s.id
      on conflict do nothing;

      created := created + 1;
    end if;
    d := d + 1;
  end loop;

  -- Keep future occurrences in step with the series' pets. The insert trigger fires before
  -- the page has attached job_series_pets, and a carer may add a dog to a series later, so
  -- every roll tops up the pets on still-scheduled future occurrences (never past or done).
  insert into public.job_pets (job_id, client_pet_id)
  select j.id, sp.client_pet_id
    from public.jobs j
    join public.job_series_pets sp on sp.series_id = j.series_id
   where j.series_id = p_series_id and j.status = 'scheduled' and j.starts_at >= now()
  on conflict do nothing;

  return created;
end;
$$;

revoke all on function public.generate_job_occurrences(uuid, integer) from public, anon;
grant execute on function public.generate_job_occurrences(uuid, integer) to authenticated, service_role;

-- New active series materialise immediately. The page inserts job_series_pets right after
-- the series row and then calls generate_job_occurrences once more, which attaches the pets
-- to the occurrences this trigger created (the generator is idempotent per day).
create or replace function private.tg_job_series_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'active' then
    perform public.generate_job_occurrences(new.id, 4);
  end if;
  return new;
end;
$$;
revoke all on function private.tg_job_series_created() from public, anon, authenticated;

drop trigger if exists trg_job_series_created on public.job_series;
create trigger trg_job_series_created after insert on public.job_series
  for each row execute function private.tg_job_series_created();

-- Nightly roll: retire ended series, top up four weeks for the rest. Same slot family as
-- roll-series-bookings (16:00 UTC, about 2am Sydney), five minutes later.
create or replace function public.roll_all_job_series()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r     record;
  total integer := 0;
begin
  update public.job_series
     set status = 'ended', updated_at = now()
   where status = 'active' and end_date is not null and end_date < current_date;

  for r in select id from public.job_series where status = 'active' loop
    total := total + public.generate_job_occurrences(r.id, 4);
  end loop;
  return total;
end;
$$;
revoke all on function public.roll_all_job_series() from public, anon, authenticated;
grant execute on function public.roll_all_job_series() to service_role;

do $$
begin
  perform cron.unschedule('roll-job-series')
  where exists (select 1 from cron.job where jobname = 'roll-job-series');
end $$;
select cron.schedule('roll-job-series', '5 16 * * *', $$select public.roll_all_job_series();$$);

-- ── 5. The unified schedule ───────────────────────────────────────────────────
-- Definer view scoped by auth.uid() in the WHERE clause (the booking_party_names pattern):
-- a carer cannot read the owner's users / customer_profiles / pets rows under RLS, so the
-- customer name and pet names for marketplace bookings must come through a definer view.
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
    j.updated_at
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
    b.updated_at
  from public.bookings b
  join public.provider_profiles pp on pp.id = b.provider_id
  join public.customer_profiles cp on cp.id = b.customer_id
  join public.users cu on cu.id = cp.user_id
  left join public.provider_services ps on ps.id = b.service_id
  left join public.clients cl on cl.provider_user_id = pp.user_id and cl.linked_customer_id = cp.id
  where pp.user_id = auth.uid();

revoke all on public.provider_schedule from public, anon;
grant select on public.provider_schedule to authenticated, service_role;

-- ── 6. Truffl owners appear in the carer's client book automatically ──────────
-- Snapshot the owner (and their pets) into the carer's book the first time a booking with
-- that carer is confirmed. Idempotent: keyed on (carer, customer) and (client, pet).
create or replace function private.ensure_client_for_booking(p_booking_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider_user uuid;
  v_customer_id   uuid;
  v_cp            public.customer_profiles%rowtype;
  v_user          public.users%rowtype;
  v_client_id     uuid;
begin
  select pp.user_id, b.customer_id
    into v_provider_user, v_customer_id
    from public.bookings b
    join public.provider_profiles pp on pp.id = b.provider_id
   where b.id = p_booking_id;
  if v_provider_user is null or v_customer_id is null then return null; end if;

  select * into v_cp from public.customer_profiles where id = v_customer_id;
  if v_cp.id is null then return null; end if;

  select * into v_user from public.users where id = v_cp.user_id;
  -- A deleted owner (TRU-228) has nothing worth copying.
  if v_user.id is null or v_user.is_active = false then return null; end if;

  select id into v_client_id
    from public.clients
   where provider_user_id = v_provider_user and linked_customer_id = v_cp.id;

  if v_client_id is null then
    insert into public.clients (provider_user_id, first_name, last_name, phone, email,
                                address, suburb, postcode, source, linked_customer_id)
    values (v_provider_user, coalesce(nullif(v_user.first_name, ''), 'Owner'), v_user.last_name,
            v_user.phone, v_user.email, v_cp.address, v_cp.suburb, v_cp.postcode,
            'truffl', v_cp.id)
    returning id into v_client_id;
  end if;

  insert into public.client_pets (client_id, name, species, breed, sex, dob, weight_kg,
                                  behaviour_notes, medical_notes, vet_name, vet_phone, photo_url, linked_pet_id)
  select v_client_id, p.name, p.species, p.breed, p.sex, p.dob, p.weight_kg,
         p.behaviour_notes, p.medical_notes, p.vet_name, p.vet_phone, p.photo_url, p.id
    from public.pets p
   where p.customer_id = v_cp.id and p.is_active
     and not exists (select 1 from public.client_pets x where x.client_id = v_client_id and x.linked_pet_id = p.id);

  return v_client_id;
end;
$$;
revoke all on function private.ensure_client_for_booking(uuid) from public, anon, authenticated;

-- Fires on the transition into a confirmed state. Exception-wrapped: the client book is an
-- enhancement and must never roll back a booking write (the TRU-146 / TRU-118 discipline).
create or replace function private.tg_booking_link_client()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status in ('confirmed','in_progress','completed')
     and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    begin
      perform private.ensure_client_for_booking(new.id);
    exception when others then null;
    end;
  end if;
  return new;
end;
$$;
revoke all on function private.tg_booking_link_client() from public, anon, authenticated;

drop trigger if exists trg_booking_link_client on public.bookings;
create trigger trg_booking_link_client after insert or update of status on public.bookings
  for each row execute function private.tg_booking_link_client();

-- Backfill: one client per (carer, owner) pair that has ever had a confirmed booking.
do $$
declare r record;
begin
  for r in
    select distinct on (b.provider_id, b.customer_id) b.id
      from public.bookings b
     where b.status in ('confirmed','in_progress','completed')
     order by b.provider_id, b.customer_id, b.scheduled_at desc
  loop
    begin
      perform private.ensure_client_for_booking(r.id);
    exception when others then null;
    end;
  end loop;
end $$;

-- ── 7. Calendar feed token (ICS subscribe) ────────────────────────────────────
-- 64 hex chars from two v4 UUIDs (244 random bits). No pgcrypto dependency.
alter table public.provider_profiles
  add column if not exists calendar_token text;

update public.provider_profiles
   set calendar_token = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
 where calendar_token is null;

alter table public.provider_profiles
  alter column calendar_token set default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  alter column calendar_token set not null;

create unique index if not exists idx_provider_profiles_calendar_token
  on public.provider_profiles (calendar_token);

-- Carer rotates their own token (invalidates every subscribed calendar until re-added).
create or replace function public.rotate_calendar_token()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare v_token text;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  update public.provider_profiles
     set calendar_token = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
         updated_at = now()
   where user_id = auth.uid()
   returning calendar_token into v_token;
  if v_token is null then raise exception 'No provider profile'; end if;
  return v_token;
end;
$$;
revoke all on function public.rotate_calendar_token() from public, anon;
grant execute on function public.rotate_calendar_token() to authenticated;

-- Events for the feed. service_role only: the edge function resolves the token, the browser
-- never calls this. Same row shape on both branches as provider_schedule, minus the
-- carer-only fields the calendar does not need.
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
  with owner as (
    select pp.id as pp_id, pp.user_id
      from public.provider_profiles pp
     where p_token is not null and length(p_token) >= 32 and pp.calendar_token = p_token
  )
  select
    'job-' || j.id::text                                                as uid,
    'job'                                                               as kind,
    concat_ws(' ',
      case j.service_type when 'dog_walking' then 'Walk' when 'dog_sitting' then 'Sitting'
                          when 'dog_boarding' then 'Boarding' when 'pet_sitting' then 'Visit' else 'Job' end,
      coalesce(nullif(btrim(concat_ws(' ', c.first_name, c.last_name)), ''), nullif(btrim(j.title), '')),
      case when pn.names is not null then '(' || pn.names || ')' end)  as summary,
    j.notes                                                             as description,
    concat_ws(', ', c.address, c.suburb, c.postcode)                    as location,
    j.starts_at, j.ends_at,
    case j.status when 'cancelled' then 'CANCELLED' else 'CONFIRMED' end as status,
    j.updated_at
  from owner o
  join public.jobs j on j.provider_user_id = o.user_id
  left join public.clients c on c.id = j.client_id
  left join lateral (
    select string_agg(cp.name, ', ' order by cp.name) as names
      from public.job_pets jp join public.client_pets cp on cp.id = jp.client_pet_id
     where jp.job_id = j.id
  ) pn on true
  where j.starts_at between now() - interval '30 days' and now() + interval '90 days'

  union all

  select
    'booking-' || b.id::text,
    'booking',
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
  from owner o
  join public.bookings b on b.provider_id = o.pp_id
  join public.customer_profiles cp on cp.id = b.customer_id
  join public.users cu on cu.id = cp.user_id
  left join public.provider_services ps on ps.id = b.service_id
  left join lateral (
    select coalesce(
      (select string_agg(p.name, ', ' order by p.name)
         from public.booking_pets bp join public.pets p on p.id = bp.pet_id where bp.booking_id = b.id),
      (select p.name from public.pets p where p.id = b.pet_id)) as names
  ) pn on true
  where b.scheduled_at between now() - interval '30 days' and now() + interval '90 days';
$$;
revoke all on function public.calendar_feed_events(text) from public, anon, authenticated;
grant execute on function public.calendar_feed_events(text) to service_role;

-- ── 8. Account deletion: purge the client book too (extends TRU-228) ──────────
-- Full replacement of admin_delete_account with two additions in the PURGE block:
--   * a carer who leaves takes their client book, series and jobs with them (hard delete:
--     no Truffl-processed money lives on these rows, and they are the carer's private data);
--   * an owner who leaves is scrubbed from every carer's book where Truffl put them there
--     (source = 'truffl'); a carer's hand-typed record of a person is theirs and is left alone.
-- Everything else is verbatim from 20260729000000_tru228_account_deletion.sql.
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

  -- Supply-side additions. A leaving carer's client book, series and jobs are deleted
  -- outright (client_pets, job_pets and job_series_pets cascade). A leaving owner is
  -- scrubbed from every carer's book where Truffl created the record.
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
    -- A hand-typed client that happened to be linked keeps the carer's own notes but loses the link.
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
