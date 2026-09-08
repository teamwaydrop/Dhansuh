-- Migration: Passenger identity fields for the Intercity "who am I serving" UX fix.
-- Date: 2026-07-21
--
-- CONTEXT: a traveller who has accepted several intercity passengers currently sees only
-- generic customer IDs on the Accept Request card, the Active Task card, and (most critically)
-- the pre-OTP screen, making it easy to verify the wrong passenger. Fixing this needs three new
-- pieces of passenger data that don't exist anywhere in the schema today:
--   1. gender          -- never collected from passengers at all.
--   2. profile_photo_url -- passengers have no photo/storage bucket (only riders do, via KYC).
--   3. completed trip count -- not stored; only derivable by counting orders.
-- All three are optional/derived, so this is purely additive: existing rows get NULL gender/photo
-- and a computed 0 trip count, with the UI degrading gracefully (see travel_plan_details_screen.dart,
-- rider_home_tab.dart, rider_active_order_screen.dart, and profile_tab.dart for the collection UI).

ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS gender text CHECK (gender = ANY (ARRAY['male'::text, 'female'::text, 'other'::text])),
    ADD COLUMN IF NOT EXISTS profile_photo_url text;

-- =====================================================
-- STORAGE: passenger profile photo bucket, mirroring the existing rider_kyc/parcel_images
-- pattern (public bucket, owner-scoped write access via storage.objects.owner_id).
-- =====================================================

INSERT INTO storage.buckets (id, name, public)
VALUES ('user_profile_photos', 'user_profile_photos', true)
ON CONFLICT (id) DO UPDATE SET public = true;

DROP POLICY IF EXISTS "Allow authenticated users to upload own profile photo" ON storage.objects;
DROP POLICY IF EXISTS "Allow public to view profile photos" ON storage.objects;
DROP POLICY IF EXISTS "Allow users to update own profile photo" ON storage.objects;
DROP POLICY IF EXISTS "Allow users to delete own profile photo" ON storage.objects;

CREATE POLICY "Allow authenticated users to upload own profile photo"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'user_profile_photos' AND auth.uid()::text = (storage.foldername(name))[1]);

CREATE POLICY "Allow public to view profile photos"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'user_profile_photos');

CREATE POLICY "Allow users to update own profile photo"
ON storage.objects FOR UPDATE
TO authenticated
USING (bucket_id = 'user_profile_photos' AND auth.uid()::text = owner_id);

CREATE POLICY "Allow users to delete own profile photo"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'user_profile_photos' AND auth.uid()::text = owner_id);

-- =====================================================
-- Passenger trip-stats view: the passenger-side mirror of rider_reliability_view
-- (20260622000002_smart_matching_final_production.sql) -- same trade-off already accepted
-- there (any authenticated user can read any counterpart's aggregate stats, never raw rows)
-- applied symmetrically here. Exposes only a completed-trip count, nothing else.
-- =====================================================

CREATE OR REPLACE VIEW public.passenger_trip_stats_view AS
SELECT
    u.id AS user_id,
    COUNT(o.id) FILTER (WHERE o.order_status::text IN ('completed', 'delivered')) AS completed_trips
FROM public.users u
LEFT JOIN public.orders o ON o.user_id = u.id
GROUP BY u.id;

GRANT SELECT ON public.passenger_trip_stats_view TO authenticated;
