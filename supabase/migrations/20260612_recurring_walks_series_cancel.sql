-- TRU-38 — Recurring walks: series-level cancellation cascade.
--
-- Applied to Supabase via the Supabase MCP; this file is the
-- version-controlled record.
--
-- When a series is cancelled (by either party via the existing update RLS),
-- cancel all of its FUTURE pending/confirmed bookings. Past, in-progress and
-- completed walks are left untouched. The rolling job already skips
-- non-active series, so nothing regenerates.
CREATE OR REPLACE FUNCTION public.trg_series_cancelled()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'cancelled' AND (OLD.status IS DISTINCT FROM 'cancelled') THEN
    UPDATE public.bookings
       SET status = 'cancelled', updated_at = now()
     WHERE series_id = NEW.id
       AND status IN ('pending', 'confirmed')
       AND scheduled_at > now();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS series_cancelled ON public.booking_series;
CREATE TRIGGER series_cancelled
  AFTER UPDATE OF status ON public.booking_series
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_series_cancelled();
