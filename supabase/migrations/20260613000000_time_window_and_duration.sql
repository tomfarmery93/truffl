-- TRU-73: time window + walk length for walking/drop-in.
-- Applied to Supabase via the Supabase MCP; this file is the record.
--
-- scheduled_at is the window START; window_end_at is the window END (same day).
-- duration_mins snapshots the chosen walk length (also derivable from service_id).
ALTER TABLE public.bookings       ADD COLUMN IF NOT EXISTS window_end_at timestamptz;
ALTER TABLE public.bookings       ADD COLUMN IF NOT EXISTS duration_mins integer;
ALTER TABLE public.booking_series ADD COLUMN IF NOT EXISTS window_end_time time;

-- Series generation now carries the window end + duration onto each booking.
CREATE OR REPLACE FUNCTION public.generate_series_bookings(p_series_id uuid, p_weeks_ahead int DEFAULT 4)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s public.booking_series%ROWTYPE;
  d date;
  horizon date;
  dow int;
  want boolean;
  scheduled timestamptz;
  win_end timestamptz;
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
$$;
