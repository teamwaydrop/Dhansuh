-- Migration: recreate the 3 pg_cron jobs that never actually got scheduled, now that pg_cron is
-- enabled on this project.
-- Date: 2026-08-07
--
-- ROOT CAUSE: three prior migrations each guarded their `cron.schedule(...)` call with
-- `IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')` and ran at a time pg_cron was
-- NOT installed on this project -- so all three silently no-op'd. Confirmed directly:
-- `SELECT * FROM cron.job` returned zero rows before this migration; `pg_extension` had no
-- `pg_cron` row until it was just enabled via the Supabase Dashboard. Enabling the extension does
-- not retroactively re-run any migration's guarded block, so all three needed to be re-issued here.
--
-- A FOURTH complication, found while writing this migration: `20260801000000_kyc_upload_storage_
-- policies_and_cleanup.sql` (the source of job #3, cleanup-abandoned-kyc-uploads) was ALSO never
-- actually applied -- its version string collides with an unrelated, already-applied migration
-- (a `prevent_role_self_escalation()` search_path fix recorded under the same "20260801000000"
-- version in supabase_migrations.schema_migrations, confirmed by reading its stored `statements`
-- directly). Since `supabase db push` tracks applied state purely by version string, it has always
-- treated "20260801000000" as satisfied and skipped the KYC-cleanup file's content entirely -- so
-- `public.trigger_cleanup_abandoned_kyc_uploads()` (the function job #3's schedule calls) does not
-- exist on this database either. This migration recreates it too, or job #3 would be scheduled
-- against a function that errors on every run.
--
-- SCOPE DECISION: `20260801000000`'s OTHER half -- four `rider_kyc` storage.objects policies,
-- including "Allow public to view kyc documents" (bucket-wide, unrestricted, `TO public`) -- is
-- deliberately NOT reproduced here. That policy set predates and directly conflicts with
-- `20260731000004_rider_kyc_bucket_private.sql` (confirmed live and correct: bucket flipped
-- private, owner/admin-scoped policies, narrow rider_image/vehicle_image-only public carve-out).
-- Reapplying the old public-read policy would silently re-expose every rider's Aadhaar/PAN/DL/RC
-- images to any unauthenticated caller -- a severe regression of an already-shipped security fix,
-- and the opposite of "preserve existing production behavior." Only the cleanup function (which
-- touches no storage RLS) and its cron schedule are recreated below.
--
-- IDEMPOTENCY: every job is scheduled only if a job of that exact name does not already exist in
-- cron.job -- never blindly re-calls cron.schedule (which would either duplicate the job under a
-- new jobid on older pg_cron versions, or silently rewrite an operator's manually-adjusted schedule
-- on newer ones). Existing schedules for any of the three jobs, if one somehow already exists, are
-- left completely untouched. Safe to re-run this migration any number of times.

-- =====================================================================
-- 1. Recreate trigger_cleanup_abandoned_kyc_uploads() -- job #3's target function never existed on
--    this database (see header). Body is byte-for-byte identical to the original, never-applied
--    20260801000000 definition -- no logic change.
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

-- =====================================================================
-- 2. Schedule all three jobs, each only if missing. Schedules/commands match their original
--    source migrations exactly:
--      rider-dormant-and-expiry-checks : 20260602000003_expand_notifications_logic.sql
--      intercity-expiry-checks         : 20260717000008_intercity_expiry_scheduling_and_notifications.sql
--      cleanup-abandoned-kyc-uploads   : 20260801000000_kyc_upload_storage_policies_and_cleanup.sql
-- =====================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN

        IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'rider-dormant-and-expiry-checks') THEN
            PERFORM cron.schedule(
                'rider-dormant-and-expiry-checks',
                '0 * * * *', -- At minute 0 of every hour
                'SELECT public.check_dormant_riders();'
            );
        END IF;

        IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'intercity-expiry-checks') THEN
            PERFORM cron.schedule(
                'intercity-expiry-checks',
                '*/15 * * * *', -- every 15 minutes
                'SELECT public.expire_stale_intercity_requests();'
            );
        END IF;

        IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'cleanup-abandoned-kyc-uploads') THEN
            PERFORM cron.schedule(
                'cleanup-abandoned-kyc-uploads',
                '0 3 * * *', -- daily at 03:00
                'SELECT public.trigger_cleanup_abandoned_kyc_uploads();'
            );
        END IF;

    END IF;
END $$;
