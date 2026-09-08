-- =====================================================================
-- SECURITY FIX: accept_intercity_request() has no caller-identity check of its own.
-- =====================================================================
-- accept_intercity_request(p_request_id, p_rider_user_id) is SECURITY DEFINER and has
-- never had an explicit GRANT/REVOKE recorded in any migration (confirmed via grep
-- across supabase/migrations) -- so it still carries Postgres's default EXECUTE-TO-PUBLIC
-- grant. The intended caller, supabase/functions/accept-intercity-request/index.ts,
-- already does this correctly: it authenticates the caller via auth.getUser(token) and
-- passes p_rider_user_id = user.id, derived from the verified JWT, never from the
-- request body.
--
-- But because the RPC itself is directly callable (PostgREST exposes every RPC to
-- `anon`/`authenticated` by default under a PUBLIC grant), any authenticated client can
-- call supabase.rpc('accept_intercity_request', { p_request_id, p_rider_user_id })
-- directly, bypassing the Edge Function entirely, and pass ANY rider's user_id --
-- accepting/confirming a Travel Together request on behalf of a rider who never
-- consented, using only public/guessable identifiers (the request's own traveller_id
-- check only verifies the request belongs to whichever rider p_rider_user_id names, not
-- that the caller IS that rider).
--
-- Same pattern and fix already applied to find_nearby_riders in
-- 20260729000001_find_nearby_riders_security_definer_and_authz.sql: an
-- `auth.uid() IS NOT NULL AND auth.uid() != <claimed identity>` guard, which is a no-op
-- for service-role callers (auth.uid() is NULL with no JWT -- the Edge Function's
-- service-role client is completely unaffected) and only blocks a direct authenticated
-- call impersonating a different rider.
--
-- Function body below is byte-for-byte identical to the live version in
-- 20260728000000_fix_intercity_parcel_pricing_and_fare_guard.sql except for the one
-- added guard immediately after BEGIN. EXECUTE is additionally locked down to
-- service_role only (the only legitimate caller), matching the precedent already set
-- for initiate_withdrawal/fail_withdrawal/complete_withdrawal in
-- 20260530000001_rider_withdrawals.sql.
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

-- EXECUTE lockdown: only the accept-intercity-request Edge Function (service_role) is a
-- legitimate caller. Removing the default PUBLIC grant closes the direct-RPC vector
-- outright; the auth.uid() guard above is defense-in-depth on top of it.
REVOKE EXECUTE ON FUNCTION public.accept_intercity_request(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.accept_intercity_request(uuid, uuid) TO service_role;
