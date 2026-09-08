


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE TYPE "public"."activation_status_enum" AS ENUM (
    'inactive',
    'profile_pending',
    'active',
    'suspended'
);


ALTER TYPE "public"."activation_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."assignment_status_enum" AS ENUM (
    'sent',
    'viewed',
    'accepted',
    'rejected',
    'timed_out',
    'expired',
    'cancelled'
);


ALTER TYPE "public"."assignment_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."cancelled_by_enum" AS ENUM (
    'user',
    'rider',
    'admin',
    'system'
);


ALTER TYPE "public"."cancelled_by_enum" OWNER TO "postgres";


CREATE TYPE "public"."cashfree_beneficiary_status_enum" AS ENUM (
    'pending',
    'active',
    'failed',
    'disabled'
);


ALTER TYPE "public"."cashfree_beneficiary_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."intercity_assignment_status_enum" AS ENUM (
    'sent',
    'viewed',
    'accepted',
    'rejected',
    'timed_out',
    'expired',
    'cancelled',
    'accepted_by_user'
);


ALTER TYPE "public"."intercity_assignment_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."kyc_status_enum" AS ENUM (
    'pending',
    'under_review',
    'approved',
    'rejected',
    'resubmitted'
);


ALTER TYPE "public"."kyc_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."order_status_enum" AS ENUM (
    'created',
    'searching',
    'accepted',
    'rider_arrived',
    'picked_up',
    'ongoing',
    'rider_at_drop',
    'completed',
    'delivered',
    'cancelled',
    'expired'
);


ALTER TYPE "public"."order_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."order_type_enum" AS ENUM (
    'ride',
    'intercity_ride',
    'ride_sharing',
    'local_parcel',
    'intercity_parcel',
    'batch_delivery',
    'food_delivery',
    'grocery_delivery'
);


ALTER TYPE "public"."order_type_enum" OWNER TO "postgres";


CREATE TYPE "public"."parcel_type_enum" AS ENUM (
    'documents',
    'electronics',
    'food',
    'clothes',
    'fragile',
    'others'
);


ALTER TYPE "public"."parcel_type_enum" OWNER TO "postgres";


CREATE TYPE "public"."payment_for_enum" AS ENUM (
    'ride_order',
    'parcel_order',
    'wallet_topup',
    'subscription',
    'withdrawal',
    'refund',
    'cod_settlement',
    'ride_boost',
    'intercity_ride_boost',
    'intercity_parcel_boost',
    'intercity_ride_order',
    'intercity_parcel_order',
    'ride_sharing'
);


ALTER TYPE "public"."payment_for_enum" OWNER TO "postgres";


CREATE TYPE "public"."payment_method_enum" AS ENUM (
    'upi',
    'card',
    'wallet',
    'netbanking',
    'cash',
    'cod',
    'cashfree'
);


ALTER TYPE "public"."payment_method_enum" OWNER TO "postgres";


CREATE TYPE "public"."payment_mode_enum" AS ENUM (
    'cash',
    'online',
    'wallet'
);


ALTER TYPE "public"."payment_mode_enum" OWNER TO "postgres";


CREATE TYPE "public"."payment_status_enum" AS ENUM (
    'pending',
    'paid',
    'failed',
    'refunded',
    'partial_refund',
    'cash_collected',
    'cash_pending_settlement'
);


ALTER TYPE "public"."payment_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."payout_method_enum" AS ENUM (
    'bank_account',
    'upi'
);


ALTER TYPE "public"."payout_method_enum" OWNER TO "postgres";


CREATE TYPE "public"."preferred_mode_enum" AS ENUM (
    'user',
    'rider'
);


ALTER TYPE "public"."preferred_mode_enum" OWNER TO "postgres";


CREATE TYPE "public"."pricing_city_tier_enum" AS ENUM (
    'tier_1',
    'tier_2'
);


ALTER TYPE "public"."pricing_city_tier_enum" OWNER TO "postgres";


CREATE TYPE "public"."pricing_service_type_enum" AS ENUM (
    'ride',
    'local_parcel',
    'intercity_parcel',
    'intercity_ride',
    'ride_sharing'
);


ALTER TYPE "public"."pricing_service_type_enum" OWNER TO "postgres";


CREATE TYPE "public"."review_tag" AS ENUM (
    'clean_vehicle',
    'polite_behavior',
    'safe_driving',
    'on_time',
    'dirty_vehicle',
    'rude_behavior',
    'unsafe_driving',
    'late_arrival',
    'other'
);


ALTER TYPE "public"."review_tag" OWNER TO "postgres";


CREATE TYPE "public"."rider_account_status_enum" AS ENUM (
    'online',
    'offline',
    'busy',
    'blocked'
);


ALTER TYPE "public"."rider_account_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."rider_withdrawal_status_enum" AS ENUM (
    'pending',
    'processing',
    'success',
    'failed'
);


ALTER TYPE "public"."rider_withdrawal_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."subscription_status_enum" AS ENUM (
    'active',
    'expired',
    'cancelled',
    'pending'
);


ALTER TYPE "public"."subscription_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."travel_plan_status_enum" AS ENUM (
    'active',
    'completed',
    'cancelled',
    'fully_booked',
    'expired'
);


ALTER TYPE "public"."travel_plan_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."vehicle_type_enum" AS ENUM (
    'bike',
    'auto',
    'cab'
);


ALTER TYPE "public"."vehicle_type_enum" OWNER TO "postgres";


CREATE TYPE "public"."weight_category_enum" AS ENUM (
    '0_5',
    '6_15',
    '16_25',
    '26_50'
);


ALTER TYPE "public"."weight_category_enum" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."accept_intercity_offer"("p_request_id" "uuid", "p_actor_type" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_request RECORD;
    v_metadata jsonb;
BEGIN
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found';
    END IF;
    
    v_metadata := COALESCE(v_request.metadata, '{}'::jsonb);
    
    IF p_actor_type = 'sender' THEN
        v_metadata := v_metadata || '{"sender_agreed": true}'::jsonb;
    ELSIF p_actor_type = 'traveller' THEN
        v_metadata := v_metadata || '{"traveller_agreed": true}'::jsonb;
    ELSE
        RAISE EXCEPTION 'Invalid actor type: %', p_actor_type;
    END IF;
    
    IF COALESCE((v_metadata->>'sender_agreed')::boolean, false) = true 
       AND COALESCE((v_metadata->>'traveller_agreed')::boolean, false) = true THEN
        UPDATE public.intercity_requests
        SET metadata = v_metadata,
            status = 'fare_agreed',
            updated_at = now()
        WHERE id = p_request_id;
    ELSE
        UPDATE public.intercity_requests
        SET metadata = v_metadata,
            status = 'discussion_started',
            updated_at = now()
        WHERE id = p_request_id;
    END IF;
    
    SELECT json_build_object(
        'id', id,
        'status', status,
        'metadata', metadata,
        'proposed_fare', proposed_fare
    )::jsonb INTO v_metadata
    FROM public.intercity_requests
    WHERE id = p_request_id;
    
    RETURN v_metadata;
END;
$$;


ALTER FUNCTION "public"."accept_intercity_offer"("p_request_id" "uuid", "p_actor_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."accept_intercity_request"("p_request_id" "uuid", "p_rider_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
    -- FIX: sender_id must be the rider's auth user id (order_chat_messages_sender_id_fkey
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
$$;


ALTER FUNCTION "public"."accept_intercity_request"("p_request_id" "uuid", "p_rider_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_nearby_searching_orders_to_rider"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_order RECORD;
    v_radius_km double precision;
    v_stale_sec integer;
    v_dist_km double precision;
    v_timeout_sec integer;
    v_existing_id uuid;
    v_existing_status text;
BEGIN
    -- 1. If coordinates are missing, bypass
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    -- 2. Fetch active dispatch config values
    SELECT 
        COALESCE(round_2_radius_km, 5.0),
        COALESCE(rider_location_stale_sec, 60),
        COALESCE(rider_response_timeout_sec, 15)
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
    v_timeout_sec := COALESCE(v_timeout_sec, 15);

    -- 3. Find all orders that are currently in 'searching' status (strictly excluding rider's own orders)
    FOR v_order IN (
        SELECT o.id, o.pickup_lat, o.pickup_lng, o.vehicle_type::text AS vehicle_type, o.order_type, o.rider_earning
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

        -- If the rider is within the max radius, and matches the vehicle type filter
        IF v_dist_km <= v_radius_km AND (v_order.order_type != 'ride' OR EXISTS (
            SELECT 1 FROM public.rider_kyc rk 
            WHERE rk.user_id = NEW.user_id 
              AND rk.vehicle_type::text = v_order.vehicle_type
        )) THEN
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
                        expires_at
                    ) VALUES (
                        v_order.id,
                        NEW.id,
                        1,
                        'sent',
                        v_dist_km,
                        v_order.rider_earning,
                        NOW(),
                        NOW() + (v_timeout_sec || ' seconds')::interval
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
                    -- Check if they just went online (OLD.account_status was not 'online')
                    -- OR if they have been online and the assignment has been expired for at least 1 minute (60 seconds)
                    IF OLD.account_status IS DISTINCT FROM 'online' OR EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND responded_at <= NOW() - INTERVAL '1 minute'
                    ) THEN
                        -- Update existing assignment back to 'sent' with fresh expiry
                        UPDATE public.rider_assignments
                        SET 
                            assignment_status = 'sent',
                            distance_km = v_dist_km,
                            sent_at = NOW(),
                            expires_at = NOW() + (v_timeout_sec || ' seconds')::interval,
                            updated_at = NOW(),
                            responded_at = NULL
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
                -- Safely ignore duplicate key constraint violations (e.g. concurrent inserts)
                NULL;
            END;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."assign_nearby_searching_orders_to_rider"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."audit_rider_wallets"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."audit_rider_wallets"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_order"("p_order_id" "uuid", "p_cancelled_by" "text", "p_cancel_reason" "text" DEFAULT NULL::"text", "p_rider_id" "uuid" DEFAULT NULL::"uuid", "p_user_id" "uuid" DEFAULT NULL::"uuid", "p_admin_id" "uuid" DEFAULT NULL::"uuid") RETURNS json
    LANGUAGE "plpgsql"
    AS $$

DECLARE

    v_order RECORD;

BEGIN



    -- =====================================================
    -- LOCK ORDER
    -- =====================================================

    SELECT *

    INTO v_order

    FROM orders

    WHERE id = p_order_id

    FOR UPDATE;



    IF v_order IS NULL THEN

        RETURN json_build_object(

            'success', false,

            'message', 'Order not found'

        );

    END IF;



    -- =====================================================
    -- COMPLETED CHECK
    -- =====================================================

    IF v_order.order_status IN (

        'completed',

        'delivered',

        'cancelled'

    ) THEN

        RETURN json_build_object(

            'success', false,

            'message', 'Order already closed'

        );

    END IF;



    -- =====================================================
    -- RIDER CANCEL AFTER ACCEPT
    -- =====================================================
    --
    -- VERY IMPORTANT MARKETPLACE FLOW
    --
    -- accepted
    -- → rider cancels
    -- → back to searching
    --
    -- =====================================================

    IF

        p_cancelled_by = 'rider'

        AND

        v_order.order_status IN (

            'accepted',

            'rider_arrived'

        )

    THEN



        -- ================================================
        -- RELEASE RIDER
        -- ================================================

        UPDATE riders

        SET

            account_status = 'online',

            updated_at = now()

        WHERE id = v_order.rider_id;



        -- ================================================
        -- RESET ORDER
        -- ================================================

        UPDATE orders

        SET

            rider_id = NULL,

            order_status = 'searching',

            accepted_at = NULL,

            updated_at = now()

        WHERE id = p_order_id;



        -- ================================================
        -- STATUS HISTORY
        -- ================================================

        INSERT INTO order_status_history (

            order_id,

            previous_status,

            new_status,

            changed_by,

            changed_by_rider_id,

            notes,

            metadata

        )

        VALUES (

            p_order_id,

            v_order.order_status,

            'searching',

            'rider',

            p_rider_id,

            'Rider cancelled order, dispatch restarted',

            json_build_object(

                'cancel_reason',

                p_cancel_reason

            )

        );



        RETURN json_build_object(

            'success', true,

            'message', 'Order returned to searching state'

        );

    END IF;



    -- =====================================================
    -- NORMAL CANCELLATION
    -- =====================================================

    UPDATE orders

    SET

        order_status = 'cancelled',

        cancelled_by = p_cancelled_by,

        cancel_reason = p_cancel_reason,

        cancelled_at = now(),

        updated_at = now()

    WHERE id = p_order_id;



    -- =====================================================
    -- RELEASE RIDER IF EXISTS
    -- =====================================================

    IF v_order.rider_id IS NOT NULL THEN

        UPDATE riders

        SET

            account_status = 'online',

            updated_at = now()

        WHERE id = v_order.rider_id;

    END IF;



    -- =====================================================
    -- EXPIRE ASSIGNMENTS
    -- =====================================================

    UPDATE order_assignment_logs

    SET

        assignment_status = 'cancelled',

        responded_at = now()

    WHERE

        order_id = p_order_id

        AND assignment_status IN (

            'sent',

            'accepted'

        );



    -- =====================================================
    -- STATUS HISTORY
    -- =====================================================

    INSERT INTO order_status_history (

        order_id,

        previous_status,

        new_status,

        changed_by,

        changed_by_user_id,

        changed_by_rider_id,

        changed_by_admin_id,

        notes,

        metadata

    )

    VALUES (

        p_order_id,

        v_order.order_status,

        'cancelled',

        p_cancelled_by,

        p_user_id,

        p_rider_id,

        p_admin_id,

        'Order cancelled',

        json_build_object(

            'cancel_reason',

            p_cancel_reason

        )

    );



    RETURN json_build_object(

        'success', true,

        'message', 'Order cancelled successfully'

    );

END;

$$;


ALTER FUNCTION "public"."cancel_order"("p_order_id" "uuid", "p_cancelled_by" "text", "p_cancel_reason" "text", "p_rider_id" "uuid", "p_user_id" "uuid", "p_admin_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_dormant_riders"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
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


ALTER FUNCTION "public"."check_dormant_riders"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_is_order_candidate_rider"("p_order_id" "uuid", "p_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.rider_assignments ra
        INNER JOIN public.riders r ON r.id = ra.rider_id
        WHERE ra.order_id = p_order_id AND r.user_id = p_user_id
    );
$$;


ALTER FUNCTION "public"."check_is_order_candidate_rider"("p_order_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_is_order_passenger"("p_order_id" "uuid", "p_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.orders
        WHERE id = p_order_id AND user_id = p_user_id
    );
$$;


ALTER FUNCTION "public"."check_is_order_passenger"("p_order_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_payout_update_limit"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."check_payout_update_limit"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_travel_plan_active_bookings"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.intercity_requests
        WHERE route_id = OLD.id
          AND status IN ('confirmed', 'paid')
    ) THEN
        RAISE EXCEPTION 'Cannot delete travel plan while active bookings exist. Mark it inactive instead.';
    END IF;
    RETURN OLD;
END;
$$;


ALTER FUNCTION "public"."check_travel_plan_active_bookings"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_withdrawal"("p_withdrawal_id" "uuid", "p_cashfree_ref_id" "text", "p_status" "text", "p_response" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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

    -- First get the rider_id (simple read, no lock to determine which rider to lock)
    SELECT rider_id INTO v_rider_id
    FROM public.rider_withdrawals
    WHERE id = p_withdrawal_id;

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Withdrawal record not found');
    END IF;

    -- Lock rider first (consistent ordering with initiate_withdrawal to prevent deadlocks)
    PERFORM id FROM public.riders WHERE id = v_rider_id FOR UPDATE;

    -- Now lock the withdrawal record
    SELECT rider_id, amount, status INTO v_rider_id, v_amount, v_current_status
    FROM public.rider_withdrawals
    WHERE id = p_withdrawal_id
    FOR UPDATE;

    -- Re-check if the withdrawal still exists after acquiring locks
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

    -- Rider is already locked above; refund rider's wallet balance if status resolved to failed
    IF v_new_status = 'failed'::public.rider_withdrawal_status_enum THEN
        UPDATE public.riders
        SET wallet_balance = wallet_balance + v_amount
        WHERE id = v_rider_id;
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$;


ALTER FUNCTION "public"."complete_withdrawal"("p_withdrawal_id" "uuid", "p_cashfree_ref_id" "text", "p_status" "text", "p_response" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."confirm_intercity_booking"("p_request_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_request RECORD;
    v_active_bookings INT;
    v_max_bookings INT;
    v_plan_pickup TEXT;
    v_plan_dest TEXT;
    v_plan_vehicle public.vehicle_type_enum;
    v_plan_date TIMESTAMPTZ;
    v_plan_weight NUMERIC;
    v_order_weight NUMERIC;
    v_order_type TEXT;
    v_pickup_city TEXT;
    v_dest_city TEXT;
    v_metadata jsonb;
BEGIN
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found';
    END IF;
    
    IF v_request.status = 'confirmed' THEN
        RETURN json_build_object('success', true, 'status', 'confirmed')::jsonb;
    END IF;
    
    IF COALESCE((v_request.metadata->>'sender_agreed')::boolean, false) IS NOT TRUE 
       OR COALESCE((v_request.metadata->>'traveller_agreed')::boolean, false) IS NOT TRUE THEN
        RAISE EXCEPTION 'Cannot confirm booking before both parties agree on the fare.';
    END IF;
    
    SELECT max_bookings, pickup_city, destination_city, vehicle_type, travel_date, max_weight_kg 
    INTO v_max_bookings, v_plan_pickup, v_plan_dest, v_plan_vehicle, v_plan_date, v_plan_weight
    FROM public.rider_travel_plans
    WHERE id = v_request.route_id
    FOR UPDATE;
    
    SELECT COUNT(*) INTO v_active_bookings
    FROM public.intercity_requests
    WHERE route_id = v_request.route_id
      AND status IN ('confirmed', 'paid')
      AND id IS DISTINCT FROM p_request_id;
      
    IF v_active_bookings >= v_max_bookings THEN
        RAISE EXCEPTION 'This travel plan is fully booked. (Current: %, Max limit: %)', v_active_bookings, v_max_bookings;
    END IF;
    
    SELECT actual_weight_kg, order_type, pickup_city, destination_city
    INTO v_order_weight, v_order_type, v_pickup_city, v_dest_city
    FROM public.orders
    WHERE id = v_request.parcel_id;
    
    v_metadata := COALESCE(v_request.metadata, '{}'::jsonb) || jsonb_build_object(
        'travel_plan_snapshot', jsonb_build_object(
            'pickup_city', v_plan_pickup,
            'destination_city', v_plan_dest,
            'vehicle_type', v_plan_vehicle,
            'travel_date', v_plan_date,
            'max_weight_kg', v_plan_weight
        ),
        'booking_snapshot', jsonb_build_object(
            'agreed_fare', v_request.proposed_fare,
            'booking_type', v_request.booking_type,
            'pickup_city', v_pickup_city,
            'destination_city', v_dest_city,
            'weight_kg', v_order_weight
        )
    );
    
    UPDATE public.intercity_requests
    SET status = 'confirmed',
        metadata = v_metadata,
        updated_at = now()
    WHERE id = p_request_id;
    
    UPDATE public.orders
    SET order_status = 'accepted'::public.order_status_enum,
        rider_id = v_request.traveller_id,
        final_fare = v_request.proposed_fare,
        current_fare = v_request.proposed_fare,
        updated_at = now()
    WHERE id = v_request.parcel_id;
    
    RETURN json_build_object('success', true, 'status', 'confirmed')::jsonb;
END;
$$;


ALTER FUNCTION "public"."confirm_intercity_booking"("p_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_rider_profile_on_activation"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$

BEGIN

  -- =====================================
  -- PREVENT DUPLICATES
  -- =====================================

  IF NOT EXISTS (

    SELECT 1

    FROM riders

    WHERE user_id = NEW.user_id

  ) THEN

    INSERT INTO riders (

      kyc_id,

      user_id,

      account_status,

      is_verified

    )

    VALUES (

      NEW.id,

      NEW.user_id,

      'offline',

      true
    );

  END IF;

  RETURN NEW;

END;

$$;


ALTER FUNCTION "public"."create_rider_profile_on_activation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."deliver_push_notification_http_fnc"("p_user_id" "uuid", "p_title" "text", "p_body" "text", "p_data" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    PERFORM net.http_post(
        url := 'https://yvwpchffctiagevpqgwy.supabase.co/functions/v1/send-push-notification',
        headers := '{"Content-Type": "application/json", "Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl2d3BjaGZmY3RpYWdldnBxZ3d5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgxMzQ3NzUsImV4cCI6MjA5MzcxMDc3NX0.y4Shv58UDlTF2BNGsVVy3fWR3O7M2MzjQmHabJAFdCA"}'::jsonb,
        body := jsonb_build_object(
            'user_id', p_user_id,
            'title', p_title,
            'body', p_body,
            'data', p_data
        ),
        timeout_milliseconds := 5000
    );
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed to send push notification HTTP call: %', SQLERRM;
END;
$$;


ALTER FUNCTION "public"."deliver_push_notification_http_fnc"("p_user_id" "uuid", "p_title" "text", "p_body" "text", "p_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expire_stale_intercity_requests"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Stale negotiation expiration (24h)
    UPDATE public.intercity_requests
    SET status = 'expired',
        expiry_reason = 'negotiation_timeout',
        updated_at = now()
    WHERE status IN ('request_sent', 'discussion_started', 'fare_agreed')
      AND expires_at < now();

    -- Travel plan auto-expiry
    UPDATE public.rider_travel_plans
    SET status = 'expired'::public.travel_plan_status_enum
    WHERE travel_date < now()
      AND status = 'active'::public.travel_plan_status_enum;
END;
$$;


ALTER FUNCTION "public"."expire_stale_intercity_requests"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fail_withdrawal"("p_withdrawal_id" "uuid", "p_error_response" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_rider_id uuid;
    v_amount numeric;
    v_status public.rider_withdrawal_status_enum;
BEGIN
    -- First get the rider_id (simple read, no lock to determine which rider to lock)
    SELECT rider_id INTO v_rider_id
    FROM public.rider_withdrawals
    WHERE id = p_withdrawal_id;

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Withdrawal record not found');
    END IF;

    -- Lock rider first (consistent ordering with initiate_withdrawal to prevent deadlocks)
    PERFORM id FROM public.riders WHERE id = v_rider_id FOR UPDATE;

    -- Now lock the withdrawal record
    SELECT rider_id, amount, status INTO v_rider_id, v_amount, v_status
    FROM public.rider_withdrawals
    WHERE id = p_withdrawal_id
    FOR UPDATE;

    -- Re-check if the withdrawal still exists after acquiring locks
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

    -- Rider is already locked above; refund rider's wallet balance
    UPDATE public.riders
    SET wallet_balance = wallet_balance + v_amount
    WHERE id = v_rider_id;

    RETURN jsonb_build_object('success', true);
END;
$$;


ALTER FUNCTION "public"."fail_withdrawal"("p_withdrawal_id" "uuid", "p_error_response" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."find_nearby_riders"("p_order_id" "uuid", "p_pickup_lat" double precision, "p_pickup_lng" double precision, "p_radius_km" double precision, "p_limit" integer) RETURNS TABLE("rider_id" "uuid", "user_id" "uuid", "full_name" "text", "vehicle_type" "text", "vehicle_number" "text", "current_lat" double precision, "current_lng" double precision, "distance_km" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_order_type text;
    v_vehicle_type text;
    v_stale_sec integer;
    v_creator_user_id uuid;
BEGIN
    -- Fetch order creator user_id and order details
    SELECT
        o.order_type,
        o.vehicle_type,
        o.user_id
    INTO
        v_order_type,
        v_vehicle_type,
        v_creator_user_id
    FROM orders o
    WHERE o.id = p_order_id;

    -- Fetch stale timeout from active dispatch config, fallback to 60 seconds
    SELECT COALESCE(rider_location_stale_sec, 60)
    INTO v_stale_sec
    FROM dispatch_config
    WHERE is_active = true
    LIMIT 1;

    RETURN QUERY
    SELECT
        r.id AS rider_id,
        r.user_id,
        rk.full_name,
        rk.vehicle_type::text AS vehicle_type,
        rk.vehicle_number,
        r.current_lat,
        r.current_lng,
        ROUND(
            (
                6371 * acos(
                    LEAST(GREATEST(
                        cos(radians(p_pickup_lat))
                        * cos(radians(r.current_lat))
                        * cos(
                            radians(r.current_lng)
                            - radians(p_pickup_lng)
                        )
                        + sin(radians(p_pickup_lat))
                        * sin(radians(r.current_lat))
                    , -1.0), 1.0)
                )
            )::numeric,
            2
        ) AS distance_km
    FROM riders r
    INNER JOIN rider_kyc rk
        ON rk.user_id = r.user_id
    WHERE
        r.account_status = 'online'
        AND r.current_lat IS NOT NULL
        AND r.current_lng IS NOT NULL
        -- Enforce strict creator user exclusion constraint
        AND r.user_id != v_creator_user_id
        -- Relaxed KYC / Activation checks for simulator and testing flexibility
        AND (rk.kyc_status::text IN ('approved', 'pending', 'under_review', 'resubmitted') OR rk.kyc_status IS NULL)
        AND (rk.activation_status::text IN ('active', 'pending', 'inactive') OR rk.activation_status IS NULL)
        -- Location freshness check (stale limit config, but fallback to 24 hours or null to support simulator testing)
        AND (
            r.last_location_updated_at >= (NOW() - (v_stale_sec || ' seconds')::interval)
            OR
            r.last_location_updated_at >= (NOW() - INTERVAL '24 hours')
            OR
            r.last_location_updated_at IS NULL
        )
        -- Vehicle filter
        AND (
            v_order_type != 'ride'
            OR
            rk.vehicle_type::text = v_vehicle_type
        )
        -- No active orders filter
        AND NOT EXISTS (
            SELECT 1
            FROM orders o
            WHERE
                o.rider_id = r.id
                AND o.order_status IN (
                    'accepted',
                    'rider_arrived',
                    'picked_up',
                    'ongoing'
                )
        )
        -- Search radius filter
        AND (
            6371 * acos(
                LEAST(GREATEST(
                    cos(radians(p_pickup_lat))
                    * cos(radians(r.current_lat))
                    * cos(
                        radians(r.current_lng)
                        - radians(p_pickup_lng)
                    )
                    + sin(radians(p_pickup_lat))
                    * sin(radians(r.current_lat))
                , -1.0), 1.0)
            )
        ) <= p_radius_km
    ORDER BY distance_km ASC
    LIMIT p_limit;
END;
$$;


ALTER FUNCTION "public"."find_nearby_riders"("p_order_id" "uuid", "p_pickup_lat" double precision, "p_pickup_lng" double precision, "p_radius_km" double precision, "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_police_reference_code"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_date text;
    v_random_sos text;
    v_random_sup text;
    v_code_sos text;
    v_code_sup text;
    v_exists boolean;
BEGIN
    v_date := to_char(NOW(), 'YYYYMMDD');
    
    -- Generate Police Reference Code (SOS-WDP-YYYYMMDD-XXXXXX)
    LOOP
        v_random_sos := upper(substring(md5(random()::text) from 1 for 6));
        v_code_sos := 'SOS-WDP-' || v_date || '-' || v_random_sos;
        
        SELECT EXISTS(SELECT 1 FROM public.police_sos_logs WHERE police_reference_code = v_code_sos) INTO v_exists;
        IF NOT v_exists THEN
            NEW.police_reference_code := v_code_sos;
            EXIT;
        END IF;
    END LOOP;
    
    -- Generate Support Ticket Code (SUP-YYYYMMDD-XXXXXX)
    LOOP
        v_random_sup := upper(substring(md5(random()::text) from 1 for 6));
        v_code_sup := 'SUP-' || v_date || '-' || v_random_sup;
        
        SELECT EXISTS(SELECT 1 FROM public.police_sos_logs WHERE support_ticket_code = v_code_sup) INTO v_exists;
        IF NOT v_exists THEN
            NEW.support_ticket_code := v_code_sup;
            EXIT;
        END IF;
    END LOOP;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."generate_police_reference_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_random_alphanumeric"("p_length" integer) RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_chars text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    v_result text := '';
    i integer;
BEGIN
    FOR i IN 1..p_length LOOP
        v_result := v_result || substr(v_chars, floor(random() * length(v_chars) + 1)::integer, 1);
    END LOOP;
    RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."generate_random_alphanumeric"("p_length" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_rider_beneficiary_id"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.beneficiary_id IS NULL THEN
        NEW.beneficiary_id :=
            'WDR' || LPAD(NEXTVAL('public.rider_beneficiary_seq')::TEXT, 6, '0');
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."generate_rider_beneficiary_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_unique_order_code"("p_order_type" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_prefix text;
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    v_prefix := public.get_order_code_prefix(p_order_type);
    LOOP
        v_attempts := v_attempts + 1;
        v_code := v_prefix || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.orders WHERE order_code = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique order_code after 100 attempts';
        END IF;
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."generate_unique_order_code"("p_order_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_unique_payment_code"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    LOOP
        v_attempts := v_attempts + 1;
        v_code := 'WDTX' || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.payments WHERE payment_code = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique payment_code after 100 attempts';
        END IF;
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."generate_unique_payment_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_unique_plan_code"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    LOOP
        v_attempts := v_attempts + 1;
        v_code := 'WDTP' || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.rider_travel_plans WHERE plan_code = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique plan_code after 100 attempts';
        END IF;
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."generate_unique_plan_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_unique_transfer_id"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    LOOP
        v_attempts := v_attempts + 1;
        v_code := 'WDPY' || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.rider_withdrawals WHERE transfer_id = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique transfer_id after 100 attempts';
        END IF;
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."generate_unique_transfer_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_unique_user_code"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    LOOP
        v_attempts := v_attempts + 1;
        v_code := 'WDU' || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.users WHERE user_code = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique user_code after 100 attempts';
        END IF;
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."generate_unique_user_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_order_code_prefix"("p_order_type" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
BEGIN
    RETURN CASE p_order_type
        WHEN 'ride' THEN 'WDR'
        WHEN 'intercity_ride' THEN 'WDIR'
        WHEN 'local_parcel' THEN 'WDP'
        WHEN 'intercity_parcel' THEN 'WDIP'
        WHEN 'ride_sharing' THEN 'WDS'
        WHEN 'food_delivery' THEN 'WDF'
        WHEN 'grocery_delivery' THEN 'WDG'
        WHEN 'batch_delivery' THEN 'WDB'
        ELSE 'WD'
    END;
END;
$$;


ALTER FUNCTION "public"."get_order_code_prefix"("p_order_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_rider_reliability_stats"("p_rider_id" "uuid") RETURNS TABLE("reliability_score" integer, "rating" numeric, "completion_rate" numeric, "on_time_rate" numeric, "total_completed" bigint, "total_cancelled" bigint, "experience_score" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."get_rider_reliability_stats"("p_rider_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_order_activity_tracking"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."handle_order_activity_tracking"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_promo_usage_changes"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.promo_codes
    SET uses_count = uses_count + 1
    WHERE id = NEW.promo_code_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.promo_codes
    SET uses_count = GREATEST(0, uses_count - 1)
    WHERE id = OLD.promo_code_id;
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."handle_promo_usage_changes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_rider_status_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."handle_rider_status_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."initiate_withdrawal"("p_amount" numeric, "p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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

    -- 5. Generate unique transfer_id
    v_transfer_id := 'WDT' || REPLACE(gen_random_uuid()::text, '-', '');

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
$$;


ALTER FUNCTION "public"."initiate_withdrawal"("p_amount" numeric, "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_rider_withdrawal_event"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."log_rider_withdrawal_event"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_intercity_request_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."on_intercity_request_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_new_chat_message"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."on_new_chat_message"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_notification_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."on_notification_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_order_status_update"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."on_order_status_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_rider_assignment_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."on_rider_assignment_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_rider_review_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."on_rider_review_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_rider_wallet_balance_update"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."on_rider_wallet_balance_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_wallet_transaction_modifications"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RAISE EXCEPTION 'Immutable Ledger Error: Wallet transactions cannot be updated or deleted.';
END;
$$;


ALTER FUNCTION "public"."prevent_wallet_transaction_modifications"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_order"("p_order_id" "uuid", "p_rider_id" "uuid", "p_rejection_reason" "text" DEFAULT NULL::"text") RETURNS json
    LANGUAGE "plpgsql"
    AS $$

DECLARE

    v_order RECORD;

BEGIN



    -- =====================================================
    -- FETCH ORDER
    -- =====================================================

    SELECT *

    INTO v_order

    FROM orders

    WHERE id = p_order_id;



    IF v_order IS NULL THEN

        RETURN json_build_object(

            'success', false,

            'message', 'Order not found'

        );

    END IF;



    -- =====================================================
    -- VALIDATE STATUS
    -- =====================================================

    IF v_order.order_status NOT IN (

        'created',

        'searching'

    ) THEN

        RETURN json_build_object(

            'success', false,

            'message', 'Order no longer available'

        );

    END IF;



    -- =====================================================
    -- UPDATE ASSIGNMENT LOG
    -- =====================================================

    UPDATE order_assignment_logs

    SET

        assignment_status = 'rejected',

        rejection_reason = p_rejection_reason,

        responded_at = now()

    WHERE

        order_id = p_order_id

        AND rider_id = p_rider_id

        AND assignment_status = 'sent';



    -- =====================================================
    -- INSERT STATUS HISTORY
    -- =====================================================

    INSERT INTO order_status_history (

        order_id,

        previous_status,

        new_status,

        changed_by,

        changed_by_rider_id,

        notes,

        metadata

    )

    VALUES (

        p_order_id,

        v_order.order_status,

        v_order.order_status,

        'rider',

        p_rider_id,

        'Rider rejected assignment',

        json_build_object(

            'rejection_reason',

            p_rejection_reason

        )

    );



    RETURN json_build_object(

        'success', true,

        'message', 'Order rejected successfully'

    );

END;

$$;


ALTER FUNCTION "public"."reject_order"("p_order_id" "uuid", "p_rider_id" "uuid", "p_rejection_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."send_admin_push_notification"("p_recipient_type" "text", "p_city" "text", "p_title" "text", "p_body" "text", "p_data" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
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


ALTER FUNCTION "public"."send_admin_push_notification"("p_recipient_type" "text", "p_city" "text", "p_title" "text", "p_body" "text", "p_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."send_push_notification_fnc"("p_user_id" "uuid", "p_title" "text", "p_body" "text", "p_data" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    PERFORM net.http_post(
        url := 'https://yvwpchffctiagevpqgwy.supabase.co/functions/v1/send-push-notification',
        headers := '{"Content-Type": "application/json", "Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl2d3BjaGZmY3RpYWdldnBxZ3d5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgxMzQ3NzUsImV4cCI6MjA5MzcxMDc3NX0.y4Shv58UDlTF2BNGsVVy3fWR3O7M2MzjQmHabJAFdCA"}'::jsonb,
        body := jsonb_build_object(
            'user_id', p_user_id,
            'title', p_title,
            'body', p_body,
            'data', p_data
        ),
        timeout_milliseconds := 5000
    );
EXCEPTION WHEN OTHERS THEN
    -- Prevent trigger failure if pg_net has issues
    RAISE WARNING 'Failed to send push notification via pg_net: %', SQLERRM;
END;
$$;


ALTER FUNCTION "public"."send_push_notification_fnc"("p_user_id" "uuid", "p_title" "text", "p_body" "text", "p_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_compliance_retention"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF (NEW.order_status IN ('completed', 'delivered') AND OLD.order_status NOT IN ('completed', 'delivered')) THEN
        NEW.compliance_retention_until := NOW() + INTERVAL '5 years';
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_compliance_retention"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_travel_plan_status_after"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_active_bookings INT;
    v_max_bookings INT;
    v_plan_status public.travel_plan_status_enum;
    v_route_id uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_route_id := OLD.route_id;
    ELSE
        v_route_id := NEW.route_id;
    END IF;

    IF v_route_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT max_bookings, status INTO v_max_bookings, v_plan_status
    FROM public.rider_travel_plans
    WHERE id = v_route_id
    FOR UPDATE;

    SELECT COUNT(*) INTO v_active_bookings
    FROM public.intercity_requests
    WHERE route_id = v_route_id
      AND status IN ('confirmed', 'paid');

    IF v_active_bookings >= v_max_bookings THEN
        IF v_plan_status = 'active'::public.travel_plan_status_enum THEN
            UPDATE public.rider_travel_plans 
            SET status = 'fully_booked'::public.travel_plan_status_enum 
            WHERE id = v_route_id;
        END IF;
    ELSE
        -- Revive only fully_booked plans. Never touch expired or cancelled plans.
        IF v_plan_status = 'fully_booked'::public.travel_plan_status_enum THEN
            UPDATE public.rider_travel_plans 
            SET status = 'active'::public.travel_plan_status_enum 
            WHERE id = v_route_id;
        END IF;
    END IF;

    RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."sync_travel_plan_status_after"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."timeout_assignment"("p_order_id" "uuid", "p_rider_id" "uuid") RETURNS json
    LANGUAGE "plpgsql"
    AS $$

BEGIN



    UPDATE order_assignment_logs

    SET

        assignment_status = 'timed_out',

        responded_at = now()

    WHERE

        order_id = p_order_id

        AND rider_id = p_rider_id

        AND assignment_status = 'sent';



    RETURN json_build_object(

        'success', true,

        'message', 'Assignment timed out'

    );

END;

$$;


ALTER FUNCTION "public"."timeout_assignment"("p_order_id" "uuid", "p_rider_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_orders_order_code"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.order_code IS NULL OR NEW.order_code = '' OR NEW.order_code LIKE 'WX%' THEN
        NEW.order_code := public.generate_unique_order_code(NEW.order_type::text);
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_orders_order_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_payments_payment_code"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.payment_code IS NULL OR NEW.payment_code = '' THEN
        NEW.payment_code := public.generate_unique_payment_code();
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_payments_payment_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_rider_withdrawals_transfer_id"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.transfer_id IS NULL OR NEW.transfer_id = '' OR NOT (NEW.transfer_id LIKE 'WDPY%') THEN
        NEW.transfer_id := public.generate_unique_transfer_id();
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_rider_withdrawals_transfer_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_travel_plans_plan_code"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.plan_code IS NULL OR NEW.plan_code = '' THEN
        NEW.plan_code := public.generate_unique_plan_code();
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_travel_plans_plan_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_users_user_code"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.user_code IS NULL OR NEW.user_code = '' THEN
        NEW.user_code := public.generate_unique_user_code();
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_users_user_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_rider_average_rating"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_rider_id UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_rider_id := OLD.rider_id;
  ELSE
    v_rider_id := NEW.rider_id;
  END IF;

  UPDATE public.riders
  SET rating = (
    SELECT CASE 
      WHEN COUNT(rating) > 0 THEN
        GREATEST(
          ROUND(
            (SUM(rating) + 25.0)::numeric / (COUNT(rating) + 5),
            2
          ),
          3.5
        )
      ELSE 5.0
    END
    FROM public.rider_reviews
    WHERE rider_id = v_rider_id
  )
  WHERE id = v_rider_id;
  
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."update_rider_average_rating"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_and_calculate_promo"("p_code" character varying, "p_order_value" numeric, "p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_promo record;
  v_used_count integer;
  v_discount numeric := 0.00;
BEGIN
  -- 1. Fetch promo details
  SELECT * INTO v_promo
  FROM public.promo_codes
  WHERE code = UPPER(p_code)
    AND is_active = true
    AND expires_at > now();

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

  -- 2. Verify global usage limit
  IF v_promo.max_uses IS NOT NULL AND v_promo.uses_count >= v_promo.max_uses THEN
    RETURN jsonb_build_object('success', false, 'message', 'Promo code usage limit has been reached');
  END IF;

  -- 3. Verify min order value
  IF p_order_value < v_promo.min_order_value THEN
    RETURN jsonb_build_object('success', false, 'message', 'Minimum order value of ₹' || v_promo.min_order_value::text || ' is required');
  END IF;

  -- 4. Verify single usage per user
  SELECT count(*) INTO v_used_count
  FROM public.user_promo_usages
  WHERE user_id = p_user_id AND promo_code_id = v_promo.id;

  IF v_used_count > 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'You have already used this promo code');
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
$$;


ALTER FUNCTION "public"."validate_and_calculate_promo"("p_code" character varying, "p_order_value" numeric, "p_user_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."admin_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admin_id" "uuid" NOT NULL,
    "action_type" "text" NOT NULL,
    "target_type" "text" NOT NULL,
    "target_id" "uuid" NOT NULL,
    "description" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "ip_address" "text",
    "user_agent" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."admin_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admins" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admin_code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "phone" "text" NOT NULL,
    "email" "text" NOT NULL,
    "password_hash" "text" NOT NULL,
    "role" "text" NOT NULL,
    "permissions" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "is_active" boolean DEFAULT true,
    "is_account_locked" boolean DEFAULT false,
    "last_login_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."admins" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dispatch_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "config_code" "text" NOT NULL,
    "round_1_radius_km" numeric DEFAULT 3 NOT NULL,
    "round_1_batch_size" integer DEFAULT 3 NOT NULL,
    "round_2_radius_km" numeric DEFAULT 6 NOT NULL,
    "round_2_batch_size" integer DEFAULT 5 NOT NULL,
    "round_3_radius_km" numeric DEFAULT 10 NOT NULL,
    "round_3_batch_size" integer DEFAULT 8 NOT NULL,
    "rider_response_timeout_sec" integer DEFAULT 25 NOT NULL,
    "max_search_duration_sec" integer DEFAULT 900 NOT NULL,
    "reject_cooldown_sec" integer DEFAULT 600 NOT NULL,
    "timeout_cooldown_sec" integer DEFAULT 120 NOT NULL,
    "rider_location_stale_sec" integer DEFAULT 30 NOT NULL,
    "max_active_orders_per_rider" integer DEFAULT 1 NOT NULL,
    "allow_round_3" boolean DEFAULT true,
    "allow_boosted_priority" boolean DEFAULT true,
    "is_active" boolean DEFAULT true,
    "updated_by_admin_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "round_2_trigger_if_no_riders_sec" integer DEFAULT 60,
    "round_2_trigger_after_sec" integer DEFAULT 300,
    "round_3_trigger_after_sec" integer DEFAULT 600
);


ALTER TABLE "public"."dispatch_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."distance_discounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "km_5_discount" numeric(5,2) DEFAULT 0 NOT NULL,
    "km_10_discount" numeric(5,2) DEFAULT 0 NOT NULL,
    "km_15_discount" numeric(5,2) DEFAULT 0 NOT NULL,
    "km_20_discount" numeric(5,2) DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "km_10_discount_range" CHECK ((("km_10_discount" >= (0)::numeric) AND ("km_10_discount" <= (100)::numeric))),
    CONSTRAINT "km_15_discount_range" CHECK ((("km_15_discount" >= (0)::numeric) AND ("km_15_discount" <= (100)::numeric))),
    CONSTRAINT "km_20_discount_range" CHECK ((("km_20_discount" >= (0)::numeric) AND ("km_20_discount" <= (100)::numeric))),
    CONSTRAINT "km_5_discount_range" CHECK ((("km_5_discount" >= (0)::numeric) AND ("km_5_discount" <= (100)::numeric)))
);


ALTER TABLE "public"."distance_discounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."intercity_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "parcel_id" "uuid" NOT NULL,
    "route_id" "uuid",
    "traveller_id" "uuid" NOT NULL,
    "sender_id" "uuid" NOT NULL,
    "initiated_by" "text" NOT NULL,
    "status" "text" DEFAULT 'request_sent'::"text" NOT NULL,
    "proposed_fare" numeric NOT NULL,
    "sender_confirmed" boolean DEFAULT false NOT NULL,
    "traveller_confirmed" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "booking_type" "text",
    "expires_at" timestamp with time zone DEFAULT ("now"() + '24:00:00'::interval),
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "expiry_reason" "text",
    CONSTRAINT "intercity_requests_booking_type_check" CHECK (("booking_type" = ANY (ARRAY['ride'::"text", 'parcel'::"text"]))),
    CONSTRAINT "intercity_requests_expiry_reason_check" CHECK (("expiry_reason" = ANY (ARRAY['negotiation_timeout'::"text", 'travel_date_passed'::"text", 'no_show'::"text"]))),
    CONSTRAINT "intercity_requests_initiated_by_check" CHECK (("initiated_by" = ANY (ARRAY['traveller'::"text", 'sender'::"text"]))),
    CONSTRAINT "intercity_requests_status_check" CHECK (("status" = ANY (ARRAY['request_sent'::"text", 'discussion_started'::"text", 'fare_agreed'::"text", 'confirmed'::"text", 'paid'::"text", 'expired'::"text", 'cancelled'::"text", 'rejected'::"text"])))
);

ALTER TABLE ONLY "public"."intercity_requests" REPLICA IDENTITY FULL;


ALTER TABLE "public"."intercity_requests" OWNER TO "postgres";


COMMENT ON COLUMN "public"."intercity_requests"."status" IS 'Negotiation and booking states:
- request_sent: Initial offer/request sent from rider/user.
- discussion_started: Discussion accepted, chat unlocked.
- fare_agreed: Mutual fare agreed (metadata: sender_agreed = true, traveller_agreed = true).
- confirmed: Booking locked (capacity reserved, snapshots taken, payment due timer set).
- paid: Payment completed (unlocks all media chat features, waiting for transit).
- expired: Expired due to timeout (payment timeout or negotiation timeout).
- cancelled: Cancelled by one of the parties before payment or journey.
- rejected: Booking request rejected.';



CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "notification_type" "text" NOT NULL,
    "reference_id" "uuid",
    "reference_type" "text",
    "is_read" boolean DEFAULT false NOT NULL,
    "push_sent" boolean DEFAULT false NOT NULL,
    "delivery_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "delivery_error" "text",
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "read_at" timestamp with time zone
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_assignment_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "rider_id" "uuid" NOT NULL,
    "assignment_status" "public"."intercity_assignment_status_enum" DEFAULT 'sent'::"public"."intercity_assignment_status_enum" NOT NULL,
    "assignment_round" integer DEFAULT 1,
    "rider_distance_km" numeric,
    "estimated_pickup_time_min" integer,
    "sent_at" timestamp with time zone DEFAULT "now"(),
    "viewed_at" timestamp with time zone,
    "responded_at" timestamp with time zone,
    "rejection_reason" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."order_assignment_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_chat_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "rider_id" "uuid",
    "sender_id" "uuid" NOT NULL,
    "sender_type" "text" NOT NULL,
    "message" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "is_support" boolean DEFAULT false,
    "user_id" "uuid",
    "message_type" "text" DEFAULT 'text'::"text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    CONSTRAINT "order_chat_messages_message_type_check" CHECK (("message_type" = ANY (ARRAY['text'::"text", 'offer'::"text", 'image'::"text", 'location'::"text"]))),
    CONSTRAINT "order_chat_messages_sender_type_check" CHECK (("sender_type" = ANY (ARRAY['user'::"text", 'rider'::"text", 'admin'::"text", 'support'::"text"])))
);

ALTER TABLE ONLY "public"."order_chat_messages" REPLICA IDENTITY FULL;


ALTER TABLE "public"."order_chat_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_declarations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "declaration_text" "text" NOT NULL,
    "accepted" boolean NOT NULL,
    "accepted_ip" "inet",
    "accepted_device_id" "text",
    "accepted_at" timestamp with time zone DEFAULT "now"(),
    "declaration_version" "text" DEFAULT '1.0'::"text",
    "accepted_device_ref" "text"
);


ALTER TABLE "public"."order_declarations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_parcel_photos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "rider_id" "uuid" NOT NULL,
    "photo_url" "text" NOT NULL,
    "latitude" numeric,
    "longitude" numeric,
    "captured_at" timestamp with time zone DEFAULT "now"(),
    "photo_type" "text" DEFAULT 'pickup'::"text" NOT NULL,
    "file_sha256" "text",
    CONSTRAINT "order_parcel_photos_photo_type_check" CHECK (("photo_type" = ANY (ARRAY['pickup'::"text", 'dropoff'::"text", 'damage'::"text", 'evidence'::"text", 'rider_selfie'::"text"])))
);


ALTER TABLE "public"."order_parcel_photos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_status_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "previous_status" "text",
    "new_status" "text" NOT NULL,
    "changed_by" "text" NOT NULL,
    "changed_by_user_id" "uuid",
    "changed_by_rider_id" "uuid",
    "changed_by_admin_id" "uuid",
    "notes" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."order_status_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_verifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "verification_type" "text" NOT NULL,
    "verification_status" "text" DEFAULT 'verified'::"text" NOT NULL,
    "photo_url" "text",
    "latitude" numeric,
    "longitude" numeric,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    CONSTRAINT "order_verifications_verification_status_check" CHECK (("verification_status" = ANY (ARRAY['verified'::"text", 'bypassed'::"text", 'pending_sync'::"text", 'failed'::"text"]))),
    CONSTRAINT "order_verifications_verification_type_check" CHECK (("verification_type" = ANY (ARRAY['pickup'::"text", 'dropoff'::"text", 'damage_report'::"text", 'signature'::"text"])))
);

ALTER TABLE ONLY "public"."order_verifications" REPLICA IDENTITY FULL;


ALTER TABLE "public"."order_verifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_code" "text" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "rider_id" "uuid",
    "order_type" "public"."order_type_enum" NOT NULL,
    "vehicle_type" "public"."vehicle_type_enum",
    "order_status" "public"."order_status_enum" DEFAULT 'created'::"public"."order_status_enum" NOT NULL,
    "pricing_config_id" "uuid",
    "distance_meters" integer NOT NULL,
    "distance_km" numeric NOT NULL,
    "estimated_duration_min" integer,
    "actual_duration_min" integer,
    "time_taken_seconds" integer,
    "pickup_address" "text" NOT NULL,
    "pickup_lat" double precision NOT NULL,
    "pickup_lng" double precision NOT NULL,
    "destination_address" "text" NOT NULL,
    "destination_lat" double precision NOT NULL,
    "destination_lng" double precision NOT NULL,
    "actual_fare" numeric NOT NULL,
    "current_fare" numeric NOT NULL,
    "final_fare" numeric,
    "base_fare" numeric DEFAULT 0,
    "distance_fare" numeric DEFAULT 0,
    "time_fare" numeric DEFAULT 0,
    "waiting_charge" numeric DEFAULT 0,
    "platform_fee" numeric DEFAULT 0,
    "gst_percentage" numeric DEFAULT 0,
    "gst_amount" numeric DEFAULT 0,
    "commission_percentage" numeric DEFAULT 0,
    "commission_amount" numeric DEFAULT 0,
    "rider_earning" numeric DEFAULT 0,
    "boost_amount" numeric DEFAULT 0,
    "subscription_commission_waived" boolean DEFAULT false,
    "pricing_snapshot" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "payment_mode" "public"."payment_mode_enum" NOT NULL,
    "payment_status" "public"."payment_status_enum" DEFAULT 'pending'::"public"."payment_status_enum" NOT NULL,
    "payment_id" "uuid",
    "pickup_otp" "text",
    "delivery_otp" "text",
    "search_expires_at" timestamp with time zone,
    "cancelled_by" "public"."cancelled_by_enum",
    "cancel_reason" "text",
    "parcel_type" "public"."parcel_type_enum",
    "receiver_name" "text",
    "receiver_phone" "text",
    "weight_category" "text",
    "actual_weight_kg" numeric,
    "parcel_images" "text"[],
    "special_instructions" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "accepted_at" timestamp with time zone,
    "rider_arrived_at" timestamp with time zone,
    "picked_up_at" timestamp with time zone,
    "rider_at_drop_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "cancelled_at" timestamp with time zone,
    "pickup_otp_attempts" integer DEFAULT 0,
    "delivery_otp_attempts" integer DEFAULT 0,
    "boost_company_earning" numeric DEFAULT 0,
    "boost_rider_earning" numeric DEFAULT 0,
    "boost_percentage" numeric DEFAULT 0,
    "dispatch_attempts" integer DEFAULT 0,
    "boost_round" integer DEFAULT 0,
    "current_search_radius_km" numeric DEFAULT 3,
    "last_dispatched_at" timestamp with time zone,
    "rider_rejections_count" integer DEFAULT 0,
    "redispatch_count" integer DEFAULT 0,
    "pickup_city" "text",
    "destination_city" "text",
    "travel_date" timestamp with time zone,
    "dispatch_state" "jsonb" DEFAULT '{}'::"jsonb",
    "created_ip_address" "inet",
    "created_lat" double precision,
    "created_lng" double precision,
    "sender_declaration_accepted" boolean DEFAULT false,
    "sender_declaration_accepted_at" timestamp with time zone,
    "pickup_verification_completed" boolean DEFAULT false,
    "pickup_verification_completed_at" timestamp with time zone,
    "compliance_flagged" boolean DEFAULT false,
    "compliance_notes" "text",
    "created_device_ref" "text",
    "created_device_record_id" "uuid",
    "created_device_model" "text",
    "created_device_brand" "text",
    "created_os_version" "text",
    "created_app_version" "text",
    "compliance_status" "text" DEFAULT 'pending'::"text",
    "compliance_score" integer DEFAULT 100,
    "compliance_retention_until" timestamp with time zone,
    "parcel_declared_value" numeric,
    "high_risk_parcel" boolean DEFAULT false,
    "dispatch_worker_running" boolean DEFAULT false,
    "dispatch_worker_started_at" timestamp with time zone,
    CONSTRAINT "check_intercity_parcel_weight" CHECK ((("order_type" <> 'intercity_parcel'::"public"."order_type_enum") OR (("actual_weight_kg" IS NOT NULL) AND ("actual_weight_kg" > (0)::numeric)))),
    CONSTRAINT "chk_actual_fare" CHECK (("actual_fare" >= (0)::numeric)),
    CONSTRAINT "chk_commission_percentage" CHECK ((("commission_percentage" >= (0)::numeric) AND ("commission_percentage" <= (100)::numeric))),
    CONSTRAINT "chk_current_fare" CHECK (("current_fare" >= (0)::numeric)),
    CONSTRAINT "chk_distance_km" CHECK (("distance_km" >= (0)::numeric)),
    CONSTRAINT "chk_distance_meters" CHECK (("distance_meters" >= 0)),
    CONSTRAINT "chk_final_fare" CHECK ((("final_fare" IS NULL) OR ("final_fare" >= (0)::numeric))),
    CONSTRAINT "chk_gst_percentage" CHECK ((("gst_percentage" >= (0)::numeric) AND ("gst_percentage" <= (100)::numeric))),
    CONSTRAINT "orders_compliance_status_check" CHECK (("compliance_status" = ANY (ARRAY['pending'::"text", 'verified'::"text", 'flagged'::"text", 'investigating'::"text"])))
);

ALTER TABLE ONLY "public"."orders" REPLICA IDENTITY FULL;


ALTER TABLE "public"."orders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."parcel_compliance_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "generated_for" "text",
    "generated_at" timestamp with time zone DEFAULT "now"(),
    "report_json" "jsonb" NOT NULL,
    "generated_by" "uuid"
);


ALTER TABLE "public"."parcel_compliance_reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."police_sos_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "rider_id" "uuid" NOT NULL,
    "opened_at" timestamp with time zone DEFAULT "now"(),
    "latitude" double precision,
    "longitude" double precision,
    "notes" "text",
    "police_reference_code" "text",
    "support_ticket_code" "text",
    "rider_lat" numeric,
    "rider_lng" numeric
);


ALTER TABLE "public"."police_sos_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" NOT NULL,
    "phone" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()),
    "full_name" "text",
    "email" "text",
    "profile_completed" boolean DEFAULT false,
    "onboarding_completed" boolean DEFAULT false,
    "preferred_mode" "public"."preferred_mode_enum" DEFAULT 'user'::"public"."preferred_mode_enum",
    "last_active_mode" "public"."preferred_mode_enum" DEFAULT 'user'::"public"."preferred_mode_enum",
    "role" "text" DEFAULT 'user'::"text",
    "pref_order_notifications" boolean DEFAULT true NOT NULL,
    "pref_chat_notifications" boolean DEFAULT true NOT NULL,
    "pref_rating_notifications" boolean DEFAULT true NOT NULL,
    "pref_admin_notifications" boolean DEFAULT true NOT NULL,
    "user_code" "text",
    "order_notification_mode" "text" DEFAULT 'important_only'::"text" NOT NULL,
    CONSTRAINT "users_order_notification_mode_check" CHECK (("order_notification_mode" = ANY (ARRAY['all'::"text", 'important_only'::"text", 'tracking_silent'::"text"])))
);

ALTER TABLE ONLY "public"."users" REPLICA IDENTITY FULL;


ALTER TABLE "public"."users" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."parcel_compliance_view" AS
 SELECT "o"."id" AS "order_id",
    "o"."order_code",
    "o"."order_type",
    "o"."order_status",
    "o"."compliance_status",
    "o"."compliance_score",
    "o"."compliance_flagged",
    "o"."compliance_notes",
    "o"."parcel_declared_value",
    "o"."high_risk_parcel",
    "o"."created_device_ref",
    "o"."created_device_record_id",
    "o"."created_device_model",
    "o"."created_device_brand",
    "o"."created_os_version",
    "o"."created_app_version",
    "o"."created_ip_address",
    "o"."created_lat",
    "o"."created_lng",
    "o"."pickup_verification_completed",
    "o"."pickup_verification_completed_at",
    "o"."compliance_retention_until",
    "u"."id" AS "sender_id",
    "u"."phone" AS "sender_phone",
    "od"."id" AS "declaration_id",
    "od"."declaration_version",
    "od"."declaration_text",
    "od"."accepted_at" AS "declaration_accepted_at",
    "od"."accepted_ip" AS "declaration_accepted_ip",
    "od"."accepted_device_ref" AS "declaration_accepted_device_ref",
    ( SELECT "count"(*) AS "count"
           FROM "public"."police_sos_logs" "psl"
          WHERE ("psl"."order_id" = "o"."id")) AS "sos_trigger_count",
    ( SELECT "count"(*) AS "count"
           FROM "public"."order_parcel_photos" "opp"
          WHERE ("opp"."order_id" = "o"."id")) AS "photo_count"
   FROM (("public"."orders" "o"
     LEFT JOIN "public"."users" "u" ON (("u"."id" = "o"."user_id")))
     LEFT JOIN "public"."order_declarations" "od" ON (("od"."order_id" = "o"."id")));


ALTER VIEW "public"."parcel_compliance_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."parcel_security_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "sender_user_id" "uuid" NOT NULL,
    "rider_id" "uuid",
    "event_type" "text" NOT NULL,
    "photo_url" "text",
    "latitude" double precision,
    "longitude" double precision,
    "ip_address" "inet",
    "device_id" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "event_latitude" numeric,
    "event_longitude" numeric
);


ALTER TABLE "public"."parcel_security_logs" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."parcel_security_timeline_view" AS
 SELECT "o"."id" AS "order_id",
    "o"."order_code",
    "psl"."id" AS "log_id",
    "psl"."event_type",
    "psl"."event_latitude",
    "psl"."event_longitude",
    "psl"."created_at" AS "event_timestamp",
    "psl"."device_id",
    "psl"."metadata"
   FROM ("public"."orders" "o"
     JOIN "public"."parcel_security_logs" "psl" ON (("psl"."order_id" = "o"."id")))
  ORDER BY "psl"."created_at";


ALTER VIEW "public"."parcel_security_timeline_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_code" "text" NOT NULL,
    "user_id" "uuid",
    "rider_id" "uuid",
    "payment_for" "public"."payment_for_enum" NOT NULL,
    "reference_id" "uuid",
    "amount" numeric NOT NULL,
    "gst_amount" numeric DEFAULT 0,
    "platform_fee" numeric DEFAULT 0,
    "discount_amount" numeric DEFAULT 0,
    "final_amount" numeric NOT NULL,
    "payment_method" "public"."payment_method_enum" NOT NULL,
    "payment_gateway" "text",
    "gateway_transaction_id" "text",
    "gateway_order_id" "text",
    "payment_status" "public"."payment_status_enum" DEFAULT 'pending'::"public"."payment_status_enum" NOT NULL,
    "paid_at" timestamp with time zone,
    "refunded_at" timestamp with time zone,
    "refund_reason" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "rider_earning" numeric DEFAULT 0,
    "company_earning" numeric DEFAULT 0,
    "webhook_received" boolean DEFAULT false,
    "webhook_payload" "jsonb",
    "failure_reason" "text",
    "settlement_reference" "text",
    "payment_source" "text"
);

ALTER TABLE ONLY "public"."payments" REPLICA IDENTITY FULL;


ALTER TABLE "public"."payments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pricing_change_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "pricing_config_id" "uuid" NOT NULL,
    "changed_by_admin_id" "uuid" NOT NULL,
    "old_data" "jsonb" NOT NULL,
    "new_data" "jsonb" NOT NULL,
    "change_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."pricing_change_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pricing_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "pricing_code" "text" NOT NULL,
    "service_type" "text" NOT NULL,
    "vehicle_type" "text",
    "city_tier" "text",
    "pricing_zone_id" "uuid",
    "commission_percentage" numeric NOT NULL,
    "gst_percentage" numeric DEFAULT 5 NOT NULL,
    "cancellation_fee" numeric DEFAULT 0,
    "waiting_charge_per_min" numeric DEFAULT 0,
    "subscription_commission_waiver" boolean DEFAULT true,
    "max_boost_percentage" numeric DEFAULT 50,
    "pricing_rules" "jsonb" NOT NULL,
    "future_rules" "jsonb" DEFAULT '{}'::"jsonb",
    "approval_status" "text" DEFAULT 'approved'::"text" NOT NULL,
    "approved_by_admin_id" "uuid",
    "approved_at" timestamp with time zone,
    "rejection_reason" "text",
    "is_active" boolean DEFAULT true,
    "effective_from" timestamp with time zone DEFAULT "now"(),
    "effective_until" timestamp with time zone,
    "created_by_admin_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "chk_boost_percentage" CHECK ((("max_boost_percentage" >= (0)::numeric) AND ("max_boost_percentage" <= (500)::numeric))),
    CONSTRAINT "chk_commission_percentage" CHECK ((("commission_percentage" >= (0)::numeric) AND ("commission_percentage" <= (100)::numeric))),
    CONSTRAINT "chk_gst_percentage" CHECK ((("gst_percentage" >= (0)::numeric) AND ("gst_percentage" <= (100)::numeric)))
);


ALTER TABLE "public"."pricing_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pricing_zones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "zone_code" "text" NOT NULL,
    "zone_name" "text" NOT NULL,
    "zone_type" "text" NOT NULL,
    "cities" "text"[] NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "center_lat" double precision,
    "center_lng" double precision,
    "radius_km" double precision,
    "zone_shape" "text" DEFAULT 'radius'::"text" NOT NULL,
    CONSTRAINT "chk_latitude" CHECK ((("center_lat" IS NULL) OR (("center_lat" >= ('-90'::integer)::double precision) AND ("center_lat" <= (90)::double precision)))),
    CONSTRAINT "chk_longitude" CHECK ((("center_lng" IS NULL) OR (("center_lng" >= ('-180'::integer)::double precision) AND ("center_lng" <= (180)::double precision)))),
    CONSTRAINT "chk_radius_positive" CHECK ((("radius_km" IS NULL) OR ("radius_km" > (0)::double precision)))
);


ALTER TABLE "public"."pricing_zones" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."promo_code_users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "promo_code_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."promo_code_users" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."promo_codes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" character varying NOT NULL,
    "discount_type" character varying NOT NULL,
    "discount_value" numeric(10,2) NOT NULL,
    "max_discount" numeric(10,2),
    "min_order_value" numeric(10,2) DEFAULT 0.00,
    "expires_at" timestamp with time zone NOT NULL,
    "max_uses" integer,
    "uses_count" integer DEFAULT 0,
    "is_active" boolean DEFAULT true,
    "audience_type" character varying DEFAULT 'everyone'::character varying NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "promo_codes_audience_type_check" CHECK ((("audience_type")::"text" = ANY ((ARRAY['everyone'::character varying, 'restricted'::character varying])::"text"[]))),
    CONSTRAINT "promo_codes_discount_type_check" CHECK ((("discount_type")::"text" = ANY ((ARRAY['percentage'::character varying, 'fixed_amount'::character varying])::"text"[])))
);


ALTER TABLE "public"."promo_codes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rider_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "rider_id" "uuid" NOT NULL,
    "assignment_round" integer DEFAULT 1 NOT NULL,
    "assignment_status" "public"."intercity_assignment_status_enum" DEFAULT 'sent'::"public"."intercity_assignment_status_enum" NOT NULL,
    "distance_km" numeric,
    "estimated_earnings" numeric,
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "viewed_at" timestamp with time zone,
    "responded_at" timestamp with time zone,
    "expires_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "last_seen_at" timestamp with time zone,
    "last_response_at" timestamp with time zone,
    "response_type" "text",
    "hidden_until" timestamp with time zone,
    "last_seen_fare" numeric
);

ALTER TABLE ONLY "public"."rider_assignments" REPLICA IDENTITY FULL;


ALTER TABLE "public"."rider_assignments" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."rider_beneficiary_seq"
    START WITH 100001
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."rider_beneficiary_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rider_daily_activity" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "rider_id" "uuid" NOT NULL,
    "date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "online_seconds" integer DEFAULT 0 NOT NULL,
    "active_seconds" integer DEFAULT 0 NOT NULL,
    "completed_orders" integer DEFAULT 0,
    "cancelled_orders" integer DEFAULT 0,
    "earnings" numeric DEFAULT 0.0,
    "last_online_toggle_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."rider_daily_activity" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rider_kyc" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "father_name" "text" NOT NULL,
    "vehicle_type" "public"."vehicle_type_enum" NOT NULL,
    "aadhaar_number" "text" NOT NULL,
    "pan_number" "text" NOT NULL,
    "driving_license_number" "text" NOT NULL,
    "vehicle_number" "text" NOT NULL,
    "rider_image" "text" NOT NULL,
    "aadhaar_front_image" "text" NOT NULL,
    "aadhaar_back_image" "text" NOT NULL,
    "pan_front_image" "text" NOT NULL,
    "pan_back_image" "text" NOT NULL,
    "license_front_image" "text" NOT NULL,
    "license_back_image" "text" NOT NULL,
    "vehicle_image" "text" NOT NULL,
    "kyc_status" "public"."kyc_status_enum" DEFAULT 'pending'::"public"."kyc_status_enum" NOT NULL,
    "activation_status" "public"."activation_status_enum" DEFAULT 'inactive'::"public"."activation_status_enum" NOT NULL,
    "handled_by_admin_id" "uuid",
    "approved_at" timestamp with time zone,
    "rejected_at" timestamp with time zone,
    "rejection_reason" "text",
    "activated_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "rejection_count" integer DEFAULT 0,
    "blocked_until" timestamp with time zone,
    "date_of_birth" "date" NOT NULL,
    "VECHILE_RC_front_image" "text",
    "VECHILE_RC_back_image" "text",
    CONSTRAINT "aadhaar_length_check" CHECK (("length"("aadhaar_number") = 12)),
    CONSTRAINT "pan_format_check" CHECK (("pan_number" ~ '^[A-Z]{5}[0-9]{4}[A-Z]{1}$'::"text")),
    CONSTRAINT "rider_minimum_age_check" CHECK (("date_of_birth" <= (CURRENT_DATE - '18 years'::interval)))
);

ALTER TABLE ONLY "public"."rider_kyc" REPLICA IDENTITY FULL;


ALTER TABLE "public"."rider_kyc" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rider_payout_accounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "rider_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "beneficiary_id" "text" NOT NULL,
    "beneficiary_name" "text" NOT NULL,
    "beneficiary_email" "text",
    "beneficiary_phone" "text" NOT NULL,
    "account_number" "text",
    "ifsc_code" "text",
    "upi_vpa" "text",
    "cashfree_beneficiary_added" boolean DEFAULT false,
    "cashfree_beneficiary_status" "public"."cashfree_beneficiary_status_enum",
    "cashfree_beneficiary_response" "jsonb",
    "is_primary" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "payout_method" "public"."payout_method_enum" NOT NULL,
    CONSTRAINT "account_number_length_check" CHECK ((("length"("account_number") >= 8) AND ("length"("account_number") <= 20))),
    CONSTRAINT "ifsc_format_check" CHECK (("ifsc_code" ~ '^[A-Z]{4}0[A-Z0-9]{6}$'::"text")),
    CONSTRAINT "payout_method_validation_check" CHECK (((("payout_method" = 'bank_account'::"public"."payout_method_enum") AND ("account_number" IS NOT NULL) AND ("ifsc_code" IS NOT NULL)) OR (("payout_method" = 'upi'::"public"."payout_method_enum") AND ("upi_vpa" IS NOT NULL))))
);


ALTER TABLE "public"."rider_payout_accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rider_payout_updates_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."rider_payout_updates_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."riders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "kyc_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "rating" numeric DEFAULT 5,
    "total_orders" integer DEFAULT 0,
    "total_completed_orders" integer DEFAULT 0,
    "total_cancelled_orders" integer DEFAULT 0,
    "total_earnings" numeric DEFAULT 0,
    "today_earnings" numeric DEFAULT 0,
    "wallet_balance" numeric DEFAULT 0,
    "cod_pending_amount" numeric DEFAULT 0,
    "cod_limit" numeric DEFAULT '500'::numeric,
    "account_status" "public"."rider_account_status_enum" DEFAULT 'offline'::"public"."rider_account_status_enum" NOT NULL,
    "current_lat" double precision,
    "current_lng" double precision,
    "current_heading" double precision,
    "last_location_updated_at" timestamp with time zone,
    "last_active_at" timestamp with time zone,
    "subscription_active" boolean DEFAULT false,
    "subscription_expires_at" timestamp with time zone,
    "commission_waiver_active" boolean DEFAULT false,
    "is_verified" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "last_dormant_notification_sent_at" timestamp with time zone,
    "last_sub_offline_notification_sent_at" timestamp with time zone
);

ALTER TABLE ONLY "public"."riders" REPLICA IDENTITY FULL;


ALTER TABLE "public"."riders" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."rider_reliability_view" AS
 SELECT "r"."id" AS "rider_id",
    "r"."user_id",
    "stats"."reliability_score",
    "stats"."rating",
    "stats"."completion_rate",
    "stats"."on_time_rate",
    "stats"."total_completed",
    "stats"."total_cancelled",
    "stats"."experience_score"
   FROM ("public"."riders" "r"
     CROSS JOIN LATERAL "public"."get_rider_reliability_stats"("r"."id") "stats"("reliability_score", "rating", "completion_rate", "on_time_rate", "total_completed", "total_cancelled", "experience_score"));


ALTER VIEW "public"."rider_reliability_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rider_reviews" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "rider_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "rating" integer NOT NULL,
    "tags" "public"."review_tag"[] DEFAULT '{}'::"public"."review_tag"[],
    "comment" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    CONSTRAINT "rider_reviews_rating_check" CHECK ((("rating" >= 1) AND ("rating" <= 5)))
);


ALTER TABLE "public"."rider_reviews" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rider_subscription_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "rider_id" "uuid" NOT NULL,
    "amount" numeric NOT NULL,
    "payment_status" "text" NOT NULL,
    "payment_id" "uuid",
    "starts_at" timestamp with time zone NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "expire_warning_sent" boolean DEFAULT false
);


ALTER TABLE "public"."rider_subscription_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rider_travel_plans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "rider_id" "uuid" NOT NULL,
    "pickup_city" "text" NOT NULL,
    "destination_city" "text" NOT NULL,
    "pickup_lat" double precision,
    "pickup_lng" double precision,
    "destination_lat" double precision,
    "destination_lng" double precision,
    "weight_preference" "text",
    "travel_date" timestamp with time zone NOT NULL,
    "status" "public"."travel_plan_status_enum" DEFAULT 'active'::"public"."travel_plan_status_enum" NOT NULL,
    "created_at" "text" DEFAULT (("now"() AT TIME ZONE 'UTC'::"text"))::"text",
    "updated_at" "text" DEFAULT (("now"() AT TIME ZONE 'UTC'::"text"))::"text",
    "plan_code" "text",
    "max_weight_kg" numeric DEFAULT 0 NOT NULL,
    "max_bookings" integer DEFAULT 3 NOT NULL,
    "travel_plan_type" "text" DEFAULT 'both'::"text" NOT NULL,
    "vehicle_type" "public"."vehicle_type_enum",
    "route_geometry" "text",
    CONSTRAINT "rider_travel_plans_travel_plan_type_check" CHECK (("travel_plan_type" = ANY (ARRAY['ride'::"text", 'parcel'::"text", 'both'::"text"])))
);

ALTER TABLE ONLY "public"."rider_travel_plans" REPLICA IDENTITY FULL;


ALTER TABLE "public"."rider_travel_plans" OWNER TO "postgres";


COMMENT ON COLUMN "public"."rider_travel_plans"."route_geometry" IS 'JSON string representing the list of route coordinates [[lat, lng], ...] for corridor matching.';



CREATE TABLE IF NOT EXISTS "public"."rider_withdrawal_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "withdrawal_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "old_status" "public"."rider_withdrawal_status_enum",
    "new_status" "public"."rider_withdrawal_status_enum" NOT NULL,
    "response" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."rider_withdrawal_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rider_withdrawals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "rider_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "amount" numeric(10,2) NOT NULL,
    "transfer_id" "text" NOT NULL,
    "status" "public"."rider_withdrawal_status_enum" DEFAULT 'pending'::"public"."rider_withdrawal_status_enum" NOT NULL,
    "cashfree_reference_id" "text",
    "cashfree_response" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "rider_withdrawals_amount_check" CHECK (("amount" > (0)::numeric))
);

ALTER TABLE ONLY "public"."rider_withdrawals" REPLICA IDENTITY FULL;


ALTER TABLE "public"."rider_withdrawals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."wallet_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "rider_id" "uuid" NOT NULL,
    "amount" numeric(10,2) NOT NULL,
    "type" character varying NOT NULL,
    "reference_id" "uuid" NOT NULL,
    "reference_type" character varying NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "wallet_transactions_reference_type_check" CHECK ((("reference_type")::"text" = ANY ((ARRAY['order'::character varying, 'withdrawal'::character varying, 'settlement'::character varying, 'bonus'::character varying])::"text"[]))),
    CONSTRAINT "wallet_transactions_type_check" CHECK ((("type")::"text" = ANY ((ARRAY['credit'::character varying, 'debit'::character varying, 'bonus'::character varying, 'settlement'::character varying, 'adjustment'::character varying])::"text"[])))
);


ALTER TABLE "public"."wallet_transactions" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."settlement_reconciliation_summary" AS
 SELECT "id" AS "order_id",
    "rider_id",
    "final_fare",
    "order_status",
    "payment_mode",
    "payment_status",
        CASE
            WHEN (("payment_mode" = 'cash'::"public"."payment_mode_enum") AND ("order_status" = ANY (ARRAY['completed'::"public"."order_status_enum", 'delivered'::"public"."order_status_enum"]))) THEN "final_fare"
            ELSE 0.00
        END AS "cash_collected",
    COALESCE(( SELECT "sum"("wallet_transactions"."amount") AS "sum"
           FROM "public"."wallet_transactions"
          WHERE (("wallet_transactions"."reference_id" = "o"."id") AND (("wallet_transactions"."reference_type")::"text" = 'order'::"text"))), 0.00) AS "wallet_transaction_sum",
    COALESCE(( SELECT "sum"("rider_withdrawals"."amount") AS "sum"
           FROM "public"."rider_withdrawals"
          WHERE (("rider_withdrawals"."rider_id" = "o"."rider_id") AND ("rider_withdrawals"."status" = 'success'::"public"."rider_withdrawal_status_enum"))), 0.00) AS "total_settlements"
   FROM "public"."orders" "o";


ALTER VIEW "public"."settlement_reconciliation_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."travel_plan_capacity_view" AS
 WITH "active_weight_usage" AS (
         SELECT "o"."rider_id",
            COALESCE("sum"(COALESCE("o"."actual_weight_kg", (COALESCE(NULLIF("regexp_replace"("o"."weight_category", '[^0-9.]'::"text", ''::"text", 'g'::"text"), ''::"text"), '0'::"text"))::numeric)), 0.0) AS "used_weight_kg"
           FROM "public"."orders" "o"
          WHERE ("o"."order_status" = ANY (ARRAY['accepted'::"public"."order_status_enum", 'rider_arrived'::"public"."order_status_enum", 'picked_up'::"public"."order_status_enum", 'ongoing'::"public"."order_status_enum", 'rider_at_drop'::"public"."order_status_enum"]))
          GROUP BY "o"."rider_id"
        )
 SELECT "tp"."id" AS "plan_id",
    "tp"."max_weight_kg",
    COALESCE("uw"."used_weight_kg", 0.0) AS "used_weight_kg",
    GREATEST(("tp"."max_weight_kg" - COALESCE("uw"."used_weight_kg", 0.0)), 0.0) AS "remaining_capacity_kg"
   FROM ("public"."rider_travel_plans" "tp"
     LEFT JOIN "active_weight_usage" "uw" ON (("uw"."rider_id" = "tp"."rider_id")));


ALTER VIEW "public"."travel_plan_capacity_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_device_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "fcm_token" "text" NOT NULL,
    "device_type" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "device_id" "text",
    "device_model" "text",
    "device_brand" "text",
    "os_version" "text",
    "app_version" "text",
    "last_ip_address" "inet",
    "last_lat" double precision,
    "last_lng" double precision,
    "user_device_id" "uuid"
);


ALTER TABLE "public"."user_device_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_devices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "device_id" "text" NOT NULL,
    "device_ref" "text" NOT NULL,
    "device_model" "text",
    "device_brand" "text",
    "os_version" "text",
    "app_version" "text",
    "last_ip_address" "inet",
    "last_seen_at" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_active" boolean DEFAULT true
);


ALTER TABLE "public"."user_devices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_promo_usages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "promo_code_id" "uuid" NOT NULL,
    "used_at" timestamp with time zone DEFAULT "now"(),
    "order_id" "uuid"
);


ALTER TABLE "public"."user_promo_usages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."wallet_audit_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "run_at" timestamp with time zone DEFAULT "now"(),
    "discrepancies_found" integer NOT NULL,
    "details" "jsonb"
);


ALTER TABLE "public"."wallet_audit_logs" OWNER TO "postgres";


ALTER TABLE ONLY "public"."admin_logs"
    ADD CONSTRAINT "admin_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_admin_code_key" UNIQUE ("admin_code");



ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_phone_key" UNIQUE ("phone");



ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dispatch_config"
    ADD CONSTRAINT "dispatch_config_config_code_key" UNIQUE ("config_code");



ALTER TABLE ONLY "public"."dispatch_config"
    ADD CONSTRAINT "dispatch_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."distance_discounts"
    ADD CONSTRAINT "distance_discounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."intercity_requests"
    ADD CONSTRAINT "intercity_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_assignment_logs"
    ADD CONSTRAINT "order_assignment_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_chat_messages"
    ADD CONSTRAINT "order_chat_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_declarations"
    ADD CONSTRAINT "order_declarations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_parcel_photos"
    ADD CONSTRAINT "order_parcel_photos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_status_history"
    ADD CONSTRAINT "order_status_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_verifications"
    ADD CONSTRAINT "order_verifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_order_code_key" UNIQUE ("order_code");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."parcel_compliance_reports"
    ADD CONSTRAINT "parcel_compliance_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."parcel_security_logs"
    ADD CONSTRAINT "parcel_security_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_payment_code_key" UNIQUE ("payment_code");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."police_sos_logs"
    ADD CONSTRAINT "police_sos_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."police_sos_logs"
    ADD CONSTRAINT "police_sos_logs_police_reference_code_key" UNIQUE ("police_reference_code");



ALTER TABLE ONLY "public"."police_sos_logs"
    ADD CONSTRAINT "police_sos_logs_support_ticket_code_key" UNIQUE ("support_ticket_code");



ALTER TABLE ONLY "public"."pricing_change_logs"
    ADD CONSTRAINT "pricing_change_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pricing_config"
    ADD CONSTRAINT "pricing_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pricing_config"
    ADD CONSTRAINT "pricing_config_pricing_code_key" UNIQUE ("pricing_code");



ALTER TABLE ONLY "public"."pricing_zones"
    ADD CONSTRAINT "pricing_zones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pricing_zones"
    ADD CONSTRAINT "pricing_zones_zone_code_key" UNIQUE ("zone_code");



ALTER TABLE ONLY "public"."promo_code_users"
    ADD CONSTRAINT "promo_code_users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."promo_code_users"
    ADD CONSTRAINT "promo_code_users_unique" UNIQUE ("promo_code_id", "user_id");



ALTER TABLE ONLY "public"."promo_codes"
    ADD CONSTRAINT "promo_codes_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."promo_codes"
    ADD CONSTRAINT "promo_codes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rider_assignments"
    ADD CONSTRAINT "rider_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rider_daily_activity"
    ADD CONSTRAINT "rider_daily_activity_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rider_daily_activity"
    ADD CONSTRAINT "rider_daily_activity_rider_id_date_key" UNIQUE ("rider_id", "date");



ALTER TABLE ONLY "public"."rider_kyc"
    ADD CONSTRAINT "rider_kyc_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rider_payout_accounts"
    ADD CONSTRAINT "rider_payout_accounts_beneficiary_id_key" UNIQUE ("beneficiary_id");



ALTER TABLE ONLY "public"."rider_payout_accounts"
    ADD CONSTRAINT "rider_payout_accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rider_payout_updates_log"
    ADD CONSTRAINT "rider_payout_updates_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rider_reviews"
    ADD CONSTRAINT "rider_reviews_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rider_subscription_history"
    ADD CONSTRAINT "rider_subscription_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rider_travel_plans"
    ADD CONSTRAINT "rider_travel_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rider_travel_plans"
    ADD CONSTRAINT "rider_travel_plans_plan_code_key" UNIQUE ("plan_code");



ALTER TABLE ONLY "public"."rider_withdrawal_events"
    ADD CONSTRAINT "rider_withdrawal_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rider_withdrawals"
    ADD CONSTRAINT "rider_withdrawals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rider_withdrawals"
    ADD CONSTRAINT "rider_withdrawals_transfer_id_key" UNIQUE ("transfer_id");



ALTER TABLE ONLY "public"."riders"
    ADD CONSTRAINT "riders_kyc_id_key" UNIQUE ("kyc_id");



ALTER TABLE ONLY "public"."riders"
    ADD CONSTRAINT "riders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."riders"
    ADD CONSTRAINT "riders_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."order_assignment_logs"
    ADD CONSTRAINT "unique_order_rider_assignment" UNIQUE ("order_id", "rider_id", "assignment_round");



ALTER TABLE ONLY "public"."rider_reviews"
    ADD CONSTRAINT "uq_rider_reviews_order" UNIQUE ("order_id");



ALTER TABLE ONLY "public"."user_device_tokens"
    ADD CONSTRAINT "user_device_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_device_tokens"
    ADD CONSTRAINT "user_device_tokens_token_key" UNIQUE ("fcm_token");



ALTER TABLE ONLY "public"."user_devices"
    ADD CONSTRAINT "user_devices_device_id_key" UNIQUE ("device_id");



ALTER TABLE ONLY "public"."user_devices"
    ADD CONSTRAINT "user_devices_device_ref_key" UNIQUE ("device_ref");



ALTER TABLE ONLY "public"."user_devices"
    ADD CONSTRAINT "user_devices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_promo_usages"
    ADD CONSTRAINT "user_promo_usages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_promo_usages"
    ADD CONSTRAINT "user_promo_usages_user_promo_unique" UNIQUE ("user_id", "promo_code_id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_phone_key" UNIQUE ("phone");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_user_code_key" UNIQUE ("user_code");



ALTER TABLE ONLY "public"."wallet_audit_logs"
    ADD CONSTRAINT "wallet_audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."wallet_transactions"
    ADD CONSTRAINT "wallet_transactions_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_admin_logs_action_type" ON "public"."admin_logs" USING "btree" ("action_type");



CREATE INDEX "idx_admin_logs_admin_id" ON "public"."admin_logs" USING "btree" ("admin_id");



CREATE INDEX "idx_admin_logs_created_at" ON "public"."admin_logs" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_admin_logs_target_id" ON "public"."admin_logs" USING "btree" ("target_id");



CREATE UNIQUE INDEX "idx_distance_discounts_active" ON "public"."distance_discounts" USING "btree" ("is_active") WHERE ("is_active" = true);



CREATE INDEX "idx_order_assignment_logs_assignment_round" ON "public"."order_assignment_logs" USING "btree" ("assignment_round");



CREATE INDEX "idx_order_assignment_logs_assignment_status" ON "public"."order_assignment_logs" USING "btree" ("assignment_status");



CREATE INDEX "idx_order_assignment_logs_order_id" ON "public"."order_assignment_logs" USING "btree" ("order_id");



CREATE INDEX "idx_order_assignment_logs_rider_id" ON "public"."order_assignment_logs" USING "btree" ("rider_id");



CREATE INDEX "idx_order_assignment_logs_sent_at" ON "public"."order_assignment_logs" USING "btree" ("sent_at" DESC);



CREATE INDEX "idx_order_status_history_created_at" ON "public"."order_status_history" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_order_status_history_new_status" ON "public"."order_status_history" USING "btree" ("new_status");



CREATE INDEX "idx_order_status_history_order_id" ON "public"."order_status_history" USING "btree" ("order_id");



CREATE INDEX "idx_orders_created_at" ON "public"."orders" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_orders_destination_location" ON "public"."orders" USING "btree" ("destination_lat", "destination_lng");



CREATE INDEX "idx_orders_order_code" ON "public"."orders" USING "btree" ("order_code");



CREATE INDEX "idx_orders_order_status" ON "public"."orders" USING "btree" ("order_status");



CREATE INDEX "idx_orders_order_type" ON "public"."orders" USING "btree" ("order_type");



CREATE INDEX "idx_orders_payment_id" ON "public"."orders" USING "btree" ("payment_id");



CREATE INDEX "idx_orders_payment_status" ON "public"."orders" USING "btree" ("payment_status");



CREATE INDEX "idx_orders_pickup_location" ON "public"."orders" USING "btree" ("pickup_lat", "pickup_lng");



CREATE INDEX "idx_orders_pricing_config_id" ON "public"."orders" USING "btree" ("pricing_config_id");



CREATE INDEX "idx_orders_rider_id" ON "public"."orders" USING "btree" ("rider_id");



CREATE INDEX "idx_orders_search_expires_at" ON "public"."orders" USING "btree" ("search_expires_at");



CREATE INDEX "idx_orders_user_id" ON "public"."orders" USING "btree" ("user_id");



CREATE INDEX "idx_orders_vehicle_type" ON "public"."orders" USING "btree" ("vehicle_type");



CREATE INDEX "idx_payments_created_at" ON "public"."payments" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_payments_payment_status" ON "public"."payments" USING "btree" ("payment_status");



CREATE INDEX "idx_payments_reference_id" ON "public"."payments" USING "btree" ("reference_id");



CREATE INDEX "idx_payments_rider_id" ON "public"."payments" USING "btree" ("rider_id");



CREATE INDEX "idx_payments_user_id" ON "public"."payments" USING "btree" ("user_id");



CREATE INDEX "idx_pricing_change_logs_changed_by_admin_id" ON "public"."pricing_change_logs" USING "btree" ("changed_by_admin_id");



CREATE INDEX "idx_pricing_change_logs_created_at" ON "public"."pricing_change_logs" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_pricing_change_logs_pricing_config_id" ON "public"."pricing_change_logs" USING "btree" ("pricing_config_id");



CREATE INDEX "idx_pricing_config_approval_status" ON "public"."pricing_config" USING "btree" ("approval_status");



CREATE INDEX "idx_pricing_config_city_tier" ON "public"."pricing_config" USING "btree" ("city_tier");



CREATE INDEX "idx_pricing_config_created_at" ON "public"."pricing_config" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_pricing_config_is_active" ON "public"."pricing_config" USING "btree" ("is_active");



CREATE INDEX "idx_pricing_config_service_type" ON "public"."pricing_config" USING "btree" ("service_type");



CREATE INDEX "idx_pricing_config_vehicle_type" ON "public"."pricing_config" USING "btree" ("vehicle_type");



CREATE INDEX "idx_promo_codes_code" ON "public"."promo_codes" USING "btree" ("code");



CREATE INDEX "idx_rider_assignments_expires_at" ON "public"."rider_assignments" USING "btree" ("expires_at" DESC);



CREATE INDEX "idx_rider_assignments_order_id" ON "public"."rider_assignments" USING "btree" ("order_id");



CREATE INDEX "idx_rider_assignments_rider_id" ON "public"."rider_assignments" USING "btree" ("rider_id");



CREATE INDEX "idx_rider_assignments_round" ON "public"."rider_assignments" USING "btree" ("assignment_round");



CREATE INDEX "idx_rider_assignments_status" ON "public"."rider_assignments" USING "btree" ("assignment_status");



CREATE INDEX "idx_rider_kyc_activation_status" ON "public"."rider_kyc" USING "btree" ("activation_status");



CREATE INDEX "idx_rider_kyc_created_at" ON "public"."rider_kyc" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_rider_kyc_handled_by_admin_id" ON "public"."rider_kyc" USING "btree" ("handled_by_admin_id");



CREATE INDEX "idx_rider_kyc_kyc_status" ON "public"."rider_kyc" USING "btree" ("kyc_status");



CREATE INDEX "idx_rider_kyc_user_id" ON "public"."rider_kyc" USING "btree" ("user_id");



CREATE INDEX "idx_rider_payout_accounts_beneficiary_id" ON "public"."rider_payout_accounts" USING "btree" ("beneficiary_id");



CREATE INDEX "idx_rider_payout_accounts_cashfree_status" ON "public"."rider_payout_accounts" USING "btree" ("cashfree_beneficiary_status");



CREATE UNIQUE INDEX "idx_rider_payout_accounts_rider_id" ON "public"."rider_payout_accounts" USING "btree" ("rider_id");



CREATE UNIQUE INDEX "idx_rider_payout_accounts_user_id" ON "public"."rider_payout_accounts" USING "btree" ("user_id");



CREATE INDEX "idx_rider_payout_updates_log_user_created" ON "public"."rider_payout_updates_log" USING "btree" ("user_id", "created_at");



CREATE INDEX "idx_rider_subscription_created_at" ON "public"."rider_subscription_history" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_rider_subscription_expires_at" ON "public"."rider_subscription_history" USING "btree" ("expires_at" DESC);



CREATE INDEX "idx_rider_subscription_is_active" ON "public"."rider_subscription_history" USING "btree" ("is_active");



CREATE INDEX "idx_rider_subscription_payment_id" ON "public"."rider_subscription_history" USING "btree" ("payment_id");



CREATE INDEX "idx_rider_subscription_rider_id" ON "public"."rider_subscription_history" USING "btree" ("rider_id");



CREATE INDEX "idx_rider_withdrawal_events_withdrawal_id" ON "public"."rider_withdrawal_events" USING "btree" ("withdrawal_id");



CREATE INDEX "idx_rider_withdrawals_rider_id" ON "public"."rider_withdrawals" USING "btree" ("rider_id");



CREATE INDEX "idx_rider_withdrawals_transfer_id" ON "public"."rider_withdrawals" USING "btree" ("transfer_id");



CREATE INDEX "idx_rider_withdrawals_user_id" ON "public"."rider_withdrawals" USING "btree" ("user_id");



CREATE INDEX "idx_riders_account_status" ON "public"."riders" USING "btree" ("account_status");



CREATE INDEX "idx_riders_created_at" ON "public"."riders" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_riders_current_lat" ON "public"."riders" USING "btree" ("current_lat");



CREATE INDEX "idx_riders_current_lng" ON "public"."riders" USING "btree" ("current_lng");



CREATE INDEX "idx_riders_kyc_id" ON "public"."riders" USING "btree" ("kyc_id");



CREATE INDEX "idx_riders_location_updated" ON "public"."riders" USING "btree" ("last_location_updated_at" DESC);



CREATE INDEX "idx_riders_subscription_active" ON "public"."riders" USING "btree" ("subscription_active");



CREATE INDEX "idx_riders_user_id" ON "public"."riders" USING "btree" ("user_id");



CREATE UNIQUE INDEX "idx_unique_gateway_txn" ON "public"."payments" USING "btree" ("gateway_transaction_id");



CREATE UNIQUE INDEX "idx_unique_pending_payment" ON "public"."payments" USING "btree" ("user_id", "payment_for", "reference_id") WHERE ("payment_status" = 'pending'::"public"."payment_status_enum");



CREATE UNIQUE INDEX "idx_unique_subscription_payment" ON "public"."rider_subscription_history" USING "btree" ("payment_id");



CREATE INDEX "idx_user_device_tokens_token" ON "public"."user_device_tokens" USING "btree" ("fcm_token");



CREATE INDEX "idx_user_device_tokens_user_id" ON "public"."user_device_tokens" USING "btree" ("user_id");



CREATE UNIQUE INDEX "unique_active_pricing_config" ON "public"."pricing_config" USING "btree" ("service_type", COALESCE("vehicle_type", ''::"text"), COALESCE(("pricing_zone_id")::"text", ''::"text")) WHERE ("is_active" = true);



CREATE OR REPLACE TRIGGER "log_withdrawal_event" AFTER INSERT OR UPDATE ON "public"."rider_withdrawals" FOR EACH ROW EXECUTE FUNCTION "public"."log_rider_withdrawal_event"();



CREATE OR REPLACE TRIGGER "on_order_activity_tracking" AFTER UPDATE OF "order_status" ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."handle_order_activity_tracking"();



CREATE OR REPLACE TRIGGER "on_rider_status_change" AFTER UPDATE OF "account_status" ON "public"."riders" FOR EACH ROW EXECUTE FUNCTION "public"."handle_rider_status_change"();



CREATE OR REPLACE TRIGGER "prevent_delete_active_travel_plan" BEFORE DELETE ON "public"."rider_travel_plans" FOR EACH ROW EXECUTE FUNCTION "public"."check_travel_plan_active_bookings"();



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."rider_withdrawals" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "tr_update_rider_average_rating" AFTER INSERT OR DELETE OR UPDATE ON "public"."rider_reviews" FOR EACH ROW EXECUTE FUNCTION "public"."update_rider_average_rating"();



CREATE OR REPLACE TRIGGER "trg_orders_compliance_retention" BEFORE UPDATE ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."set_compliance_retention"();



CREATE OR REPLACE TRIGGER "trg_police_sos_reference_code" BEFORE INSERT ON "public"."police_sos_logs" FOR EACH ROW EXECUTE FUNCTION "public"."generate_police_reference_code"();



CREATE OR REPLACE TRIGGER "trg_populate_order_code" BEFORE INSERT ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."trg_orders_order_code"();



CREATE OR REPLACE TRIGGER "trg_populate_payment_code" BEFORE INSERT ON "public"."payments" FOR EACH ROW EXECUTE FUNCTION "public"."trg_payments_payment_code"();



CREATE OR REPLACE TRIGGER "trg_populate_plan_code" BEFORE INSERT ON "public"."rider_travel_plans" FOR EACH ROW EXECUTE FUNCTION "public"."trg_travel_plans_plan_code"();



CREATE OR REPLACE TRIGGER "trg_populate_transfer_id" BEFORE INSERT ON "public"."rider_withdrawals" FOR EACH ROW EXECUTE FUNCTION "public"."trg_rider_withdrawals_transfer_id"();



CREATE OR REPLACE TRIGGER "trg_populate_user_code" BEFORE INSERT ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."trg_users_user_code"();



CREATE OR REPLACE TRIGGER "trigger_assign_nearby_orders" AFTER UPDATE OF "account_status", "current_lat", "current_lng", "last_location_updated_at" ON "public"."riders" FOR EACH ROW WHEN ((("new"."account_status" = 'online'::"public"."rider_account_status_enum") AND (("old"."account_status" IS DISTINCT FROM 'online'::"public"."rider_account_status_enum") OR ("new"."current_lat" IS DISTINCT FROM "old"."current_lat") OR ("new"."current_lng" IS DISTINCT FROM "old"."current_lng") OR ("new"."last_location_updated_at" IS DISTINCT FROM "old"."last_location_updated_at")))) EXECUTE FUNCTION "public"."assign_nearby_searching_orders_to_rider"();



CREATE OR REPLACE TRIGGER "trigger_check_payout_update_limit" BEFORE INSERT OR UPDATE ON "public"."rider_payout_accounts" FOR EACH ROW EXECUTE FUNCTION "public"."check_payout_update_limit"();



CREATE OR REPLACE TRIGGER "trigger_create_rider_profile" AFTER UPDATE OF "kyc_status", "activation_status" ON "public"."rider_kyc" FOR EACH ROW WHEN ((("new"."kyc_status" = 'approved'::"public"."kyc_status_enum") AND ("new"."activation_status" = 'active'::"public"."activation_status_enum"))) EXECUTE FUNCTION "public"."create_rider_profile_on_activation"();



CREATE OR REPLACE TRIGGER "trigger_generate_beneficiary_id" BEFORE INSERT ON "public"."rider_payout_accounts" FOR EACH ROW EXECUTE FUNCTION "public"."generate_rider_beneficiary_id"();



CREATE OR REPLACE TRIGGER "trigger_handle_promo_usage_changes" AFTER INSERT OR DELETE ON "public"."user_promo_usages" FOR EACH ROW EXECUTE FUNCTION "public"."handle_promo_usage_changes"();



CREATE OR REPLACE TRIGGER "trigger_intercity_request_change" AFTER INSERT OR UPDATE ON "public"."intercity_requests" FOR EACH ROW EXECUTE FUNCTION "public"."on_intercity_request_change"();



CREATE OR REPLACE TRIGGER "trigger_new_chat_message" AFTER INSERT ON "public"."order_chat_messages" FOR EACH ROW EXECUTE FUNCTION "public"."on_new_chat_message"();



CREATE OR REPLACE TRIGGER "trigger_notification_insert" AFTER INSERT ON "public"."notifications" FOR EACH ROW EXECUTE FUNCTION "public"."on_notification_insert"();



CREATE OR REPLACE TRIGGER "trigger_order_status_update" AFTER UPDATE OF "order_status" ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."on_order_status_update"();



CREATE OR REPLACE TRIGGER "trigger_prevent_wallet_transaction_mods" BEFORE DELETE OR UPDATE ON "public"."wallet_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_wallet_transaction_modifications"();



CREATE OR REPLACE TRIGGER "trigger_rider_assignment_change" AFTER INSERT OR UPDATE OF "assignment_status" ON "public"."rider_assignments" FOR EACH ROW EXECUTE FUNCTION "public"."on_rider_assignment_change"();



CREATE OR REPLACE TRIGGER "trigger_rider_review_insert" AFTER INSERT ON "public"."rider_reviews" FOR EACH ROW EXECUTE FUNCTION "public"."on_rider_review_insert"();



CREATE OR REPLACE TRIGGER "trigger_rider_wallet_balance_update" AFTER UPDATE OF "wallet_balance" ON "public"."riders" FOR EACH ROW EXECUTE FUNCTION "public"."on_rider_wallet_balance_update"();



CREATE OR REPLACE TRIGGER "trigger_sync_travel_plan_status" AFTER INSERT OR DELETE OR UPDATE ON "public"."intercity_requests" FOR EACH ROW EXECUTE FUNCTION "public"."sync_travel_plan_status_after"();



ALTER TABLE ONLY "public"."admin_logs"
    ADD CONSTRAINT "admin_logs_admin_id_fkey" FOREIGN KEY ("admin_id") REFERENCES "public"."admins"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dispatch_config"
    ADD CONSTRAINT "dispatch_config_updated_by_admin_id_fkey" FOREIGN KEY ("updated_by_admin_id") REFERENCES "public"."admins"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."intercity_requests"
    ADD CONSTRAINT "intercity_requests_parcel_id_fkey" FOREIGN KEY ("parcel_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."intercity_requests"
    ADD CONSTRAINT "intercity_requests_route_id_fkey" FOREIGN KEY ("route_id") REFERENCES "public"."rider_travel_plans"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."intercity_requests"
    ADD CONSTRAINT "intercity_requests_sender_id_fkey" FOREIGN KEY ("sender_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."intercity_requests"
    ADD CONSTRAINT "intercity_requests_traveller_id_fkey" FOREIGN KEY ("traveller_id") REFERENCES "public"."riders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_assignment_logs"
    ADD CONSTRAINT "order_assignment_logs_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_assignment_logs"
    ADD CONSTRAINT "order_assignment_logs_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_chat_messages"
    ADD CONSTRAINT "order_chat_messages_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_chat_messages"
    ADD CONSTRAINT "order_chat_messages_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_chat_messages"
    ADD CONSTRAINT "order_chat_messages_sender_id_fkey" FOREIGN KEY ("sender_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_chat_messages"
    ADD CONSTRAINT "order_chat_messages_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_declarations"
    ADD CONSTRAINT "order_declarations_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."order_declarations"
    ADD CONSTRAINT "order_declarations_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."order_parcel_photos"
    ADD CONSTRAINT "order_parcel_photos_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."order_parcel_photos"
    ADD CONSTRAINT "order_parcel_photos_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id");



ALTER TABLE ONLY "public"."order_status_history"
    ADD CONSTRAINT "order_status_history_changed_by_admin_id_fkey" FOREIGN KEY ("changed_by_admin_id") REFERENCES "public"."admins"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."order_status_history"
    ADD CONSTRAINT "order_status_history_changed_by_rider_id_fkey" FOREIGN KEY ("changed_by_rider_id") REFERENCES "public"."riders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."order_status_history"
    ADD CONSTRAINT "order_status_history_changed_by_user_id_fkey" FOREIGN KEY ("changed_by_user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."order_status_history"
    ADD CONSTRAINT "order_status_history_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_verifications"
    ADD CONSTRAINT "order_verifications_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."order_verifications"
    ADD CONSTRAINT "order_verifications_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_created_device_record_id_fkey" FOREIGN KEY ("created_device_record_id") REFERENCES "public"."user_devices"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_pricing_config_id_fkey" FOREIGN KEY ("pricing_config_id") REFERENCES "public"."pricing_config"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."parcel_compliance_reports"
    ADD CONSTRAINT "parcel_compliance_reports_generated_by_fkey" FOREIGN KEY ("generated_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."parcel_compliance_reports"
    ADD CONSTRAINT "parcel_compliance_reports_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."parcel_security_logs"
    ADD CONSTRAINT "parcel_security_logs_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."parcel_security_logs"
    ADD CONSTRAINT "parcel_security_logs_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id");



ALTER TABLE ONLY "public"."parcel_security_logs"
    ADD CONSTRAINT "parcel_security_logs_sender_user_id_fkey" FOREIGN KEY ("sender_user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."police_sos_logs"
    ADD CONSTRAINT "police_sos_logs_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."police_sos_logs"
    ADD CONSTRAINT "police_sos_logs_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id");



ALTER TABLE ONLY "public"."pricing_change_logs"
    ADD CONSTRAINT "pricing_change_logs_changed_by_admin_id_fkey" FOREIGN KEY ("changed_by_admin_id") REFERENCES "public"."admins"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."pricing_change_logs"
    ADD CONSTRAINT "pricing_change_logs_pricing_config_id_fkey" FOREIGN KEY ("pricing_config_id") REFERENCES "public"."pricing_config"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pricing_config"
    ADD CONSTRAINT "pricing_config_approved_by_admin_id_fkey" FOREIGN KEY ("approved_by_admin_id") REFERENCES "public"."admins"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pricing_config"
    ADD CONSTRAINT "pricing_config_created_by_admin_id_fkey" FOREIGN KEY ("created_by_admin_id") REFERENCES "public"."admins"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."pricing_config"
    ADD CONSTRAINT "pricing_config_pricing_zone_id_fkey" FOREIGN KEY ("pricing_zone_id") REFERENCES "public"."pricing_zones"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."promo_code_users"
    ADD CONSTRAINT "promo_code_users_promo_code_id_fkey" FOREIGN KEY ("promo_code_id") REFERENCES "public"."promo_codes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."promo_code_users"
    ADD CONSTRAINT "promo_code_users_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_assignments"
    ADD CONSTRAINT "rider_assignments_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_assignments"
    ADD CONSTRAINT "rider_assignments_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_daily_activity"
    ADD CONSTRAINT "rider_daily_activity_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_kyc"
    ADD CONSTRAINT "rider_kyc_handled_by_admin_id_fkey" FOREIGN KEY ("handled_by_admin_id") REFERENCES "public"."admins"("id");



ALTER TABLE ONLY "public"."rider_kyc"
    ADD CONSTRAINT "rider_kyc_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_payout_accounts"
    ADD CONSTRAINT "rider_payout_accounts_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_payout_accounts"
    ADD CONSTRAINT "rider_payout_accounts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_payout_updates_log"
    ADD CONSTRAINT "rider_payout_updates_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_reviews"
    ADD CONSTRAINT "rider_reviews_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_reviews"
    ADD CONSTRAINT "rider_reviews_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_reviews"
    ADD CONSTRAINT "rider_reviews_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_subscription_history"
    ADD CONSTRAINT "rider_subscription_history_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."rider_subscription_history"
    ADD CONSTRAINT "rider_subscription_history_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_travel_plans"
    ADD CONSTRAINT "rider_travel_plans_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_withdrawal_events"
    ADD CONSTRAINT "rider_withdrawal_events_withdrawal_id_fkey" FOREIGN KEY ("withdrawal_id") REFERENCES "public"."rider_withdrawals"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_withdrawals"
    ADD CONSTRAINT "rider_withdrawals_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rider_withdrawals"
    ADD CONSTRAINT "rider_withdrawals_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."riders"
    ADD CONSTRAINT "riders_kyc_id_fkey" FOREIGN KEY ("kyc_id") REFERENCES "public"."rider_kyc"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."riders"
    ADD CONSTRAINT "riders_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_device_tokens"
    ADD CONSTRAINT "user_device_tokens_user_device_id_fkey" FOREIGN KEY ("user_device_id") REFERENCES "public"."user_devices"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_device_tokens"
    ADD CONSTRAINT "user_device_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_devices"
    ADD CONSTRAINT "user_devices_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_promo_usages"
    ADD CONSTRAINT "user_promo_usages_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_promo_usages"
    ADD CONSTRAINT "user_promo_usages_promo_code_id_fkey" FOREIGN KEY ("promo_code_id") REFERENCES "public"."promo_codes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."wallet_transactions"
    ADD CONSTRAINT "wallet_transactions_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE CASCADE;



CREATE POLICY "Allow assigned rider to insert order verifications" ON "public"."order_verifications" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_verifications"."order_id") AND ("o"."rider_id" IN ( SELECT "r"."id"
           FROM "public"."riders" "r"
          WHERE ("r"."user_id" = "auth"."uid"())))))));



CREATE POLICY "Allow authenticated to select parcel verification photos" ON "public"."order_parcel_photos" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated to select police sos logs" ON "public"."police_sos_logs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated users to insert security logs" ON "public"."parcel_security_logs" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow authenticated users to select compliance reports" ON "public"."parcel_compliance_reports" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated users to view active travel plans" ON "public"."rider_travel_plans" FOR SELECT TO "authenticated" USING ((("status" = 'active'::"public"."travel_plan_status_enum") OR (EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_travel_plans"."rider_id") AND ("r"."user_id" = "auth"."uid"()))))));



CREATE POLICY "Allow authenticated users to view online riders" ON "public"."riders" FOR SELECT TO "authenticated" USING ((("account_status" = 'online'::"public"."rider_account_status_enum") OR ("auth"."uid"() = "user_id")));



CREATE POLICY "Allow chat participants to read/write" ON "public"."order_chat_messages" TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."users"
  WHERE (("users"."id" = "auth"."uid"()) AND (("users"."role" = 'admin'::"text") OR ("users"."role" = 'support'::"text"))))) OR ("sender_id" = "auth"."uid"()) OR ("user_id" = "auth"."uid"()) OR (("order_id" IS NOT NULL) AND ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_chat_messages"."order_id") AND ("o"."user_id" = "auth"."uid"())))) OR (EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."user_id" = "auth"."uid"()) AND (("r"."id" = "order_chat_messages"."rider_id") OR ("r"."id" IN ( SELECT "o"."rider_id"
           FROM "public"."orders" "o"
          WHERE ("o"."id" = "order_chat_messages"."order_id"))) OR ("r"."id" IN ( SELECT "ra"."rider_id"
           FROM "public"."rider_assignments" "ra"
          WHERE ("ra"."order_id" = "ra"."order_id"))))))))) OR (("order_id" IS NULL) AND (("sender_id" = "auth"."uid"()) OR ("rider_id" IN ( SELECT "riders"."id"
   FROM "public"."riders"
  WHERE ("riders"."user_id" = "auth"."uid"())))))));



CREATE POLICY "Allow participants to view order verifications" ON "public"."order_verifications" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_verifications"."order_id") AND (("o"."user_id" = "auth"."uid"()) OR ("o"."rider_id" IN ( SELECT "r"."id"
           FROM "public"."riders" "r"
          WHERE ("r"."user_id" = "auth"."uid"()))))))));



CREATE POLICY "Allow passengers and assigned riders to update orders" ON "public"."orders" FOR UPDATE TO "authenticated" USING ((("auth"."uid"() = "user_id") OR (EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "orders"."rider_id") AND ("r"."user_id" = "auth"."uid"()))))));



CREATE POLICY "Allow passengers to create orders" ON "public"."orders" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Allow passengers to insert assignments for their own orders" ON "public"."rider_assignments" FOR INSERT TO "authenticated" WITH CHECK ("public"."check_is_order_passenger"("order_id", "auth"."uid"()));



CREATE POLICY "Allow passengers to update assignments for their own orders" ON "public"."rider_assignments" FOR UPDATE TO "authenticated" USING ("public"."check_is_order_passenger"("order_id", "auth"."uid"())) WITH CHECK ("public"."check_is_order_passenger"("order_id", "auth"."uid"()));



CREATE POLICY "Allow passengers to view assignments for their own orders" ON "public"."rider_assignments" FOR SELECT TO "authenticated" USING ("public"."check_is_order_passenger"("order_id", "auth"."uid"()));



CREATE POLICY "Allow public read access to pricing_zones" ON "public"."pricing_zones" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Allow read access to active and applicable promos" ON "public"."promo_codes" FOR SELECT TO "authenticated" USING ((("is_active" = true) AND ("expires_at" > "now"()) AND ((("audience_type")::"text" = 'everyone'::"text") OR (EXISTS ( SELECT 1
   FROM "public"."promo_code_users" "pcu"
  WHERE (("pcu"."promo_code_id" = "pcu"."id") AND ("pcu"."user_id" = "auth"."uid"())))))));



CREATE POLICY "Allow request participants to read/write" ON "public"."intercity_requests" TO "authenticated" USING ((("sender_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "intercity_requests"."traveller_id") AND ("r"."user_id" = "auth"."uid"())))))) WITH CHECK ((("sender_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "intercity_requests"."traveller_id") AND ("r"."user_id" = "auth"."uid"()))))));



CREATE POLICY "Allow riders and orders owners to view logs" ON "public"."order_assignment_logs" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "order_assignment_logs"."rider_id") AND ("r"."user_id" = "auth"."uid"())))) OR (EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_assignment_logs"."order_id") AND ("o"."user_id" = "auth"."uid"()))))));



CREATE POLICY "Allow riders to delete their own travel plans" ON "public"."rider_travel_plans" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_travel_plans"."rider_id") AND ("r"."user_id" = "auth"."uid"())))));



CREATE POLICY "Allow riders to insert parcel verification photos" ON "public"."order_parcel_photos" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow riders to insert police sos logs" ON "public"."police_sos_logs" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow riders to insert their own assignments" ON "public"."rider_assignments" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_assignments"."rider_id") AND ("r"."user_id" = "auth"."uid"())))));



CREATE POLICY "Allow riders to insert their own travel plans" ON "public"."rider_travel_plans" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_travel_plans"."rider_id") AND ("r"."user_id" = "auth"."uid"())))));



CREATE POLICY "Allow riders to update their own assignments" ON "public"."rider_assignments" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_assignments"."rider_id") AND ("r"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_assignments"."rider_id") AND ("r"."user_id" = "auth"."uid"())))));



CREATE POLICY "Allow riders to update their own profile" ON "public"."riders" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Allow riders to update their own travel plans" ON "public"."rider_travel_plans" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_travel_plans"."rider_id") AND ("r"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_travel_plans"."rider_id") AND ("r"."user_id" = "auth"."uid"())))));



CREATE POLICY "Allow riders to view their own assignments" ON "public"."rider_assignments" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_assignments"."rider_id") AND ("r"."user_id" = "auth"."uid"())))));



CREATE POLICY "Allow users to insert order declarations" ON "public"."order_declarations" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow users to insert their own devices" ON "public"."user_devices" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Allow users to select their declarations" ON "public"."order_declarations" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow users to select their own devices" ON "public"."user_devices" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Allow users to update their own devices" ON "public"."user_devices" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Allow users to view their own or assigned orders" ON "public"."orders" FOR SELECT TO "authenticated" USING ((("auth"."uid"() = "user_id") OR (EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "orders"."rider_id") AND ("r"."user_id" = "auth"."uid"())))) OR "public"."check_is_order_candidate_rider"("id", "auth"."uid"())));



CREATE POLICY "Allow users/riders to select their parcel security logs" ON "public"."parcel_security_logs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow view own KYC or online rider KYC" ON "public"."rider_kyc" FOR SELECT TO "authenticated" USING ((("auth"."uid"() = "user_id") OR (EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."user_id" = "rider_kyc"."user_id") AND ("r"."account_status" = 'online'::"public"."rider_account_status_enum"))))));



CREATE POLICY "Authenticated can insert rider assignments" ON "public"."rider_assignments" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Public read distance_discounts" ON "public"."distance_discounts" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Riders can delete their own payout account" ON "public"."rider_payout_accounts" FOR DELETE TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Riders can insert own KYC" ON "public"."rider_kyc" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Riders can update own assignments" ON "public"."rider_assignments" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_assignments"."rider_id") AND ("r"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_assignments"."rider_id") AND ("r"."user_id" = "auth"."uid"())))));



CREATE POLICY "Riders can update own rider profile" ON "public"."riders" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Riders can view own KYC" ON "public"."rider_kyc" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Riders can view own assignments" ON "public"."rider_assignments" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_assignments"."rider_id") AND ("r"."user_id" = "auth"."uid"())))));



CREATE POLICY "Riders can view own rider profile" ON "public"."riders" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Riders can view their own daily activity" ON "public"."rider_daily_activity" FOR SELECT TO "authenticated" USING (("rider_id" IN ( SELECT "riders"."id"
   FROM "public"."riders"
  WHERE ("riders"."user_id" = "auth"."uid"()))));



CREATE POLICY "Riders can view their own payout account" ON "public"."rider_payout_accounts" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Riders can view their own payout updates log" ON "public"."rider_payout_updates_log" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Riders can view their own wallet transactions" ON "public"."wallet_transactions" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "wallet_transactions"."rider_id") AND ("r"."user_id" = "auth"."uid"())))));



CREATE POLICY "Riders can view their own withdrawal events" ON "public"."rider_withdrawal_events" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."rider_withdrawals" "w"
  WHERE (("w"."id" = "rider_withdrawal_events"."withdrawal_id") AND ("w"."user_id" = "auth"."uid"())))));



CREATE POLICY "Riders can view their own withdrawals" ON "public"."rider_withdrawals" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users and riders can view reviews" ON "public"."rider_reviews" FOR SELECT TO "authenticated" USING ((("auth"."uid"() = "user_id") OR ("rider_id" IN ( SELECT "riders"."id"
   FROM "public"."riders"
  WHERE ("riders"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can create own kyc" ON "public"."rider_kyc" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own profile" ON "public"."users" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can insert reviews for their own orders" ON "public"."rider_reviews" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can manage their own device tokens" ON "public"."user_device_tokens" TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can record their own promo usage" ON "public"."user_promo_usages" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update own kyc" ON "public"."rider_kyc" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update own profile" ON "public"."users" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can update their own notifications" ON "public"."notifications" FOR UPDATE USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own kyc" ON "public"."rider_kyc" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own profile" ON "public"."users" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can view own rider profile" ON "public"."riders" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own withdrawal events" ON "public"."rider_withdrawal_events" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."rider_withdrawals" "rw"
  WHERE (("rw"."id" = "rider_withdrawal_events"."withdrawal_id") AND ("rw"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can view own withdrawals" ON "public"."rider_withdrawals" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own notifications" ON "public"."notifications" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own promo assignments" ON "public"."promo_code_users" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can view their own promo usages" ON "public"."user_promo_usages" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."admin_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."admins" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dispatch_config" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."distance_discounts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."intercity_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_assignment_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_chat_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_declarations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_parcel_photos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_status_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_verifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."orders" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."parcel_compliance_reports" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."parcel_security_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."police_sos_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pricing_change_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pricing_config" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pricing_zones" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."promo_code_users" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."promo_codes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rider_assignments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rider_can_view_assigned_orders" ON "public"."orders" FOR SELECT TO "authenticated" USING (("rider_id" IN ( SELECT "riders"."id"
   FROM "public"."riders"
  WHERE ("riders"."user_id" = "auth"."uid"()))));



ALTER TABLE "public"."rider_daily_activity" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rider_insert_own_payout_account" ON "public"."rider_payout_accounts" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."rider_kyc" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rider_payout_accounts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rider_payout_updates_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rider_reviews" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rider_select_own_payout_account" ON "public"."rider_payout_accounts" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."rider_subscription_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rider_travel_plans" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rider_update_own_payout_account" ON "public"."rider_payout_accounts" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."rider_withdrawal_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rider_withdrawals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."riders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_can_update_own_order" ON "public"."orders" FOR UPDATE TO "authenticated" USING ((("auth"."uid"() = "user_id") AND ("order_status" = 'searching'::"public"."order_status_enum"))) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "user_can_view_own_orders" ON "public"."orders" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."user_device_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_devices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_promo_usages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."wallet_audit_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."wallet_transactions" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."audit_rider_wallets"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."audit_rider_wallets"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_withdrawal"("p_withdrawal_id" "uuid", "p_cashfree_ref_id" "text", "p_status" "text", "p_response" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_withdrawal"("p_withdrawal_id" "uuid", "p_cashfree_ref_id" "text", "p_status" "text", "p_response" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."fail_withdrawal"("p_withdrawal_id" "uuid", "p_error_response" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fail_withdrawal"("p_withdrawal_id" "uuid", "p_error_response" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."initiate_withdrawal"("p_amount" numeric, "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."initiate_withdrawal"("p_amount" numeric, "p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."validate_and_calculate_promo"("p_code" character varying, "p_order_value" numeric, "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."validate_and_calculate_promo"("p_code" character varying, "p_order_value" numeric, "p_user_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."validate_and_calculate_promo"("p_code" character varying, "p_order_value" numeric, "p_user_id" "uuid") TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."admin_logs" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."admin_logs" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."admin_logs" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."admins" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."admins" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."admins" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."dispatch_config" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."dispatch_config" TO "authenticated";
GRANT ALL ON TABLE "public"."dispatch_config" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."distance_discounts" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."distance_discounts" TO "authenticated";
GRANT ALL ON TABLE "public"."distance_discounts" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."intercity_requests" TO "anon";
GRANT ALL ON TABLE "public"."intercity_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."intercity_requests" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."notifications" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_assignment_logs" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."order_assignment_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."order_assignment_logs" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_chat_messages" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_chat_messages" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_chat_messages" TO "service_role";



GRANT ALL ON TABLE "public"."order_declarations" TO "anon";
GRANT ALL ON TABLE "public"."order_declarations" TO "authenticated";
GRANT ALL ON TABLE "public"."order_declarations" TO "service_role";



GRANT ALL ON TABLE "public"."order_parcel_photos" TO "anon";
GRANT ALL ON TABLE "public"."order_parcel_photos" TO "authenticated";
GRANT ALL ON TABLE "public"."order_parcel_photos" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_status_history" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_status_history" TO "authenticated";
GRANT ALL ON TABLE "public"."order_status_history" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_verifications" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_verifications" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_verifications" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."orders" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."orders" TO "authenticated";
GRANT ALL ON TABLE "public"."orders" TO "service_role";



GRANT ALL ON TABLE "public"."parcel_compliance_reports" TO "anon";
GRANT ALL ON TABLE "public"."parcel_compliance_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."parcel_compliance_reports" TO "service_role";



GRANT ALL ON TABLE "public"."police_sos_logs" TO "anon";
GRANT ALL ON TABLE "public"."police_sos_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."police_sos_logs" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."users" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."users" TO "service_role";
GRANT SELECT ON TABLE "public"."users" TO "anon";



GRANT ALL ON TABLE "public"."parcel_compliance_view" TO "anon";
GRANT ALL ON TABLE "public"."parcel_compliance_view" TO "authenticated";
GRANT ALL ON TABLE "public"."parcel_compliance_view" TO "service_role";



GRANT ALL ON TABLE "public"."parcel_security_logs" TO "anon";
GRANT ALL ON TABLE "public"."parcel_security_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."parcel_security_logs" TO "service_role";



GRANT ALL ON TABLE "public"."parcel_security_timeline_view" TO "anon";
GRANT ALL ON TABLE "public"."parcel_security_timeline_view" TO "authenticated";
GRANT ALL ON TABLE "public"."parcel_security_timeline_view" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."payments" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_change_logs" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_change_logs" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_change_logs" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_config" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_config" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."pricing_config" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_zones" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_zones" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_zones" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."promo_code_users" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."promo_code_users" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."promo_code_users" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."promo_codes" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."promo_codes" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."promo_codes" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_assignments" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."rider_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."rider_assignments" TO "service_role";



GRANT UPDATE ON SEQUENCE "public"."rider_beneficiary_seq" TO "anon";
GRANT UPDATE ON SEQUENCE "public"."rider_beneficiary_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."rider_beneficiary_seq" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_daily_activity" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_daily_activity" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_daily_activity" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_kyc" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_kyc" TO "authenticated";
GRANT ALL ON TABLE "public"."rider_kyc" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_payout_accounts" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."rider_payout_accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."rider_payout_accounts" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_payout_updates_log" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_payout_updates_log" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_payout_updates_log" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."riders" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."riders" TO "authenticated";
GRANT ALL ON TABLE "public"."riders" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_reliability_view" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_reliability_view" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_reliability_view" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_reviews" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_reviews" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_reviews" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_subscription_history" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_subscription_history" TO "authenticated";
GRANT ALL ON TABLE "public"."rider_subscription_history" TO "service_role";



GRANT ALL ON TABLE "public"."rider_travel_plans" TO "anon";
GRANT ALL ON TABLE "public"."rider_travel_plans" TO "authenticated";
GRANT ALL ON TABLE "public"."rider_travel_plans" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_withdrawal_events" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_withdrawal_events" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_withdrawal_events" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_withdrawals" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."rider_withdrawals" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_withdrawals" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."wallet_transactions" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."wallet_transactions" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."wallet_transactions" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."settlement_reconciliation_summary" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."settlement_reconciliation_summary" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."settlement_reconciliation_summary" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."travel_plan_capacity_view" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."travel_plan_capacity_view" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."travel_plan_capacity_view" TO "service_role";



GRANT ALL ON TABLE "public"."user_device_tokens" TO "anon";
GRANT ALL ON TABLE "public"."user_device_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."user_device_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."user_devices" TO "anon";
GRANT ALL ON TABLE "public"."user_devices" TO "authenticated";
GRANT ALL ON TABLE "public"."user_devices" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."user_promo_usages" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."user_promo_usages" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."user_promo_usages" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."wallet_audit_logs" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."wallet_audit_logs" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."wallet_audit_logs" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT UPDATE ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT UPDATE ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT UPDATE ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "service_role";







