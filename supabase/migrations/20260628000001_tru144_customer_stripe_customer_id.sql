-- TRU-144: Customer SetupIntent (Phase 2 of Stripe payments).
-- Save a customer's card off-session at the meet & greet proceed step. Store the Stripe
-- Customer id so the saved card can be charged on service completion (Phase 3).
--
-- Applied to the live DB via apply_migration (Supabase branching is broken on this repo);
-- committed here for version control.
alter table public.customer_profiles
  add column if not exists stripe_customer_id text;
