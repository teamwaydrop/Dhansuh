-- Migration: Fix PASSENGER_ALREADY_CONFIRMED blocking every future booking regardless of date.
-- Date: 2026-07-21
--
-- ROOT CAUSE: accept_intercity_request()'s passenger-busy check (step "5b", introduced in
-- 20260717000005, currently live via 20260720000004) counts ANY orders row for that passenger
-- with order_status IN ('accepted','rider_arrived','picked_up','rider_at_drop','ongoing') as a
-- reason to block -- with zero comparison against either order's travel_date. A passenger who
-- already has a confirmed trip next month is blocked from being invited to a trip tomorrow.
--
-- This is the exact same class of bug that 20260720000004 already fixed for the RIDER side via
-- rider_is_on_active_trip(): "a rider must only be considered busy while a trip is ACTUALLY under
-- way... an intercity job that's merely Waiting for Travel Day (accepted, trip not yet started)
-- must never count as busy". That fix was never mirrored onto the passenger side. This migration
-- applies the identical rule, plus an actual time-window overlap comparison for two scheduled
-- intercity trips (something rider_is_on_active_trip doesn't need, since a rider only ever holds
-- one active trip at a time by construction -- a passenger can legitimately hold multiple future
-- accepted trips as long as they don't overlap).
--
-- FIX: new canonical helper passenger_has_conflicting_trip(), reused the same way
-- rider_is_on_active_trip() is reused elsewhere, so this rule lives in exactly one place:
--   - rider_arrived/picked_up/rider_at_drop/ongoing: always conflicting -- the passenger is
--     physically mid-trip.
--   - accepted + local job: always conflicting -- local jobs are busy the instant accepted (same
--     rule as rider_is_on_active_trip; local rides have no "future scheduled day" concept, they
--     resolve within the hour).
--   - accepted + intercity job: conflicting only if its scheduled window
--     [travel_date, travel_date + estimated_duration_min] actually overlaps the new order's
--     window. Different-day (or otherwise non-overlapping) future bookings are allowed.

CREATE OR REPLACE FUNCTION public.passenger_has_conflicting_trip(
    p_user_id uuid,
    p_exclude_order_id uuid,
    p_new_start timestamptz,
    p_new_end timestamptz
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.orders o
        WHERE o.user_id = p_user_id
          AND o.id IS DISTINCT FROM p_exclude_order_id
          AND (
                o.order_status::text IN ('rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing')
                OR (
                    o.order_status::text = 'accepted'
                    AND (
                        public.get_required_service_mode(o.order_type::text, o.distance_meters) = 'local'
                        OR tstzrange(p_new_start, p_new_end, '[]') && tstzrange(
                            COALESCE(o.travel_date, o.created_at),
                            COALESCE(o.travel_date, o.created_at)
                                + make_interval(mins => COALESCE(o.estimated_duration_min, 240)),
                            '[]'
                        )
                    )
                )
              )
    );
$$;

COMMENT ON FUNCTION public.passenger_has_conflicting_trip(uuid, uuid, timestamptz, timestamptz) IS
    'Canonical "does this passenger have a conflicting trip" check, mirroring rider_is_on_active_trip(). A local order conflicts from acceptance; an intercity order only conflicts if its scheduled [travel_date, travel_date+duration] window overlaps the candidate booking''s window, so non-overlapping future bookings on different dates are always allowed.';

-- Re-declare accept_intercity_request() with only step "5b" changed: every other line is carried
-- over unchanged from 20260720000004_intercity_trip_activity_business_logic.sql.
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

    -- 1b. Service mode gate: only Intercity Traveller-mode partners may
    -- accept intercity requests.
    IF v_rider.service_mode IS DISTINCT FROM 'intercity'::public.partner_service_mode_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'WRONG_SERVICE_MODE',
            'message', 'Switch to Intercity Traveller mode to accept this request.'
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

    -- 5. Validate rider is not currently occupied by an ACTIVE trip (not merely a future
    -- "Waiting for Travel Day" acceptance -- see rider_is_on_active_trip()).
    IF public.rider_is_on_active_trip(v_rider.id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'RIDER_ALREADY_BUSY',
            'message', 'Rider is already handling another active trip.'
        );
    END IF;

    -- 5b. Validate the passenger doesn't have a conflicting trip -- a local job is busy the
    -- moment it's accepted, an intercity job only conflicts if its scheduled window overlaps this
    -- order's window. Different-date future bookings must be allowed (previously ANY 'accepted'
    -- order blocked every future booking regardless of date -- see
    -- passenger_has_conflicting_trip()).
    IF public.passenger_has_conflicting_trip(
        v_order.user_id,
        v_order.id,
        COALESCE(v_order.travel_date, v_order.created_at),
        COALESCE(v_order.travel_date, v_order.created_at)
            + make_interval(mins => COALESCE(v_order.estimated_duration_min, 240))
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'PASSENGER_ALREADY_CONFIRMED',
            'message', 'Passenger already has a conflicting trip at this time.'
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
