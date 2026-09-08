-- =====================================================================
-- SECURITY FIX: rider_kyc storage bucket has a public-read policy that undoes the
-- earlier private-bucket fix.
-- =====================================================================
-- 20260731000004_rider_kyc_bucket_private.sql correctly made the `rider_kyc` bucket
-- private and scoped storage.objects access to: owner (own folder, all 10 file types),
-- admin/support (all files), and any authenticated user for ONLY the two non-sensitive
-- filenames (rider_image.jpg, vehicle_image.jpg).
--
-- 20260801000000_kyc_upload_storage_policies_and_cleanup.sql ran afterwards and created
-- four more storage.objects policies on the same bucket under different names. One of
-- them, "Allow public to view kyc documents", is:
--     FOR SELECT TO public USING (bucket_id = 'rider_kyc')
-- with no owner or filename scoping at all -- granting SELECT on every object in the
-- bucket to `public` (including fully unauthenticated requests). Because Postgres RLS
-- OR-combines all permissive policies on a table, this one policy alone was enough to
-- let anyone read every rider's Aadhaar, PAN, driving license, and vehicle RC images,
-- regardless of the correct owner-scoped policies also being present -- a full
-- regression of the 07-31 fix.
--
-- The other three policies added by that same migration ("Allow authenticated users to
-- upload own kyc documents", "Allow users to update own kyc documents", "Allow users to
-- delete own kyc documents") are functionally identical duplicates of the correctly
-- owner-scoped policies already created by 20260731000004 (same
-- bucket_id + (storage.foldername(name))[1] = auth.uid()::text condition) -- dropping
-- them removes redundant policy objects without changing any actual access.
--
-- This migration removes all four 20260801000000 policies, leaving exactly one
-- canonical, least-privilege set of storage.objects policies on the rider_kyc bucket:
-- the ones created by 20260731000004. No bucket flag, table, or other policy is
-- touched; owner access, admin/support access, and the narrow public
-- rider_image.jpg/vehicle_image.jpg read policy are all preserved exactly as-is.
-- =====================================================================

DROP POLICY IF EXISTS "Allow public to view kyc documents" ON storage.objects;
DROP POLICY IF EXISTS "Allow authenticated users to upload own kyc documents" ON storage.objects;
DROP POLICY IF EXISTS "Allow users to update own kyc documents" ON storage.objects;
DROP POLICY IF EXISTS "Allow users to delete own kyc documents" ON storage.objects;
