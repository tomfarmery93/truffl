-- TRU-118: transactional email sending pipeline (DB triggers -> Edge Function -> Resend).
--
-- DB events POST to the `send-notification` Edge Function via pg_net. The function URL +
-- shared webhook secret live in private.email_config, which is populated OUT OF BAND (not in
-- this migration / not in git) so the secret never lands in source control:
--
--   insert into private.email_config (id, function_url, webhook_secret, enabled)
--   values (1, 'https://<project>.supabase.co/functions/v1/send-notification', '<secret>', true)
--   on conflict (id) do update set function_url=excluded.function_url,
--     webhook_secret=excluded.webhook_secret, enabled=excluded.enabled;
--
-- The same <secret> must be set as the function's WEBHOOK_SECRET env var.

create extension if not exists pg_net;

create schema if not exists private;

create table if not exists private.email_config (
  id int primary key default 1,
  function_url text not null,
  webhook_secret text not null,
  enabled boolean not null default true,
  constraint email_config_single_row check (id = 1)
);
alter table private.email_config enable row level security;
-- no policies: only the table owner / SECURITY DEFINER functions below can read it.

-- Fire-and-forget POST of an event payload to the Edge Function.
create or replace function private.notify_email(payload jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare cfg private.email_config;
begin
  select * into cfg from private.email_config where id = 1 and enabled = true;
  if cfg.function_url is null then return; end if;
  perform net.http_post(
    url := cfg.function_url,
    headers := jsonb_build_object('Content-Type','application/json','x-webhook-secret',cfg.webhook_secret),
    body := payload
  );
end; $$;

-- Each trigger wraps the notify in its own block so an email hiccup can never roll back
-- or block the underlying booking/walk/message operation.

-- booking request -> provider
create or replace function private.tg_booking_request() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if NEW.status = 'pending' and coalesce(NEW.is_meet_and_greet,false) = false then
    begin perform private.notify_email(jsonb_build_object('type','booking_request','booking_id',NEW.id));
    exception when others then null; end;
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_email_booking_request on public.bookings;
create trigger trg_email_booking_request after insert on public.bookings for each row execute function private.tg_booking_request();

-- booking confirmed -> customer
create or replace function private.tg_booking_confirmed() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if NEW.status = 'confirmed' and OLD.status is distinct from 'confirmed' then
    begin perform private.notify_email(jsonb_build_object('type','booking_confirmed','booking_id',NEW.id));
    exception when others then null; end;
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_email_booking_confirmed on public.bookings;
create trigger trg_email_booking_confirmed after update on public.bookings for each row execute function private.tg_booking_confirmed();

-- walk started -> customer
create or replace function private.tg_walk_started() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if NEW.status = 'active' then
    begin perform private.notify_email(jsonb_build_object('type','walk_started','walk_session_id',NEW.id));
    exception when others then null; end;
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_email_walk_started on public.walk_sessions;
create trigger trg_email_walk_started after insert on public.walk_sessions for each row execute function private.tg_walk_started();

-- walk completed -> customer + carer
create or replace function private.tg_walk_completed() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if NEW.status = 'completed' and OLD.status is distinct from 'completed' then
    begin perform private.notify_email(jsonb_build_object('type','walk_completed','walk_session_id',NEW.id));
    exception when others then null; end;
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_email_walk_completed on public.walk_sessions;
create trigger trg_email_walk_completed after update on public.walk_sessions for each row execute function private.tg_walk_completed();

-- new message -> the other party
create or replace function private.tg_new_message() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin perform private.notify_email(jsonb_build_object('type','new_message','message_id',NEW.id));
  exception when others then null; end;
  return NEW;
end; $$;
drop trigger if exists trg_email_new_message on public.messages;
create trigger trg_email_new_message after insert on public.messages for each row execute function private.tg_new_message();
