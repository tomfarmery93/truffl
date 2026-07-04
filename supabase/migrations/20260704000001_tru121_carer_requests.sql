-- TRU-121: "Can't find a carer" service.
--
-- Two capture surfaces for unmet demand when carer search returns nothing:
--   • carer_requests — an explicit, actionable lead a customer (or guest) submits from the
--     zero-result empty state. Admin works it from the console (assign an existing carer, or
--     go find + onboard a new one). Inserted via a SECURITY DEFINER RPC so guests/anon never
--     need a broad INSERT grant — mirrors public.cancel_my_booking / public.search_carers.
--   • search_misses — a passive, anonymous signal: one row per zero-result search so we can
--     see demand even when nobody submits. No PII (suburb + service only).
--
-- On insert, carer_requests fires the existing email pipeline (private.notify_email ->
-- send-notification, type 'carer_request') to page every admin — the same mechanism as the
-- TRU-138 covered-cancellation alert.
--
-- Applied to the live DB via apply_migration (Supabase branching is broken on this repo);
-- committed here for version control (see TRU-145). 14-digit unique prefix.

-- ── carer_requests: the actionable lead ──────────────────────────────────────
create table if not exists public.carer_requests (
  id                   uuid primary key default gen_random_uuid(),
  -- null for a guest (search is public); set from auth.uid() when signed in.
  customer_id          uuid references public.customer_profiles(id) on delete set null,
  -- captured when a signed-in customer picks a pet; required for the in-app assign path.
  pet_id               uuid references public.pets(id) on delete set null,
  contact_name         text,
  contact_email        text,           -- required for guests (see submit RPC)
  suburb               text,
  service_type         text,
  wanted_date          date,
  recurring            boolean not null default false,
  window_start         text,           -- 'HH:MM'
  window_end           text,           -- 'HH:MM'
  dog_size             text,
  puppy                boolean not null default false,
  note                 text,           -- free-text "anything else"
  search_params        jsonb,          -- full snapshot of the search state (future-proof)
  status               text not null default 'open'
                         check (status in ('open','matched','onboarding','closed')),
  assigned_provider_id uuid references public.provider_profiles(id) on delete set null,
  assigned_booking_id  uuid references public.bookings(id) on delete set null,
  admin_note           text,
  resolved_at          timestamptz,
  resolved_by          uuid references public.users(id) on delete set null,
  created_at           timestamptz not null default now()
);
create index if not exists idx_carer_requests_status on public.carer_requests (status, created_at desc);
create index if not exists idx_carer_requests_customer on public.carer_requests (customer_id);

alter table public.carer_requests enable row level security;
-- Owners can read their own submitted requests; all writes go through the definer RPC (submit)
-- or the admin edge function (service_role). Mirrors public.customer_credits (TRU-139).
drop policy if exists carer_requests_owner_read on public.carer_requests;
create policy carer_requests_owner_read on public.carer_requests
  for select to authenticated
  using (exists (
    select 1 from public.customer_profiles cp
    where cp.id = carer_requests.customer_id and cp.user_id = (select auth.uid())
  ));
revoke insert, update, delete on public.carer_requests from anon, authenticated;
grant select on public.carer_requests to authenticated;
grant select, insert, update, delete on public.carer_requests to service_role;

-- ── search_misses: the passive anonymous signal ──────────────────────────────
create table if not exists public.search_misses (
  id           uuid primary key default gen_random_uuid(),
  suburb       text not null,
  service_type text,
  customer_id  uuid,          -- best-effort attribution when signed in; nullable
  created_at   timestamptz not null default now()
);
create index if not exists idx_search_misses_agg on public.search_misses (suburb, service_type, created_at desc);

alter table public.search_misses enable row level security;
-- No client reads; admin aggregates it via service_role. Written only through the RPC below.
revoke select, insert, update, delete on public.search_misses from anon, authenticated;
grant select, insert on public.search_misses to service_role;

-- ── submit_carer_request: public/guest-safe insert (SECURITY DEFINER) ─────────
create or replace function public.submit_carer_request(
  p_suburb        text    default null,
  p_service_type  text    default null,
  p_wanted_date   date    default null,
  p_recurring     boolean default false,
  p_window_start  text    default null,
  p_window_end    text    default null,
  p_dog_size      text    default null,
  p_puppy         boolean default false,
  p_pet_id        uuid    default null,
  p_contact_name  text    default null,
  p_contact_email text    default null,
  p_note          text    default null,
  p_search_params jsonb   default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_customer_id uuid;
  v_pet_id      uuid := null;
  v_id          uuid;
begin
  -- Tie to the caller's customer profile when signed in; otherwise it's a guest lead.
  select cp.id into v_customer_id
  from public.customer_profiles cp
  where cp.user_id = auth.uid();

  -- Guests must leave a contact email so we can reach them.
  if v_customer_id is null and coalesce(trim(p_contact_email), '') = '' then
    raise exception 'contact_email is required for guest requests';
  end if;

  -- Only accept a pet_id that actually belongs to the caller (defends the assign path).
  if p_pet_id is not null and v_customer_id is not null then
    select pt.id into v_pet_id
    from public.pets pt
    where pt.id = p_pet_id and pt.customer_id = v_customer_id;
  end if;

  insert into public.carer_requests (
    customer_id, pet_id, contact_name, contact_email, suburb, service_type,
    wanted_date, recurring, window_start, window_end, dog_size, puppy, note, search_params
  ) values (
    v_customer_id, v_pet_id,
    nullif(trim(coalesce(p_contact_name, '')), ''),
    nullif(trim(coalesce(p_contact_email, '')), ''),
    nullif(trim(coalesce(p_suburb, '')), ''),
    nullif(trim(coalesce(p_service_type, '')), ''),
    p_wanted_date, coalesce(p_recurring, false),
    nullif(trim(coalesce(p_window_start, '')), ''),
    nullif(trim(coalesce(p_window_end, '')), ''),
    nullif(trim(coalesce(p_dog_size, '')), ''),
    coalesce(p_puppy, false),
    nullif(trim(coalesce(p_note, '')), ''),
    p_search_params
  ) returning id into v_id;

  return v_id;
end; $$;

revoke all on function public.submit_carer_request(text,text,date,boolean,text,text,text,boolean,uuid,text,text,text,jsonb) from public;
grant execute on function public.submit_carer_request(text,text,date,boolean,text,text,text,boolean,uuid,text,text,text,jsonb) to anon, authenticated;

-- ── log_search_miss: fire-and-forget passive signal (SECURITY DEFINER) ────────
create or replace function public.log_search_miss(
  p_suburb  text,
  p_service text default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(trim(p_suburb), '') = '' then return; end if;
  insert into public.search_misses (suburb, service_type, customer_id)
  values (
    trim(p_suburb),
    nullif(trim(coalesce(p_service, '')), ''),
    (select cp.id from public.customer_profiles cp where cp.user_id = auth.uid())
  );
end; $$;

revoke all on function public.log_search_miss(text, text) from public;
grant execute on function public.log_search_miss(text, text) to anon, authenticated;

-- ── founder alert on insert (reuses the TRU-118 email pipeline) ───────────────
create or replace function private.tg_carer_request() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- Wrapped so an email hiccup can never roll back the request insert.
  begin
    perform private.notify_email(jsonb_build_object('type', 'carer_request', 'request_id', NEW.id));
  exception when others then null;
  end;
  return NEW;
end; $$;

drop trigger if exists trg_email_carer_request on public.carer_requests;
create trigger trg_email_carer_request after insert on public.carer_requests
  for each row execute function private.tg_carer_request();
