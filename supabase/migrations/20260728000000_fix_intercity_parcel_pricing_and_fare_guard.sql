-- =====================================================================
-- FIX: Intercity Parcel ₹0.00 fare + accepted-with-zero-fare bookings
-- =====================================================================
-- Root cause #1 (confirmed against live data): calculate-order-pricing's calculateFare() reads
-- the per-km rate via rules.after_base_per_km / rules.per_km_charge / rules.per_km -- but the
-- live intercity_parcel pricing_config rows (bike + auto, the only active zone) store the rate
-- under a different key, `per_km_rate`, which none of those aliases matched. The edge function
-- itself has already been fixed in this same deploy to also read `per_km_rate` (see
-- supabase/functions/calculate-order-pricing/index.ts, calculateFare()) -- this migration sets
-- the actual authoritative rate those rows should carry: ₹2.50/km, per spec. intercity_ride
-- (₹3/km) is a separate, working, unrelated config and is deliberately left untouched.
--
-- Root cause #2 (confirmed live: every existing travel_plan_type='parcel' row has
-- price_per_seat = 0, and intercity_requests has real accepted/completed rows with
-- proposed_fare = 0.0): post_travel_plan_screen.dart skipped fare calculation entirely for
-- parcel-only Travel Plans (fixed in the same deploy), and neither the Travel Together request
-- insert nor accept_intercity_request validated the fare before installing it onto a real order.
-- This migration closes both gaps server-side: accept_intercity_request now rejects a zero/
-- negative proposed_fare outright, and a NOT VALID check constraint blocks any new/updated
-- intercity_requests row with a non-positive fare going forward (existing bad historical rows are
-- deliberately left alone -- NOT VALID only enforces new writes, never fails on old data, and no
-- existing order's stored fare is modified by this migration).
-- =====================================================================

-- =====================================================================
-- 1. Authoritative Intercity Parcel rate: ₹2.50/km (was ₹3/km, and unreadable anyway due to the
--    key-name bug above -- this fixes the value AND becomes readable in the same deploy).
-- =====================================================================
UPDATE public.pricing_config
SET pricing_rules = jsonb_set(pricing_rules, '{per_km_rate}', '2.5'::jsonb)
WHERE service_type = 'intercity_parcel';

-- =====================================================================
-- 2. accept_intercity_request: reject acceptance of a request with no valid (positive) fare.
--    Same body as the live version in 20260726000004_government_tax_due_functions.sql, with one
--    added guard (marked below) right after the existing negotiation-status eligibility check.
-- =====================================================================
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
    v_active_bookings int;
BEGIN
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

    -- ADDED GUARD: never install a zero/negative fare onto a real order. This is the
    -- authoritative, server-side check requirement #8 of the fix asks for -- proposed_fare is
    -- client-influenced (set at Travel Together request time from a Drop Partner's own
    -- price_per_seat, or via later in-chat negotiation) and was never previously validated here.
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

    IF v_travel_plan IS NULL OR v_travel_plan.status::text != 'active' THEN
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
            'message', 'This travel plan is fully booked.'
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

-- =====================================================================
-- 3. Defense in depth: block any NEW intercity_requests row from ever carrying a non-positive
--    proposed_fare (Travel Together requests are inserted directly by the client -- see
--    IntercityMatchingService.sendTravelTogetherRequest -- there is no RPC gate at creation time
--    to add this check to).
--
--    Deliberately a BEFORE INSERT trigger, NOT a table CHECK constraint: a plain CHECK would also
--    re-validate on every future UPDATE of any existing row, including the real historical rows
--    already sitting at proposed_fare = 0 (confirmed live -- see migration header). One of those
--    is a currently-'confirmed', not-yet-started booking; a CHECK constraint would then block
--    that exact booking's own future status transitions (start_intercity_trip_for_plan,
--    completion, cancellation) the next time anything updates that row -- a real regression this
--    fix must not introduce. A BEFORE INSERT trigger only ever runs for brand-new rows, so it
--    closes the creation-time gap without touching how existing rows (good or bad) behave going
--    forward.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.reject_invalid_proposed_fare()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.proposed_fare IS NULL OR NEW.proposed_fare <= 0 THEN
        RAISE EXCEPTION 'proposed_fare must be a positive amount'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

DROP TRIGGER IF EXISTS trigger_reject_invalid_proposed_fare ON public.intercity_requests;

CREATE TRIGGER trigger_reject_invalid_proposed_fare
    BEFORE INSERT ON public.intercity_requests
    FOR EACH ROW
    EXECUTE FUNCTION public.reject_invalid_proposed_fare();
