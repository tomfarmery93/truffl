-- TRU-224: convert a captured lead into an owner + first booking with the founder as carer.
--
-- The capture flow (TRU-216) ends with a lead record; this migration wires it into the real
-- booking pipeline:
--   • carer_requests.converted_customer_id / assigned_series_id link the lead to the owner
--     account and the founder booking series, so the TRU-221 pipeline can follow through.
--   • public.admin_create_lead_series is the server-side path the admin console uses to
--     create the founder (or any carer's) pending_meet_greet series for a lead. It mirrors
--     public.create_booking_series exactly (provider derived from the service, price via
--     private.compute_service_price, M&G booking created atomically) but takes an explicit
--     customer instead of auth.uid(), because the admin — not the owner — drives this step.
--     EXECUTE is granted to service_role ONLY: it is called from the stripe-api edge function
--     behind its users.is_admin gate, never from clients.
--
-- Payment stays exactly where TRU-144/146 put it: card captured at the M&G proceed step,
-- charge on completion. Nothing here touches money.
--
-- Applied to the live DB via apply_migration (Supabase branching is broken on this repo);
-- committed here for version control (see TRU-145). 14-digit unique prefix.

alter table public.carer_requests
  add column if not exists converted_customer_id uuid references public.customer_profiles(id) on delete set null,
  add column if not exists assigned_series_id    uuid references public.booking_series(id) on delete set null;

create or replace function public.admin_create_lead_series(
  p_request_id      uuid,
  p_customer_id     uuid,
  p_service_id      uuid,
  p_pet_ids         uuid[],
  p_booking_kind    text,
  p_frequency_type  public.series_frequency,
  p_days_of_week    int[],
  p_time_of_day     time,
  p_window_end_time time        default null,
  p_start_date      date        default null,
  p_end_date        date        default null,
  p_mg_scheduled_at timestamptz default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_provider_id uuid;
  v_owned       int;
  v_locked      int;
  v_series_id   uuid;
  v_mg_id       uuid;
  v_status      text;
begin
  select status into v_status from public.carer_requests where id = p_request_id;
  if v_status is null then
    raise exception 'Lead % not found', p_request_id;
  end if;
  if v_status in ('transitioned', 'lost', 'closed') then
    raise exception 'Lead % is already resolved (%)', p_request_id, v_status;
  end if;

  if p_pet_ids is null or array_length(p_pet_ids, 1) is null then
    raise exception 'At least one pet is required';
  end if;
  select count(*) into v_owned
    from public.pets where id = any(p_pet_ids) and customer_id = p_customer_id;
  if v_owned <> cardinality(p_pet_ids) then
    raise exception 'One or more pets do not belong to customer %', p_customer_id;
  end if;

  -- provider_services.provider_id is an auth.users.id; map it to provider_profiles.id.
  select pp.id into v_provider_id
    from public.provider_services ps
    join public.provider_profiles pp on pp.user_id = ps.provider_id
   where ps.id = p_service_id;
  if v_provider_id is null then
    raise exception 'Service % not found or has no provider profile', p_service_id;
  end if;
  v_locked := private.compute_service_price(p_service_id, cardinality(p_pet_ids));

  insert into public.booking_series (
    customer_id, provider_id, service_id, booking_kind,
    frequency_type, days_of_week, time_of_day, window_end_time,
    start_date, end_date, status, locked_price_cents
  ) values (
    p_customer_id, v_provider_id, p_service_id, coalesce(p_booking_kind, 'recurring'),
    p_frequency_type, coalesce(p_days_of_week, '{}'::int[]), p_time_of_day, p_window_end_time,
    p_start_date, p_end_date, 'pending_meet_greet'::public.series_status, v_locked
  ) returning id into v_series_id;

  insert into public.series_pets (series_id, pet_id)
  select v_series_id, unnest(p_pet_ids);

  -- The gate booking: free flagged M&G, same shape as create_booking_series's M&G branch.
  insert into public.bookings (
    customer_id, provider_id, pet_id, service_id, status,
    scheduled_at, duration_mins, total_cents, is_meet_and_greet, series_id
  ) values (
    p_customer_id, v_provider_id, p_pet_ids[1], p_service_id, 'confirmed',
    coalesce(p_mg_scheduled_at, (p_start_date::timestamp + time '12:00') at time zone 'Australia/Sydney'),
    30, 0, true, v_series_id
  ) returning id into v_mg_id;

  insert into public.booking_pets (booking_id, pet_id)
  select v_mg_id, unnest(p_pet_ids);

  -- Wire the lead into the pipeline: it parks at meet_greet_booked (TRU-221 board) and
  -- carries the links the follow-through needs.
  update public.carer_requests set
    status                = 'meet_greet_booked',
    converted_customer_id = p_customer_id,
    customer_id           = coalesce(customer_id, p_customer_id),
    pet_id                = coalesce(pet_id, p_pet_ids[1]),
    assigned_series_id    = v_series_id,
    assigned_provider_id  = v_provider_id
  where id = p_request_id;

  return v_series_id;
end; $$;

revoke all on function public.admin_create_lead_series(uuid, uuid, uuid, uuid[], text, public.series_frequency, int[], time, time, date, date, timestamptz) from public, anon, authenticated;
grant execute on function public.admin_create_lead_series(uuid, uuid, uuid, uuid[], text, public.series_frequency, int[], time, time, date, date, timestamptz) to service_role;
