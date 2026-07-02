-- TRU-139: reassign a covered booking to the backup (founder) + payment handling.
--
-- Reassignment model: the booking's provider_id is swapped to the backup's
-- provider profile (created inactive+unverified on first use, so it is never
-- searchable) and the originally booked walker is snapshotted in
-- original_provider_id — records always distinguish booked walker from actual
-- walker, and walk tracking / RLS / owner UI keep working unchanged for the
-- covered walk. Payment: charge-booking charges the owner the full original
-- price but omits the destination transfer for cover_status='reassigned', so
-- the walker share is retained by the platform and the original walker is not
-- paid (they cancelled).
--
-- Fall-through: cover_status='fell_through' + a customer_credits row. Credits
-- are MANUAL at MVP (decided with Tom): admin-issued, admin-redeemed, visible
-- to the owner — the charge engine does NOT auto-apply them.
--
-- Applied to the live DB via apply_migration; committed for version control.

alter table public.bookings
  add column if not exists original_provider_id uuid references public.provider_profiles(id);

create table if not exists public.customer_credits (
  id            uuid primary key default gen_random_uuid(),
  customer_id   uuid not null references public.customer_profiles(id) on delete cascade,
  amount_cents  integer not null check (amount_cents > 0),
  reason        text,
  booking_id    uuid references public.bookings(id) on delete set null,
  created_at    timestamptz not null default now(),
  redeemed_at   timestamptz,
  redeemed_note text
);
create index if not exists idx_customer_credits_customer
  on public.customer_credits (customer_id, redeemed_at);

alter table public.customer_credits enable row level security;

-- Owners can see their own credits (profile banner); only the admin console
-- (service role via stripe-api) writes them.
drop policy if exists credits_owner_read on public.customer_credits;
create policy credits_owner_read on public.customer_credits
  for select to authenticated
  using (exists (
    select 1 from public.customer_profiles cp
    where cp.id = customer_credits.customer_id and cp.user_id = auth.uid()
  ));

revoke insert, update, delete on public.customer_credits from anon, authenticated;
grant select on public.customer_credits to authenticated, service_role;
