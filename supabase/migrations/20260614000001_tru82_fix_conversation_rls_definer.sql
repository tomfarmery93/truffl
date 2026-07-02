-- TRU-82 follow-up: the policies in 20260614_tru82_conversations_person_grouping.sql
-- inlined joins across BOTH parties' profile tables. Per-table RLS blocks the opposite
-- role (e.g. a provider can't read customer_profiles), so a provider saw zero conversations.
-- Move those checks into SECURITY DEFINER helpers in a private schema (not exposed by
-- PostgREST, so not callable as RPC).

create schema if not exists private;
grant usage on schema private to anon, authenticated, service_role;

-- Does this exact (customer_user, provider_user) pair share at least one booking?
create or replace function private.pair_shares_booking(cust uuid, prov uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from bookings b
    join customer_profiles cp on cp.id = b.customer_id
    join provider_profiles pp on pp.id = b.provider_id
    where cp.user_id = cust and pp.user_id = prov
  );
$$;

-- Is the current user a participant of this conversation?
-- VOLATILE (not STABLE): this is consulted in the messages INSERT WITH CHECK, which runs
-- AFTER the BEFORE trigger creates the conversation in the same statement. A STABLE function
-- uses the statement-start snapshot and can't see that new row, so the first message of a
-- pair would be rejected. VOLATILE takes a fresh snapshot per call.
create or replace function private.is_conversation_participant(cid uuid)
returns boolean language sql security definer volatile set search_path = public as $$
  select exists (
    select 1 from conversations c
    where c.id = cid and (c.customer_user_id = auth.uid() or c.provider_user_id = auth.uid())
  );
$$;

grant execute on function private.pair_shares_booking(uuid, uuid) to anon, authenticated, service_role;
grant execute on function private.is_conversation_participant(uuid) to anon, authenticated, service_role;

-- conversations: participant AND the pair shares a booking (no stranger DMs)
drop policy if exists conversations_select_participants on public.conversations;
create policy conversations_select_participants on public.conversations
for select using (
  (auth.uid() = customer_user_id or auth.uid() = provider_user_id)
  and private.pair_shares_booking(customer_user_id, provider_user_id)
);

-- messages: gate on conversation participation via the definer helper
drop policy if exists messages_select_participants on public.messages;
create policy messages_select_participants on public.messages
for select using ( private.is_conversation_participant(conversation_id) );

drop policy if exists messages_update_participants on public.messages;
create policy messages_update_participants on public.messages
for update using ( private.is_conversation_participant(conversation_id) );

drop policy if exists messages_insert_participants on public.messages;
create policy messages_insert_participants on public.messages
for insert with check (
  auth.uid() = sender_id and (
    (conversation_id is not null and private.is_conversation_participant(conversation_id))
    or
    (booking_id is not null and (
      exists (select 1 from bookings b join customer_profiles cp on cp.id = b.customer_id
              where b.id = messages.booking_id and cp.user_id = auth.uid())
      or exists (select 1 from bookings b join provider_profiles pp on pp.id = b.provider_id
              where b.id = messages.booking_id and pp.user_id = auth.uid())
    ))
  )
);

-- Trigger functions don't need to be callable as PostgREST RPC. Revoking EXECUTE from the
-- API roles removes the /rpc exposure; triggers still fire (Postgres does not check EXECUTE
-- on trigger functions for the triggering role).
revoke execute on function public.messages_set_conversation() from anon, authenticated;
revoke execute on function public.messages_bump_conversation() from anon, authenticated;
