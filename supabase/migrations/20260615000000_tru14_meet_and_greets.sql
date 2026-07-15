-- TRU-14 Meet & greets
-- Before a customer's first booking with a new carer, the pair completes a free
-- introductory meet & greet (M&G). The M&G is the first booking between the pair
-- (bookings.is_meet_and_greet = true) and gates activation of the intended series.
--
-- Pair key: the gate ("a completed M&G already exists for this pair") is keyed on
-- (bookings.customer_id, bookings.provider_id) i.e. (customer_profiles.id,
-- provider_profiles.id) -- the identifiers the bookings tables already use. This
-- maps 1:1 to a users pair and avoids the provider_services users.id vs
-- provider_profiles.id mismatch called out in TRU-61.
--
-- Applied to the live DB via apply_migration (Supabase branching is broken on this
-- repo); committed here for version control.

-- 1. New series state: the intended booking is locked in as pending until the M&G
--    is completed and the customer proceeds.
ALTER TYPE public.series_status ADD VALUE IF NOT EXISTS 'pending_meet_greet';

-- 2. Private decline feedback. Both parties can SELECT * on booking_series, so the
--    feedback lives in its own table with INSERT-only RLS and no SELECT policy:
--    write-only from the client, never exposed to the other party (or to either
--    party) via the API -- only readable by service_role/SQL for our own analytics.
CREATE TABLE IF NOT EXISTS public.series_decline_feedback (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  series_id      uuid NOT NULL REFERENCES public.booking_series(id) ON DELETE CASCADE,
  declined_by    text NOT NULL CHECK (declined_by IN ('customer','carer')),
  decline_reason text[] NOT NULL DEFAULT '{}',
  decline_note   text,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_series_decline_feedback_series ON public.series_decline_feedback(series_id);

ALTER TABLE public.series_decline_feedback ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS customer_insert_decline_feedback ON public.series_decline_feedback;
CREATE POLICY customer_insert_decline_feedback ON public.series_decline_feedback
  FOR INSERT TO authenticated
  WITH CHECK (
    declined_by = 'customer'
    AND EXISTS (
      SELECT 1 FROM public.booking_series bs
      JOIN public.customer_profiles cp ON cp.id = bs.customer_id
      WHERE bs.id = series_decline_feedback.series_id AND cp.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS carer_insert_decline_feedback ON public.series_decline_feedback;
CREATE POLICY carer_insert_decline_feedback ON public.series_decline_feedback
  FOR INSERT TO authenticated
  WITH CHECK (
    declined_by = 'carer'
    AND EXISTS (
      SELECT 1 FROM public.booking_series bs
      JOIN public.provider_profiles pp ON pp.id = bs.provider_id
      WHERE bs.id = series_decline_feedback.series_id AND pp.user_id = auth.uid()
    )
  );

-- 3. M&G wraps EVERY first booking in a pending_meet_greet series, including
--    one-offs and multi-day boarding/sitting. booking_kind tells the generator what
--    to materialise on activation. Existing series are all recurring.
ALTER TABLE public.booking_series
  ADD COLUMN IF NOT EXISTS booking_kind text NOT NULL DEFAULT 'recurring'
    CHECK (booking_kind IN ('recurring','oneoff','multiday'));

-- Row generator: branch on booking_kind. Never (re)generate an M&G row, and never
-- materialise twice for the same series.
CREATE OR REPLACE FUNCTION public.generate_series_bookings(p_series_id uuid, p_weeks_ahead integer DEFAULT 4)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  s public.booking_series%ROWTYPE;
  d date;
  horizon date;
  dow int;
  want boolean;
  scheduled timestamptz;
  win_end timestamptz;
  ends timestamptz;
  svc_duration int;
  primary_pet uuid;
  created_count int := 0;
  new_booking_id uuid;
BEGIN
  SELECT * INTO s FROM public.booking_series WHERE id = p_series_id;
  IF NOT FOUND OR s.status <> 'active' THEN
    RETURN 0;
  END IF;

  SELECT pet_id INTO primary_pet FROM public.series_pets WHERE series_id = p_series_id ORDER BY created_at LIMIT 1;
  IF primary_pet IS NULL THEN
    RETURN 0;
  END IF;

  SELECT duration_mins INTO svc_duration FROM public.provider_services WHERE id = s.service_id;

  -- A non-M&G booking already materialised for this series? nothing to do.
  IF EXISTS (
    SELECT 1 FROM public.bookings b
    WHERE b.series_id = p_series_id AND NOT COALESCE(b.is_meet_and_greet, false)
  ) THEN
    RETURN 0;
  END IF;

  -- One-off (single timed booking) and multi-day (boarding/sitting, single row with
  -- a date range) intents materialise exactly one booking on activation.
  IF s.booking_kind = 'multiday' THEN
    scheduled := (s.start_date::timestamp + time '12:00') AT TIME ZONE 'Australia/Sydney';
    ends      := (COALESCE(s.end_date, s.start_date)::timestamp + time '12:00') AT TIME ZONE 'Australia/Sydney';
    INSERT INTO public.bookings (customer_id, provider_id, pet_id, service_id, status, scheduled_at, ends_at, total_cents, series_id)
    VALUES (s.customer_id, s.provider_id, primary_pet, s.service_id, 'confirmed', scheduled, ends, COALESCE(s.locked_price_cents, 0), p_series_id)
    RETURNING id INTO new_booking_id;
    INSERT INTO public.booking_pets (booking_id, pet_id)
    SELECT new_booking_id, pet_id FROM public.series_pets WHERE series_id = p_series_id;
    RETURN 1;

  ELSIF s.booking_kind = 'oneoff' THEN
    scheduled := (s.start_date::timestamp + s.time_of_day) AT TIME ZONE 'Australia/Sydney';
    win_end   := CASE WHEN s.window_end_time IS NOT NULL
                      THEN (s.start_date::timestamp + s.window_end_time) AT TIME ZONE 'Australia/Sydney'
                      ELSE NULL END;
    INSERT INTO public.bookings (customer_id, provider_id, pet_id, service_id, status, scheduled_at, window_end_at, duration_mins, total_cents, series_id)
    VALUES (s.customer_id, s.provider_id, primary_pet, s.service_id, 'confirmed', scheduled, win_end, svc_duration, COALESCE(s.locked_price_cents, 0), p_series_id)
    RETURNING id INTO new_booking_id;
    INSERT INTO public.booking_pets (booking_id, pet_id)
    SELECT new_booking_id, pet_id FROM public.series_pets WHERE series_id = p_series_id;
    RETURN 1;
  END IF;

  -- Recurring schedule (existing behaviour).
  horizon := LEAST(
    COALESCE(s.end_date, (current_date + (p_weeks_ahead * 7))),
    (current_date + (p_weeks_ahead * 7))
  );
  d := GREATEST(s.start_date, current_date);

  WHILE d <= horizon LOOP
    dow := EXTRACT(isodow FROM d);
    want := CASE s.frequency_type
      WHEN 'daily' THEN true
      WHEN 'weekdays' THEN dow BETWEEN 1 AND 5
      WHEN 'specific_days' THEN dow = ANY(s.days_of_week)
      ELSE false
    END;

    IF want THEN
      scheduled := (d::timestamp + s.time_of_day) AT TIME ZONE 'Australia/Sydney';
      win_end := CASE WHEN s.window_end_time IS NOT NULL
                      THEN (d::timestamp + s.window_end_time) AT TIME ZONE 'Australia/Sydney'
                      ELSE NULL END;
      IF NOT EXISTS (
        SELECT 1 FROM public.bookings b
        WHERE b.series_id = p_series_id
          AND NOT COALESCE(b.is_meet_and_greet, false)
          AND (b.scheduled_at AT TIME ZONE 'Australia/Sydney')::date = d
      ) THEN
        INSERT INTO public.bookings (customer_id, provider_id, pet_id, service_id, status, scheduled_at, window_end_at, duration_mins, total_cents, series_id)
        VALUES (s.customer_id, s.provider_id, primary_pet, s.service_id, 'confirmed', scheduled, win_end, svc_duration, COALESCE(s.locked_price_cents, 0), p_series_id)
        RETURNING id INTO new_booking_id;

        INSERT INTO public.booking_pets (booking_id, pet_id)
        SELECT new_booking_id, pet_id FROM public.series_pets WHERE series_id = p_series_id;

        created_count := created_count + 1;
      END IF;
    END IF;
    d := d + 1;
  END LOOP;

  RETURN created_count;
END;
$function$;

-- 4. Cancel trigger: never cancel the M&G booking -- it stays on record (completed)
--    even when the series is declined/cancelled.
CREATE OR REPLACE FUNCTION public.trg_series_cancelled()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.status = 'cancelled' AND (OLD.status IS DISTINCT FROM 'cancelled') THEN
    UPDATE public.bookings
       SET status = 'cancelled', updated_at = now()
     WHERE series_id = NEW.id
       AND NOT COALESCE(is_meet_and_greet, false)
       AND status IN ('pending', 'confirmed')
       AND scheduled_at > now();
  END IF;
  RETURN NEW;
END;
$function$;

-- 5. Gate enforcement: a series may only move pending_meet_greet -> active once a
--    completed M&G booking exists for it. Server-side so a client cannot bypass the
--    gate by PATCHing status directly.
CREATE OR REPLACE FUNCTION public.trg_meet_greet_gate()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF OLD.status = 'pending_meet_greet' AND NEW.status = 'active' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE b.series_id = NEW.id
        AND b.is_meet_and_greet = true
        AND b.status = 'completed'
    ) THEN
      RAISE EXCEPTION 'Cannot activate series % before its meet & greet is completed', NEW.id
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS series_meet_greet_gate ON public.booking_series;
CREATE TRIGGER series_meet_greet_gate
  BEFORE UPDATE OF status ON public.booking_series
  FOR EACH ROW EXECUTE FUNCTION public.trg_meet_greet_gate();

-- Trigger function — not meant to be RPC-callable.
REVOKE ALL ON FUNCTION public.trg_meet_greet_gate() FROM PUBLIC, anon, authenticated;

-- 6. Completion RPC. Customers have no UPDATE policy on bookings, so marking the
--    (free) M&G complete runs through a definer fn scoped to the booking's customer.
CREATE OR REPLACE FUNCTION public.mark_meet_greet_complete(p_booking_id uuid)
 RETURNS public.bookings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  b public.bookings%ROWTYPE;
BEGIN
  SELECT bk.* INTO b FROM public.bookings bk WHERE bk.id = p_booking_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;
  IF NOT b.is_meet_and_greet THEN
    RAISE EXCEPTION 'Booking % is not a meet & greet', p_booking_id;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.customer_profiles cp
    WHERE cp.id = b.customer_id AND cp.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not authorised to complete this meet & greet';
  END IF;

  UPDATE public.bookings
     SET status = 'completed', completed_at = now(), updated_at = now()
   WHERE id = p_booking_id
   RETURNING * INTO b;
  RETURN b;
END;
$function$;

REVOKE ALL ON FUNCTION public.mark_meet_greet_complete(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_meet_greet_complete(uuid) TO authenticated;
