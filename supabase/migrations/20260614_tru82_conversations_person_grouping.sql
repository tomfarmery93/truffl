-- TRU-82: person-grouped messaging. Conversation = one customer<->provider pair.
-- booking_id is demoted to nullable context; conversation_id owns thread identity.

-- 1. conversations table
create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  customer_user_id uuid not null references public.users(id) on delete cascade,
  provider_user_id uuid not null references public.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  last_message_at timestamptz,
  unique (customer_user_id, provider_user_id)
);
create index conversations_customer_idx on public.conversations(customer_user_id);
create index conversations_provider_idx on public.conversations(provider_user_id);
grant all on public.conversations to anon, authenticated, service_role;

-- 2. messages: add conversation_id, relax booking_id, preserve history if a booking is hard-deleted
alter table public.messages add column conversation_id uuid;
alter table public.messages alter column booking_id drop not null;
alter table public.messages drop constraint messages_booking_id_fkey;
alter table public.messages add constraint messages_booking_id_fkey
  foreign key (booking_id) references public.bookings(id) on delete set null;
alter table public.messages add constraint messages_conversation_id_fkey
  foreign key (conversation_id) references public.conversations(id) on delete cascade;
create index messages_conversation_idx on public.messages(conversation_id, created_at);

-- 3. backfill conversations from existing booking pairs
insert into public.conversations (customer_user_id, provider_user_id)
select distinct cp.user_id, pp.user_id
from public.bookings b
join public.customer_profiles cp on cp.id = b.customer_id
join public.provider_profiles pp on pp.id = b.provider_id
on conflict (customer_user_id, provider_user_id) do nothing;

-- 4. backfill messages.conversation_id from each message's booking pair
update public.messages m
set conversation_id = c.id
from public.bookings b
join public.customer_profiles cp on cp.id = b.customer_id
join public.provider_profiles pp on pp.id = b.provider_id
join public.conversations c on c.customer_user_id = cp.user_id and c.provider_user_id = pp.user_id
where m.booking_id = b.id and m.conversation_id is null;

-- 5. denormalised last_message_at for inbox ordering
update public.conversations c
set last_message_at = sub.mx
from (select conversation_id, max(created_at) mx from public.messages group by conversation_id) sub
where sub.conversation_id = c.id;

-- 6. now that every row is grouped, require conversation_id
alter table public.messages alter column conversation_id set not null;

-- 7. get-or-create conversation on insert (lets callers send only booking_id)
create or replace function public.messages_set_conversation()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_customer uuid; v_provider uuid; v_conv uuid;
begin
  if new.conversation_id is null then
    if new.booking_id is null then
      raise exception 'messages require either conversation_id or booking_id';
    end if;
    select cp.user_id, pp.user_id into v_customer, v_provider
    from bookings b
    join customer_profiles cp on cp.id = b.customer_id
    join provider_profiles pp on pp.id = b.provider_id
    where b.id = new.booking_id;
    if v_customer is null then
      raise exception 'could not resolve conversation for booking %', new.booking_id;
    end if;
    insert into conversations (customer_user_id, provider_user_id)
    values (v_customer, v_provider)
    on conflict (customer_user_id, provider_user_id) do nothing;
    select id into v_conv from conversations
    where customer_user_id = v_customer and provider_user_id = v_provider;
    new.conversation_id := v_conv;
  end if;
  return new;
end;
$$;
create trigger messages_set_conversation_trg
before insert on public.messages
for each row execute function public.messages_set_conversation();

-- 8. keep last_message_at fresh
create or replace function public.messages_bump_conversation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update conversations set last_message_at = new.created_at where id = new.conversation_id;
  return null;
end;
$$;
create trigger messages_bump_conversation_trg
after insert on public.messages
for each row execute function public.messages_bump_conversation();

-- 9. conversations RLS: participant, and only if the pair shares >=1 booking (no stranger DMs)
--    NOTE: superseded by 20260614_tru82_fix_conversation_rls_definer.sql, which moves the
--    booking-existence check into a SECURITY DEFINER helper so the opposite role isn't blocked
--    by per-table RLS on the counterparty's profile. Kept here as applied for history.
alter table public.conversations enable row level security;
create policy conversations_select_participants on public.conversations
for select using (
  (auth.uid() = customer_user_id or auth.uid() = provider_user_id)
  and exists (
    select 1 from bookings b
    join customer_profiles cp on cp.id = b.customer_id
    join provider_profiles pp on pp.id = b.provider_id
    where cp.user_id = conversations.customer_user_id
      and pp.user_id = conversations.provider_user_id
  )
);

-- 10. messages RLS rewritten around conversation participation (booking-party fallback on insert)
drop policy if exists booking_parties_read_messages on public.messages;
drop policy if exists booking_parties_insert_messages on public.messages;
drop policy if exists booking_parties_update_read_at on public.messages;

create policy messages_select_participants on public.messages
for select using (
  exists (select 1 from conversations c where c.id = messages.conversation_id
          and (c.customer_user_id = auth.uid() or c.provider_user_id = auth.uid()))
);

create policy messages_insert_participants on public.messages
for insert with check (
  auth.uid() = sender_id and (
    (conversation_id is not null and exists (
      select 1 from conversations c where c.id = messages.conversation_id
        and (c.customer_user_id = auth.uid() or c.provider_user_id = auth.uid())))
    or
    (booking_id is not null and (
      exists (select 1 from bookings b join customer_profiles cp on cp.id = b.customer_id
              where b.id = messages.booking_id and cp.user_id = auth.uid())
      or exists (select 1 from bookings b join provider_profiles pp on pp.id = b.provider_id
              where b.id = messages.booking_id and pp.user_id = auth.uid())))
  )
);

create policy messages_update_participants on public.messages
for update using (
  exists (select 1 from conversations c where c.id = messages.conversation_id
          and (c.customer_user_id = auth.uid() or c.provider_user_id = auth.uid()))
);

-- 11. participant-name lookup analogous to booking_party_names, scoped to the caller
create view public.conversation_party_names as
select c.id as conversation_id,
  c.customer_user_id, cu.first_name as customer_first_name, cu.last_name as customer_last_name,
  c.provider_user_id, pu.first_name as provider_first_name, pu.last_name as provider_last_name,
  c.last_message_at
from public.conversations c
join public.users cu on cu.id = c.customer_user_id
join public.users pu on pu.id = c.provider_user_id
where c.customer_user_id = auth.uid() or c.provider_user_id = auth.uid();
grant select on public.conversation_party_names to anon, authenticated, service_role;
