-- Fix: the owner's single-booking Cancel button never worked. profile/index.html
-- PATCHes bookings.status='cancelled', but customers have no UPDATE policy on
-- bookings (only providers do), so the PATCH matches 0 rows and the UI shows
-- "Couldn't save — you may not have permission". Verified live: an RLS-scoped
-- UPDATE as a test customer updates 0 rows.
--
-- Fixed with a definer RPC rather than a customer UPDATE policy: an UPDATE policy
-- can't restrict WHICH columns change, so it would let an owner PATCH total_cents
-- or payment_status. The RPC allows exactly one transition — cancel your own
-- pending booking (any time) or confirmed booking that hasn't started — and
-- nothing else. Meet & greets are excluded (they cancel through the series
-- decline flow). The TRU-137 cancel triggers still fire: cancelled_by stamps as
-- 'customer' via auth.uid(), and no walker counters / cover path run (those
-- require cancelled_by='provider').
--
-- Applied to the live DB via apply_migration; committed for version control.

create or replace function public.cancel_my_booking(p_booking_id uuid, p_reason text default null)
returns public.bookings
language plpgsql security definer set search_path = public
as $$
declare
  b public.bookings%rowtype;
begin
  select bk.* into b
  from public.bookings bk
  join public.customer_profiles cp on cp.id = bk.customer_id
  where bk.id = p_booking_id and cp.user_id = auth.uid();
  if not found then
    raise exception 'Booking not found';
  end if;
  if coalesce(b.is_meet_and_greet, false) then
    raise exception 'Meet & greets are cancelled from the meet & greet card';
  end if;
  if not (b.status = 'pending' or (b.status = 'confirmed' and b.scheduled_at > now())) then
    raise exception 'This booking can no longer be cancelled';
  end if;

  update public.bookings
     set status = 'cancelled',
         cancel_reason = coalesce(nullif(trim(p_reason), ''), 'Cancelled by owner'),
         updated_at = now()
   where id = p_booking_id
   returning * into b;
  return b;
end;
$$;

revoke all on function public.cancel_my_booking(uuid, text) from public, anon;
grant execute on function public.cancel_my_booking(uuid, text) to authenticated;
