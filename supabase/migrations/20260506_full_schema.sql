-- ============================================================
-- Full schema migration — all outstanding feature tickets
-- Supabase project: gadflsntbnbnnxbpiral
-- Run in: Supabase Dashboard → SQL Editor
-- ============================================================


-- ── 1. Extend users (TRU-9, TRU-30, TRU-31) ────────────────

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS avatar_url text;


-- ── 2. Extend pets (TRU-10, TRU-16) ────────────────────────

ALTER TABLE pets
  ADD COLUMN IF NOT EXISTS weight_kg float,
  ADD COLUMN IF NOT EXISTS age_years float,
  ADD COLUMN IF NOT EXISTS vet_name text,
  ADD COLUMN IF NOT EXISTS vet_phone text,
  ADD COLUMN IF NOT EXISTS medical_notes text,
  ADD COLUMN IF NOT EXISTS behaviour_notes text,
  ADD COLUMN IF NOT EXISTS photo_url text;


-- ── 3. booking_pets join table (TRU-10, TRU-35) ─────────────

CREATE TABLE IF NOT EXISTS booking_pets (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid        NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  pet_id     uuid        NOT NULL REFERENCES pets(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(booking_id, pet_id)
);

-- Migrate existing single-pet bookings into the join table
INSERT INTO booking_pets (booking_id, pet_id)
SELECT id, pet_id
FROM bookings
WHERE pet_id IS NOT NULL
ON CONFLICT DO NOTHING;

-- Keep bookings.pet_id as nullable — do NOT drop yet
COMMENT ON COLUMN bookings.pet_id IS 'DEPRECATED: use booking_pets join table. Kept for backwards compatibility during frontend migration.';

ALTER TABLE booking_pets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "customers_read_own_booking_pets" ON booking_pets
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM bookings b
      JOIN customer_profiles cp ON cp.id = b.customer_id
      WHERE b.id = booking_pets.booking_id
      AND cp.user_id = auth.uid()
    )
  );

CREATE POLICY "providers_read_assigned_booking_pets" ON booking_pets
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM bookings b
      JOIN provider_profiles pp ON pp.id = b.provider_id
      WHERE b.id = booking_pets.booking_id
      AND pp.user_id = auth.uid()
    )
  );

CREATE POLICY "customers_insert_own_booking_pets" ON booking_pets
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM bookings b
      JOIN customer_profiles cp ON cp.id = b.customer_id
      WHERE b.id = booking_pets.booking_id
      AND cp.user_id = auth.uid()
    )
  );


-- ── 4. Extend bookings (TRU-14, TRU-33) ─────────────────────

ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS is_meet_and_greet boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS series_id uuid;
-- FK from series_id → booking_series added after that table is created below


-- ── 5. booking_series table (TRU-33) ────────────────────────

DO $$ BEGIN
  CREATE TYPE series_frequency AS ENUM ('daily', 'weekdays', 'specific_days');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE series_status AS ENUM ('pending', 'active', 'cancelled', 'completed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS booking_series (
  id                 uuid             PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id        uuid             NOT NULL REFERENCES customer_profiles(id) ON DELETE RESTRICT,
  provider_id        uuid             NOT NULL REFERENCES provider_profiles(id) ON DELETE RESTRICT,
  service_id         uuid             NOT NULL REFERENCES provider_services(id) ON DELETE RESTRICT,
  frequency_type     series_frequency NOT NULL,
  days_of_week       int[]            DEFAULT '{}',
  time_of_day        time             NOT NULL,
  start_date         date             NOT NULL,
  end_date           date,
  status             series_status    NOT NULL DEFAULT 'pending',
  locked_price_cents int,
  created_at         timestamptz      NOT NULL DEFAULT now(),
  updated_at         timestamptz      NOT NULL DEFAULT now()
);

ALTER TABLE bookings
  ADD CONSTRAINT IF NOT EXISTS bookings_series_id_fkey
  FOREIGN KEY (series_id) REFERENCES booking_series(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_booking_series_status ON booking_series(status);
CREATE INDEX IF NOT EXISTS idx_bookings_series_id ON bookings(series_id);

ALTER TABLE booking_series ENABLE ROW LEVEL SECURITY;

CREATE POLICY "customers_read_own_series" ON booking_series
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM customer_profiles cp
      WHERE cp.id = booking_series.customer_id
      AND cp.user_id = auth.uid()
    )
  );

CREATE POLICY "providers_read_assigned_series" ON booking_series
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM provider_profiles pp
      WHERE pp.id = booking_series.provider_id
      AND pp.user_id = auth.uid()
    )
  );

CREATE POLICY "customers_insert_series" ON booking_series
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM customer_profiles cp
      WHERE cp.id = booking_series.customer_id
      AND cp.user_id = auth.uid()
    )
  );

CREATE POLICY "customers_update_own_series" ON booking_series
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM customer_profiles cp
      WHERE cp.id = booking_series.customer_id
      AND cp.user_id = auth.uid()
    )
  );

CREATE POLICY "providers_update_assigned_series" ON booking_series
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM provider_profiles pp
      WHERE pp.id = booking_series.provider_id
      AND pp.user_id = auth.uid()
    )
  );


-- ── 6. series_pets join table (TRU-10, TRU-33) ──────────────

CREATE TABLE IF NOT EXISTS series_pets (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  series_id  uuid        NOT NULL REFERENCES booking_series(id) ON DELETE CASCADE,
  pet_id     uuid        NOT NULL REFERENCES pets(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(series_id, pet_id)
);

ALTER TABLE series_pets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "customers_read_own_series_pets" ON series_pets
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM booking_series bs
      JOIN customer_profiles cp ON cp.id = bs.customer_id
      WHERE bs.id = series_pets.series_id
      AND cp.user_id = auth.uid()
    )
  );

CREATE POLICY "providers_read_assigned_series_pets" ON series_pets
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM booking_series bs
      JOIN provider_profiles pp ON pp.id = bs.provider_id
      WHERE bs.id = series_pets.series_id
      AND pp.user_id = auth.uid()
    )
  );

CREATE POLICY "customers_insert_series_pets" ON series_pets
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM booking_series bs
      JOIN customer_profiles cp ON cp.id = bs.customer_id
      WHERE bs.id = series_pets.series_id
      AND cp.user_id = auth.uid()
    )
  );


-- ── 7. reviews table (TRU-25) ───────────────────────────────

CREATE TABLE IF NOT EXISTS reviews (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id  uuid        NOT NULL UNIQUE REFERENCES bookings(id) ON DELETE RESTRICT,
  customer_id uuid        NOT NULL REFERENCES customer_profiles(id) ON DELETE RESTRICT,
  provider_id uuid        NOT NULL REFERENCES provider_profiles(id) ON DELETE RESTRICT,
  rating      int         NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment     text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reviews_provider_id ON reviews(provider_id);
CREATE INDEX IF NOT EXISTS idx_reviews_customer_id ON reviews(customer_id);

ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;

CREATE POLICY "reviews_public_read" ON reviews
  FOR SELECT USING (true);

CREATE POLICY "customers_insert_own_reviews" ON reviews
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM bookings b
      JOIN customer_profiles cp ON cp.id = b.customer_id
      WHERE b.id = reviews.booking_id
      AND b.status = 'completed'
      AND cp.user_id = auth.uid()
    )
    AND EXISTS (
      SELECT 1 FROM customer_profiles cp
      WHERE cp.id = reviews.customer_id
      AND cp.user_id = auth.uid()
    )
  );

CREATE POLICY "customers_update_own_reviews" ON reviews
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM customer_profiles cp
      WHERE cp.id = reviews.customer_id
      AND cp.user_id = auth.uid()
    )
  );


-- ── 8. provider_rating_view (TRU-29) ────────────────────────

CREATE OR REPLACE VIEW provider_rating_view AS
SELECT
  provider_id,
  COUNT(*)                    AS review_count,
  ROUND(AVG(rating)::numeric, 1) AS avg_rating
FROM reviews
GROUP BY provider_id;


-- ── 9. messages table (TRU-7) ───────────────────────────────

CREATE TABLE IF NOT EXISTS messages (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid        NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  sender_id  uuid        NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  body       text        NOT NULL,
  read_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_messages_booking_id ON messages(booking_id);
CREATE INDEX IF NOT EXISTS idx_messages_sender_id  ON messages(sender_id);

ALTER TABLE messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "booking_parties_read_messages" ON messages
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM bookings b
      JOIN customer_profiles cp ON cp.id = b.customer_id
      WHERE b.id = messages.booking_id
      AND cp.user_id = auth.uid()
    )
    OR
    EXISTS (
      SELECT 1 FROM bookings b
      JOIN provider_profiles pp ON pp.id = b.provider_id
      WHERE b.id = messages.booking_id
      AND pp.user_id = auth.uid()
    )
  );

CREATE POLICY "booking_parties_insert_messages" ON messages
  FOR INSERT WITH CHECK (
    auth.uid() = sender_id
    AND (
      EXISTS (
        SELECT 1 FROM bookings b
        JOIN customer_profiles cp ON cp.id = b.customer_id
        WHERE b.id = messages.booking_id
        AND cp.user_id = auth.uid()
      )
      OR
      EXISTS (
        SELECT 1 FROM bookings b
        JOIN provider_profiles pp ON pp.id = b.provider_id
        WHERE b.id = messages.booking_id
        AND pp.user_id = auth.uid()
      )
    )
  );

CREATE POLICY "booking_parties_update_read_at" ON messages
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM bookings b
      JOIN customer_profiles cp ON cp.id = b.customer_id
      WHERE b.id = messages.booking_id
      AND cp.user_id = auth.uid()
    )
    OR
    EXISTS (
      SELECT 1 FROM bookings b
      JOIN provider_profiles pp ON pp.id = b.provider_id
      WHERE b.id = messages.booking_id
      AND pp.user_id = auth.uid()
    )
  );


-- ── 10. Unique constraint on provider_services (TRU-49) ─────

-- Remove existing duplicates first (keep lowest id)
DELETE FROM provider_services a
USING provider_services b
WHERE a.id > b.id
AND a.provider_id = b.provider_id
AND a.service_type = b.service_type;

ALTER TABLE provider_services
  ADD CONSTRAINT unique_provider_service_type
  UNIQUE (provider_id, service_type);


-- ── 11. Storage buckets ──────────────────────────────────────

INSERT INTO storage.buckets (id, name, public)
VALUES ('profile-photos', 'profile-photos', true)
ON CONFLICT DO NOTHING;

INSERT INTO storage.buckets (id, name, public)
VALUES ('walk-photos', 'walk-photos', true)
ON CONFLICT DO NOTHING;

-- RLS for profile-photos bucket
CREATE POLICY "profile_photos_public_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'profile-photos');

CREATE POLICY "profile_photos_auth_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'profile-photos'
    AND auth.role() = 'authenticated'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

CREATE POLICY "profile_photos_auth_update" ON storage.objects
  FOR UPDATE USING (
    bucket_id = 'profile-photos'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );


-- ── 12. updated_at triggers ──────────────────────────────────

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_booking_series_updated_at
  BEFORE UPDATE ON booking_series
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER set_reviews_updated_at
  BEFORE UPDATE ON reviews
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
