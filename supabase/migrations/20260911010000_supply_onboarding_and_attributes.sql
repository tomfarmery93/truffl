-- Supply-side Phase 2, positioning and signup (GitHub #173, #174).
--
--   * provider_profiles.onboarding: first-run progress for the tools (which steps a carer has
--     done or dismissed on /schedule/), kept on the profile rather than the device so it
--     follows them between phone and laptop. Free-form jsonb: {"calendar_subscribed_at": ts,
--     "dismissed_at": ts}. Steps that can be inferred from data (has a client, has a job)
--     are not stored.
--
--   * provider_attributes: registration no longer collects the "capabilities" owners can
--     filter by (own vehicle, large dogs OK, ...); they move to the dashboard's Services tab.
--     The baseline's "Providers can manage own attributes" ALL policy compares provider_id to
--     provider_profiles.id, but every row is keyed by users.id (registration has always
--     inserted provider_id = auth.uid(), and the SELECT/INSERT policies compare to auth.uid()),
--     so a carer could insert a capability but never update or remove it. Add UPDATE and
--     DELETE policies keyed the way the rows actually are.

alter table public.provider_profiles
  add column if not exists onboarding jsonb not null default '{}'::jsonb;

drop policy if exists provider_attributes_owner_update on public.provider_attributes;
create policy provider_attributes_owner_update on public.provider_attributes
  for update to authenticated
  using (provider_id = (select auth.uid()))
  with check (provider_id = (select auth.uid()));

drop policy if exists provider_attributes_owner_delete on public.provider_attributes;
create policy provider_attributes_owner_delete on public.provider_attributes
  for delete to authenticated
  using (provider_id = (select auth.uid()));
