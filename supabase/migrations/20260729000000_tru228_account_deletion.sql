-- TRU-228: in-app account deletion.
--
-- Apple guideline 5.1.1(v) requires account deletion to be initiated AND completed
-- in-app; Play requires an in-app route plus a web-accessible deletion URL. Neither
-- existed — there was no deletion or deactivation code anywhere in the codebase.
--
-- WHY ANONYMISE RATHER THAN DELETE. This is forced by the schema, not a preference:
--   * messages.sender_id is ON DELETE RESTRICT, and reviews.customer_id/provider_id
--     and booking_series.customer_id/provider_id are too. A hard delete of a
--     public.users or *_profiles row fails outright on those.
--   * privacy/ section 6 publicly commits to keeping payment and transaction records
--     for seven years, and those live denormalised on bookings (total_cents,
--     stripe_payment_intent_id, charged_at, refunded_at...). Deleting the booking row
--     would break that commitment.
--   * A booking has two parties. A carer's record of the walks they completed should
--     not evaporate because an owner closed their account, and vice versa.
-- So we strip the identity and keep the skeleton.
--
-- KEEP THE LEDGER, DROP THE TRAIL. The retain/purge split is deliberately expressed as
-- one contiguous block below so an item can be moved across the line in one place.
--   RETAIN (de-identified): bookings, booking_series, walk_sessions, reviews,
--     customer_credits.
--   PURGE: gps_pings route geometry, message bodies, walk/booking update text+photos,
--     private.backup_access, notifications, system_messages, precise location geography.
-- This matches privacy/ section 6 as written ("walk routes, messages and booking
-- history are kept while your account is active"), so no policy rewrite is needed.
--
-- NOT DONE, DELIBERATELY: Stripe is left untouched. A deleted owner's Stripe Customer
-- and saved card remain at Stripe, and carers' Connect accounts persist — payout and
-- AU tax obligations outlive the app account. customer_profiles.stripe_customer_id and
-- provider_profiles.stripe_account_id are therefore retained; they are also the only
-- link back to the financial records we are required to keep. Raised with Tom and left
-- out by choice, not oversight.
--
-- ORDERING NOTE for the caller: public.users has NO foreign key to auth.users (both
-- ids are populated by the handle_new_user trigger). Deleting the auth user first
-- would orphan the entire public graph, so the delete-account edge function calls the
-- sweep FIRST and only then calls auth.admin.deleteUser().

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Pre-flight: what would stop this account being deleted?
--    Client-callable so the profile page can explain the blockers before the user
--    commits to anything irreversible. Advisory only — the sweep re-checks.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.account_deletion_blockers()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_cp_id   uuid;
  v_pp_id   uuid;
  v_future  integer := 0;
  v_owed    integer := 0;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select id into v_cp_id from public.customer_profiles where user_id = v_user_id;
  select id into v_pp_id from public.provider_profiles where user_id = v_user_id;

  -- Still-live commitments to the other party. ends_at is null on older rows, so fall
  -- back to scheduled_at.
  select count(*) into v_future
  from public.bookings b
  where b.status in ('pending', 'confirmed')
    and coalesce(b.ends_at, b.scheduled_at) > now()
    and ( (v_cp_id is not null and b.customer_id = v_cp_id)
       or (v_pp_id is not null and b.provider_id = v_pp_id) );

  -- Money not yet settled either way: an owner must not be able to delete their way
  -- out of a charge, and a carer should be paid before they go.
  select count(*) into v_owed
  from public.bookings b
  where b.status = 'completed'
    and coalesce(b.payment_status, 'unpaid') in ('unpaid', 'failed', 'processing')
    and ( (v_cp_id is not null and b.customer_id = v_cp_id)
       or (v_pp_id is not null and b.provider_id = v_pp_id) );

  return jsonb_build_object(
    'future_bookings',  v_future,
    'unpaid_completed', v_owed,
    'can_delete',       (v_future = 0 and v_owed = 0)
  );
end;
$$;

revoke all on function public.account_deletion_blockers() from public, anon;
grant execute on function public.account_deletion_blockers() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. The sweep. service_role only — same discipline as admin_create_lead_series:
--    it lives in public because PostgREST (and therefore the edge function's
--    sb.rpc()) only sees exposed schemas, but EXECUTE is revoked from every client
--    role so it is unreachable from a browser.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_delete_account(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cp_id  uuid;
  v_pp_id  uuid;
  v_email  text;
  v_future integer;
  v_owed   integer;
  -- users.email is UNIQUE, so the placeholder must be too. Use the WHOLE user id —
  -- it is the primary key, so it is unique by construction. Do not truncate it: a
  -- shortened prefix can collide, and the collision surfaces as a hard failure that
  -- makes the second user's account undeletable.
  v_tag    text := replace(p_user_id::text, '-', '');
  v_pings  integer := 0;
  v_msgs   integer := 0;
  -- Every walk session this user was party to, on either side of the booking.
  v_sessions uuid[];
begin
  select email into v_email from public.users where id = p_user_id;
  if v_email is null then
    raise exception 'No such user: %', p_user_id;
  end if;

  select id into v_cp_id from public.customer_profiles where user_id = p_user_id;
  select id into v_pp_id from public.provider_profiles where user_id = p_user_id;

  -- Re-check the blockers here, inside the transaction. The pre-flight the UI ran is
  -- advisory; state can change between the two calls, and this function is the only
  -- thing standing between a client request and irreversible data loss.
  select count(*) into v_future
  from public.bookings b
  where b.status in ('pending', 'confirmed')
    and coalesce(b.ends_at, b.scheduled_at) > now()
    and ( (v_cp_id is not null and b.customer_id = v_cp_id)
       or (v_pp_id is not null and b.provider_id = v_pp_id) );
  if v_future > 0 then
    raise exception 'Cannot delete: % future booking(s) still scheduled', v_future;
  end if;

  select count(*) into v_owed
  from public.bookings b
  where b.status = 'completed'
    and coalesce(b.payment_status, 'unpaid') in ('unpaid', 'failed', 'processing')
    and ( (v_cp_id is not null and b.customer_id = v_cp_id)
       or (v_pp_id is not null and b.provider_id = v_pp_id) );
  if v_owed > 0 then
    raise exception 'Cannot delete: % completed booking(s) not yet settled', v_owed;
  end if;

  -- ── Delist first ───────────────────────────────────────────────────────────
  -- Before anything else, so a carer disappears from search and can't be booked
  -- while the rest of the sweep runs. is_active gates the public RLS read policy,
  -- provider_search_view and search_carers.
  if v_pp_id is not null then
    update public.provider_profiles
       set is_active = false, updated_at = now()
     where id = v_pp_id;
    update public.provider_services set is_available = false where provider_id = p_user_id;
  end if;

  -- ── PURGE: the trail ───────────────────────────────────────────────────────
  -- Resolve the sessions once. Membership is by EITHER side of the booking, not just
  -- walk_sessions.provider_id: when an owner leaves, the route and the update photos
  -- are the carer's rows but they are *about* the owner's dog and home.
  select array_agg(ws.id) into v_sessions
    from public.walk_sessions ws
    left join public.bookings b on b.id = ws.booking_id
   where ws.provider_id = p_user_id
      or (v_cp_id is not null and b.customer_id = v_cp_id)
      or (v_pp_id is not null and b.provider_id = v_pp_id);

  -- Route geometry goes when either party leaves; the walk_sessions row (when, how
  -- long, how far) survives so the other party keeps their record of the walk.
  delete from public.gps_pings where walk_session_id = any(v_sessions);
  get diagnostics v_pings = row_count;

  -- Own message bodies only — never the other party's side of the conversation.
  update public.messages set body = '[deleted]' where sender_id = p_user_id;
  get diagnostics v_msgs = row_count;

  -- Free-text and photo pointers. The storage objects themselves are removed by the
  -- edge function; nulling the URL stops a dangling link.
  update public.walk_updates
     set message = null, photo_url = null
   where provider_id = p_user_id
      or walk_session_id = any(v_sessions);

  -- booking_updates.photo_url is NOT NULL — these rows ARE the photo check-in, so a
  -- blanked row would be meaningless, and attempting to null it aborts the whole
  -- deletion. Delete them instead; the booking's own status and completed_at already
  -- record that the visit happened.
  delete from public.booking_updates bu
   where bu.provider_user_id = p_user_id
      or (v_cp_id is not null and bu.booking_id in (select id from public.bookings where customer_id = v_cp_id));

  -- Personal, addressed to this user, and of no value to anyone else.
  delete from public.notifications  where user_id = p_user_id;
  delete from public.system_messages where recipient_user_id = p_user_id;

  -- Home access details. privacy/ section 6 already promises these go immediately on
  -- opt-out; closing the account is at least as strong a signal.
  if v_cp_id is not null then
    delete from private.backup_access where customer_id = v_cp_id;
  end if;

  -- No FK on this column, so it would silently dangle rather than cascade.
  update public.search_misses set customer_id = null where customer_id = v_cp_id;

  -- ── ANONYMISE: the identity ────────────────────────────────────────────────
  if v_cp_id is not null then
    update public.customer_profiles
       set address = null, suburb = null, postcode = null,
           emergency_contact = null, emergency_phone = null,
           location = null,                      -- precise geography
           backup_cover_enabled = false,
           updated_at = now()
     where id = v_cp_id;

    -- Pets are identifying (name, microchip, vet) and their photos are being removed.
    update public.pets
       set name = 'Pet', breed = null, microchip_no = null,
           vet_name = null, vet_phone = null,
           medical_notes = null, behaviour_notes = null,
           photo_url = null, is_active = false
     where customer_id = v_cp_id;
  end if;

  if v_pp_id is not null then
    update public.provider_profiles
       set bio = null, suburb = null, postcode = null, abn = null,
           location = null, service_area = null,  -- precise geography
           updated_at = now()
     where id = v_pp_id;
  end if;

  -- Lead capture. customer_id is nullable by design (search is public), so guest leads
  -- have no user key at all — match on the email address as well or they survive.
  update public.carer_requests
     set contact_name = 'Deleted user', contact_email = null, contact_phone = null,
         note = null, dog_name = null, dog_breed = null, dog_temperament_note = null,
         search_params = null
   where (v_cp_id is not null and (customer_id = v_cp_id or converted_customer_id = v_cp_id))
      or lower(contact_email) = lower(v_email);

  update public.users
     set first_name = 'Deleted',
         last_name  = 'user',
         email      = 'deleted+' || v_tag || '@trufflpets.com',
         phone      = null,
         avatar_url = null,
         is_active  = false,
         is_admin   = false,
         updated_at = now()
   where id = p_user_id;

  return jsonb_build_object(
    'user_id',            p_user_id,
    'gps_pings_deleted',  v_pings,
    'messages_redacted',  v_msgs,
    'had_customer_profile', v_cp_id is not null,
    'had_provider_profile', v_pp_id is not null
  );
end;
$$;

-- TRU-153 discipline: a definer function must never be reachable by a client role.
revoke all on function public.admin_delete_account(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_account(uuid) to service_role;
