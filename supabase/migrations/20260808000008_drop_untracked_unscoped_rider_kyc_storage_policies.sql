-- =====================================================================
-- SECURITY FIX: rider_kyc bucket has 4 untracked storage.objects policies, created
-- directly on production (never via any migration -- confirmed by querying
-- pg_policies on the live linked project and grepping the entire supabase/migrations
-- history for their exact names, which found nothing), that grant ANY authenticated
-- user unrestricted access to EVERY object in the bucket:
--
--   rider_kyc_select  (SELECT)  USING (bucket_id = 'rider_kyc')
--   rider_kyc_update  (UPDATE)  USING (bucket_id = 'rider_kyc') WITH CHECK (bucket_id = 'rider_kyc')
--   rider_kyc_delete  (DELETE)  USING (bucket_id = 'rider_kyc')
--   rider_kyc_upload  (INSERT)  WITH CHECK (bucket_id = 'rider_kyc')
--
-- None of these four scope by (storage.foldername(name))[1] = auth.uid()::text (or any
-- other ownership check), unlike the correct sibling policies created by
-- 20260731000004_rider_kyc_bucket_private.sql ("Riders can view/upload/replace/delete
-- their own KYC documents", "Admin support can view all KYC documents", "Authenticated
-- users can view rider and vehicle photos"). Because Postgres RLS OR-combines all
-- permissive policies on a table, these four alone let any logged-in user (rider or
-- passenger) read every rider's Aadhaar/PAN/driving-license/vehicle-RC/insurance
-- images, and additionally overwrite or delete any rider's documents outright --
-- broader than a read-only leak.
--
-- This migration removes exactly these 4 untracked policies. The 6 correctly
-- owner/admin-scoped policies from 20260731000004 are untouched and now become the
-- sole access path to this bucket: owner (own folder, all 10 file types), admin/support
-- (full read), and any authenticated user for only the two non-sensitive filenames
-- (rider_image.jpg, vehicle_image.jpg). No bucket flag or other table is touched.
-- =====================================================================

DROP POLICY IF EXISTS "rider_kyc_select" ON storage.objects;
DROP POLICY IF EXISTS "rider_kyc_update" ON storage.objects;
DROP POLICY IF EXISTS "rider_kyc_delete" ON storage.objects;
DROP POLICY IF EXISTS "rider_kyc_upload" ON storage.objects;
