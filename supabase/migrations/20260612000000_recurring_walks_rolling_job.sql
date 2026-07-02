-- TRU-34 — Recurring walks: daily rolling job.
--
-- NOTE: DB changes on this project are applied to Supabase via the Supabase
-- MCP (apply_migration), not by a CLI pipeline. This file is the
-- version-controlled record of what was applied. Depends on
-- generate_series_bookings(series_id, weeks_ahead) from the previous
-- recurring-walks PR.

-- Daily rolling job: keep ~4 weeks of bookings populated for every active
-- series, and retire series that have passed their end date.
CREATE OR REPLACE FUNCTION public.roll_all_series_bookings()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
  total int := 0;
BEGIN
  -- Retire series whose end date has passed.
  UPDATE public.booking_series
     SET status = 'completed', updated_at = now()
   WHERE status = 'active'
     AND end_date IS NOT NULL
     AND end_date < current_date;

  -- Top up upcoming bookings for everything still active.
  FOR r IN SELECT id FROM public.booking_series WHERE status = 'active' LOOP
    total := total + public.generate_series_bookings(r.id, 4);
  END LOOP;

  RETURN total;
END;
$$;

-- Schedule it daily at 16:00 UTC (~2am Sydney) via pg_cron.
CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
BEGIN
  PERFORM cron.unschedule('roll-series-bookings')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'roll-series-bookings');
END $$;

SELECT cron.schedule('roll-series-bookings', '0 16 * * *', $$SELECT public.roll_all_series_bookings();$$);
