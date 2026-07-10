-- TRU-173: reaper for bookings stranded in payment_status = 'processing'.
--
-- charge-booking atomically claims a booking (unpaid/failed -> processing) before calling
-- Stripe. If the function crashes after the claim, the booking is stuck in 'processing'
-- forever — no retry, no sweep, nothing surfaces it, so that booking silently never charges.
--
-- Fix: stamp when the claim happened (bookings.payment_processing_at, set by the edge fn),
-- then a pg_cron sweep RETRIES anything stale past a timeout via private.charge_booking.
-- Retry (not mark-failed) is deliberate:
--   * charge-booking uses idempotency key charge_<booking_id>, so if the original attempt had
--     actually succeeded at Stripe before crashing, the retry returns the same succeeded
--     PaymentIntent and the booking settles to 'paid' — no double charge.
--   * marking a booking 'failed' would fire private.tg_payment_failed (TRU-149) and email the
--     customer about a failure that may never have really happened.
--
-- Applied to the live DB via apply_migration; committed here for version control. The
-- "Supabase Preview" PR check is expected to fail and is non-blocking (see TRU-145).

-- 1. When the booking was claimed into 'processing' — lets the sweep measure staleness.
alter table public.bookings
  add column if not exists payment_processing_at timestamptz;

-- 2. Retry bookings stuck in 'processing' longer than the timeout. Returns how many it retried.
--    A null stamp is treated as stale (legacy rows claimed before this column existed).
create or replace function private.reap_stranded_charges(p_timeout interval default '15 minutes')
returns integer language plpgsql security definer set search_path = '' as $$
declare
  r record;
  n int := 0;
begin
  for r in
    select id from public.bookings
    where payment_status = 'processing'
      and (payment_processing_at is null or payment_processing_at < now() - p_timeout)
  loop
    -- Release the stuck claim so charge-booking can re-claim (unpaid/failed -> processing).
    update public.bookings
       set payment_status = 'unpaid', payment_processing_at = null
     where id = r.id;
    -- Re-dispatch the charge (idempotency-keyed, so a prior success is not double-charged).
    perform private.charge_booking(r.id);
    n := n + 1;
  end loop;
  if n > 0 then
    raise log 'reap_stranded_charges: retried % stranded booking(s)', n;
  end if;
  return n;
end; $$;

-- Runs only from cron (definer context); never reachable over the public API.
revoke execute on function private.reap_stranded_charges(interval) from public, anon, authenticated;

-- 3. Sweep every 10 minutes via pg_cron (default 15-minute staleness window).
create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule('reap-stranded-charges')
  where exists (select 1 from cron.job where jobname = 'reap-stranded-charges');
end $$;

select cron.schedule('reap-stranded-charges', '*/10 * * * *', $$select private.reap_stranded_charges();$$);
