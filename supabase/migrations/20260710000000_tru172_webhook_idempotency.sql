-- TRU-172: Stripe webhook idempotency + account.updated ordering guard.
--
-- Two correctness bugs in supabase/functions/stripe-webhook:
--   1. No dedupe on Stripe's event.id — a replayed event re-ran its handler.
--   2. account.updated blindly wrote whatever the event said, so an out-of-order or
--      replayed event could flip a carer's payouts_enabled/charges_enabled BACKWARDS.
--
-- DB logic lives in SECURITY DEFINER RPCs (matches the codebase pattern) so the dedupe
-- store can stay in `private` and PostgREST never needs the private schema exposed. The
-- webhook (service-role client) calls these via sb.rpc(...), hence the explicit
-- grant to service_role after revoking the public/anon/authenticated defaults.
--
-- Applied to the live DB via apply_migration (Supabase branching is broken on this repo);
-- committed here for version control.

-- 1. Dedupe store: one row per processed Stripe event id. Written only by the RPC below.
create table if not exists private.stripe_processed_events (
  event_id      text primary key,
  type          text,
  event_created timestamptz,
  processed_at  timestamptz not null default now()
);

-- 2. High-water mark for account.updated ordering.
alter table public.provider_profiles
  add column if not exists last_account_event_at timestamptz;

-- 3a. Has this event already been fully processed? Read-only pre-check so the webhook can
--     short-circuit a replay before running any handler.
create or replace function public.stripe_event_seen(p_event_id text)
returns boolean language sql security definer set search_path = '' stable as $$
  select exists (select 1 from private.stripe_processed_events where event_id = p_event_id);
$$;

-- 3b. Record an event id AFTER its handler succeeds. Idempotent (on conflict do nothing) so a
--     retry that races is harmless. Recording only on success means a transient handler failure
--     is safely reprocessed on Stripe's retry rather than being permanently swallowed.
create or replace function public.record_stripe_event(p_event_id text, p_type text, p_created bigint)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into private.stripe_processed_events (event_id, type, event_created)
  values (p_event_id, p_type, to_timestamp(p_created))
  on conflict (event_id) do nothing;
end; $$;

-- 4. Apply account.updated only if strictly newer than the last applied event for this
--    account. Atomic monotonic guard — replayed/out-of-order events are no-ops.
create or replace function public.apply_stripe_account_update(
  p_account_id text, p_payouts boolean, p_charges boolean, p_created bigint)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.provider_profiles
     set payouts_enabled       = p_payouts,
         charges_enabled       = p_charges,
         last_account_event_at = to_timestamp(p_created)
   where stripe_account_id = p_account_id
     and (last_account_event_at is null or last_account_event_at < to_timestamp(p_created));
end; $$;

-- 5. Reachable only via the service-role webhook, never over the public API.
revoke execute on function public.stripe_event_seen(text) from public, anon, authenticated;
grant  execute on function public.stripe_event_seen(text) to service_role;
revoke execute on function public.record_stripe_event(text, text, bigint) from public, anon, authenticated;
grant  execute on function public.record_stripe_event(text, text, bigint) to service_role;
revoke execute on function public.apply_stripe_account_update(text, boolean, boolean, bigint) from public, anon, authenticated;
grant  execute on function public.apply_stripe_account_update(text, boolean, boolean, bigint) to service_role;
