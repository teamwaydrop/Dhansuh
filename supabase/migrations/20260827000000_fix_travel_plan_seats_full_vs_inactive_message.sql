-- Migration: Issue 2 -- misleading "Travel plan is no longer active" shown when a plan is actually
-- just fully booked (one seat left, two requests, accepting the second after the first).
--
-- ROOT CAUSE (confirmed via live schema/trigger inspection, not assumed):
-- rider_travel_plans.status has a distinct 'fully_booked' value (travel_plan_status_enum, added in
-- 20260617000001_intercity_workflow_updates.sql), which a trigger in that same migration sets
-- automatically once a travel plan's active bookings reach max_bookings, and revives back to
-- 'active' if a seat frees up again -- 'fully_booked' is a transient, seat-driven state, distinct
-- from the genuinely terminal ones (cancelled/completed/expired).
--
-- accept_intercity_request()'s existing guard is:
--     IF v_travel_plan IS NULL OR v_travel_plan.status::text != 'active' THEN
--         RETURN ... 'TRAVEL_PLAN_INACTIVE' ... 'Travel plan is no longer active.'
--     END IF;
--     ... (seat-count check, further below, would return 'PLAN_FULLY_BOOKED' /
--     'This travel plan is fully booked.')
-- Once the first request is accepted and the plan flips to 'fully_booked', this guard's
-- `!= 'active'` condition is satisfied by that status too, so accepting a second request always
-- short-circuits into the wrong, misleading TRAVEL_PLAN_INACTIVE branch -- the correct
-- PLAN_FULLY_BOOKED branch a few lines below it is never reached once a plan has ever filled up.
--
-- FIX: the inactive-plan guard now excludes 'fully_booked' explicitly, letting it fall through to
-- the existing seat-count check instead -- which already returns the correct, distinct
-- PLAN_FULLY_BOOKED / "This travel plan is fully booked." response. Every other clause in this
-- function (auth, service_mode, tax-due, request/order/OTP validation, the FOR UPDATE row lock on
-- rider_travel_plans that keeps this race-safe, rider_is_on_active_trip, passenger conflict check)
-- is reproduced byte-for-byte from the live definition -- only this one guard condition changes.
--
-- RACE SAFETY: unchanged. `SELECT * FROM rider_travel_plans WHERE id = v_request.route_id FOR
-- UPDATE` already locks the plan row for the duration of this transaction, so two concurrent
-- accept_intercity_request() calls for the same plan still serialize on that lock -- the second
-- caller's v_active_bookings count is always read after the first caller's UPDATE (or rollback) is
-- visible, so it can never see a stale, under-counted total and can never overbook.

CREATE OR REPLACE FUNCTION public.accept_intercity_request(p_request_id uuid, p_rider_user_id uuid)
RETURNS jsonb AS $$
DECLARE
    v_request RECORD;
    v_order RECORD;
    v_rider RECORD;
    v_travel_plan RECORD;
    v_otp text;
    v_active_bookings int;
BEGIN
    -- SECURITY (new): reject impersonation on any direct/authenticated RPC call. No-op
    -- for the Edge Function's service-role call path (auth.uid() is NULL there).
    IF auth.uid() IS NOT NULL AND auth.uid() != p_rider_user_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'UNAUTHORIZED',
            'message', 'You are not authorized to accept this request.'
        );
    END IF;

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

    IF v_rider.service_mode IS DISTINCT FROM 'intercity'::public.partner_service_mode_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'WRONG_SERVICE_MODE',
            'message', 'Switch to Intercity Traveller mode to accept this request.'
        );
    END IF;

    -- GOVERNMENT TAX DUE: a rider at/above the configured threshold cannot accept new work
    -- through this path either -- the block applies to all new assignments, not just local ones.
    IF public.is_rider_blocked_by_tax_due(v_rider.id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'TAX_DUE_THRESHOLD_BLOCKED',
            'message', 'New orders are paused because your Government Tax Due has reached the limit. Pay the due amount to continue receiving orders.'
        );
    END IF;

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

    IF v_request.traveller_id != v_rider.id THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Request does not belong to this traveller.'
        );
    END IF;

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

    IF v_order.rider_id = v_rider.id AND v_order.order_status = 'accepted' THEN
        RETURN jsonb_build_object(
            'success', true,
            'code', 'ALREADY_ACCEPTED',
            'order_id', v_order.id,
            'request_id', v_request.id
        );
    END IF;

    IF v_order.order_status != 'searching' OR v_order.rider_id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ORDER_ALREADY_ASSIGNED',
            'message', 'Booking no longer available.'
        );
    END IF;

    IF v_order.search_expires_at IS NOT NULL AND v_order.search_expires_at < now() THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REQUEST_EXPIRED',
            'message', 'Order search has expired.'
        );
    END IF;

    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;

    IF v_request.expires_at IS NOT NULL AND v_request.expires_at < now() THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REQUEST_EXPIRED',
            'message', 'Request negotiation has expired.'
        );
    END IF;

    IF v_request.status NOT IN ('request_sent', 'discussion_started', 'fare_agreed') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Request status is not eligible for acceptance.'
        );
    END IF;

    -- Never install a zero/negative fare onto a real order. Server-side check --
    -- proposed_fare is client-influenced (set at Travel Together request time from a Drop
    -- Partner's own price_per_seat, or via later in-chat negotiation) and was never
    -- previously validated here.
    IF v_request.proposed_fare IS NULL OR v_request.proposed_fare <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_FARE',
            'message', 'This request has no valid fare and cannot be accepted. Please ask the sender to resend the request.'
        );
    END IF;

    SELECT * INTO v_travel_plan
    FROM public.rider_travel_plans
    WHERE id = v_request.route_id
    FOR UPDATE;

    -- Issue 2 fix: 'fully_booked' is a distinct, transient, seat-driven status (set/revived
    -- automatically as bookings change -- see 20260617000001), never a genuine
    -- cancelled/completed/expired plan. It must fall through to the seat-count check below
    -- instead of being treated the same as a truly inactive plan here.
    IF v_travel_plan IS NULL OR v_travel_plan.status::text NOT IN ('active', 'fully_booked') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'TRAVEL_PLAN_INACTIVE',
            'message', 'Travel plan is no longer active.'
        );
    END IF;

    SELECT COUNT(*) INTO v_active_bookings
    FROM public.intercity_requests
    WHERE route_id = v_request.route_id
      AND status IN ('confirmed', 'paid', 'in_progress')
      AND id IS DISTINCT FROM p_request_id;

    IF v_active_bookings >= v_travel_plan.max_bookings THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'PLAN_FULLY_BOOKED',
            'message', 'All available seats have already been booked.'
        );
    END IF;

    IF public.rider_is_on_active_trip(v_rider.id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'RIDER_ALREADY_BUSY',
            'message', 'Rider is already handling another active trip.'
        );
    END IF;

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

    LOOP
        v_otp := floor(random() * 9000 + 1000)::text;
        PERFORM 1 FROM public.orders WHERE pickup_otp = v_otp AND order_status IN ('accepted', 'picked_up');
        EXIT WHEN NOT FOUND;
    END LOOP;

    UPDATE public.intercity_requests
    SET status = 'confirmed',
        updated_at = now()
    WHERE id = p_request_id;

    UPDATE public.orders
    SET order_status = 'accepted'::public.order_status_enum,
        rider_id = v_rider.id,
        final_fare = v_request.proposed_fare,
        current_fare = v_request.proposed_fare,
        pickup_otp = v_otp,
        updated_at = now()
    WHERE id = v_order.id;

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
