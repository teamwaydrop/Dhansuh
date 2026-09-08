-- Migration: Add SET search_path = public to all SECURITY DEFINER functions
-- that don't already have it.
-- Date: 2026-07-16
--
-- SECURITY DEFINER functions run with the privileges of the function owner
-- rather than the calling role. Without a pinned search_path, an unqualified
-- identifier inside the function body could theoretically resolve against a
-- schema earlier in the caller's search_path than 'public' (e.g. if a
-- malicious/shadowing object were created in a schema that precedes public
-- for some role) — a well-known Postgres privilege-escalation hardening
-- gap and a standard Supabase security-linter flag. Current exploitability
-- in this codebase is low since every table reference in these functions is
-- already schema-qualified (public.foo), but this closes the gap
-- unconditionally rather than relying on that continuing to hold for every
-- future edit.
--
-- This is pure hardening: SET search_path = public is added to each
-- function's signature with zero other change to logic, matching each
-- function's current (latest) definition exactly. Three functions already
-- had it (check_is_order_passenger, check_is_order_candidate_rider,
-- check_is_order_passenger_for_intercity) and are left untouched. Three
-- more (accept_intercity_offer, confirm_intercity_booking,
-- deliver_push_notification_http_fnc) are hardened together with their
-- own separate, substantive fixes in sibling migrations from this same
-- batch (M10/M11) rather than here, to avoid two competing redefinitions
-- of the same function landing in this batch.

-- accept_intercity_request (latest definition from 20260714000000_fix_accept_intercity_chat_sender_id.sql)
CREATE OR REPLACE FUNCTION public.accept_intercity_request(
    p_request_id uuid,
    p_rider_user_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_request RECORD;
    v_order RECORD;
    v_rider RECORD;
    v_travel_plan RECORD;
    v_otp text;
    v_active_orders_count int;
BEGIN
    -- 1. Get rider details and validate active status
    SELECT * INTO v_rider
    FROM public.riders
    WHERE user_id = p_rider_user_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Rider profile not found for user.'
        );
    END IF;

    -- 2. Fetch request to find the order ID (read-only for now)
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Intercity request not found.'
        );
    END IF;

    -- Ownership check: Request traveller_id must match rider id
    IF v_request.traveller_id != v_rider.id THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Request does not belong to this traveller.'
        );
    END IF;

    -- 3. Lock and fetch order (Order is source of truth, lock first)
    SELECT * INTO v_order
    FROM public.orders
    WHERE id = v_request.parcel_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Associated order not found.'
        );
    END IF;

    -- Idempotency check: If order is already assigned to this rider and accepted
    IF v_order.rider_id = v_rider.id AND v_order.order_status = 'accepted' THEN
        RETURN jsonb_build_object(
            'success', true,
            'code', 'ALREADY_ACCEPTED',
            'order_id', v_order.id,
            'request_id', v_request.id
        );
    END IF;

    -- Validate order availability
    IF v_order.order_status != 'searching' OR v_order.rider_id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ORDER_ALREADY_ASSIGNED',
            'message', 'Booking no longer available.'
        );
    END IF;

    -- Validate order search expiration
    IF v_order.search_expires_at IS NOT NULL AND v_order.search_expires_at < now() THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REQUEST_EXPIRED',
            'message', 'Order search has expired.'
        );
    END IF;

    -- Lock request now for update
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;

    -- Validate request expiration
    IF v_request.expires_at IS NOT NULL AND v_request.expires_at < now() THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REQUEST_EXPIRED',
            'message', 'Request negotiation has expired.'
        );
    END IF;

    -- Validate request status is eligible
    IF v_request.status NOT IN ('request_sent', 'discussion_started', 'fare_agreed') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Request status is not eligible for acceptance.'
        );
    END IF;

    -- 4. Validate traveler plan active status
    SELECT * INTO v_travel_plan
    FROM public.rider_travel_plans
    WHERE id = v_request.route_id;

    IF v_travel_plan IS NULL OR v_travel_plan.status::text != 'active' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'TRAVEL_PLAN_INACTIVE',
            'message', 'Travel plan is no longer active.'
        );
    END IF;

    -- 5. Validate rider is not already busy on another active order
    SELECT COUNT(*) INTO v_active_orders_count
    FROM public.orders
    WHERE rider_id = v_rider.id
      AND order_status IN ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing');

    IF v_active_orders_count > 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'RIDER_ALREADY_BUSY',
            'message', 'Rider is already handling another active order.'
        );
    END IF;

    -- 6. Generate cryptographically safe 4-digit OTP (loop to avoid collisions on orders)
    LOOP
        v_otp := floor(random() * 9000 + 1000)::text;
        -- Check collision in orders table
        PERFORM 1 FROM public.orders WHERE pickup_otp = v_otp AND order_status IN ('accepted', 'picked_up');
        EXIT WHEN NOT FOUND;
    END LOOP;

    -- 7. Update Request Status to 'confirmed'
    UPDATE public.intercity_requests
    SET status = 'confirmed',
        updated_at = now()
    WHERE id = p_request_id;

    -- 8. Update Order (assigned, otp, pricing)
    UPDATE public.orders
    SET order_status = 'accepted'::public.order_status_enum,
        rider_id = v_rider.id,
        final_fare = v_request.proposed_fare,
        current_fare = v_request.proposed_fare,
        pickup_otp = v_otp,
        updated_at = now()
    WHERE id = v_order.id;

    -- 9. Insert chat system notification message
    -- sender_id must be the rider's auth user id (order_chat_messages_sender_id_fkey
    -- references auth.users(id)), NOT v_rider.id which is the riders table's own PK.
    INSERT INTO public.order_chat_messages(
        sender_id,
        sender_type,
        message,
        user_id,
        is_support,
        order_id,
        rider_id,
        created_at
    ) VALUES (
        v_rider.user_id,
        'rider',
        '[AGREED] Rider accepted the request. Booking is confirmed.',
        v_order.user_id,
        false,
        v_order.id,
        v_rider.id,
        now()
    );

    RETURN jsonb_build_object(
        'success', true,
        'code', 'SUCCESS',
        'order_id', v_order.id,
        'request_id', v_request.id
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', SQLERRM
        );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- assign_nearby_searching_orders_to_rider (latest definition from 20260716000000_fix_dispatch_trigger_self_match_and_weight.sql)
CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_to_rider()
RETURNS TRIGGER AS $$
DECLARE
    v_order RECORD;
    v_radius_km double precision;
    v_stale_sec integer;
    v_dist_km double precision;
    v_timeout_sec integer;
    v_existing_id uuid;
    v_existing_status text;
    v_rider_vehicle text;
BEGIN
    -- 1. If coordinates are missing, bypass
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    -- 2. Fetch active dispatch config values
    SELECT
        COALESCE(round_2_radius_km, 5.0),
        COALESCE(rider_location_stale_sec, 60),
        COALESCE(rider_response_timeout_sec, 120)
    INTO
        v_radius_km,
        v_stale_sec,
        v_timeout_sec
    FROM public.dispatch_config
    WHERE is_active = true
    LIMIT 1;

    -- Fallbacks if config is missing or null
    v_radius_km := COALESCE(v_radius_km, 5.0);
    v_stale_sec := COALESCE(v_stale_sec, 60);
    v_timeout_sec := COALESCE(v_timeout_sec, 120);

    -- 3. Fetch rider's vehicle type (for weight/vehicle-aware matching)
    SELECT COALESCE(rk.vehicle_type::text, '') INTO v_rider_vehicle
    FROM public.rider_kyc rk
    WHERE rk.user_id = NEW.user_id
    LIMIT 1;

    FOR v_order IN (
        SELECT
            o.id,
            o.pickup_lat,
            o.pickup_lng,
            o.vehicle_type::text AS vehicle_type,
            o.order_type::text AS order_type,
            o.rider_earning,
            COALESCE(
                o.actual_weight_kg,
                COALESCE(NULLIF(regexp_replace(o.weight_category::text, '[^0-9.]', '', 'g'), ''), '0')::double precision
            )::double precision AS weight_kg
        FROM public.orders o
        WHERE o.order_status = 'searching'
          AND o.user_id != NEW.user_id
    ) LOOP
        -- Calculate distance between rider and order pickup location
        v_dist_km := 6371 * acos(
            LEAST(GREATEST(
                cos(radians(v_order.pickup_lat))
                * cos(radians(NEW.current_lat))
                * cos(
                    radians(NEW.current_lng)
                    - radians(v_order.pickup_lng)
                )
                + sin(radians(v_order.pickup_lat))
                * sin(radians(NEW.current_lat))
            , -1.0), 1.0)
        );

        -- If the rider is within the max radius, and matches the vehicle/weight filter
        IF v_dist_km <= v_radius_km AND (
            ((v_order.order_type = 'ride' OR v_order.order_type = 'intercity_ride' OR v_order.order_type = 'intercity') AND
             v_rider_vehicle = v_order.vehicle_type)
            OR
            (v_order.order_type = 'ride_sharing' AND v_rider_vehicle IN ('auto', 'cab'))
            OR
            -- Local Parcels / Deliveries
            (
                (v_order.order_type = 'local_parcel' OR v_order.order_type LIKE '%parcel%' OR v_order.order_type LIKE '%delivery%')
                AND v_order.order_type != 'intercity_parcel'
                AND
                (
                    (v_order.weight_kg < 10.0 AND v_rider_vehicle = 'bike')
                    OR
                    (v_order.weight_kg >= 10.0 AND v_rider_vehicle = 'auto')
                )
            )
            OR
            -- Intercity Parcels
            (
                v_order.order_type = 'intercity_parcel'
                AND
                (
                    (v_order.weight_kg < 10.0 AND v_rider_vehicle = 'bike')
                    OR
                    (v_order.weight_kg >= 10.0 AND v_rider_vehicle IN ('auto', 'cab'))
                )
            )
            OR
            (v_order.order_type NOT IN ('ride', 'intercity_ride', 'intercity', 'ride_sharing', 'local_parcel', 'intercity_parcel') AND v_order.order_type NOT LIKE '%parcel%' AND v_order.order_type NOT LIKE '%delivery%')
        ) THEN
            -- Check if this rider doesn't already have an assignment for this order
            v_existing_id := NULL;
            v_existing_status := NULL;

            SELECT id, assignment_status INTO v_existing_id, v_existing_status
            FROM public.rider_assignments
            WHERE order_id = v_order.id
              AND rider_id = NEW.id
            LIMIT 1;

            BEGIN
                IF v_existing_id IS NULL THEN
                    -- Insert assignment
                    INSERT INTO public.rider_assignments (
                        order_id,
                        rider_id,
                        assignment_round,
                        assignment_status,
                        distance_km,
                        estimated_earnings,
                        sent_at,
                        expires_at,
                        last_seen_at,
                        last_seen_fare
                    ) VALUES (
                        v_order.id,
                        NEW.id,
                        1,
                        'sent',
                        v_dist_km,
                        v_order.rider_earning,
                        NOW(),
                        NOW() + (v_timeout_sec || ' seconds')::interval,
                        NOW(),
                        v_order.rider_earning
                    );

                    -- Also insert into logs
                    INSERT INTO public.order_assignment_logs (
                        order_id,
                        rider_id,
                        assignment_round,
                        assignment_status,
                        rider_distance_km,
                        estimated_pickup_time_min,
                        sent_at
                    ) VALUES (
                        v_order.id,
                        NEW.id,
                        1,
                        'sent',
                        v_dist_km,
                        v_order.rider_earning,
                        NOW()
                    );
                ELSIF v_existing_status = 'expired' THEN
                    -- Only show again if the fare is boosted
                    IF EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND v_order.rider_earning > COALESCE(last_seen_fare, estimated_earnings, 0)
                    ) THEN
                        -- Update existing assignment back to 'sent' with fresh expiry
                        UPDATE public.rider_assignments
                        SET
                            assignment_status = 'sent',
                            distance_km = v_dist_km,
                            sent_at = NOW(),
                            expires_at = NOW() + (v_timeout_sec || ' seconds')::interval,
                            updated_at = NOW(),
                            responded_at = NULL,
                            response_type = NULL,
                            hidden_until = NULL,
                            last_seen_at = NOW(),
                            last_seen_fare = v_order.rider_earning
                        WHERE id = v_existing_id;

                        -- Log the update
                        INSERT INTO public.order_assignment_logs (
                            order_id,
                            rider_id,
                            assignment_round,
                            assignment_status,
                            rider_distance_km,
                            estimated_pickup_time_min,
                            sent_at
                        ) VALUES (
                            v_order.id,
                            NEW.id,
                            1,
                            'sent',
                            v_dist_km,
                            CEIL(v_dist_km * 3),
                            NOW()
                        );
                    END IF;
                ELSIF v_existing_status = 'rejected' THEN
                    -- Only show again if 4-minute cooldown is over AND the fare is boosted
                    IF EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND NOW() >= COALESCE(hidden_until, NOW())
                          AND v_order.rider_earning > COALESCE(last_seen_fare, estimated_earnings, 0)
                    ) THEN
                        -- Update existing assignment back to 'sent' with fresh expiry
                        UPDATE public.rider_assignments
                        SET
                            assignment_status = 'sent',
                            distance_km = v_dist_km,
                            sent_at = NOW(),
                            expires_at = NOW() + (v_timeout_sec || ' seconds')::interval,
                            updated_at = NOW(),
                            responded_at = NULL,
                            response_type = NULL,
                            hidden_until = NULL,
                            last_seen_at = NOW(),
                            last_seen_fare = v_order.rider_earning
                        WHERE id = v_existing_id;

                        -- Log the update
                        INSERT INTO public.order_assignment_logs (
                            order_id,
                            rider_id,
                            assignment_round,
                            assignment_status,
                            rider_distance_km,
                            estimated_pickup_time_min,
                            sent_at
                        ) VALUES (
                            v_order.id,
                            NEW.id,
                            1,
                            'sent',
                            v_dist_km,
                            CEIL(v_dist_km * 3),
                            NOW()
                        );
                    END IF;
                END IF;
            EXCEPTION WHEN unique_violation THEN
                -- Safely ignore duplicate key constraint violations
                NULL;
            END;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- audit_rider_wallets (latest definition from 20260616000006_financial_audits.sql)
CREATE OR REPLACE FUNCTION public.audit_rider_wallets()
RETURNS jsonb AS $$
DECLARE
  v_discrepancy_count integer := 0;
  v_details jsonb;
BEGIN
  -- Find all riders where wallet_balance != sum of wallet_transactions
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'rider_id', r.id,
    'wallet_balance', r.wallet_balance,
    'ledger_sum', coalesce(sum(t.amount), 0)
  )), '[]'::jsonb)
  INTO v_details
  FROM public.riders r
  LEFT JOIN public.wallet_transactions t ON t.rider_id = r.id
  GROUP BY r.id, r.wallet_balance
  HAVING r.wallet_balance != coalesce(sum(t.amount), 0);

  v_discrepancy_count := jsonb_array_length(v_details);

  -- Log the run results
  INSERT INTO public.wallet_audit_logs (discrepancies_found, details)
  VALUES (v_discrepancy_count, v_details);

  RETURN jsonb_build_object(
    'success', true,
    'discrepancies_found', v_discrepancy_count,
    'details', v_details
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- check_dormant_riders (latest definition from 20260602000003_expand_notifications_logic.sql)
CREATE OR REPLACE FUNCTION public.check_dormant_riders()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_rider RECORD;
    v_sub RECORD;
    v_hour integer;
BEGIN
    -- Get current hour in IST timezone
    v_hour := extract(hour from now() at time zone 'Asia/Kolkata');

    -- 3.1. Morning Dormant Rider Check (8:00 AM to 11:00 AM IST)
    -- If rider is offline for >2 hours and hasn't been notified today
    IF v_hour >= 8 AND v_hour <= 11 THEN
        FOR v_rider IN 
            SELECT r.id, r.user_id 
            FROM public.riders r
            WHERE (r.account_status != 'online' OR r.account_status IS NULL)
              AND (r.updated_at IS NULL OR r.updated_at < now() - INTERVAL '2 hours')
              AND (r.last_dormant_notification_sent_at IS NULL OR r.last_dormant_notification_sent_at < date_trunc('day', now() at time zone 'Asia/Kolkata'))
        LOOP
            PERFORM public.send_push_notification_fnc(
                v_rider.user_id,
                'Go Online! Rides & Parcels Waiting 🚀',
                'Rides and parcels are waiting in your location. Go online now to start earning!',
                jsonb_build_object('type', 'go_online')
            );
            
            UPDATE public.riders 
            SET last_dormant_notification_sent_at = now() 
            WHERE id = v_rider.id;
        END LOOP;
    END IF;

    -- 3.2. Active Subscription Offline Check
    -- If subscription is active, and rider is offline for >2 hours, remind them of zero commission benefits
    FOR v_rider IN 
        SELECT r.id, r.user_id 
        FROM public.riders r
        INNER JOIN public.rider_subscription_history sub ON sub.rider_id = r.id
        WHERE (r.account_status != 'online' OR r.account_status IS NULL)
          AND sub.is_active = true 
          AND sub.expires_at > now()
          AND (r.updated_at IS NULL OR r.updated_at < now() - INTERVAL '2 hours')
          AND (r.last_sub_offline_notification_sent_at IS NULL OR r.last_sub_offline_notification_sent_at < now() - INTERVAL '24 hours')
    LOOP
        PERFORM public.send_push_notification_fnc(
            v_rider.user_id,
            'Your Subscription is Active! ⚡',
            'Your Waydrop MAX subscription is active. Go online and take rides now to avail 100% commission-free earnings!',
            jsonb_build_object('type', 'go_online_sub')
        );
        
        UPDATE public.riders 
        SET last_sub_offline_notification_sent_at = now() 
        WHERE id = v_rider.id;
    END LOOP;

    -- 3.3. Subscription Expiry Checker
    -- A) Mark expired subscriptions inactive & notify
    FOR v_sub IN 
        SELECT sub.id, sub.rider_id, r.user_id 
        FROM public.rider_subscription_history sub
        INNER JOIN public.riders r ON r.id = sub.rider_id
        WHERE sub.is_active = true 
          AND sub.expires_at <= now()
    LOOP
        UPDATE public.rider_subscription_history 
        SET is_active = false 
        WHERE id = v_sub.id;

        PERFORM public.send_push_notification_fnc(
            v_sub.user_id,
            'Waydrop MAX Subscription Expired ⚠️',
            'Your commission-free subscription has expired. Renew/extend now to keep earning without commissions!',
            jsonb_build_object('type', 'subscription_expired')
        );
    END LOOP;

    -- B) Notify subscriptions expiring in the next 24 hours
    FOR v_sub IN 
        SELECT sub.id, sub.rider_id, r.user_id, sub.expires_at 
        FROM public.rider_subscription_history sub
        INNER JOIN public.riders r ON r.id = sub.rider_id
        WHERE sub.is_active = true 
          AND sub.expires_at > now() 
          AND sub.expires_at <= now() + INTERVAL '24 hours'
          AND sub.expire_warning_sent = false
    LOOP
        UPDATE public.rider_subscription_history 
        SET expire_warning_sent = true 
        WHERE id = v_sub.id;

        PERFORM public.send_push_notification_fnc(
            v_sub.user_id,
            'Subscription Expiring Soon ⏰',
            'Your Waydrop MAX subscription expires in less than 24 hours (on ' || to_char(v_sub.expires_at at time zone 'Asia/Kolkata', 'HH:MI AM, DD Mon') || '). Extend now!',
            jsonb_build_object('type', 'subscription_expiring')
        );
    END LOOP;
END;
$$;

-- check_otp_lockout (latest definition from 20260616000007_otp_limits_rls.sql)
CREATE OR REPLACE FUNCTION public.check_otp_lockout(p_phone varchar)
RETURNS jsonb AS $$
DECLARE
  v_failed_count_15m integer;
  v_failed_count_24h integer;
  v_locked_until timestamp with time zone;
BEGIN
  -- 1. Check if there are 20+ failed attempts in the last 24h -> require a completely fresh OTP code
  SELECT count(*) INTO v_failed_count_24h
  FROM public.otp_attempts
  WHERE phone = p_phone
    AND action_type = 'verify'
    AND is_successful = false
    AND attempted_at >= now() - interval '24 hours';

  IF v_failed_count_24h >= 20 THEN
    RETURN jsonb_build_object(
      'locked', true,
      'lockout_type', 'fresh_issuance',
      'message', 'Too many failed verification attempts. Please request a fresh OTP code.',
      'retry_after_seconds', 0
    );
  END IF;

  -- 2. Check for 10 failed attempts within 24h -> 1 hour lockout
  IF v_failed_count_24h >= 10 THEN
    -- Find when the 10th failure occurred
    SELECT attempted_at + interval '1 hour' INTO v_locked_until
    FROM public.otp_attempts
    WHERE phone = p_phone
      AND action_type = 'verify'
      AND is_successful = false
      AND attempted_at >= now() - interval '24 hours'
    ORDER BY attempted_at DESC
    LIMIT 1 OFFSET 9;

    IF v_locked_until > now() THEN
      RETURN jsonb_build_object(
        'locked', true,
        'lockout_type', '1_hour',
        'message', 'Account locked for 1 hour due to 10 failed verification attempts.',
        'retry_after_seconds', extract(epoch from (v_locked_until - now()))::integer
      );
    END IF;
  END IF;

  -- 3. Check for 5 failed attempts in the last 15m -> 15 min lockout
  SELECT count(*) INTO v_failed_count_15m
  FROM public.otp_attempts
  WHERE phone = p_phone
    AND action_type = 'verify'
    AND is_successful = false
    AND attempted_at >= now() - interval '15 minutes';

  IF v_failed_count_15m >= 5 THEN
    -- Find when the 5th failure occurred
    SELECT attempted_at + interval '15 minutes' INTO v_locked_until
    FROM public.otp_attempts
    WHERE phone = p_phone
      AND action_type = 'verify'
      AND is_successful = false
      AND attempted_at >= now() - interval '15 minutes'
    ORDER BY attempted_at DESC
    LIMIT 1 OFFSET 4;

    IF v_locked_until > now() THEN
      RETURN jsonb_build_object(
        'locked', true,
        'lockout_type', '15_minutes',
        'message', 'Account locked for 15 minutes due to 5 incorrect OTP attempts.',
        'retry_after_seconds', extract(epoch from (v_locked_until - now()))::integer
      );
    END IF;
  END IF;

  RETURN jsonb_build_object('locked', false);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- check_payout_update_limit (latest definition from 20260530000000_rider_payout_accounts.sql)
CREATE OR REPLACE FUNCTION public.check_payout_update_limit()
RETURNS TRIGGER AS $$
DECLARE
    v_update_count integer;
BEGIN
    -- Check if it's insert, or if it's update where rider-initiated fields changed
    IF (TG_OP = 'INSERT') OR 
       (TG_OP = 'UPDATE' AND (
           OLD.account_number IS DISTINCT FROM NEW.account_number OR
           OLD.ifsc_code IS DISTINCT FROM NEW.ifsc_code OR
           OLD.upi_vpa IS DISTINCT FROM NEW.upi_vpa OR
           OLD.beneficiary_name IS DISTINCT FROM NEW.beneficiary_name OR
           OLD.beneficiary_phone IS DISTINCT FROM NEW.beneficiary_phone OR
           OLD.beneficiary_email IS DISTINCT FROM NEW.beneficiary_email OR
           OLD.payout_method IS DISTINCT FROM NEW.payout_method
       )) THEN
       
        -- 1. Lock the user row to prevent race conditions on concurrent requests
        PERFORM 1 FROM public.users WHERE id = NEW.user_id FOR UPDATE;

        -- 2. Count updates in the last 7 days (rolling window)
        SELECT COUNT(*) INTO v_update_count
        FROM public.rider_payout_updates_log
        WHERE user_id = NEW.user_id
          AND created_at > now() - INTERVAL '7 days';

        IF v_update_count >= 2 THEN
            RAISE EXCEPTION 'Maximum of 2 payout account updates allowed per week';
        END IF;

        -- 3. Log this update event
        INSERT INTO public.rider_payout_updates_log (user_id)
        VALUES (NEW.user_id);
        
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- complete_withdrawal (latest definition from 20260716000001_fix_wallet_ledger_withdrawal_functions.sql)
CREATE OR REPLACE FUNCTION public.complete_withdrawal(
    p_withdrawal_id uuid,
    p_cashfree_ref_id text,
    p_status text,
    p_response jsonb
)
RETURNS jsonb AS $$
DECLARE
    v_rider_id uuid;
    v_amount numeric;
    v_current_status public.rider_withdrawal_status_enum;
    v_new_status public.rider_withdrawal_status_enum;
BEGIN
    -- Safely cast input status text to enum
    BEGIN
        v_new_status := p_status::public.rider_withdrawal_status_enum;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Invalid status to complete withdrawal');
    END;

    -- Fetch and lock the withdrawal record
    SELECT rider_id, amount, status INTO v_rider_id, v_amount, v_current_status
    FROM public.rider_withdrawals
    WHERE id = p_withdrawal_id
    FOR UPDATE;

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Withdrawal record not found');
    END IF;

    -- Check if already finalized (success or failed)
    IF v_current_status IN ('success'::public.rider_withdrawal_status_enum, 'failed'::public.rider_withdrawal_status_enum) THEN
        RETURN jsonb_build_object('success', true, 'message', 'Withdrawal already finalized in ' || v_current_status::text || ' state');
    END IF;

    -- Prevent invalid transition from processing back to pending
    IF v_current_status = 'processing'::public.rider_withdrawal_status_enum AND v_new_status = 'pending'::public.rider_withdrawal_status_enum THEN
        RETURN jsonb_build_object('success', false, 'message', 'Cannot transition from processing back to pending');
    END IF;

    -- Update withdrawal status (updated_at is handled by trigger)
    UPDATE public.rider_withdrawals
    SET status = v_new_status,
        cashfree_reference_id = p_cashfree_ref_id,
        cashfree_response = p_response
    WHERE id = p_withdrawal_id;

    -- Refund rider's wallet balance if status resolved to failed
    IF v_new_status = 'failed'::public.rider_withdrawal_status_enum THEN
        -- Lock rider row for update
        PERFORM id FROM public.riders WHERE id = v_rider_id FOR UPDATE;

        UPDATE public.riders
        SET wallet_balance = wallet_balance + v_amount
        WHERE id = v_rider_id;

        -- Record the ledger entry for this wallet refund
        INSERT INTO public.wallet_transactions (
            rider_id,
            amount,
            type,
            reference_id,
            reference_type,
            description
        ) VALUES (
            v_rider_id,
            v_amount,
            'credit',
            p_withdrawal_id,
            'withdrawal',
            'Withdrawal failed, refunded to wallet'
        );
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- expire_trip_sharing_tokens (latest definition from 20260616000007_otp_limits_rls.sql)
CREATE OR REPLACE FUNCTION public.expire_trip_sharing_tokens()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.order_status IN ('completed', 'delivered', 'cancelled') THEN
    UPDATE public.trip_share_tokens
    SET is_revoked = true
    WHERE order_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- fail_withdrawal (latest definition from 20260716000001_fix_wallet_ledger_withdrawal_functions.sql)
CREATE OR REPLACE FUNCTION public.fail_withdrawal(p_withdrawal_id uuid, p_error_response jsonb)
RETURNS jsonb AS $$
DECLARE
    v_rider_id uuid;
    v_amount numeric;
    v_status public.rider_withdrawal_status_enum;
BEGIN
    -- Fetch and lock the withdrawal record
    SELECT rider_id, amount, status INTO v_rider_id, v_amount, v_status
    FROM public.rider_withdrawals
    WHERE id = p_withdrawal_id
    FOR UPDATE;

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Withdrawal record not found');
    END IF;

    -- Only allow failing from non-finalized states (pending or processing)
    IF v_status IN ('success'::public.rider_withdrawal_status_enum, 'failed'::public.rider_withdrawal_status_enum) THEN
        RETURN jsonb_build_object('success', true, 'message', 'Withdrawal already finalized in ' || v_status::text || ' state');
    END IF;

    -- Update withdrawal status (updated_at is handled by trigger)
    UPDATE public.rider_withdrawals
    SET status = 'failed'::public.rider_withdrawal_status_enum,
        cashfree_response = p_error_response
    WHERE id = p_withdrawal_id;

    -- Lock rider row for update
    PERFORM id FROM public.riders WHERE id = v_rider_id FOR UPDATE;

    -- Refund rider's wallet balance
    UPDATE public.riders
    SET wallet_balance = wallet_balance + v_amount
    WHERE id = v_rider_id;

    -- Record the ledger entry for this wallet refund
    INSERT INTO public.wallet_transactions (
        rider_id,
        amount,
        type,
        reference_id,
        reference_type,
        description
    ) VALUES (
        v_rider_id,
        v_amount,
        'credit',
        p_withdrawal_id,
        'withdrawal',
        'Withdrawal failed, refunded to wallet'
    );

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- get_rider_reliability_stats (latest definition from 20260622000002_smart_matching_final_production.sql)
CREATE OR REPLACE FUNCTION public.get_rider_reliability_stats(p_rider_id UUID)
RETURNS TABLE (
    reliability_score INT,
    rating NUMERIC,
    completion_rate NUMERIC,
    on_time_rate NUMERIC,
    total_completed BIGINT,
    total_cancelled BIGINT,
    experience_score INT
) AS $$
DECLARE
    v_rating NUMERIC;
    v_completed BIGINT;
    v_cancelled BIGINT;
    v_on_time BIGINT;
    v_completion_rate NUMERIC;
    v_on_time_rate NUMERIC;
    v_experience_score INT;
    v_rating_score NUMERIC;
    v_reliability_score INT;
BEGIN
    -- 1. Get rating (Bayesian rating calculated in riders table)
    SELECT COALESCE(r.rating, 5.0) INTO v_rating FROM public.riders r WHERE r.id = p_rider_id;
    v_rating_score := v_rating * 20.0; -- 5.0 rating -> 100 points

    -- 2. Completed / Cancelled / On-Time counts
    SELECT 
        COUNT(id) FILTER (WHERE order_status IN ('completed', 'delivered')),
        COUNT(id) FILTER (WHERE order_status = 'cancelled'),
        COUNT(id) FILTER (
            WHERE order_status IN ('completed', 'delivered') 
              AND (travel_date IS NULL OR completed_at <= travel_date + INTERVAL '4 hours')
              AND NOT EXISTS (
                  SELECT 1 FROM public.rider_reviews rr 
                  WHERE rr.order_id = orders.id AND 'late_arrival' = ANY(rr.tags)
              )
        )
    INTO v_completed, v_cancelled, v_on_time
    FROM public.orders
    WHERE rider_id = p_rider_id;

    -- 3. Calculate Rates
    IF (v_completed + v_cancelled) > 0 THEN
        v_completion_rate := (v_completed::numeric / (v_completed + v_cancelled)) * 100.0;
    ELSE
        v_completion_rate := 100.0; -- Default for new riders
    END IF;

    IF v_completed > 0 THEN
        v_on_time_rate := (v_on_time::numeric / v_completed) * 100.0;
    ELSE
        v_on_time_rate := 100.0; -- Default for new riders
    END IF;

    -- 4. Experience Score (Piecewise curve)
    IF v_completed = 0 THEN
        v_experience_score := 0;
    ELSIF v_completed < 10 THEN
        v_experience_score := 20;
    ELSIF v_completed < 50 THEN
        v_experience_score := 60;
    ELSIF v_completed < 100 THEN
        v_experience_score := 80;
    ELSE
        v_experience_score := 100;
    END IF;

    -- 5. Calculate final reliability score (40% rating, 40% completion rate, 20% experience)
    v_reliability_score := ROUND((v_rating_score * 0.40) + (v_completion_rate * 0.40) + (v_experience_score * 0.20));

    RETURN QUERY SELECT 
        LEAST(GREATEST(v_reliability_score, 0), 100)::INT,
        v_rating,
        ROUND(v_completion_rate, 2),
        ROUND(v_on_time_rate, 2),
        v_completed,
        v_cancelled,
        v_experience_score;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- get_trip_share_token (latest definition from 20260715000001_fix_trip_share_tokens_rls.sql)
CREATE OR REPLACE FUNCTION public.get_trip_share_token(p_token varchar)
RETURNS TABLE (
  token_id uuid,
  order_id uuid,
  expires_at timestamp with time zone
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT t.token_id, t.order_id, t.expires_at
  FROM public.trip_share_tokens t
  WHERE t.token = p_token
    AND t.is_revoked = false
    AND t.expires_at > now();
END;
$$;

-- handle_order_activity_tracking (latest definition from 20260616000010_timezone_alignment.sql)
CREATE OR REPLACE FUNCTION public.handle_order_activity_tracking()
RETURNS TRIGGER AS $$
DECLARE
  v_trip_time integer := 0;
  v_earnings numeric := 0.0;
  v_date date;
BEGIN
  -- Track changes to completed, delivered, or cancelled status
  IF NEW.order_status IS DISTINCT FROM OLD.order_status THEN
    v_date := (COALESCE(NEW.completed_at, NEW.cancelled_at, now()) AT TIME ZONE 'Asia/Kolkata')::date;
    
    -- Completed / Delivered
    IF NEW.order_status IN ('completed', 'delivered') AND NEW.rider_id IS NOT NULL THEN
      -- Calculate trip time in seconds
      IF NEW.time_taken_seconds IS NOT NULL AND NEW.time_taken_seconds > 0 THEN
        v_trip_time := NEW.time_taken_seconds;
      ELSE
        -- Fallback to difference between completed_at and picked_up_at / accepted_at
        IF NEW.completed_at IS NOT NULL THEN
          v_trip_time := EXTRACT(EPOCH FROM (NEW.completed_at - COALESCE(NEW.picked_up_at, NEW.accepted_at, NEW.created_at)))::integer;
          IF v_trip_time < 0 THEN v_trip_time := 0; END IF;
        END IF;
      END IF;

      v_earnings := COALESCE(NEW.rider_earning, 0.0);

      INSERT INTO public.rider_daily_activity (rider_id, date, active_seconds, completed_orders, earnings)
      VALUES (NEW.rider_id, v_date, v_trip_time, 1, v_earnings)
      ON CONFLICT (rider_id, date) DO UPDATE
      SET active_seconds = rider_daily_activity.active_seconds + v_trip_time,
          completed_orders = rider_daily_activity.completed_orders + 1,
          earnings = rider_daily_activity.earnings + v_earnings,
          updated_at = now();
          
    -- Cancelled
    ELSIF NEW.order_status = 'cancelled' AND NEW.rider_id IS NOT NULL THEN
      INSERT INTO public.rider_daily_activity (rider_id, date, cancelled_orders)
      VALUES (NEW.rider_id, v_date, 1)
      ON CONFLICT (rider_id, date) DO UPDATE
      SET cancelled_orders = rider_daily_activity.cancelled_orders + 1,
          updated_at = now();
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- handle_promo_usage_changes (latest definition from 20260716000006_fix_promo_redemption_race_condition.sql)
CREATE OR REPLACE FUNCTION public.handle_promo_usage_changes()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    UPDATE public.promo_codes
    SET uses_count = GREATEST(0, uses_count - 1)
    WHERE id = OLD.promo_code_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- handle_rider_status_change (latest definition from 20260616000010_timezone_alignment.sql)
CREATE OR REPLACE FUNCTION public.handle_rider_status_change()
RETURNS TRIGGER AS $$
DECLARE
BEGIN
  -- If account_status is toggled
  IF NEW.account_status IS DISTINCT FROM OLD.account_status THEN
    -- Going online
    IF NEW.account_status = 'online' THEN
      INSERT INTO public.rider_daily_activity (rider_id, date, last_online_toggle_at)
      VALUES (NEW.id, (now() AT TIME ZONE 'Asia/Kolkata')::date, now())
      ON CONFLICT (rider_id, date) DO UPDATE
      SET last_online_toggle_at = now(),
          updated_at = now();
    -- Going offline
    ELSIF NEW.account_status = 'offline' AND OLD.account_status = 'online' THEN
      UPDATE public.rider_daily_activity
      SET online_seconds = online_seconds + EXTRACT(EPOCH FROM (now() - last_online_toggle_at))::integer,
          last_online_toggle_at = NULL,
          updated_at = now()
      WHERE rider_id = NEW.id AND last_online_toggle_at IS NOT NULL;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- initiate_withdrawal (latest definition from 20260716000001_fix_wallet_ledger_withdrawal_functions.sql)
CREATE OR REPLACE FUNCTION public.initiate_withdrawal(p_amount numeric, p_user_id uuid)
RETURNS jsonb AS $$
DECLARE
    v_rider_id uuid;
    v_wallet_balance numeric;
    v_payout_account_id uuid;
    v_payout_status public.cashfree_beneficiary_status_enum;
    v_transfer_id text;
    v_withdrawal_id uuid;
    v_beneficiary_id text;
    v_payout_method public.payout_method_enum;
    v_upi_vpa text;
BEGIN
    -- 1. Validation for withdrawal amount
    IF p_amount <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Invalid withdrawal amount'
        );
    END IF;

    -- 2. Fetch rider and lock row to prevent race conditions on balance updates
    SELECT id, wallet_balance INTO v_rider_id, v_wallet_balance
    FROM public.riders
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Rider profile not found');
    END IF;

    -- 3. Fetch payout account details (limit to 1 account to prevent multi-row return database exception)
    SELECT id, cashfree_beneficiary_status, beneficiary_id, payout_method, upi_vpa
    INTO v_payout_account_id, v_payout_status, v_beneficiary_id, v_payout_method, v_upi_vpa
    FROM public.rider_payout_accounts
    WHERE user_id = p_user_id
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_payout_account_id IS NULL OR v_beneficiary_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Payout account beneficiary ID not found');
    END IF;

    -- 4. Check wallet balance
    IF v_wallet_balance < p_amount THEN
        RETURN jsonb_build_object('success', false, 'message', 'Insufficient wallet balance');
    END IF;

    -- 5. Generate unique transfer_id using WDPY prefix
    v_transfer_id := public.generate_unique_transfer_id();

    -- 6. Deduct wallet balance (rider row is already locked)
    UPDATE public.riders
    SET wallet_balance = wallet_balance - p_amount
    WHERE id = v_rider_id;

    -- 7. Insert pending withdrawal (logs trigger automatically)
    INSERT INTO public.rider_withdrawals (
        rider_id,
        user_id,
        amount,
        transfer_id,
        status
    ) VALUES (
        v_rider_id,
        p_user_id,
        p_amount,
        v_transfer_id,
        'pending'::public.rider_withdrawal_status_enum
    ) RETURNING id INTO v_withdrawal_id;

    -- 8. Record the ledger entry for this wallet debit
    INSERT INTO public.wallet_transactions (
        rider_id,
        amount,
        type,
        reference_id,
        reference_type,
        description
    ) VALUES (
        v_rider_id,
        -p_amount,
        'debit',
        v_withdrawal_id,
        'withdrawal',
        'Withdrawal requested, debited from wallet'
    );

    RETURN jsonb_build_object(
        'success', true,
        'rider_id', v_rider_id,
        'withdrawal_id', v_withdrawal_id,
        'transfer_id', v_transfer_id,
        'beneficiary_id', v_beneficiary_id,
        'payout_method', v_payout_method,
        'upi_vpa', v_upi_vpa
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- log_otp_attempt (latest definition from 20260616000007_otp_limits_rls.sql)
CREATE OR REPLACE FUNCTION public.log_otp_attempt(
  p_phone varchar,
  p_is_successful boolean,
  p_action_type varchar,
  p_otp_code varchar DEFAULT NULL,
  p_client_ip varchar DEFAULT NULL
)
RETURNS void AS $$
BEGIN
  INSERT INTO public.otp_attempts (phone, is_successful, action_type, otp_code, client_ip)
  VALUES (p_phone, p_is_successful, p_action_type, p_otp_code, p_client_ip);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- log_rider_withdrawal_event (latest definition from 20260530000001_rider_withdrawals.sql)
CREATE OR REPLACE FUNCTION public.log_rider_withdrawal_event()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO public.rider_withdrawal_events (
            withdrawal_id,
            event_type,
            old_status,
            new_status,
            response
        ) VALUES (
            NEW.id,
            'initiated',
            NULL,
            NEW.status,
            NEW.cashfree_response
        );
    ELSIF (TG_OP = 'UPDATE') THEN
        -- Only log if status changed, response metadata changed, or reference id changed
        IF (OLD.status != NEW.status OR OLD.cashfree_response IS DISTINCT FROM NEW.cashfree_response OR OLD.cashfree_reference_id IS DISTINCT FROM NEW.cashfree_reference_id) THEN
            INSERT INTO public.rider_withdrawal_events (
                withdrawal_id,
                event_type,
                old_status,
                new_status,
                response
            ) VALUES (
                NEW.id,
                CASE 
                    WHEN OLD.status != NEW.status THEN 'status_change'
                    ELSE 'metadata_update'
                END,
                OLD.status,
                NEW.status,
                NEW.cashfree_response
            );
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- on_intercity_request_change (latest definition from 20260603000001_create_intercity_requests.sql)
CREATE OR REPLACE FUNCTION public.on_intercity_request_change()
RETURNS TRIGGER AS $$
DECLARE
    v_rider_user_id uuid := NULL;
    v_passenger_user_id uuid := NEW.sender_id;
    v_title text := '';
    v_body text := '';
    v_notify_user_id uuid := NULL;
BEGIN
    -- Fetch the rider's user_id
    SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.traveller_id;

    -- A) When a request is INSERTED (request_sent)
    IF TG_OP = 'INSERT' THEN
        IF NEW.initiated_by = 'sender' THEN
            -- Sender is passenger, notify rider (traveller)
            v_notify_user_id := v_rider_user_id;
            v_title := 'New Request Received 📦';
            v_body := 'A passenger wants you to carry their shipment or ride. Open details to discuss!';
        ELSE
            -- Initiator is rider, notify passenger (sender)
            v_notify_user_id := v_passenger_user_id;
            v_title := 'New Offer Received ⚡';
            v_body := 'A traveller offered to carry your shipment or ride. Open details to discuss!';
        END IF;

    -- B) When request is UPDATED and status changes
    ELSIF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
        IF NEW.status = 'discussion_started' THEN
            -- Discussion accepted, notify the initiator of request
            IF NEW.initiated_by = 'sender' THEN
                v_notify_user_id := v_passenger_user_id;
            ELSE
                v_notify_user_id := v_rider_user_id;
            END IF;
            v_title := 'Discussion Opened 💬';
            v_body := 'The conversation has been accepted. You can now chat and negotiate the fare!';
            
        ELSIF NEW.status = 'confirmed' THEN
            -- Notify BOTH (need to send separately, here we notify the one who did NOT trigger the final confirm, or just notify sender that they can pay)
            -- Let's notify passenger (sender) to complete payment
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Booking Confirmed! 🎉';
            v_body := 'Both parties have confirmed the booking. Please proceed to payment.';
            
        ELSIF NEW.status = 'paid' THEN
            -- Passenger paid, notify traveller (rider)
            v_notify_user_id := v_rider_user_id;
            v_title := 'Payment Verified! 💳';
            v_body := 'Passenger has paid for the trip. You can now start the transit.';
            
        ELSIF NEW.status = 'in_progress' THEN
            -- Trip started, notify passenger
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Trip on the Way 🗺️';
            v_body := 'Traveller has collected the parcel/started the ride. Track live updates!';
            
        ELSIF NEW.status = 'completed' THEN
            -- Completed, notify passenger
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Trip Completed Successfully 🎉';
            v_body := 'Your shipment/ride has been delivered. Thank the traveller!';
        END IF;
    END IF;

    -- Send push notification if a target recipient is identified
    IF v_notify_user_id IS NOT NULL THEN
        PERFORM public.send_push_notification_fnc(
            v_notify_user_id,
            v_title,
            v_body,
            jsonb_build_object(
                'type', 'intercity_request',
                'request_id', NEW.id,
                'order_id', NEW.parcel_id,
                'rider_id', NEW.traveller_id,
                'status', NEW.status
            )
        );
    END IF;

    -- In case of final confirmed status, let's also notify the rider (separate call since both need it)
    IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'confirmed' THEN
        IF v_rider_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_rider_user_id,
                'Booking Confirmed! 🎉',
                'Booking is confirmed by the passenger. Awaiting payment.',
                jsonb_build_object(
                    'type', 'intercity_request',
                    'request_id', NEW.id,
                    'order_id', NEW.parcel_id,
                    'rider_id', NEW.traveller_id,
                    'status', NEW.status
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- on_new_chat_message (latest definition from 20260602000002_create_notification_triggers.sql)
CREATE OR REPLACE FUNCTION public.on_new_chat_message()
RETURNS TRIGGER AS $$
DECLARE
    v_recipient_user_id uuid := NULL;
    v_customer_user_id uuid := NULL;
    v_rider_user_id uuid := NULL;
    v_order_rider_id uuid := NULL;
    v_sender_name text := 'Someone';
BEGIN
    -- Get sender name if possible
    SELECT COALESCE(full_name, 'Someone') INTO v_sender_name 
    FROM public.users 
    WHERE id = NEW.sender_id;

    IF NEW.order_id IS NOT NULL THEN
        -- Order chat
        SELECT user_id, rider_id INTO v_customer_user_id, v_order_rider_id 
        FROM public.orders 
        WHERE id = NEW.order_id;
        
        -- Get rider's user_id
        IF NEW.rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;
        ELSIF v_order_rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = v_order_rider_id;
        END IF;

        IF NEW.sender_id = v_customer_user_id THEN
            v_recipient_user_id := v_rider_user_id;
        ELSIF NEW.sender_id = v_rider_user_id THEN
            v_recipient_user_id := v_customer_user_id;
        END IF;
    ELSE
        -- Support chat
        IF NEW.user_id IS NOT NULL AND NEW.sender_id != NEW.user_id THEN
            v_recipient_user_id := NEW.user_id;
        END IF;
    END IF;

    -- Send notification if recipient is determined
    IF v_recipient_user_id IS NOT NULL THEN
        PERFORM public.send_push_notification_fnc(
            v_recipient_user_id,
            v_sender_name,
            NEW.message,
            jsonb_build_object(
                'type', 'chat_message',
                'order_id', NEW.order_id,
                'message_id', NEW.id,
                'sender_type', NEW.sender_type
            )
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- on_notification_insert (latest definition from 20260617000000_add_order_notification_mode.sql)
CREATE OR REPLACE FUNCTION public.on_notification_insert()
RETURNS TRIGGER AS $$
BEGIN
    -- Call delivery helper to trigger FCM send-push-notification edge function
    PERFORM public.deliver_push_notification_http_fnc(
        NEW.user_id,
        NEW.title,
        NEW.body,
        NEW.payload || jsonb_build_object(
            'notification_id', NEW.id,
            'type', NEW.notification_type,
            'reference_id', NEW.reference_id,
            'reference_type', NEW.reference_type
        )
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- on_order_status_update (latest definition from 20260602000003_expand_notifications_logic.sql)
CREATE OR REPLACE FUNCTION public.on_order_status_update()
RETURNS TRIGGER AS $$
DECLARE
    v_rider_user_id uuid := NULL;
    v_title text := '';
    v_body text := '';
    v_otp text := '';
BEGIN
    -- Check if status actually changed
    IF OLD.order_status IS DISTINCT FROM NEW.order_status THEN
        -- 1. Notify Passenger (NEW.user_id) for status updates
        IF NEW.order_status = 'accepted' THEN
            v_title := 'Order Accepted 🚗';
            v_body := 'A rider has accepted your order and is on the way!';
        ELSIF NEW.order_status = 'rider_arrived' THEN
            v_otp := COALESCE(NEW.pickup_otp, '');
            IF NEW.order_type = 'ride' THEN
                v_title := 'Your Rider has Arrived! 👋';
                v_body := 'Your rider has arrived. Share OTP ' || v_otp || ' with the rider to start your trip.';
            ELSE
                v_title := 'Rider at Pickup Location 📦';
                v_body := 'Your rider has arrived at the pickup location. Share OTP ' || v_otp || ' to start the delivery.';
            END IF;
        ELSIF NEW.order_status = 'picked_up' OR NEW.order_status = 'ongoing' THEN
            v_title := 'Trip on the Way 🗺️';
            v_body := 'Your trip has started. Track your rider''s live location on the map.';
        ELSIF NEW.order_status = 'rider_at_drop' THEN
            v_otp := COALESCE(NEW.delivery_otp, '');
            v_title := 'Rider Reached Drop-off 📍';
            v_body := 'Your rider has reached the drop-off point. Please share OTP ' || v_otp || ' with the receiver to complete the delivery.';
        ELSIF NEW.order_status = 'completed' OR NEW.order_status = 'delivered' THEN
            v_title := 'Order Delivered Successfully 🎉';
            v_body := 'Your order has been completed. Rate your experience and thank the rider!';
        ELSIF NEW.order_status = 'cancelled' THEN
            v_title := 'Order Cancelled ❌';
            v_body := 'Your order has been cancelled.';
        ELSE
            v_title := 'Order Status Update ℹ️';
            v_body := 'There is a new update on your order. Status is now: ' || NEW.order_status;
        END IF;

        -- Send to passenger
        IF v_title != '' AND v_body != '' AND NEW.user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                NEW.user_id,
                v_title,
                v_body,
                jsonb_build_object(
                    'type', 'order_status',
                    'order_id', NEW.id,
                    'status', NEW.order_status
                )
            );
        END IF;

        -- 2. Notify Rider if order was cancelled
        IF NEW.order_status = 'cancelled' AND NEW.rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;
            
            IF v_rider_user_id IS NOT NULL THEN
                PERFORM public.send_push_notification_fnc(
                    v_rider_user_id,
                    'Order Cancelled ❌',
                    'The order you accepted has been cancelled by the customer.',
                    jsonb_build_object(
                        'type', 'order_status',
                        'order_id', NEW.id,
                        'status', 'cancelled'
                    )
                );
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- on_rider_assignment_change (latest definition from 20260602000002_create_notification_triggers.sql)
CREATE OR REPLACE FUNCTION public.on_rider_assignment_change()
RETURNS TRIGGER AS $$
DECLARE
    v_rider_user_id uuid := NULL;
BEGIN
    -- Notify when status is set or updated to 'sent'
    IF NEW.assignment_status = 'sent' AND (TG_OP = 'INSERT' OR OLD.assignment_status IS DISTINCT FROM 'sent') THEN
        SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

        IF v_rider_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_rider_user_id,
                'New Order Request',
                'You have a new order request nearby!',
                jsonb_build_object(
                    'type', 'order_assignment',
                    'order_id', NEW.order_id,
                    'assignment_id', NEW.id
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- on_rider_review_insert (latest definition from 20260602000003_expand_notifications_logic.sql)
CREATE OR REPLACE FUNCTION public.on_rider_review_insert()
RETURNS TRIGGER AS $$
DECLARE
    v_rider_user_id uuid := NULL;
    v_title text := 'New Review Received';
    v_body text := '';
BEGIN
    SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

    IF v_rider_user_id IS NOT NULL THEN
        IF NEW.rating = 5 THEN
            v_title := 'You''ve been rated 5-Star! 🌟';
            v_body := 'Excellent job! A passenger rated you 5 stars. Keep up the amazing work!';
        ELSE
            v_title := 'New Rating Received ⭐';
            v_body := 'You received a new ' || NEW.rating::text || '-star rating from your recent ride.';
        END IF;

        IF NEW.comment IS NOT NULL AND NEW.comment != '' THEN
            v_body := v_body || ' Feedback: "' || substring(NEW.comment from 1 for 40) || '..."';
        END IF;

        PERFORM public.send_push_notification_fnc(
            v_rider_user_id,
            v_title,
            v_body,
            jsonb_build_object(
                'type', 'new_rating',
                'rating', NEW.rating,
                'review_id', NEW.id
            )
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- on_rider_wallet_balance_update (latest definition from 20260602000003_expand_notifications_logic.sql)
CREATE OR REPLACE FUNCTION public.on_rider_wallet_balance_update()
RETURNS TRIGGER AS $$
BEGIN
    -- If wallet balance drops below -500 (meaning they owe more than 500 rupees cash collected)
    -- And it was not below -500 before (to avoid spamming on subsequent updates)
    IF NEW.wallet_balance < -500 AND (OLD.wallet_balance IS NULL OR OLD.wallet_balance >= -500) THEN
        PERFORM public.send_push_notification_fnc(
            NEW.user_id,
            'COD Settlement Required 💳',
            'Your cash collections exceed the allowed limit. Please pay your COD settlement of ₹' || ABS(NEW.wallet_balance)::text || ' to continue receiving ride requests.',
            jsonb_build_object(
                'type', 'cod_settlement',
                'balance', NEW.wallet_balance
            )
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- prevent_role_self_escalation (latest definition from 20260716000005_prevent_role_self_escalation.sql)
CREATE OR REPLACE FUNCTION public.prevent_role_self_escalation()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.role IS DISTINCT FROM OLD.role THEN
        IF auth.role() != 'service_role' THEN
            RAISE EXCEPTION 'Changing the role column is not permitted for this session.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- send_admin_push_notification (latest definition from 20260602000003_expand_notifications_logic.sql)
CREATE OR REPLACE FUNCTION public.send_admin_push_notification(
    p_recipient_type text, -- 'all', 'users', 'riders'
    p_city text,           -- NULL or city name
    p_title text,
    p_body text,
    p_data jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id uuid;
BEGIN
    IF p_recipient_type = 'riders' THEN
        FOR v_user_id IN 
            SELECT DISTINCT r.user_id 
            FROM public.riders r
            WHERE p_city IS NULL OR EXISTS (
                SELECT 1 FROM public.orders o 
                WHERE o.rider_id = r.id AND (o.pickup_city = p_city OR o.destination_city = p_city)
                LIMIT 1
            )
        LOOP
            PERFORM public.send_push_notification_fnc(v_user_id, p_title, p_body, p_data);
        END LOOP;
        
    ELSIF p_recipient_type = 'users' THEN
        FOR v_user_id IN 
            SELECT DISTINCT u.id 
            FROM public.users u
            WHERE (p_city IS NULL OR EXISTS (
                SELECT 1 FROM public.orders o 
                WHERE o.user_id = u.id AND (o.pickup_city = p_city OR o.destination_city = p_city)
                LIMIT 1
            ))
            AND NOT EXISTS (SELECT 1 FROM public.riders r WHERE r.user_id = u.id)
        LOOP
            PERFORM public.send_push_notification_fnc(v_user_id, p_title, p_body, p_data);
        END LOOP;
        
    ELSE
        FOR v_user_id IN 
            SELECT id FROM public.users u
            WHERE p_city IS NULL OR EXISTS (
                SELECT 1 FROM public.orders o 
                WHERE o.user_id = u.id AND (o.pickup_city = p_city OR o.destination_city = p_city)
                LIMIT 1
            )
        LOOP
            PERFORM public.send_push_notification_fnc(v_user_id, p_title, p_body, p_data);
        END LOOP;
    END IF;
END;
$$;

-- send_push_notification_fnc (latest definition from 20260617000000_add_order_notification_mode.sql)
CREATE OR REPLACE FUNCTION public.send_push_notification_fnc(
    p_user_id uuid,
    p_title text,
    p_body text,
    p_data jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_notification_type text := COALESCE(p_data->>'type', 'general');
    v_reference_id uuid := NULL;
    v_reference_type text := NULL;
BEGIN
    -- Extract reference info if present
    IF p_data ? 'order_id' THEN
        BEGIN
            v_reference_id := (p_data->>'order_id')::uuid;
            v_reference_type := 'order';
        EXCEPTION WHEN OTHERS THEN
            -- Ignore formatting errors
        END;
    ELSIF p_data ? 'payment_id' THEN
        BEGIN
            v_reference_id := (p_data->>'payment_id')::uuid;
            v_reference_type := 'payment';
        EXCEPTION WHEN OTHERS THEN
            -- Ignore formatting errors
        END;
    END IF;

    -- Insert into notifications log table (which triggers async HTTP delivery)
    INSERT INTO public.notifications (
        user_id,
        title,
        body,
        notification_type,
        reference_id,
        reference_type,
        payload
    ) VALUES (
        p_user_id,
        p_title,
        p_body,
        v_notification_type,
        v_reference_id,
        v_reference_type,
        p_data
    );
END;
$$;

-- validate_and_calculate_promo (latest definition from 20260716000006_fix_promo_redemption_race_condition.sql)
CREATE OR REPLACE FUNCTION public.validate_and_calculate_promo(
  p_code varchar,
  p_order_value numeric,
  p_user_id uuid
)
RETURNS jsonb AS $$
DECLARE
  v_promo record;
  v_used_count integer;
  v_discount numeric := 0.00;
BEGIN
  -- 1. Fetch promo details, locking the row so concurrent redemptions of
  -- the same code are serialized against the reservation UPDATE below.
  SELECT * INTO v_promo
  FROM public.promo_codes
  WHERE code = UPPER(p_code)
    AND is_active = true
    AND expires_at > now()
  FOR UPDATE;

  IF v_promo.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Invalid or expired promo code');
  END IF;

  -- 1.5 Verify audience constraints
  IF v_promo.audience_type = 'restricted' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.promo_code_users
      WHERE promo_code_id = v_promo.id AND user_id = p_user_id
    ) THEN
      RETURN jsonb_build_object('success', false, 'message', 'This promo code is not valid for your account');
    END IF;
  END IF;

  -- 2. Verify min order value
  IF p_order_value < v_promo.min_order_value THEN
    RETURN jsonb_build_object('success', false, 'message', 'Minimum order value of ₹' || v_promo.min_order_value::text || ' is required');
  END IF;

  -- 3. Verify single usage per user
  SELECT count(*) INTO v_used_count
  FROM public.user_promo_usages
  WHERE user_id = p_user_id AND promo_code_id = v_promo.id;

  IF v_used_count > 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'You have already used this promo code');
  END IF;

  -- 4. Atomically reserve a usage slot, enforcing the global cap (if any)
  -- in the same statement as the increment so it can never be exceeded.
  UPDATE public.promo_codes
  SET uses_count = uses_count + 1
  WHERE id = v_promo.id
    AND (max_uses IS NULL OR uses_count < max_uses);

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Promo code usage limit has been reached');
  END IF;

  -- 5. Calculate discount amount
  IF v_promo.discount_type = 'fixed_amount' THEN
    v_discount := LEAST(v_promo.discount_value, p_order_value);
  ELSIF v_promo.discount_type = 'percentage' THEN
    v_discount := (p_order_value * (v_promo.discount_value / 100.00));
    IF v_promo.max_discount IS NOT NULL THEN
      v_discount := LEAST(v_discount, v_promo.max_discount);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'promo_id', v_promo.id,
    'discount_amount', round(v_discount, 2),
    'discount_type', v_promo.discount_type,
    'discount_value', v_promo.discount_value
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

