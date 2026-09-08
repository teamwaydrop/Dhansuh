-- Migration: block delete_own_account() while the caller has any order still in an active,
-- non-terminal state -- either as the passenger (orders.user_id) or, if they ever completed
-- rider onboarding, as the assigned rider/traveller (orders.rider_id).
--
-- BUG FIX (production bug report): delete_own_account() (20260802000000, most recently replaced
-- by 20260803000000) had no active-order check at all -- a traveller mid intercity-parcel
-- delivery, or a rider/passenger mid local ride/parcel, could delete their account while an
-- order was still live, anonymizing the identity a counterparty and any in-flight
-- OTP/payment/dispatch state still depended on.
--
-- SCOPE, DELIBERATELY MINIMAL: only the guard is new. Every other branch of
-- delete_own_account() (already-deleted short-circuit, data_deletion_requests bookkeeping, KYC
-- archival, riders/orders/users anonymization, auth.uid() binding) is preserved byte-for-byte
-- from 20260803000000. The guard runs BEFORE the data_deletion_requests INSERT and before any
-- anonymization write, so a blocked attempt leaves zero partial state behind -- a later retry
-- (once the order is no longer active) runs the exact same function from a clean start.
--
-- "Active, non-terminal" reuses the exact status list already established elsewhere in this
-- codebase for the identical purpose (e.g. app_start_screen.dart's active-order classification):
-- created, searching, accepted, rider_arrived, picked_up, ongoing, rider_at_drop,
-- payment_pending. completed/delivered/cancelled/expired orders never block deletion, matching
-- the explicit requirement that only genuinely active states are blocking. A rider's merely-
-- posted travel plan with no accepted booking against it is not itself blocking -- only a real
-- order in one of the statuses above is (an empty travel plan carries no counterparty risk).
--
-- The rider_id lookup is a self-contained subquery (not the function's own v_rider variable,
-- which is populated later and whose PL/pgSQL FOUND state the existing rider-data-clearing
-- branch further down still depends on byte-for-byte) so this guard cannot interact with or
-- change any existing control flow below it.

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

    -- =====================================================
    -- BUG FIX: block deletion while a genuinely active order exists for this account, either as
    -- passenger or as the assigned rider/traveller. Checked first, before any other write.
    -- =====================================================
    IF EXISTS (
        SELECT 1 FROM public.orders o
        WHERE (
            o.user_id = v_user_id
            OR o.rider_id IN (SELECT id FROM public.riders WHERE user_id = v_user_id)
        )
        AND o.order_status::text IN (
            'created', 'searching', 'accepted', 'rider_arrived',
            'picked_up', 'ongoing', 'rider_at_drop', 'payment_pending'
        )
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ACTIVE_ORDER_EXISTS',
            'message', 'You cannot delete your account while you have an active trip or parcel delivery. Please complete or cancel the active trip first.'
        );
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
