-- TRU-137: walker cancellation flow + minimum-notice policy.
-- TRU-138: covered-cancellation founder alert (the event fires here; the email is
-- rendered/sent by the send-notification edge function, type 'cover_cancellation').
--
-- Policy constants (MVP, founder-changeable by editing the trigger fn):
--   * minimum notice window = 3 hours (cancelling a confirmed walk with less
--     notice — or after its start — is a "late cancellation", treated like a
--     no-show on the walker's record);
--   * cover trigger horizon = 48 hours (a covered walk only pages the founder
--     when it's actually imminent; further-out walks can simply be rebooked).
--
-- Scope decisions (per ticket): cancellations only, no no-show detection; cover
-- applies to walks and drop-ins only; declining a *pending* request is not a
-- cancellation (counters and cover fire only when a CONFIRMED booking is
-- cancelled by its walker). Series cascades cancel each future booking, so each
-- confirmed one counts individually and each covered one within the horizon
-- alerts individually.
--
-- Applied to the live DB via apply_migration; committed for version control.

alter table public.bookings
  add column if not exists cancel_reason text,
  add column if not exists cancelled_by text
    check (cancelled_by in ('customer','provider','admin')),
  add column if not exists cancelled_at timestamptz,
  add column if not exists late_cancellation boolean,
  add column if not exists cover_status text not null default 'none'
    check (cover_status in ('none','triggered','reassigned','fell_through'));

alter table public.provider_profiles
  add column if not exists cancellation_count integer not null default 0,
  add column if not exists late_cancellation_count integer not null default 0;

-- ── Stamp pass (BEFORE): who cancelled, when, late?, covered? ────────────────
create or replace function public.trg_booking_cancel_stamp()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_service_type text;
begin
  if NEW.status = 'cancelled' and OLD.status is distinct from 'cancelled' then
    NEW.cancelled_at := coalesce(NEW.cancelled_at, now());

    if NEW.cancelled_by is null then
      if exists (select 1 from provider_profiles pp
                 where pp.id = NEW.provider_id and pp.user_id = auth.uid()) then
        NEW.cancelled_by := 'provider';
      elsif exists (select 1 from customer_profiles cp
                    where cp.id = NEW.customer_id and cp.user_id = auth.uid()) then
        NEW.cancelled_by := 'customer';
      elsif exists (select 1 from users u
                    where u.id = auth.uid() and u.is_admin) then
        NEW.cancelled_by := 'admin';
      end if;
    end if;

    -- Reliability + cover only apply when a walker cancels a CONFIRMED booking.
    if NEW.cancelled_by = 'provider' and OLD.status = 'confirmed' then
      -- Late = inside the 3-hour minimum-notice window (or after the start).
      NEW.late_cancellation := (NEW.scheduled_at - now()) < interval '3 hours';

      select ps.service_type into v_service_type
        from provider_services ps where ps.id = NEW.service_id;

      if v_service_type in ('dog_walking', 'drop_in')
         and not coalesce(NEW.is_meet_and_greet, false)
         and NEW.scheduled_at > now()
         and NEW.scheduled_at < now() + interval '48 hours'
         and exists (
           select 1
             from customer_profiles cp
             join private.backup_access ba on ba.customer_id = cp.id
            where cp.id = NEW.customer_id
              and cp.backup_cover_enabled
         ) then
        NEW.cover_status := 'triggered';
      end if;
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists booking_cancel_stamp on public.bookings;
create trigger booking_cancel_stamp
  before update of status on public.bookings
  for each row execute function public.trg_booking_cancel_stamp();

-- ── Effects pass (AFTER): reliability counters + founder alert ───────────────
create or replace function public.trg_booking_cancel_effects()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if NEW.status = 'cancelled' and OLD.status is distinct from 'cancelled'
     and NEW.cancelled_by = 'provider' and OLD.status = 'confirmed' then
    update provider_profiles
       set cancellation_count = cancellation_count + 1,
           late_cancellation_count = late_cancellation_count
             + (case when coalesce(NEW.late_cancellation, false) then 1 else 0 end)
     where id = NEW.provider_id;

    if NEW.cover_status = 'triggered' then
      -- Same fire-and-forget pg_net path as the email pipeline; an alert hiccup
      -- must never roll back the cancellation write.
      begin
        perform private.notify_email(
          jsonb_build_object('type', 'cover_cancellation', 'booking_id', NEW.id));
      exception when others then null;
      end;
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists booking_cancel_effects on public.bookings;
create trigger booking_cancel_effects
  after update of status on public.bookings
  for each row execute function public.trg_booking_cancel_effects();

-- Internal trigger functions — not RPC-callable (TRU-153 pattern).
revoke execute on function public.trg_booking_cancel_stamp() from public, anon, authenticated;
revoke execute on function public.trg_booking_cancel_effects() from public, anon, authenticated;

-- ── Series cascade: record a reason on the cancelled rows ────────────────────
-- Same body as the TRU-14 version, plus cancel_reason so cascaded cancellations
-- always carry a reason (AC: "walker cancellation always records a reason").
create or replace function public.trg_series_cancelled()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if NEW.status = 'cancelled' and (OLD.status is distinct from 'cancelled') then
    update public.bookings
       set status = 'cancelled',
           cancel_reason = coalesce(cancel_reason, 'Recurring schedule cancelled'),
           updated_at = now()
     where series_id = NEW.id
       and not coalesce(is_meet_and_greet, false)
       and status in ('pending', 'confirmed')
       and scheduled_at > now();
  end if;
  return NEW;
end;
$$;

-- ── Founder-alert data (TRU-138) ─────────────────────────────────────────────
-- The ONE operational surface where stored access detail is exposed. The private
-- schema isn't reachable over the API, so send-notification (service role) reads
-- through this definer fn. service_role only — not callable by users.
create or replace function public.get_cover_details(p_booking_id uuid)
returns jsonb
language plpgsql security definer stable set search_path = public
as $$
declare
  b public.bookings%rowtype;
  result jsonb;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then return null; end if;

  select jsonb_build_object(
    'access_location', ba.access_location,
    'access_code',     ba.access_code,
    'access_notes',    ba.access_notes,
    'consent_at',      ba.consent_at,
    'consent_version', ba.consent_version,
    'address',         cp.address,
    'suburb',          cp.suburb,
    'postcode',        cp.postcode,
    'owner_name',      trim(coalesce(u.first_name,'') || ' ' || coalesce(u.last_name,'')),
    'owner_phone',     u.phone,
    'owner_email',     u.email
  ) into result
  from customer_profiles cp
  join users u on u.id = cp.user_id
  left join private.backup_access ba on ba.customer_id = cp.id
  where cp.id = b.customer_id;

  return result;
end;
$$;

revoke all on function public.get_cover_details(uuid) from public, anon, authenticated;
grant execute on function public.get_cover_details(uuid) to service_role;
