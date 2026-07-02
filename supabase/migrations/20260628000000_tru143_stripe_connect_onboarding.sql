-- TRU-143: Stripe Connect Express onboarding for carers (Phase 1 of Stripe payments).
-- Track each provider's connected account + payout readiness, and add a private single-row
-- config table (mirrors private.email_config) the Phase-3 charge pipeline uses to POST to the
-- charge Edge Function via pg_net.
--
-- Applied to the live DB via apply_migration (Supabase branching is broken on this repo);
-- committed here for version control. The "Supabase Preview" check on the PR is expected to
-- fail and is non-blocking.

alter table public.provider_profiles
  add column if not exists stripe_account_id text,
  add column if not exists payouts_enabled boolean not null default false,
  add column if not exists charges_enabled boolean not null default false;

-- Single-row config for the Stripe charge pipeline (Phase 3). Mirrors private.email_config:
-- populated OUT OF BAND (not in git) so the shared secret never lands in source control:
--   insert into private.stripe_config (id, function_base_url, webhook_secret, enabled)
--   values (1, 'https://<project>.supabase.co/functions/v1', '<secret>', true)
--   on conflict (id) do update set function_base_url=excluded.function_base_url,
--     webhook_secret=excluded.webhook_secret, enabled=excluded.enabled;
create schema if not exists private;
create table if not exists private.stripe_config (
  id int primary key default 1,
  function_base_url text not null,
  webhook_secret text not null,
  enabled boolean not null default true,
  constraint stripe_config_single_row check (id = 1)
);
alter table private.stripe_config enable row level security;
-- no policies: only the table owner / SECURITY DEFINER functions can read it.
