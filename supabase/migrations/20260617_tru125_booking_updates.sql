-- TRU-125: carer check-ins for non-walk stays (boarding/sitting).
-- A photo + short update so owners have peace of mind when there's no live GPS.
--
-- Repurposes the pre-existing empty `booking_updates` stub (keeping its
-- message/photo_url/sent_at columns so the legacy active_walk_view stays valid)
-- and adds the check-in columns. Applied to the live DB via apply_migration;
-- committed here for version control.

ALTER TABLE public.booking_updates
  ADD COLUMN IF NOT EXISTS provider_user_id uuid,
  ADD COLUMN IF NOT EXISTS update_type      text,
  ADD COLUMN IF NOT EXISTS tags             text[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS has_concern      boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS created_at       timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.booking_updates ALTER COLUMN sent_at SET DEFAULT now();
ALTER TABLE public.booking_updates
  ALTER COLUMN provider_user_id SET NOT NULL,
  ALTER COLUMN update_type SET NOT NULL,
  ALTER COLUMN photo_url SET NOT NULL;

ALTER TABLE public.booking_updates DROP CONSTRAINT IF EXISTS booking_updates_update_type_check;
ALTER TABLE public.booking_updates ADD CONSTRAINT booking_updates_update_type_check CHECK (update_type IN ('arrival','daily','completion'));
ALTER TABLE public.booking_updates DROP CONSTRAINT IF EXISTS booking_updates_booking_id_fkey;
ALTER TABLE public.booking_updates ADD CONSTRAINT booking_updates_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_booking_updates_booking ON public.booking_updates(booking_id, created_at);

ALTER TABLE public.booking_updates ENABLE ROW LEVEL SECURITY;

-- The carer who owns the booking posts their own check-ins.
DROP POLICY IF EXISTS carer_insert_booking_update ON public.booking_updates;
CREATE POLICY carer_insert_booking_update ON public.booking_updates
  FOR INSERT TO authenticated
  WITH CHECK (
    provider_user_id = auth.uid()
    AND EXISTS (SELECT 1 FROM public.bookings b JOIN public.provider_profiles pp ON pp.id = b.provider_id
                WHERE b.id = booking_updates.booking_id AND pp.user_id = auth.uid())
  );

-- Both parties to the booking can read the check-ins.
DROP POLICY IF EXISTS parties_read_booking_update ON public.booking_updates;
CREATE POLICY parties_read_booking_update ON public.booking_updates
  FOR SELECT TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.bookings b
            LEFT JOIN public.provider_profiles pp ON pp.id = b.provider_id
            LEFT JOIN public.customer_profiles cp ON cp.id = b.customer_id
            WHERE b.id = booking_updates.booking_id AND (pp.user_id = auth.uid() OR cp.user_id = auth.uid()))
  );

-- Which bookings need check-ins, and how many nights. Non-walk, non-M&G services
-- require an arrival check-in plus one "evening" daily per night.
CREATE OR REPLACE FUNCTION public.booking_checkin_spec(p_booking_id uuid)
 RETURNS TABLE(requires boolean, nights int)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT
    (svc.service_type IS DISTINCT FROM 'dog_walking' AND NOT COALESCE(b.is_meet_and_greet, false)) AS requires,
    GREATEST(1, (COALESCE(b.ends_at, b.scheduled_at)::date - b.scheduled_at::date))::int AS nights
  FROM public.bookings b JOIN public.provider_services svc ON svc.id = b.service_id
  WHERE b.id = p_booking_id;
$function$;
REVOKE ALL ON FUNCTION public.booking_checkin_spec(uuid) FROM PUBLIC, anon, authenticated;

-- Completion gate: a non-walk stay can't be marked completed until the required
-- check-ins exist. Server-side so a client can't bypass it. Walks and meet &
-- greets are exempt (they complete through their own flows).
CREATE OR REPLACE FUNCTION public.trg_stay_completion_gate()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_requires boolean; v_nights int; v_arr int; v_daily int;
BEGIN
  IF NEW.status = 'completed' AND OLD.status IS DISTINCT FROM 'completed' THEN
    SELECT requires, nights INTO v_requires, v_nights FROM public.booking_checkin_spec(NEW.id);
    IF v_requires THEN
      SELECT count(*) FILTER (WHERE update_type = 'arrival'),
             count(*) FILTER (WHERE update_type = 'daily')
        INTO v_arr, v_daily FROM public.booking_updates WHERE booking_id = NEW.id;
      IF v_arr < 1 OR v_daily < v_nights THEN
        RAISE EXCEPTION 'Check-ins required before completing (have % arrival, % of % daily)', v_arr, v_daily, v_nights
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.trg_stay_completion_gate() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS stay_completion_gate ON public.bookings;
CREATE TRIGGER stay_completion_gate
  BEFORE UPDATE OF status ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.trg_stay_completion_gate();

-- Notify the owner in-app on each check-in (rides the one-way "Truffl" channel
-- from TRU-15). Concern flag gets a more prominent message. Push/email come later
-- with the native app + email infra.
CREATE OR REPLACE FUNCTION public.trg_booking_update_notify()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_customer uuid; v_carer text; v_dog text; v_body text;
BEGIN
  SELECT cp.user_id, COALESCE(cu.first_name, 'Your carer')
    INTO v_customer, v_carer
  FROM public.bookings b
  JOIN public.customer_profiles cp ON cp.id = b.customer_id
  JOIN public.provider_profiles pp ON pp.id = b.provider_id
  JOIN public.users cu ON cu.id = pp.user_id
  WHERE b.id = NEW.booking_id;

  SELECT COALESCE(string_agg(p.name, ' & '), 'your dog') INTO v_dog
  FROM public.booking_pets bp JOIN public.pets p ON p.id = bp.pet_id
  WHERE bp.booking_id = NEW.booking_id;

  IF v_customer IS NULL THEN RETURN NEW; END IF;

  IF NEW.has_concern THEN
    v_body := '⚠️ ' || v_carer || ' flagged something on ' || COALESCE(v_dog,'your dog') || '''s stay that may need a look. Tap to see the details.';
  ELSE
    v_body := '📸 ' || v_carer || ' shared a new check-in on ' || COALESCE(v_dog,'your dog') || '''s stay — tap to see how they''re getting on.';
  END IF;

  PERFORM public.post_system_message(v_customer, v_body, '/track/?booking=' || NEW.booking_id, 'See the update');
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.trg_booking_update_notify() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS booking_update_notify ON public.booking_updates;
CREATE TRIGGER booking_update_notify
  AFTER INSERT ON public.booking_updates
  FOR EACH ROW EXECUTE FUNCTION public.trg_booking_update_notify();

-- Per-booking check-in status for the dashboard + owner view. A definer view
-- (bypasses RLS) scoped by auth.uid() in the WHERE, matching the existing
-- *_party_names views — security_invoker would return nothing because neither
-- party can read the counterparty's profile row that the view joins. This trips
-- the security_definer_view advisor lint, which is accepted/intentional here.
CREATE VIEW public.booking_checkin_status AS
  SELECT b.id AS booking_id,
    GREATEST(1, (COALESCE(b.ends_at, b.scheduled_at)::date - b.scheduled_at::date))::int AS nights,
    (svc.service_type IS DISTINCT FROM 'dog_walking' AND NOT COALESCE(b.is_meet_and_greet, false)) AS requires_checkins,
    (SELECT count(*) FROM public.booking_updates u WHERE u.booking_id = b.id AND u.update_type = 'arrival') AS arrival_count,
    (SELECT count(*) FROM public.booking_updates u WHERE u.booking_id = b.id AND u.update_type = 'daily') AS daily_count,
    (SELECT count(*) FROM public.booking_updates u WHERE u.booking_id = b.id) AS total_count,
    (SELECT max(created_at) FROM public.booking_updates u WHERE u.booking_id = b.id AND u.update_type = 'daily') AS last_daily_at
  FROM public.bookings b
  JOIN public.provider_services svc ON svc.id = b.service_id
  JOIN public.provider_profiles pp ON pp.id = b.provider_id
  JOIN public.customer_profiles cp ON cp.id = b.customer_id
  WHERE pp.user_id = auth.uid() OR cp.user_id = auth.uid();
