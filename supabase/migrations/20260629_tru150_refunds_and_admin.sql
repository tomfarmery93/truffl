-- TRU-150: refunds + admin gating.
-- Admin flag for the founder (gates the refund tools, enforced server-side in stripe-api).
-- Refund tracking + the 'refunded' payment state.
--
-- Applied to the live DB via apply_migration (Supabase branching is broken on this repo);
-- committed here for version control. The "Supabase Preview" check on the PR is expected to
-- fail and is non-blocking (see TRU-145).
alter table public.users add column if not exists is_admin boolean not null default false;

alter table public.bookings
  add column if not exists refunded_at timestamptz,
  add column if not exists stripe_refund_id text;

alter table public.bookings drop constraint if exists bookings_payment_status_check;
alter table public.bookings add constraint bookings_payment_status_check
  check (payment_status in ('unpaid','processing','paid','failed','refunded'));
