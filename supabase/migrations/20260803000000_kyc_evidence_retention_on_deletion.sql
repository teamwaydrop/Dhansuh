-- =====================================================================
-- P0-CLASS SAFETY FIX: delete_own_account() destroyed Drop Partner identity evidence with no
-- backup, breaking the historical order -> rider_id -> identity-evidence chain a fraud/safety/
-- legal investigation would need.
-- =====================================================================
-- CONFIRMED BEFORE THIS MIGRATION (re-read the live 20260802000000 definition, not assumed):
--   - rider_kyc: Aadhaar/PAN/DL numbers, full_name, father_name, date_of_birth, and every
--     document image PATH STRING are overwritten with placeholders in place -- no copy retained.
--   - rider_vehicles (additional vehicles' RC front/back + vehicle photo): hard-deleted outright.
--   - The delete-account edge function's removeAllUnderPrefix("rider_kyc", userId) permanently
--     deletes every KYC document image from Storage (Aadhaar/PAN/DL front+back, rider photo,
--     vehicle photo, primary RC front+back) -- no copy retained.
--   - riders/orders rows themselves are correctly preserved (not deleted) -- so the historical
--     link survives, but it now points at identity data that no longer exists anywhere.
--
-- FIX: archive the identity evidence into a new, strictly admin/support-only table + storage
-- bucket BEFORE anonymizing/deleting the live copies. The live rider_kyc/rider_vehicles rows and
-- the rider_kyc Storage bucket behave EXACTLY as before (still anonymized/deleted from the
-- caller's/any-ordinary-user's perspective, still never publicly/passenger/driver accessible --
-- P1's private-bucket hardening is untouched) -- the only change is that a admin/support-only
-- copy now survives the deletion, for the narrow case of a later fraud/safety/legal need.
--
-- RETENTION PERIOD: deliberately NOT invented here. retention_expires_at is nullable and left
-- NULL (= indefinite hold pending an actual decision) -- see the column comment. The exact
-- retention duration and its legal basis (e.g. under applicable data-protection or KYC/AML
-- regulation) is a BUSINESS/LEGAL DECISION that Way Drop's legal/compliance function must set;
-- this migration only adds the field to record that decision once made, plus a legal_hold flag
-- for case-by-case extension (e.g. an active investigation), and does not implement any
-- automatic purge job (inventing an expiry/purge policy is explicitly out of scope here).
--
-- ACCESS CONTROL: mirrors the exact admin/support pattern already established for rider_kyc
-- itself (20260731000000) and storage.objects (20260731000004) -- no new role system invented.
-- The deleted user, and every other ordinary app user, has zero access: no owner-based policy
-- exists on this table/bucket at all (unlike rider_kyc's own owner-SELECT policy).
-- =====================================================================
--
-- RECONCILIATION NOTE (2026-08-04): applied directly to the linked Supabase project but never
-- committed to this repo; reconstructed verbatim from supabase_migrations.schema_migrations.

-- =====================================================================
-- 1. Archive table for rider identity evidence (Aadhaar/PAN/DL/RC + document images).
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.rider_kyc_retention_archive (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    rider_id uuid NOT NULL REFERENCES public.riders(id),
    user_id uuid NOT NULL,
    kyc_id uuid,

    full_name text,
    father_name text,
    date_of_birth date,
    aadhaar_number text,
    pan_number text,
    driving_license_number text,
    vehicle_number text,
    vehicle_type text,

    -- Storage paths as they existed at the moment of archival, relative within the new
    -- kyc_retention_archive bucket (the edge function copies the original object to this same
    -- relative path in that bucket, then deletes the original from the public rider_kyc bucket).
    rider_image_path text,
    aadhaar_front_image_path text,
    aadhaar_back_image_path text,
    pan_front_image_path text,
    pan_back_image_path text,
    license_front_image_path text,
    license_back_image_path text,
    vehicle_image_path text,
    vehicle_rc_front_image_path text,
    vehicle_rc_back_image_path text,

    -- Any ADDITIONAL vehicles (public.rider_vehicles, beyond the single primary KYC vehicle
    -- above) that existed at deletion time, snapshotted as a JSON array before that table's rows
    -- are hard-deleted -- same rc_front_image/rc_back_image/vehicle_image fields, plus
    -- vehicle_type/vehicle_number, per vehicle.
    additional_vehicles jsonb NOT NULL DEFAULT '[]'::jsonb,

    deletion_requested_at timestamptz NOT NULL DEFAULT now(),
    retention_reason text NOT NULL DEFAULT 'account_deletion',

    -- NULL = indefinite hold, pending the retention-period BUSINESS/LEGAL DECISION described
    -- above. Once that decision is made, this column is where it should be recorded (either by a
    -- follow-up migration setting a default, or by an admin tool updating existing rows) -- no
    -- automatic purge/expiry job exists or is implied by this column.
    retention_expires_at timestamptz,

    -- Case-by-case override: set true to mark a specific rider's evidence as under active
    -- investigation/legal hold, independent of whatever general retention_expires_at is later
    -- configured.
    legal_hold boolean NOT NULL DEFAULT false,

    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_rider_kyc_retention_archive_rider_id
    ON public.rider_kyc_retention_archive (rider_id);

CREATE INDEX IF NOT EXISTS idx_rider_kyc_retention_archive_user_id
    ON public.rider_kyc_retention_archive (user_id);

ALTER TABLE public.rider_kyc_retention_archive ENABLE ROW LEVEL SECURITY;

-- Admin/support ONLY -- no owner-based policy exists (the deleted account must never regain
-- access to this data), and no ordinary authenticated user has any grant here at all.
DROP POLICY IF EXISTS "Admin support can view retained KYC archive" ON public.rider_kyc_retention_archive;

CREATE POLICY "Admin support can view retained KYC archive"
ON public.rider_kyc_retention_archive
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.users u
        WHERE u.id = auth.uid() AND (u.role = 'admin' OR u.role = 'support')
    )
);

-- No INSERT/UPDATE/DELETE policy for 'authenticated' at all -- writes only ever happen via
-- delete_own_account() (SECURITY DEFINER, bypasses RLS) or direct service-role access.
GRANT SELECT ON public.rider_kyc_retention_archive TO authenticated;

GRANT ALL ON public.rider_kyc_retention_archive TO service_role;

-- =====================================================================
-- 2. Restricted storage bucket for archived KYC document images. Private (never public --
--    P1's rider_kyc bucket-privacy hardening is not weakened by this migration; this is a
--    SEPARATE, even MORE restricted bucket). Admin/support SELECT only -- no owner-based
--    access, no broad "authenticated" grant of any kind (unlike rider_kyc's own narrow
--    rider_image/vehicle_image carve-out for passenger matching -- nothing in this archive
--    bucket is ever meant to be shown to any ordinary user).
-- =====================================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('kyc_retention_archive', 'kyc_retention_archive', false)
ON CONFLICT (id) DO UPDATE SET public = false;

DROP POLICY IF EXISTS "Admin support can view archived KYC storage" ON storage.objects;

CREATE POLICY "Admin support can view archived KYC storage"
ON storage.objects FOR SELECT
TO authenticated
USING (
    bucket_id = 'kyc_retention_archive'
    AND EXISTS (
        SELECT 1 FROM public.users u
        WHERE u.id = auth.uid() AND (u.role = 'admin' OR u.role = 'support')
    )
);

-- No INSERT/UPDATE/DELETE policy for 'authenticated' -- only the delete-account edge function's
-- service-role client ever writes to this bucket.

-- =====================================================================
-- 3. delete_own_account(): archive identity evidence BEFORE anonymizing/deleting it. Every
--    other branch (users/orders/notifications/user_devices/user_device_tokens/
--    rider_payout_accounts, idempotency, auth.uid() binding) is preserved byte-for-byte from
--    20260802000000 -- only the rider_kyc/rider_vehicles handling changes.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.delete_own_account()
RETURNS jsonb AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_rider RECORD;
    v_kyc RECORD;
    v_vehicle_archive jsonb := '[]'::jsonb;
    v_already_deleted boolean := false;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHENTICATED', 'message', 'Not authenticated.');
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.data_deletion_requests
        WHERE user_id = v_user_id AND status = 'completed'
    ) INTO v_already_deleted;

    IF v_already_deleted THEN
        RETURN jsonb_build_object('success', true, 'already_deleted', true, 'had_rider_profile', false, 'rider_id', NULL);
    END IF;

    INSERT INTO public.data_deletion_requests (user_id, status)
    VALUES (v_user_id, 'pending')
    ON CONFLICT (user_id) WHERE status = 'pending' DO NOTHING;

    -- =====================================================
    -- RIDER / DROP PARTNER DATA (only if this account ever completed rider onboarding)
    -- =====================================================
    SELECT * INTO v_rider FROM public.riders WHERE user_id = v_user_id;

    IF FOUND THEN
        SELECT * INTO v_kyc FROM public.rider_kyc WHERE user_id = v_user_id;

        -- Snapshot any ADDITIONAL vehicles before their rows are deleted below.
        SELECT COALESCE(
            jsonb_agg(jsonb_build_object(
                'vehicle_type', rv.vehicle_type::text,
                'vehicle_number', rv.vehicle_number,
                'rc_front_image', rv.rc_front_image,
                'rc_back_image', rv.rc_back_image,
                'vehicle_image', rv.vehicle_image,
                'created_at', rv.created_at
            )),
            '[]'::jsonb
        )
        INTO v_vehicle_archive
        FROM public.rider_vehicles rv
        WHERE rv.rider_id = v_rider.id;

        -- SAFETY FIX: archive identity evidence BEFORE it is overwritten/deleted below --
        -- preserves the historical orders.rider_id -> riders.id -> [this archive row] chain for
        -- fraud/safety/legal-investigation purposes, admin/support access only (see table RLS).
        IF v_kyc.id IS NOT NULL THEN
            INSERT INTO public.rider_kyc_retention_archive (
                rider_id, user_id, kyc_id,
                full_name, father_name, date_of_birth,
                aadhaar_number, pan_number, driving_license_number,
                vehicle_number, vehicle_type,
                rider_image_path, aadhaar_front_image_path, aadhaar_back_image_path,
                pan_front_image_path, pan_back_image_path,
                license_front_image_path, license_back_image_path,
                vehicle_image_path, vehicle_rc_front_image_path, vehicle_rc_back_image_path,
                additional_vehicles
            ) VALUES (
                v_rider.id, v_user_id, v_kyc.id,
                v_kyc.full_name, v_kyc.father_name, v_kyc.date_of_birth,
                v_kyc.aadhaar_number, v_kyc.pan_number, v_kyc.driving_license_number,
                v_kyc.vehicle_number, v_kyc.vehicle_type::text,
                v_kyc.rider_image, v_kyc.aadhaar_front_image, v_kyc.aadhaar_back_image,
                v_kyc.pan_front_image, v_kyc.pan_back_image,
                v_kyc.license_front_image, v_kyc.license_back_image,
                v_kyc.vehicle_image, v_kyc."VECHILE_RC_front_image", v_kyc."VECHILE_RC_back_image",
                v_vehicle_archive
            );
        END IF;

        -- rider_kyc: now safely archived above -- overwrite the LIVE row exactly as before
        -- (constraint-safe placeholders; most columns are NOT NULL / have CHECK constraints).
        UPDATE public.rider_kyc
        SET full_name = 'Deleted User',
            father_name = 'Deleted User',
            aadhaar_number = '000000000000',
            pan_number = 'ZZZZZ0000Z',
            driving_license_number = 'DELETED',
            vehicle_number = 'DELETED',
            date_of_birth = '1900-01-01',
            rider_image = '',
            aadhaar_front_image = '',
            aadhaar_back_image = '',
            pan_front_image = '',
            pan_back_image = '',
            license_front_image = '',
            license_back_image = '',
            vehicle_image = '',
            "VECHILE_RC_front_image" = NULL,
            "VECHILE_RC_back_image" = NULL,
            activation_status = 'suspended',
            rejection_reason = NULL,
            updated_at = now()
        WHERE user_id = v_user_id;

        -- riders: wallet/earnings/rating/order-count numbers are preserved (financial/reliability
        -- history) -- only location and dispatch-eligibility are cleared. 'blocked' permanently
        -- excludes this row from every dispatch/matching query, which all filter on
        -- account_status = 'online'.
        UPDATE public.riders
        SET current_lat = NULL,
            current_lng = NULL,
            current_heading = NULL,
            last_location_updated_at = NULL,
            account_status = 'blocked',
            updated_at = now()
        WHERE user_id = v_user_id;

        -- Financial-identity (bank/UPI): no historical/ledger value of its own (the actual
        -- payout amounts live in wallet_transactions/rider_withdrawals, untouched) -- out of
        -- scope for this identity-evidence fix, unchanged from 20260802000000.
        DELETE FROM public.rider_payout_accounts WHERE rider_id = v_rider.id;

        -- Now safely archived above (additional_vehicles) -- delete the live rows exactly as
        -- before.
        DELETE FROM public.rider_vehicles WHERE rider_id = v_rider.id;
    END IF;

    -- =====================================================
    -- PERSONAL / SESSION DATA (no financial or dispute significance) -- hard delete
    -- =====================================================
    DELETE FROM public.notifications WHERE user_id = v_user_id;
    DELETE FROM public.user_devices WHERE user_id = v_user_id;
    DELETE FROM public.user_device_tokens WHERE user_id = v_user_id;

    -- =====================================================
    -- ORDERS: this account's OWN bookings only (as passenger, via user_id) -- fare/GST/
    -- commission/status/timestamps are financial/accounting history and are never touched.
    -- =====================================================
    UPDATE public.orders
    SET pickup_address = 'Deleted',
        destination_address = 'Deleted',
        receiver_name = NULL,
        receiver_phone = NULL,
        special_instructions = NULL,
        created_ip_address = NULL,
        created_device_ref = NULL,
        created_device_model = NULL,
        created_device_brand = NULL,
        created_os_version = NULL,
        created_app_version = NULL
    WHERE user_id = v_user_id;

    -- =====================================================
    -- users: the account row itself. Never deleted (orders.user_id ON DELETE RESTRICT) --
    -- phone/email cleared (both are UNIQUE) so the same phone number can be used to sign up
    -- again in future; notification preferences flipped off as defense-in-depth.
    -- =====================================================
    UPDATE public.users
    SET full_name = 'Deleted User',
        email = NULL,
        phone = NULL,
        gender = NULL,
        profile_photo_url = NULL,
        pref_order_notifications = false,
        pref_chat_notifications = false,
        pref_rating_notifications = false,
        pref_admin_notifications = false
    WHERE id = v_user_id;

    UPDATE public.data_deletion_requests
    SET status = 'completed', processed_at = now()
    WHERE user_id = v_user_id AND status = 'pending';

    RETURN jsonb_build_object(
        'success', true,
        'already_deleted', false,
        'had_rider_profile', (v_rider.id IS NOT NULL),
        'rider_id', v_rider.id
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'DELETE_FAILED', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.delete_own_account() TO authenticated;
