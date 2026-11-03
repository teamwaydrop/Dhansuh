-- Migration: rider_kyc storage bucket policies + scheduled cleanup of abandoned upload sessions.
-- Date: 2026-08-01
--
-- Part of the incremental rider-KYC-upload redesign: each document now uploads to the `rider_kyc`
-- bucket immediately on pick instead of being batched at Final Submit. This migration covers the
-- two backend pieces that redesign needs:
--
-- 1. TRACKED STORAGE POLICIES. Unlike every other bucket in this repo (parcel_images,
--    user_profile_photos, driver_personal_qr all have their storage.objects RLS policies in a
--    migration), the `rider_kyc` bucket's policies exist only in the live dashboard, untracked
--    anywhere in this repo -- confirmed via exhaustive grep across supabase/migrations. Under the
--    old batch-at-submit flow this gap already existed but was live for only the few seconds of a
--    single Submit call; the new flow uploads far earlier and more often (every document pick, for
--    users who may never finish onboarding), raising the stakes on this gap being correct. Policies
--    below mirror the exact pattern already used for user_profile_photos
--    (20260721000006_add_passenger_gender_photo_and_trip_stats.sql): owner-scoped by the first path
--    segment for writes, public read (bucket is confirmed public=true), owner-scoped
--    update/delete (the client's existing RiderKycUploadService.rollbackFiles() calls
--    storage.remove() directly as the authenticated user, so a scoped DELETE policy must already
--    exist for that call to have ever worked -- this makes the previously-undocumented behavior
--    explicit and reviewable rather than introducing new access). Written with
--    DROP POLICY IF EXISTS + CREATE POLICY (the idempotent pattern used throughout this repo), so
--    applying this is safe regardless of whatever the live dashboard currently has under a
--    different policy name.
--
-- 2. SCHEDULED CLEANUP. Calls the new cleanup-abandoned-kyc-uploads edge function daily via the
--    same vault-based net.http_post pattern already established in
--    20260718000000_push_notification_delivery_via_vault.sql (reads the service-role key from
--    Supabase Vault at call time -- never hardcoded here -- and fails open with a RAISE WARNING if
--    the vault secret isn't configured yet, identical failure behavior to that precedent).
--    Scheduled via pg_cron following the exact guarded-extension pattern already used for the
--    dormant-rider and intercity-expiry jobs (20260602000003_expand_notifications_logic.sql,
--    20260717000008_intercity_expiry_scheduling_and_notifications.sql).

-- =====================================================================
-- 1. Storage policies for the rider_kyc bucket
-- =====================================================================

DROP POLICY IF EXISTS "Allow authenticated users to upload own kyc documents" ON storage.objects;
CREATE POLICY "Allow authenticated users to upload own kyc documents"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'rider_kyc' AND auth.uid()::text = (storage.foldername(name))[1]);

DROP POLICY IF EXISTS "Allow public to view kyc documents" ON storage.objects;
CREATE POLICY "Allow public to view kyc documents"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'rider_kyc');

DROP POLICY IF EXISTS "Allow users to update own kyc documents" ON storage.objects;
CREATE POLICY "Allow users to update own kyc documents"
ON storage.objects FOR UPDATE
TO authenticated
USING (bucket_id = 'rider_kyc' AND auth.uid()::text = (storage.foldername(name))[1]);

DROP POLICY IF EXISTS "Allow users to delete own kyc documents" ON storage.objects;
CREATE POLICY "Allow users to delete own kyc documents"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'rider_kyc' AND auth.uid()::text = (storage.foldername(name))[1]);

-- =====================================================================
-- 2. Scheduled cleanup of abandoned upload sessions
-- =====================================================================

CREATE OR REPLACE FUNCTION public.trigger_cleanup_abandoned_kyc_uploads()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_supabase_url text := 'https://yvwpchffctiagevpqgwy.supabase.co';
    v_service_role_key text;
BEGIN
    SELECT decrypted_secret INTO v_service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_service_role_key'
    LIMIT 1;

    IF v_service_role_key IS NULL THEN
        RAISE WARNING 'KYC upload cleanup skipped: vault secret "supabase_service_role_key" is not configured. Run vault.create_secret(...) once via the Supabase Dashboard SQL Editor.';
        RETURN;
    END IF;

    PERFORM net.http_post(
        url := v_supabase_url || '/functions/v1/cleanup-abandoned-kyc-uploads',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_service_role_key
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 30000
    );
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed to trigger KYC upload cleanup: %', SQLERRM;
END;
$$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule(
            'cleanup-abandoned-kyc-uploads',
            '0 3 * * *', -- daily at 03:00
            'SELECT public.trigger_cleanup_abandoned_kyc_uploads();'
        );
    END IF;
END $$;
