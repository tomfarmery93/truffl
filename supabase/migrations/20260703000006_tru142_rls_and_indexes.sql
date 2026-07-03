-- TRU-142 (2/2): DB-side performance from the Supabase advisors (206 lints).
--
-- 1. 15 missing FK indexes (INFO lints) — cheap wins for the joins every page
--    and definer view runs.
-- 2. Hot-table RLS rewrite: gps_pings (polled every few seconds during live walk
--    tracking), walk_sessions, bookings, system_messages, messages.
--    * auth.uid() wrapped as (select auth.uid()) so Postgres evaluates it once
--      per statement instead of once PER ROW (auth_rls_initplan lints).
--    * Duplicate permissive policies consolidated (multiple_permissive_policies:
--      every permissive policy is evaluated for every row) — gps_pings had FOUR
--      SELECT policies, walk_sessions had a dead ALL policy comparing
--      provider_id (a users.id) against provider_profiles.id, which never
--      matched anything.
--    * Legacy `users.auth_id = auth.uid()` sub-lookups simplified to direct
--      user_id checks — users.id == users.auth_id for every row by construction
--      (handle_new_user inserts both as NEW.id; verified 0 rows differ).
--    Row visibility verified identical before/after per role (owner, walker,
--    anon) — see PR.
--
-- Remaining ~50 initplan / duplicate-policy lints on cold tables are ticketed
-- separately. Applied via apply_migration; committed for version control.

-- ── FK indexes ────────────────────────────────────────────────────────────────
create index if not exists idx_booking_pets_pet          on public.booking_pets (pet_id);
create index if not exists idx_booking_series_customer   on public.booking_series (customer_id);
create index if not exists idx_booking_series_provider   on public.booking_series (provider_id);
create index if not exists idx_booking_series_service    on public.booking_series (service_id);
create index if not exists idx_bookings_original_provider on public.bookings (original_provider_id);
create index if not exists idx_bookings_pet              on public.bookings (pet_id);
create index if not exists idx_bookings_service          on public.bookings (service_id);
create index if not exists idx_customer_credits_booking  on public.customer_credits (booking_id);
create index if not exists idx_notifications_booking     on public.notifications (booking_id);
create index if not exists idx_pets_customer             on public.pets (customer_id);
create index if not exists idx_provider_checks_provider  on public.provider_checks (provider_id);
create index if not exists idx_series_pets_pet           on public.series_pets (pet_id);
create index if not exists idx_walk_sessions_provider    on public.walk_sessions (provider_id);
create index if not exists idx_walk_updates_provider     on public.walk_updates (provider_id);
create index if not exists idx_walk_updates_session      on public.walk_updates (walk_session_id);

-- ── gps_pings: 4 SELECT + 2 INSERT → 1 + 1 ───────────────────────────────────
drop policy if exists "Booking parties can view gps pings" on public.gps_pings;
drop policy if exists "Customers can view gps pings for their bookings" on public.gps_pings;
drop policy if exists "Providers can view own gps pings" on public.gps_pings;
drop policy if exists "Providers can create gps pings" on public.gps_pings;
drop policy if exists "Providers can insert gps pings" on public.gps_pings;

create policy gps_pings_parties_read on public.gps_pings
  for select using (
    walk_session_id in (
      select ws.id
      from public.walk_sessions ws
      join public.bookings b on b.id = ws.booking_id
      left join public.customer_profiles cp on cp.id = b.customer_id
      left join public.provider_profiles pp on pp.id = b.provider_id
      where cp.user_id = (select auth.uid()) or pp.user_id = (select auth.uid())
    )
  );
-- walk_sessions.provider_id stores users.id (== auth.uid()); the session owner
-- uploads the pings (web + native tracker both authenticate as that user).
create policy gps_pings_session_owner_insert on public.gps_pings
  for insert with check (
    walk_session_id in (
      select ws.id from public.walk_sessions ws where ws.provider_id = (select auth.uid())
    )
  );

-- ── walk_sessions: 4 read paths (one dead) → 1; owner insert/update ──────────
drop policy if exists "Booking parties can view walk sessions" on public.walk_sessions;
drop policy if exists "Customers can view walk sessions for their bookings" on public.walk_sessions;
drop policy if exists "Providers can view own walk sessions" on public.walk_sessions;
drop policy if exists "Providers can manage own walk sessions" on public.walk_sessions;
drop policy if exists "Providers can create walk sessions" on public.walk_sessions;
drop policy if exists "Providers can update own walk sessions" on public.walk_sessions;

create policy walk_sessions_parties_read on public.walk_sessions
  for select using (
    provider_id = (select auth.uid())
    or booking_id in (
      select b.id from public.bookings b
      join public.customer_profiles cp on cp.id = b.customer_id
      where cp.user_id = (select auth.uid())
    )
  );
create policy walk_sessions_owner_insert on public.walk_sessions
  for insert with check (provider_id = (select auth.uid()));
create policy walk_sessions_owner_update on public.walk_sessions
  for update using (provider_id = (select auth.uid()));

-- ── bookings: 2 SELECT → 1; initplan-safe insert/update ───────────────────────
drop policy if exists "Customers can view own bookings" on public.bookings;
drop policy if exists "Providers can view own bookings" on public.bookings;
drop policy if exists "Customers can create bookings" on public.bookings;
drop policy if exists "Providers can update own bookings" on public.bookings;

create policy bookings_parties_read on public.bookings
  for select using (
    customer_id in (select id from public.customer_profiles where user_id = (select auth.uid()))
    or provider_id in (select id from public.provider_profiles where user_id = (select auth.uid()))
  );
create policy bookings_customer_create on public.bookings
  for insert with check (
    customer_id in (select id from public.customer_profiles where user_id = (select auth.uid()))
  );
create policy bookings_provider_update on public.bookings
  for update using (
    provider_id in (select id from public.provider_profiles where user_id = (select auth.uid()))
  );

-- ── system_messages: initplan-safe ────────────────────────────────────────────
drop policy if exists system_messages_read_own on public.system_messages;
drop policy if exists system_messages_mark_read on public.system_messages;
create policy system_messages_read_own on public.system_messages
  for select to authenticated using (recipient_user_id = (select auth.uid()));
create policy system_messages_mark_read on public.system_messages
  for update to authenticated
  using (recipient_user_id = (select auth.uid()))
  with check (recipient_user_id = (select auth.uid()));

-- ── messages: initplan-safe sender check (participant helper stays — it is a
--    deliberately VOLATILE definer fn, see 20260614000001) ─────────────────────
drop policy if exists messages_insert_participants on public.messages;
create policy messages_insert_participants on public.messages
  for insert with check (
    (select auth.uid()) = sender_id and (
      (conversation_id is not null and private.is_conversation_participant(conversation_id))
      or
      (booking_id is not null and (
        exists (select 1 from public.bookings b join public.customer_profiles cp on cp.id = b.customer_id
                where b.id = messages.booking_id and cp.user_id = (select auth.uid()))
        or exists (select 1 from public.bookings b join public.provider_profiles pp on pp.id = b.provider_id
                where b.id = messages.booking_id and pp.user_id = (select auth.uid()))
      ))
    )
  );
