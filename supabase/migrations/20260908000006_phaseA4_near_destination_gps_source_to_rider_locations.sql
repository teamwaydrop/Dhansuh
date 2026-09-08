-- =============================================================================
-- PHASE A — STAGE A4: move the remaining GPS-consuming DB objects onto
--                     public.rider_locations (ADDITIVE where possible, reversible)
--
-- Ref: docs/PERF_phaseA_rider_locations_readonly_audit.md
--      (audit item S8 — the near-destination trigger is the ONLY SQL object that
--       MOVES to rider_locations; find_nearby_riders + every dispatch/rematch
--       function stay on the riders mirror, unchanged.)
--
-- WHAT A4 DOES (and ONLY this):
--   1. NEW trigger function public.check_rider_near_destination_from_rider_locations()
--      — a byte-for-byte copy of public.on_rider_location_near_destination()
--        EXCEPT the order lookup keys off NEW.rider_id (the rider_locations PK)
--        instead of NEW.id (the riders PK). Same 3.0 km radius, same
--        near_destination_notified guard, same intercity-only filter, same
--        send_push_notification_fnc('Almost There', ...) call.
--   2. NEW trigger trg_rider_locations_near_destination_check
--        AFTER UPDATE OF current_lat, current_lng ON public.rider_locations
--        -> the new function above.
--   3. DROP TRIGGER trigger_near_destination_check ON public.riders
--        (so the check runs exactly once, from the rider_locations write, and the
--         riders trigger surface stays minimal now that the Flutter writer's
--         riders GPS cadence was widened to ~1/min in A3).
--      The OLD function public.on_rider_location_near_destination() is LEFT IN
--      PLACE (now unused) so rollback is a one-line CREATE TRIGGER.
--   4. Locks down the two Phase A trigger helper functions that the Supabase
--      security advisor flagged as PUBLIC-executable SECURITY DEFINER (both are
--      INERT — RETURNS trigger, "can only be called as triggers" on a direct
--      call — but the REVOKE removes the advisor finding and matches the intent
--      of 20260906000003_relockdown_push_notification_functions.sql):
--        - public.sync_riders_gps_to_rider_locations()   (A1 bridge)
--        - public.check_rider_near_destination_from_rider_locations()  (new here)
--      No GRANT is issued: a trigger function does not need EXECUTE granted to
--      any role to fire as part of the triggering statement.
--
-- WHAT A4 DOES NOT DO:
--   * Does NOT drop / alter public.on_rider_location_near_destination() — kept
--     verbatim for rollback.
--   * Does NOT change find_nearby_riders or ANY dispatch / rematch / nearby-
--     search function — they keep reading public.riders.current_lat/lng.
--   * Does NOT change riders columns, riders REPLICA IDENTITY, the A1 bridge
--     trigger, the realtime publication, RLS, cron, or fare/payment/wallet/tax/
--     completion logic.
--   * Does NOT remove the riders GPS columns or the A1 bridge (that is a later
--     cleanup stage, A6).
--
-- delete_own_account(): updated in section 5 to also remove the deleted rider's
-- one row from public.rider_locations — mirrors how the same function already
-- deletes rider_payout_accounts / rider_vehicles. (The A1 bridge trigger already
-- propagates that function's `UPDATE riders SET current_lat = NULL ...` into
-- rider_locations, so even without this line a deleted account retains NO usable
-- coordinates; the explicit DELETE is data-hygiene / consistency, not a leak fix.)
--
-- ROLLBACK: see the commented block at the end of this file.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. NEW trigger function — near-destination check, sourced from rider_locations
--    (identical body to public.on_rider_location_near_destination(); the ONLY
--     change is `WHERE rider_id = NEW.rider_id` in place of `= NEW.id`).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_rider_near_destination_from_rider_locations()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_order RECORD;
    v_dist_km double precision;
BEGIN
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT id, user_id, destination_lat, destination_lng
    INTO v_order
    FROM public.orders
    WHERE rider_id = NEW.rider_id
      AND order_status = 'ongoing'
      AND near_destination_notified = false
      AND order_type::text LIKE 'intercity%'
      AND destination_lat IS NOT NULL
      AND destination_lng IS NOT NULL
    LIMIT 1;

    IF v_order.id IS NULL THEN
        RETURN NEW;
    END IF;

    v_dist_km := 6371 * acos(
        LEAST(GREATEST(
            cos(radians(v_order.destination_lat))
            * cos(radians(NEW.current_lat))
            * cos(radians(NEW.current_lng) - radians(v_order.destination_lng))
            + sin(radians(v_order.destination_lat))
            * sin(radians(NEW.current_lat))
        , -1.0), 1.0)
    );

    IF v_dist_km <= 3.0 THEN
        UPDATE public.orders
        SET near_destination_notified = true
        WHERE id = v_order.id;

        PERFORM public.send_push_notification_fnc(
            v_order.user_id,
            'Almost There',
            'You are about 10 minutes away from your destination.',
            jsonb_build_object('type', 'trip_near_destination', 'order_id', v_order.id)
        );
    END IF;

    RETURN NEW;
END;
$function$;

-- -----------------------------------------------------------------------------
-- 2. NEW trigger on public.rider_locations (parity with the old riders trigger:
--    AFTER UPDATE OF current_lat, current_lng, FOR EACH ROW, no WHEN clause).
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_rider_locations_near_destination_check ON public.rider_locations;
CREATE TRIGGER trg_rider_locations_near_destination_check
AFTER UPDATE OF current_lat, current_lng ON public.rider_locations
FOR EACH ROW
EXECUTE FUNCTION public.check_rider_near_destination_from_rider_locations();

-- -----------------------------------------------------------------------------
-- 3. Remove the old trigger from public.riders. The function it points at
--    (public.on_rider_location_near_destination()) is intentionally LEFT for
--    rollback — this only detaches it.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trigger_near_destination_check ON public.riders;

-- -----------------------------------------------------------------------------
-- 4. Advisor lockdown for the Phase A trigger helper functions (INERT; no GRANT).
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.sync_riders_gps_to_rider_locations() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.check_rider_near_destination_from_rider_locations() FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- 5. delete_own_account() — verbatim re-declaration of the production function
--    (CREATE OR REPLACE; body unchanged) with ONE added statement:
--        DELETE FROM public.rider_locations WHERE rider_id = v_rider.id;
--    placed in the `IF FOUND` rider block immediately after the existing
--    `DELETE FROM public.rider_vehicles ...`, matching how the function already
--    hard-deletes the rider's other pure-operational rows.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_own_account()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

        -- PHASE A (A4): the rider's single live-GPS row is pure operational data with no
        -- financial / reliability / legal-evidence value (unlike the riders row, which is
        -- retained). Remove it, consistent with the two DELETEs just above. The riders UPDATE
        -- above already fired the A1 bridge trigger, which upserted a NULL-coordinate row here;
        -- this DELETE drops that row outright.
        DELETE FROM public.rider_locations WHERE rider_id = v_rider.id;
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
$function$;


-- =============================================================================
-- ROLLBACK (run manually if needed — restores the pre-A4 state exactly):
--
--   -- 1. re-attach the near-destination check to riders
--   DROP TRIGGER IF EXISTS trg_rider_locations_near_destination_check ON public.rider_locations;
--   CREATE TRIGGER trigger_near_destination_check
--   AFTER UPDATE OF current_lat, current_lng ON public.riders
--   FOR EACH ROW EXECUTE FUNCTION public.on_rider_location_near_destination();
--
--   DROP FUNCTION IF EXISTS public.check_rider_near_destination_from_rider_locations();
--
--   -- 2. delete_own_account(): re-run the 20260819000000 / 20260803000000 body WITHOUT the
--   --    `DELETE FROM public.rider_locations ...` line (or simply leave the A4 version — the
--   --    extra DELETE is harmless if rider_locations still exists, and a no-op if A1 was also
--   --    rolled back and the table is gone... in which case restore the pre-A1 body).
--
--   -- 3. the REVOKEs in section 4 need no rollback (removing a PUBLIC EXECUTE default on an
--   --    inert trigger function changes no behaviour); to fully restore, GRANT EXECUTE ...
--   --    TO PUBLIC on both, though this is not recommended.
-- =============================================================================
