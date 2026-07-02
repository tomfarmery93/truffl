-- TRU-146: Charge on completion (Phase 3 of Stripe payments).
-- When a booking is marked completed, charge the customer's saved card off-session via a
-- Stripe destination charge to the carer's connected account (15% application fee), recorded
-- per booking. A DB trigger dispatches the charge asynchronously (pg_net) so a payment hiccup
-- can never roll back the booking write. Mirrors the email pipeline (private.notify_email).
--
-- Applied to the live DB via apply_migration (Supabase branching is broken on this repo);
-- committed here for version control. The "Supabase Preview" check on the PR is expected to
-- fail and is non-blocking (see TRU-145).

-- Per-booking payment tracking. A single PaymentIntent may settle multiple bookings, so a
-- later fortnightly per-(customer,carer) batch job can reuse the same charge engine.
alter table public.bookings
  add column if not exists payment_status text not null default 'unpaid'
    check (payment_status in ('unpaid','processing','paid','failed')),
  add column if not exists stripe_payment_intent_id text,
  add column if not exists application_fee_cents integer,
  add column if not exists charged_at timestamptz;

-- Fire-and-forget POST to the charge-booking Edge Function, reusing private.stripe_config
-- (function_base_url + shared webhook_secret), inserted out of band so the secret stays out of git.
create or replace function private.charge_booking(p_booking_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare cfg private.stripe_config;
begin
  select * into cfg from private.stripe_config where id = 1 and enabled = true;
  if cfg.function_base_url is null then return; end if;
  perform net.http_post(
    url := cfg.function_base_url || '/charge-booking',
    headers := jsonb_build_object('Content-Type','application/json','x-webhook-secret',cfg.webhook_secret),
    body := jsonb_build_object('booking_id', p_booking_id)
  );
end; $$;

-- Charge a booking when it completes. Never the (free) M&G; never a zero-value or
-- already-charged booking. Wrapped so a charge hiccup can't roll back the completion write.
create or replace function private.tg_charge_on_completion() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if NEW.status = 'completed' and OLD.status is distinct from 'completed'
     and not coalesce(NEW.is_meet_and_greet, false)
     and coalesce(NEW.total_cents, 0) > 0
     and coalesce(NEW.payment_status, 'unpaid') in ('unpaid','failed') then
    begin perform private.charge_booking(NEW.id);
    exception when others then null; end;
  end if;
  return NEW;
end; $$;

drop trigger if exists trg_charge_on_completion on public.bookings;
create trigger trg_charge_on_completion after update on public.bookings for each row execute function private.tg_charge_on_completion();
