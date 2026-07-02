-- TRU-149: notify the customer when an off-session charge fails on completion.
-- Mirrors the email pipeline (private.notify_email → send-notification). Exception-wrapped so
-- an email hiccup can never roll back the booking write.
--
-- Applied to the live DB via apply_migration (Supabase branching is broken on this repo);
-- committed here for version control. The "Supabase Preview" check on the PR is expected to
-- fail and is non-blocking (see TRU-145).
create or replace function private.tg_payment_failed() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if NEW.payment_status = 'failed' and OLD.payment_status is distinct from 'failed' then
    begin perform private.notify_email(jsonb_build_object('type','payment_failed','booking_id',NEW.id));
    exception when others then null; end;
  end if;
  return NEW;
end; $$;

drop trigger if exists trg_email_payment_failed on public.bookings;
create trigger trg_email_payment_failed after update on public.bookings for each row execute function private.tg_payment_failed();
