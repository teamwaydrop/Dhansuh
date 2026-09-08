-- Migration: Restrict rider_travel_plans / intercity_requests writes and
-- accept_intercity_request() to Partner Service Mode = 'intercity'.
-- Date: 2026-07-18
--
-- RLS layer: a local-mode rider's authenticated JWT must not be able to
-- create/modify a travel plan or act as a traveller on an intercity_requests
-- row via direct table access, independent of any app/edge-function code.
-- DELETE/SELECT policies are left untouched — removing your own stale plan
-- or viewing existing rows is not a capability grant and doesn't need
-- gating; only INSERT/UPDATE (creating or actively using the intercity
-- capability) are restricted.

-- 1. rider_travel_plans: INSERT policy (base definition: 20260601000007_rider_travel_plans.sql)
DROP POLICY IF EXISTS "Allow riders to insert their own travel plans" ON public.rider_travel_plans;
CREATE POLICY "Allow riders to insert their own travel plans"
ON public.rider_travel_plans
FOR INSERT
TO authenticated
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = rider_travel_plans.rider_id
          AND r.user_id = auth.uid()
          AND r.service_mode = 'intercity'
    )
);

-- 2. rider_travel_plans: UPDATE policy (same base definition)
DROP POLICY IF EXISTS "Allow riders to update their own travel plans" ON public.rider_travel_plans;
CREATE POLICY "Allow riders to update their own travel plans"
ON public.rider_travel_plans
FOR UPDATE
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = rider_travel_plans.rider_id
          AND r.user_id = auth.uid()
          AND r.service_mode = 'intercity'
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = rider_travel_plans.rider_id
          AND r.user_id = auth.uid()
          AND r.service_mode = 'intercity'
    )
);

-- 3. intercity_requests: INSERT policy (base definition: 20260718000003, the
-- live-verified current version — see that migration's header for the drift
-- history). Traveller-side EXISTS subquery gains the service_mode check;
-- sender-side (passenger) predicate is untouched since senders aren't
-- partners.
DROP POLICY IF EXISTS "Allow request participants to create requests" ON public.intercity_requests;
CREATE POLICY "Allow request participants to create requests" ON public.intercity_requests
FOR INSERT TO authenticated
WITH CHECK (
    (
        sender_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.riders r
            WHERE r.id = traveller_id AND r.user_id = auth.uid() AND r.service_mode = 'intercity'
        )
    )
    AND status IN ('request_sent', 'discussion_started')
    AND sender_confirmed = false
    AND traveller_confirmed = false
);

-- 4. intercity_requests: UPDATE policy (same base definition)
DROP POLICY IF EXISTS "Allow request participants to update safe fields" ON public.intercity_requests;
CREATE POLICY "Allow request participants to update safe fields" ON public.intercity_requests
FOR UPDATE TO authenticated
USING (
    sender_id = auth.uid()
    OR EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = traveller_id AND r.user_id = auth.uid() AND r.service_mode = 'intercity'
    )
)
WITH CHECK (
    (
        sender_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.riders r
            WHERE r.id = traveller_id AND r.user_id = auth.uid() AND r.service_mode = 'intercity'
        )
    )
    AND status IN ('request_sent', 'discussion_started', 'in_progress', 'paid')
    AND sender_confirmed = false
    AND traveller_confirmed = false
);

-- 5. accept_intercity_request() RPC: add an explicit service_mode check
-- immediately after the existing rider-profile lookup (step 1), returning
-- the same jsonb-error-return shape this function already uses everywhere
-- else, rather than raising (keeps its established API contract for
-- accept-intercity-request/index.ts, which just forwards {success:false,...}
-- to the client). Base definition: 20260716000007 (search_path hardening of
-- the 20260714000000 body) — every other line preserved byte-for-byte.
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
