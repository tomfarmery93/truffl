-- TRU-216 (TRU-217/218/222): No-carer-in-area capture flow — lead model + demand signal.
--
-- Extends the TRU-121 "can't find a carer" skeleton into the GTM capture flow:
--   • carer_requests grows founder-call fields (phone is the preferred contact), dog details
--     for call prep, frequency/preferred-times, and the lead pipeline statuses from TRU-221
--     (captured → called → founder_walking → sourcing_walker → meet_greet_booked →
--     transitioned, + lost/closed). status_changed_at powers days-in-status / the 14-day
--     sourcing clock in the admin console.
--   • submit_carer_request is REPLACED (dropped + recreated, never overloaded — PostgREST
--     named-arg dispatch returns 300 when two candidates match). New rule: phone is required
--     for every lead (the founder call is the product); email stays required for guests.
--   • search_misses gains postcode (derived server-side from public.suburbs — the page only
--     knows the free-text suburb) and a weekly rollup view for the recruitment-targeting
--     scorecard (TRU-222). No dashboard; admin reads it via the edge function.
--
-- Applied to the live DB via apply_migration (Supabase branching is broken on this repo);
-- committed here for version control (see TRU-145). 14-digit unique prefix.

-- ── carer_requests: founder-call + dog-detail fields ─────────────────────────
alter table public.carer_requests
  add column if not exists contact_phone        text,
  add column if not exists dog_name             text,
  add column if not exists dog_breed            text,
  add column if not exists dog_temperament_note text,
  add column if not exists frequency            text,
  add column if not exists preferred_times      text[] not null default '{}',
  add column if not exists status_changed_at    timestamptz not null default now();

-- ── lead pipeline statuses (TRU-221 set) ─────────────────────────────────────
-- Remap the TRU-121 statuses before swapping the check constraint. Site is unlaunched and
-- rows are few; a destructive remap is fine (open→captured, matched→meet_greet_booked,
-- onboarding→sourcing_walker).
alter table public.carer_requests drop constraint if exists carer_requests_status_check;
update public.carer_requests set status = case status
  when 'open'       then 'captured'
  when 'matched'    then 'meet_greet_booked'
  when 'onboarding' then 'sourcing_walker'
  else status end;
alter table public.carer_requests alter column status set default 'captured';
alter table public.carer_requests add constraint carer_requests_status_check
  check (status in ('captured','called','founder_walking','sourcing_walker',
                    'meet_greet_booked','transitioned','lost','closed'));

-- Keep status_changed_at honest so days-in-status is trustworthy.
create or replace function private.tg_carer_request_status() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if NEW.status is distinct from OLD.status then
    NEW.status_changed_at := now();
  end if;
  return NEW;
end; $$;

drop trigger if exists trg_carer_request_status on public.carer_requests;
create trigger trg_carer_request_status before update on public.carer_requests
  for each row execute function private.tg_carer_request_status();

-- ── submit_carer_request: replaced with the capture-form shape ────────────────
drop function if exists public.submit_carer_request(text,text,date,boolean,text,text,text,boolean,uuid,text,text,text,jsonb);

create function public.submit_carer_request(
  p_suburb          text    default null,
  p_service_type    text    default null,
  p_wanted_date     date    default null,
  p_recurring       boolean default false,
  p_window_start    text    default null,
  p_window_end      text    default null,
  p_dog_size        text    default null,
  p_puppy           boolean default false,
  p_pet_id          uuid    default null,
  p_contact_name    text    default null,
  p_contact_email   text    default null,
  p_note            text    default null,
  p_search_params   jsonb   default null,
  p_contact_phone   text    default null,
  p_dog_name        text    default null,
  p_dog_breed       text    default null,
  p_dog_temperament text    default null,
  p_frequency       text    default null,
  p_preferred_times text[]  default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_customer_id uuid;
  v_pet_id      uuid := null;
  v_phone       text;
  v_frequency   text;
  v_times       text[];
  v_id          uuid;
begin
  select cp.id into v_customer_id
  from public.customer_profiles cp
  where cp.user_id = auth.uid();

  -- The founder call is the product: every lead needs a phone number.
  v_phone := nullif(trim(coalesce(p_contact_phone, '')), '');
  if v_phone is null then
    raise exception 'contact_phone is required';
  end if;

  -- Guests must also leave an email (confirmation email + account invite).
  if v_customer_id is null and coalesce(trim(p_contact_email), '') = '' then
    raise exception 'contact_email is required for guest requests';
  end if;

  -- Only accept a pet_id that actually belongs to the caller (defends the assign path).
  if p_pet_id is not null and v_customer_id is not null then
    select pt.id into v_pet_id
    from public.pets pt
    where pt.id = p_pet_id and pt.customer_id = v_customer_id;
  end if;

  -- Whitelist enumerated inputs rather than trusting the client.
  v_frequency := nullif(trim(coalesce(p_frequency, '')), '');
  if v_frequency is not null
     and v_frequency not in ('one_off','weekly','few_per_week','daily') then
    raise exception 'invalid frequency %', v_frequency;
  end if;
  v_times := (
    select coalesce(array_agg(t), '{}')
    from unnest(coalesce(p_preferred_times, '{}')) as t
    where t in ('morning','midday','afternoon','evening')
  );

  insert into public.carer_requests (
    customer_id, pet_id, contact_name, contact_email, contact_phone, suburb, service_type,
    wanted_date, recurring, window_start, window_end, dog_size, puppy,
    dog_name, dog_breed, dog_temperament_note, frequency, preferred_times,
    note, search_params
  ) values (
    v_customer_id, v_pet_id,
    nullif(trim(coalesce(p_contact_name, '')), ''),
    nullif(trim(coalesce(p_contact_email, '')), ''),
    v_phone,
    nullif(trim(coalesce(p_suburb, '')), ''),
    nullif(trim(coalesce(p_service_type, '')), ''),
    p_wanted_date, coalesce(p_recurring, false),
    nullif(trim(coalesce(p_window_start, '')), ''),
    nullif(trim(coalesce(p_window_end, '')), ''),
    nullif(trim(coalesce(p_dog_size, '')), ''),
    coalesce(p_puppy, false),
    nullif(trim(coalesce(p_dog_name, '')), ''),
    nullif(trim(coalesce(p_dog_breed, '')), ''),
    nullif(trim(coalesce(p_dog_temperament, '')), ''),
    v_frequency, v_times,
    nullif(trim(coalesce(p_note, '')), ''),
    p_search_params
  ) returning id into v_id;

  return v_id;
end; $$;

revoke all on function public.submit_carer_request(text,text,date,boolean,text,text,text,boolean,uuid,text,text,text,jsonb,text,text,text,text,text,text[]) from public;
grant execute on function public.submit_carer_request(text,text,date,boolean,text,text,text,boolean,uuid,text,text,text,jsonb,text,text,text,text,text,text[]) to anon, authenticated;

-- ── search_misses: postcode + weekly rollup (TRU-222) ─────────────────────────
alter table public.search_misses add column if not exists postcode text;

-- Replaced (same drop-don't-overload rule). Postcode is derived here, not sent by the page:
-- the search box only carries a suburb name. A name can span postcodes; taking the lowest is
-- fine for a demand signal.
drop function if exists public.log_search_miss(text, text);

create function public.log_search_miss(
  p_suburb  text,
  p_service text default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(trim(p_suburb), '') = '' then return; end if;
  insert into public.search_misses (suburb, postcode, service_type, customer_id)
  values (
    trim(p_suburb),
    (select s.postcode from public.suburbs s
      where lower(s.name) = lower(trim(p_suburb))
      order by s.postcode limit 1),
    nullif(trim(coalesce(p_service, '')), ''),
    (select cp.id from public.customer_profiles cp where cp.user_id = auth.uid())
  );
end; $$;

revoke all on function public.log_search_miss(text, text) from public;
grant execute on function public.log_search_miss(text, text) to anon, authenticated;

-- Weekly counts by suburb — the recruitment-targeting scorecard. Read via service_role only
-- (the admin edge function); security_invoker so it carries no definer privileges of its own.
create or replace view public.search_miss_weekly
with (security_invoker = true) as
  select date_trunc('week', created_at)::date as week_start,
         suburb,
         max(postcode)                        as postcode,
         service_type,
         count(*)                             as misses
  from public.search_misses
  group by 1, 2, 4;

revoke all on public.search_miss_weekly from anon, authenticated;
grant select on public.search_miss_weekly to service_role;
