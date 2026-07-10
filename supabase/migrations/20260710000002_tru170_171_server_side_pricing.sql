-- TRU-171 (+ TRU-170): Move booking price computation server-side.
--
-- Problem: book/index.html computed prices in browser JS and wrote bookings.total_cents /
-- booking_series.locked_price_cents directly via PostgREST under RLS. The server never
-- recomputed or validated against provider_services, so a tampered client could book at any
-- price (TRU-171). Single (non-series) bookings were inserted with total_cents = 0 and nothing
-- ever priced them, so the completion-charge trigger (tru146) skipped them and they were never
-- charged (TRU-170).
--
-- Fix: create SECURITY DEFINER RPCs as the ONLY trusted path to create bookings/series. They
-- derive price server-side from provider_services + pet count, ignoring anything the client
-- sends. Then revoke the client's privilege to write the price columns, so the old direct-insert
-- path can no longer set a price at all. Series were already priced server-side (the tru14/tru13
-- materialize functions copy locked_price_cents -> total_cents), so making locked_price_cents
-- trustworthy at series-creation time makes every materialized booking trustworthy too.
--
-- Applied to the live DB via apply_migration (Supabase branching is broken on this repo);
-- committed here for version control. The "Supabase Preview" check on the PR is expected to
-- fail and is non-blocking (see TRU-145 and the tru146/tru172 migration headers).

-- ── 1. Single source of truth for price ───────────────────────────────────────
-- base + (extra pets * per-extra-pet fee), read straight from provider_services.
create or replace function private.compute_service_price(p_service_id uuid, p_pet_count int)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  svc public.provider_services;
begin
  if p_pet_count is null or p_pet_count < 1 then
    raise exception 'At least one pet is required';
  end if;
  select * into svc from public.provider_services where id = p_service_id;
  if not found then
    raise exception 'Service % not found', p_service_id;
  end if;
  if not svc.is_available then
    raise exception 'Service % is not available', p_service_id;
  end if;
  if svc.price_cents is null then
    raise exception 'Service % has no price set', p_service_id;
  end if;
  return svc.price_cents + greatest(0, p_pet_count - 1) * coalesce(svc.additional_pet_price_cents, 0);
end; $$;

revoke execute on function private.compute_service_price(uuid, int) from public, anon, authenticated;

-- ── shared guard: resolve + validate the calling customer and their pets ───────
-- Returns the caller's customer_profiles.id; raises if the caller isn't a customer, the pet
-- list is empty, or any pet isn't theirs. Keeps the two public RPCs DRY.
create or replace function private.assert_customer_owns_pets(p_pet_ids uuid[])
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_customer_id uuid;
  v_owned int;
begin
  if p_pet_ids is null or array_length(p_pet_ids, 1) is null then
    raise exception 'At least one pet is required';
  end if;
  select id into v_customer_id from public.customer_profiles where user_id = auth.uid();
  if v_customer_id is null then
    raise exception 'No customer profile for the current user';
  end if;
  select count(*) into v_owned
    from public.pets
   where id = any(p_pet_ids) and customer_id = v_customer_id;
  if v_owned <> cardinality(p_pet_ids) then
    raise exception 'One or more pets do not belong to you';
  end if;
  return v_customer_id;
end; $$;

revoke execute on function private.assert_customer_owns_pets(uuid[]) from public, anon, authenticated;

-- ── 2. create_booking: single (non-series) booking, priced server-side ─────────
-- Replaces the client insert that shipped total_cents = 0. Fixes TRU-170 + TRU-171 for singles.
create or replace function public.create_booking(
  p_service_id     uuid,
  p_pet_ids        uuid[],
  p_scheduled_at   timestamptz,
  p_ends_at        timestamptz default null,
  p_window_end_at  timestamptz default null,
  p_duration_mins  int         default null,
  p_customer_notes text        default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_customer_id uuid;
  v_provider_id uuid;
  v_total_cents int;
  v_booking_id  uuid;
begin
  v_customer_id := private.assert_customer_owns_pets(p_pet_ids);
  -- provider is derived from the service, never trusted from the client.
  select provider_id into v_provider_id from public.provider_services where id = p_service_id;
  if v_provider_id is null then
    raise exception 'Service % not found', p_service_id;
  end if;
  v_total_cents := private.compute_service_price(p_service_id, cardinality(p_pet_ids));

  insert into public.bookings (
    customer_id, provider_id, pet_id, service_id, status,
    scheduled_at, ends_at, window_end_at, duration_mins,
    total_cents, customer_notes, is_meet_and_greet
  ) values (
    v_customer_id, v_provider_id, p_pet_ids[1], p_service_id, 'pending',
    p_scheduled_at, p_ends_at, p_window_end_at, p_duration_mins,
    v_total_cents, nullif(btrim(coalesce(p_customer_notes, '')), ''), false
  ) returning id into v_booking_id;

  insert into public.booking_pets (booking_id, pet_id)
  select v_booking_id, unnest(p_pet_ids);

  return v_booking_id;
end; $$;

grant execute on function public.create_booking(uuid, uuid[], timestamptz, timestamptz, timestamptz, int, text) to authenticated;

-- ── 3. create_booking_series: recurring + first-time M&G, priced server-side ────
-- locked_price_cents is computed server-side. For the M&G case (p_is_meet_greet), the series is
-- pending_meet_greet and the free flagged M&G booking is created atomically. Returns the series id.
create or replace function public.create_booking_series(
  p_service_id       uuid,
  p_pet_ids          uuid[],
  p_booking_kind     text,
  p_frequency_type   public.series_frequency,
  p_days_of_week     int[],
  p_time_of_day      time,
  p_window_end_time  time        default null,
  p_start_date       date        default null,
  p_end_date         date        default null,
  p_is_meet_greet    boolean     default false,
  p_mg_scheduled_at  timestamptz default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_customer_id uuid;
  v_provider_id uuid;
  v_locked      int;
  v_series_id   uuid;
  v_mg_id       uuid;
begin
  v_customer_id := private.assert_customer_owns_pets(p_pet_ids);
  select provider_id into v_provider_id from public.provider_services where id = p_service_id;
  if v_provider_id is null then
    raise exception 'Service % not found', p_service_id;
  end if;
  v_locked := private.compute_service_price(p_service_id, cardinality(p_pet_ids));

  insert into public.booking_series (
    customer_id, provider_id, service_id, booking_kind,
    frequency_type, days_of_week, time_of_day, window_end_time,
    start_date, end_date, status, locked_price_cents
  ) values (
    v_customer_id, v_provider_id, p_service_id, coalesce(p_booking_kind, 'recurring'),
    p_frequency_type, coalesce(p_days_of_week, '{}'::int[]), p_time_of_day, p_window_end_time,
    p_start_date, p_end_date,
    case when p_is_meet_greet then 'pending_meet_greet' else 'pending' end::public.series_status,
    v_locked
  ) returning id into v_series_id;

  insert into public.series_pets (series_id, pet_id)
  select v_series_id, unnest(p_pet_ids);

  -- First-time booking with this carer: the intended booking is gated behind a free meet & greet.
  if p_is_meet_greet then
    insert into public.bookings (
      customer_id, provider_id, pet_id, service_id, status,
      scheduled_at, duration_mins, total_cents, is_meet_and_greet, series_id
    ) values (
      v_customer_id, v_provider_id, p_pet_ids[1], p_service_id, 'confirmed',
      coalesce(p_mg_scheduled_at, (p_start_date::timestamp + time '12:00') at time zone 'Australia/Sydney'),
      30, 0, true, v_series_id
    ) returning id into v_mg_id;

    insert into public.booking_pets (booking_id, pet_id)
    select v_mg_id, unnest(p_pet_ids);
  end if;

  return v_series_id;
end; $$;

grant execute on function public.create_booking_series(uuid, uuid[], text, public.series_frequency, int[], time, time, date, date, boolean, timestamptz) to authenticated;

-- ── 4. Lock down the price columns ─────────────────────────────────────────────
-- The client can no longer write price on any path. The definer RPCs run as the function owner
-- (bypassing these grants), so they remain the only way to set a price. bookings.total_cents is
-- NOT NULL with no default, so this also forces every client booking through create_booking.
-- RLS insert policies (bookings_customer_create, customers_insert_series) stay as defense in depth.
revoke insert (total_cents), update (total_cents) on public.bookings from authenticated, anon;
revoke insert (locked_price_cents), update (locked_price_cents) on public.booking_series from authenticated, anon;

-- ── 5. TRU-170 recovery report (run manually; backfill is a founder decision) ──
-- Completed, chargeable bookings that were never charged under the old total_cents = 0 bug.
-- Surfaced for a backfill/recovery decision; not auto-remediated here.
--
--   select b.id, b.customer_id, b.provider_id, b.service_id, b.scheduled_at,
--          b.completed_at, b.total_cents, b.payment_status
--     from public.bookings b
--    where b.status = 'completed'
--      and not b.is_meet_and_greet
--      and (coalesce(b.total_cents, 0) = 0 or b.payment_status <> 'paid')
--    order by b.completed_at;
