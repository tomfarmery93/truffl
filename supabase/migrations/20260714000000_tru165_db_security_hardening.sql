-- TRU-165 Epic G — DB security & payment-path hardening.
--
-- TRU-198: public.handle_new_user() is SECURITY DEFINER with an UNPINNED search_path
--          (baseline 00000000000000_baseline.sql:42-56) and runs on every auth signup — the
--          classic Supabase mutable-search-path lint, on the most-executed definer function in
--          the system. tru153 hardened the rest of the definer surface but missed this one. Pin
--          it to '' (the body already fully-qualifies public.users).
-- TRU-201: no indexes exist on the payment columns the webhook / charge / reaper paths filter on
--          (bookings.payment_status, bookings.stripe_payment_intent_id). Add them. (The separate
--          ~50 cold-table initplan/duplicate-policy advisor lints from TRU-142 are NOT addressed
--          here — tracked as remaining scope on TRU-201.)
--
-- Applied to the live DB via apply_migration (Supabase branching is broken on this repo);
-- committed here for version control.

-- ── TRU-198: pin search_path on the signup trigger function ────────────────────
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  insert into public.users (id, auth_id, email, first_name, last_name, role)
  values (
    new.id,
    new.id,
    new.email,
    new.raw_user_meta_data->>'first_name',
    new.raw_user_meta_data->>'last_name',
    coalesce(new.raw_user_meta_data->>'role', 'customer')
  );
  return new;
end;
$function$;

-- ── TRU-201: payment-path indexes ──────────────────────────────────────────────
-- Reaper sweeps `payment_status = 'processing'`; the webhook/charge paths look bookings up by
-- their Stripe PaymentIntent id (null until a charge is attempted, so a partial index).
create index if not exists idx_bookings_payment_status
  on public.bookings (payment_status);

create index if not exists idx_bookings_stripe_pi
  on public.bookings (stripe_payment_intent_id)
  where stripe_payment_intent_id is not null;
