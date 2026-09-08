-- Migration: Intercity Travel Matching System — reject RPC + passenger double-booking guard
-- Date: 2026-07-17
--
-- Two gaps identified while building the "Travel Together" accept/reject flow on top of the
-- existing intercity_requests negotiation machinery:
--
-- 1. There was no reject path for intercity_requests at all — only accept_intercity_request,
--    accept_intercity_offer and confirm_intercity_booking existed. reject_intercity_offer()
--    mirrors accept_intercity_offer()'s participant-authorization pattern and simply flips
--    status to 'rejected'; the existing on_intercity_request_change() trigger (updated in
--    20260717000009) already fires on any status UPDATE, so no notification call is needed here
--    — reusing that single existing notification pipe rather than adding a second one.
--
-- 2. The "one active order at a time" guard existed only for the rider (traveller) side, in both
--    accept_intercity_request() and confirm_intercity_booking(). Neither ever checked whether the
--    passenger (order.user_id) already had another order in-flight, so two riders could both end
--    up confirmed against the same passenger. This adds the symmetric passenger-side check using
--    the exact same status list convention already used for the rider-side check.

-- 1. Reject RPC
CREATE OR REPLACE FUNCTION public.reject_intercity_offer(
    p_request_id uuid,
    p_actor_type text
)
RETURNS jsonb AS $$
DECLARE
    v_request RECORD;
    v_is_participant boolean;
BEGIN
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found';
    END IF;

    SELECT (
        v_request.sender_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.riders r
            WHERE r.id = v_request.traveller_id AND r.user_id = auth.uid()
        )
    ) INTO v_is_participant;

    IF NOT v_is_participant THEN
        RAISE EXCEPTION 'Not authorized to act on this request';
    END IF;

    IF p_actor_type NOT IN ('sender', 'traveller') THEN
        RAISE EXCEPTION 'Invalid actor type: %', p_actor_type;
    END IF;

    IF v_request.status IN ('confirmed', 'paid', 'expired', 'cancelled', 'rejected') THEN
        RETURN json_build_object('success', true, 'status', v_request.status)::jsonb;
    END IF;

    -- Stash who rejected so on_intercity_request_change() can notify only the opposite
    -- party (Part 14), instead of also notifying the actor who just performed the reject.
    UPDATE public.intercity_requests
    SET status = 'rejected',
        metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('rejected_by', p_actor_type),
        updated_at = now()
    WHERE id = p_request_id;

    RETURN json_build_object('success', true, 'status', 'rejected')::jsonb;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- 2a. Passenger double-booking guard in accept_intercity_request (direct rider-accepts-offer path)
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
    v_passenger_active_count int;
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

    -- 5b. Validate passenger is not already confirmed on another active trip (Part 15)
    SELECT COUNT(*) INTO v_passenger_active_count
    FROM public.orders
    WHERE user_id = v_order.user_id
      AND order_status IN ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing')
      AND id IS DISTINCT FROM v_order.id;

    IF v_passenger_active_count > 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'PASSENGER_ALREADY_CONFIRMED',
            'message', 'Passenger already confirmed another trip.'
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

-- 2b. Passenger double-booking guard in confirm_intercity_booking (mutual-agreement path)
CREATE OR REPLACE FUNCTION public.confirm_intercity_booking(
    p_request_id uuid
)
RETURNS jsonb AS $$
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
    v_order_user_id uuid;
    v_used_weight_kg NUMERIC;
    v_passenger_active_count INT;
    v_metadata jsonb;
    v_is_participant boolean;
BEGIN
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found';
    END IF;

    SELECT (
        v_request.sender_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.riders r
            WHERE r.id = v_request.traveller_id AND r.user_id = auth.uid()
        )
    ) INTO v_is_participant;

    IF NOT v_is_participant THEN
        RAISE EXCEPTION 'Not authorized to act on this request';
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

    SELECT actual_weight_kg, order_type, pickup_city, destination_city, user_id
    INTO v_order_weight, v_order_type, v_pickup_city, v_dest_city, v_order_user_id
    FROM public.orders
    WHERE id = v_request.parcel_id;

    -- Passenger double-booking guard (Part 15): the passenger on this order must not already
    -- be confirmed on a different active trip, mirroring the rider-side capacity checks above.
    SELECT COUNT(*) INTO v_passenger_active_count
    FROM public.orders
    WHERE user_id = v_order_user_id
      AND order_status IN ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing')
      AND id IS DISTINCT FROM v_request.parcel_id;

    IF v_passenger_active_count > 0 THEN
        RAISE EXCEPTION 'Passenger already confirmed another trip.';
    END IF;

    SELECT COALESCE(SUM(
        COALESCE(
            o.actual_weight_kg,
            COALESCE(NULLIF(regexp_replace(o.weight_category::text, '[^0-9.]', '', 'g'), ''), '0')::numeric
        )
    ), 0.0)
    INTO v_used_weight_kg
    FROM public.orders o
    WHERE o.rider_id = v_request.traveller_id
      AND o.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing', 'rider_at_drop')
      AND o.id IS DISTINCT FROM v_request.parcel_id;

    IF v_plan_weight IS NOT NULL AND v_plan_weight > 0
       AND (v_used_weight_kg + COALESCE(v_order_weight, 0)) > v_plan_weight THEN
        RAISE EXCEPTION 'This travel plan does not have enough remaining weight capacity. (Used: %kg, Adding: %kg, Max: %kg)', v_used_weight_kg, COALESCE(v_order_weight, 0), v_plan_weight;
    END IF;

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
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
