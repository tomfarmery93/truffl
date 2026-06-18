-- TRU-126: carers acknowledge the two standards/safety guideline pages once before
-- they can take bookings. Providers already have UPDATE RLS on their own row, so
-- the acknowledge action is a direct PATCH; no new policy needed.
--
-- Applied to the live DB via apply_migration; committed here for version control.
ALTER TABLE public.provider_profiles
  ADD COLUMN IF NOT EXISTS acknowledged_commitments_at timestamptz,
  ADD COLUMN IF NOT EXISTS acknowledged_safety_at      timestamptz;
