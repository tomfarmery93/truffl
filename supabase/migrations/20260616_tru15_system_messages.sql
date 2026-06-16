-- TRU-15: one-way "Truffl" channel in the message centre.
-- Truffl posts notifications to a customer (welcome + safety on signup, and a
-- safety nudge on their first booking). Modelled as recipient-keyed rows rather
-- than shoehorning a system user into the customer<->provider conversations table.
-- The customer can read and mark-read their own; they cannot post (no INSERT
-- policy) — the UI renders this as a reply-disabled "Truffl" thread.
--
-- Applied to the live DB via apply_migration; committed here for version control.

CREATE TABLE IF NOT EXISTS public.system_messages (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  body              text NOT NULL,
  link_url          text,
  link_label        text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  read_at           timestamptz
);

CREATE INDEX IF NOT EXISTS idx_system_messages_recipient ON public.system_messages(recipient_user_id, created_at);

ALTER TABLE public.system_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS system_messages_read_own ON public.system_messages;
CREATE POLICY system_messages_read_own ON public.system_messages
  FOR SELECT TO authenticated
  USING (recipient_user_id = auth.uid());

DROP POLICY IF EXISTS system_messages_mark_read ON public.system_messages;
CREATE POLICY system_messages_mark_read ON public.system_messages
  FOR UPDATE TO authenticated
  USING (recipient_user_id = auth.uid())
  WITH CHECK (recipient_user_id = auth.uid());

-- No INSERT/DELETE policy: clients can't create or remove notifications. Only the
-- SECURITY DEFINER triggers below (owned by postgres) write them. UPDATE is limited
-- to the read_at column so recipients can mark-read but not edit the body.
REVOKE INSERT, DELETE ON public.system_messages FROM anon, authenticated;
REVOKE UPDATE ON public.system_messages FROM anon, authenticated;
GRANT UPDATE (read_at) ON public.system_messages TO authenticated;

CREATE OR REPLACE FUNCTION public.post_system_message(p_recipient uuid, p_body text, p_link_url text, p_link_label text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.system_messages (recipient_user_id, body, link_url, link_label)
  VALUES (p_recipient, p_body, p_link_url, p_link_label);
END;
$function$;
REVOKE ALL ON FUNCTION public.post_system_message(uuid, text, text, text) FROM PUBLIC, anon, authenticated;

-- Welcome + safety nudge when a customer completes signup (customer_profiles row).
CREATE OR REPLACE FUNCTION public.trg_system_welcome_customer()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.post_system_message(
    NEW.user_id,
    'Welcome to Truffl! Your dog is family, and keeping them safe is everything to us. We vet every carer, but a few simple habits of your own make all the difference — have a look at our Help & Safety section whenever you have a moment.',
    '/trust-and-safety/',
    'Open Help & Safety'
  );
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.trg_system_welcome_customer() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS system_welcome_customer ON public.customer_profiles;
CREATE TRIGGER system_welcome_customer
  AFTER INSERT ON public.customer_profiles
  FOR EACH ROW EXECUTE FUNCTION public.trg_system_welcome_customer();

-- Safety nudge on a customer's first booking.
CREATE OR REPLACE FUNCTION public.trg_system_first_booking()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_recipient uuid;
  v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM public.bookings WHERE customer_id = NEW.customer_id;
  IF v_count = 1 THEN
    SELECT user_id INTO v_recipient FROM public.customer_profiles WHERE id = NEW.customer_id;
    IF v_recipient IS NOT NULL THEN
      PERFORM public.post_system_message(
        v_recipient,
        'Exciting — your first booking is in! Before your dog''s first time with a new carer, it''s worth two minutes in our Help & Safety section: what to cover at the meet & greet, sorting access, and following along on GPS.',
        '/trust-and-safety/',
        'Open Help & Safety'
      );
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.trg_system_first_booking() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS system_first_booking ON public.bookings;
CREATE TRIGGER system_first_booking
  AFTER INSERT ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.trg_system_first_booking();
