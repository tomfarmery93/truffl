-- TRU-225: handover — nominate a permanent carer to take over a lead's booking series.
--
-- The product side of the GTM two-week rule: the founder walks as a stop-gap (TRU-224),
-- then hands the series to a sourced permanent walker at THEIR listed rate. Builds on the
-- TRU-139 reassignment pattern (original_provider_id preserves who was booked vs who
-- walked) but runs founder → new carer, operates on the whole series' future bookings,
-- and changes the price at transition.
--
--   • carer_requests.handover_* track the in-flight nomination.
--   • admin_nominate_handover: validates the nominee (active, verified, Stripe payouts
--     ready — a post-handover charge would otherwise die in charge-booking) and books the
--     3-way M&G on the same series with the nominee as provider. Lead → meet_greet_booked.
--   • admin_complete_handover: after the 3-way meet, atomically marks the handover M&G
--     completed, repoints the series (provider/service/locked_price_cents → nominee's
--     listed rate) so future materialisation is automatic, reassigns future pending/
--     confirmed walks at the new rate with history preserved, and moves the lead to
--     transitioned. NOTE the deliberate deviation from the owner-driven M&G flow: the
--     messages-page "mark complete" banner only renders for pending_meet_greet series,
--     and a handover series is already active — the founder is physically at the 3-way
--     meet, so completion is the founder's console action.
--   • trg_meet_greet_gate now requires the completed M&G to match the series' CURRENT
--     provider. Defensive: after handover a series carries a completed M&G from the old
--     provider, and any future re-arm to pending_meet_greet must not be satisfied by it.
--     Backward compatible — every M&G booking is created with the series' provider.
--
-- Both RPCs are EXECUTE-granted to service_role only (called from stripe-api behind its
-- users.is_admin gate). SECURITY DEFINER runs as postgres, so the TRU-171 price-guard
-- triggers pass.
--
-- Applied to the live DB via apply_migration (Supabase branching is broken on this repo);
-- committed here for version control (see TRU-145). 14-digit unique prefix.

alter table public.carer_requests
  add column if not exists handover_provider_id   uuid references public.provider_profiles(id) on delete set null,
  add column if not exists handover_service_id    uuid references public.provider_services(id) on delete set null,
  add column if not exists handover_mg_booking_id uuid references public.bookings(id) on delete set null;

-- ── provider-matched meet & greet gate ────────────────────────────────────────
create or replace function public.trg_meet_greet_gate()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if OLD.status = 'pending_meet_greet' and NEW.status = 'active' then
    if not exists (
      select 1 from public.bookings b
      where b.series_id = NEW.id
        and b.is_meet_and_greet = true
        and b.status = 'completed'
        and b.provider_id = NEW.provider_id  -- TRU-225: the M&G must be with the current carer
    ) then
      raise exception 'Cannot activate series % before its meet & greet is completed', NEW.id
        using errcode = 'check_violation';
    end if;
  end if;
  return NEW;
end;
$function$;

revoke all on function public.trg_meet_greet_gate() from public, anon, authenticated;

-- ── nominate: book the 3-way M&G with the incoming carer ─────────────────────
create or replace function public.admin_nominate_handover(
  p_request_id          uuid,
  p_provider_profile_id uuid,
  p_service_id          uuid,
  p_mg_scheduled_at     timestamptz
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  rq  public.carer_requests%rowtype;
  s   public.booking_series%rowtype;
  pp  public.provider_profiles%rowtype;
  svc public.provider_services%rowtype;
  cur_type text;
  v_mg_id  uuid;
begin
  select * into rq from public.carer_requests where id = p_request_id;
  if not found then raise exception 'Lead % not found', p_request_id; end if;
  if rq.status in ('transitioned', 'lost', 'closed') then
    raise exception 'Lead % is already resolved (%)', p_request_id, rq.status;
  end if;
  if rq.assigned_series_id is null then
    raise exception 'Lead % has no booking series to hand over', p_request_id;
  end if;

  select * into s from public.booking_series where id = rq.assigned_series_id;
  if not found then raise exception 'Series % not found', rq.assigned_series_id; end if;
  if s.status <> 'active' then
    raise exception 'Series % is not active (%) — handover applies to a running series', s.id, s.status;
  end if;

  select * into pp from public.provider_profiles where id = p_provider_profile_id;
  if not found then raise exception 'Carer profile % not found', p_provider_profile_id; end if;
  if not pp.is_active or not pp.is_verified then
    raise exception 'Nominee must be an active, verified carer';
  end if;
  -- Hard requirement: without a payouts-ready connected account, the first post-handover
  -- completion charge fails in charge-booking.
  if pp.stripe_account_id is null or not coalesce(pp.payouts_enabled, false) then
    raise exception 'Nominee has no payouts-ready Stripe account yet';
  end if;

  select * into svc from public.provider_services where id = p_service_id;
  if not found then raise exception 'Service % not found', p_service_id; end if;
  if svc.provider_id <> pp.user_id then
    raise exception 'Service % does not belong to the nominee', p_service_id;
  end if;
  if not svc.is_available or svc.price_cents is null then
    raise exception 'Nominee service is unavailable or has no price';
  end if;
  select ps.service_type into cur_type from public.provider_services ps where ps.id = s.service_id;
  if cur_type is not null and svc.service_type <> cur_type then
    raise exception 'Nominee service type (%) does not match the series (%)', svc.service_type, cur_type;
  end if;

  -- The 3-way M&G: same series, incoming carer as provider. Seeds the owner↔carer
  -- conversation and, once completed, satisfies the provider-matched gate for the pair.
  insert into public.bookings (
    customer_id, provider_id, pet_id, service_id, status,
    scheduled_at, duration_mins, total_cents, is_meet_and_greet, series_id
  ) values (
    s.customer_id, pp.id,
    (select sp.pet_id from public.series_pets sp where sp.series_id = s.id limit 1),
    p_service_id, 'confirmed', p_mg_scheduled_at, 30, 0, true, s.id
  ) returning id into v_mg_id;

  insert into public.booking_pets (booking_id, pet_id)
  select v_mg_id, sp.pet_id from public.series_pets sp where sp.series_id = s.id;

  update public.carer_requests set
    handover_provider_id   = pp.id,
    handover_service_id    = p_service_id,
    handover_mg_booking_id = v_mg_id,
    status                 = 'meet_greet_booked'
  where id = p_request_id;

  return v_mg_id;
end; $$;

revoke all on function public.admin_nominate_handover(uuid, uuid, uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.admin_nominate_handover(uuid, uuid, uuid, timestamptz) to service_role;

-- ── complete: transition the series to the nominee at their listed rate ───────
create or replace function public.admin_complete_handover(
  p_request_id  uuid,
  p_resolved_by uuid
) returns integer language plpgsql security definer set search_path = public as $$
declare
  rq        public.carer_requests%rowtype;
  s         public.booking_series%rowtype;
  svc       public.provider_services%rowtype;
  mg_status text;
  v_pets    int;
  v_price   int;
  v_moved   int;
begin
  select * into rq from public.carer_requests where id = p_request_id;
  if not found then raise exception 'Lead % not found', p_request_id; end if;
  if rq.status in ('transitioned', 'lost', 'closed') then
    raise exception 'Lead % is already resolved (%)', p_request_id, rq.status;
  end if;
  if rq.handover_provider_id is null or rq.handover_service_id is null or rq.handover_mg_booking_id is null then
    raise exception 'Lead % has no nominated handover', p_request_id;
  end if;

  select status into mg_status from public.bookings where id = rq.handover_mg_booking_id;
  if mg_status = 'cancelled' then
    raise exception 'The 3-way meet & greet was cancelled — nominate again';
  end if;
  -- The founder is at the 3-way meet; completing the handover completes the M&G
  -- (the owner-side banner only renders for pending_meet_greet series).
  if mg_status <> 'completed' then
    update public.bookings
       set status = 'completed', completed_at = now(), updated_at = now()
     where id = rq.handover_mg_booking_id;
  end if;

  select * into s from public.booking_series where id = rq.assigned_series_id;
  if not found then raise exception 'Series % not found', rq.assigned_series_id; end if;

  select * into svc from public.provider_services where id = rq.handover_service_id;
  if not found or svc.price_cents is null then
    raise exception 'Nominee service is missing or unpriced';
  end if;
  select count(*) into v_pets from public.series_pets where series_id = s.id;
  v_price := svc.price_cents + greatest(0, v_pets - 1) * coalesce(svc.additional_pet_price_cents, 0);

  -- Repoint the series: future materialisation (generate_series_bookings copies
  -- provider_id + locked_price_cents) is automatically at the new carer's rate.
  update public.booking_series set
    provider_id        = rq.handover_provider_id,
    service_id         = rq.handover_service_id,
    locked_price_cents = v_price
  where id = s.id;

  -- Reassign future, not-yet-walked bookings at the new rate. Completed founder walks
  -- keep provider/price history untouched (TRU-139 pattern via original_provider_id).
  update public.bookings b set
    original_provider_id = coalesce(b.original_provider_id, b.provider_id),
    provider_id          = rq.handover_provider_id,
    service_id           = rq.handover_service_id,
    total_cents          = v_price,
    duration_mins        = coalesce(svc.duration_mins, b.duration_mins),
    updated_at           = now()
  where b.series_id = s.id
    and not coalesce(b.is_meet_and_greet, false)
    and b.scheduled_at > now()
    and b.status in ('pending', 'confirmed');
  get diagnostics v_moved = row_count;

  update public.carer_requests set
    status               = 'transitioned',
    assigned_provider_id = rq.handover_provider_id,
    resolved_at          = now(),
    resolved_by          = p_resolved_by
  where id = p_request_id;

  return v_moved;
end; $$;

revoke all on function public.admin_complete_handover(uuid, uuid) from public, anon, authenticated;
grant execute on function public.admin_complete_handover(uuid, uuid) to service_role;
