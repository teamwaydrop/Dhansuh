-- =====================================================================
-- P1-2 FIX: rider_kyc storage bucket was PUBLIC (confirmed via Supabase Dashboard,
-- 2026-07-31) with zero storage.objects RLS policies ever migrated for it -- meaning
-- Aadhaar/PAN/DL/vehicle-RC document images were readable by anyone with (or able to
-- guess/enumerate) an object path, entirely outside the application's control.
-- =====================================================================
-- AUDIT SUMMARY (performed before writing this migration):
--   - Path convention (rider_kyc_upload_service.dart): every object lives under
--     "{user_id}/{phone}_attempt_{n}/{fileName}.jpg" -- the first path segment is
--     ALWAYS the uploader's own auth.uid(), confirmed by generateAttemptFolder().
--   - Of the 10 uploaded files per rider (rider_image, aadhaar_front, aadhaar_back,
--     pan_front, pan_back, license_front, license_back, vehicle_image,
--     vehicle_rc_front, vehicle_rc_back), a repo-wide grep confirms ONLY rider_image
--     and vehicle_image are ever rendered anywhere in the Flutter app (driver photo /
--     vehicle photo shown to matched passengers, own-profile screens, ratings, order
--     history). The 8 government-ID-document images are never displayed by any
--     screen in this codebase.
--   - No admin/support KYC review screen exists in this Flutter app (docs/10_Admin.md
--     references a differently-named "kyc_docs" bucket -- stale documentation, not
--     reflecting the actual "rider_kyc" bucket this app has always used). Supabase
--     Dashboard-based manual review by project staff is unaffected by this migration
--     (Dashboard access bypasses storage RLS entirely, independent of the bucket's
--     public flag).
--   - Existing stored rider_image/vehicle_image DB values are full public URLs
--     ("{SUPABASE_URL}/storage/v1/object/public/rider_kyc/{path}"), which stop
--     resolving once the bucket goes private. lib/shared/helpers/kyc_image_resolver.dart
--     (shipped in the same deploy) transparently converts either the old full-URL
--     shape or a new bare-path shape into a fresh signed URL at every read site --
--     no DB backfill, and no existing storage object is moved, renamed, or deleted.
--
-- FIX:
--   1. Flip the bucket to private.
--   2. Owner (+ admin/support) gets full SELECT/INSERT/UPDATE/DELETE on their own
--      folder -- covers all 10 file types, matching the existing upload/rollback flow
--      (rider_kyc_upload_service.dart uploads/deletes using the user's own session).
--   3. Any authenticated user additionally gets SELECT on ONLY the two safe filenames
--      (rider_image.jpg, vehicle_image.jpg) across ANY rider's folder -- this is
--      strictly narrower than today's fully-public access (now gated to logged-in
--      users only) and preserves every existing passenger-facing screen that shows a
--      matched/rated/past driver's photo, without the "online riders only" scoping
--      rider_kyc_public already uses (order-history/rating screens need to show a
--      since-gone-offline rider's photo too).
--   4. No policy ever grants access to the 8 sensitive document filenames beyond
--      owner/admin/support.
-- =====================================================================
--
-- RECONCILIATION NOTE (2026-08-04): this migration was applied directly to the linked
-- Supabase project (confirmed via supabase_migrations.schema_migrations) but never
-- committed to this repository. Reconstructed here verbatim from the executed
-- statements so local migration history matches production. No content changed.

UPDATE storage.buckets SET public = false WHERE id = 'rider_kyc';

DROP POLICY IF EXISTS "Riders can upload their own KYC documents" ON storage.objects;

CREATE POLICY "Riders can upload their own KYC documents"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'rider_kyc'
    AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Riders can replace their own KYC documents" ON storage.objects;

CREATE POLICY "Riders can replace their own KYC documents"
ON storage.objects FOR UPDATE
TO authenticated
USING (
    bucket_id = 'rider_kyc'
    AND (storage.foldername(name))[1] = auth.uid()::text
)
WITH CHECK (
    bucket_id = 'rider_kyc'
    AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Riders can delete their own KYC documents" ON storage.objects;

CREATE POLICY "Riders can delete their own KYC documents"
ON storage.objects FOR DELETE
TO authenticated
USING (
    bucket_id = 'rider_kyc'
    AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Riders can view their own KYC documents" ON storage.objects;

CREATE POLICY "Riders can view their own KYC documents"
ON storage.objects FOR SELECT
TO authenticated
USING (
    bucket_id = 'rider_kyc'
    AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Admin support can view all KYC documents" ON storage.objects;

CREATE POLICY "Admin support can view all KYC documents"
ON storage.objects FOR SELECT
TO authenticated
USING (
    bucket_id = 'rider_kyc'
    AND EXISTS (
        SELECT 1 FROM public.users u
        WHERE u.id = auth.uid() AND (u.role = 'admin' OR u.role = 'support')
    )
);

-- Non-sensitive driver/vehicle photos only -- never the 8 government-ID-document
-- filenames -- readable by any authenticated user, matching existing app-wide usage
-- (order tracking, ratings, order history, intercity matching).
DROP POLICY IF EXISTS "Authenticated users can view rider and vehicle photos" ON storage.objects;

CREATE POLICY "Authenticated users can view rider and vehicle photos"
ON storage.objects FOR SELECT
TO authenticated
USING (
    bucket_id = 'rider_kyc'
    AND (name LIKE '%/rider_image.jpg' OR name LIKE '%/vehicle_image.jpg')
);
