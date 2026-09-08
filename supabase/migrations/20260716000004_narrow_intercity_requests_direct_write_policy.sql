-- Migration: Narrow direct client writes on intercity_requests; route the
-- sensitive state transitions through the existing RPCs.
-- Date: 2026-07-16
--
-- The single FOR ALL policy (20260603000001_create_intercity_requests.sql)
-- let the sender or traveller freely UPDATE status/proposed_fare/
-- sender_confirmed/traveller_confirmed directly, even though the safe state
-- machine (row locking, travel-plan capacity checks, weight checks) only
-- lives in accept_intercity_offer()/confirm_intercity_booking()
-- (20260617000001_intercity_workflow_updates.sql). A client writing directly
-- could set status='confirmed' without ever going through those checks.
--
-- Verified against actual app usage (grepped every intercity_requests call
-- site) before narrowing, so legitimate flows keep working:
--   - INSERT always sets status to 'request_sent' (default) or
--     'discussion_started', never sender_confirmed/traveller_confirmed.
--   - The only direct UPDATEs in the app are status -> 'in_progress'
--     (travel_plan_details_screen.dart) and proposed_fare during
--     negotiation (intercity_searching_screen.dart, fare-boost), both while
--     still in 'request_sent'/'discussion_started'/'in_progress'.
--   - sender_confirmed/traveller_confirmed are legacy columns: no Flutter
--     code, RPC, or edge function reads or writes them anywhere in this
--     codebase (superseded by the metadata->>'sender_agreed'/
--     'traveller_agreed' JSONB flags used inside accept_intercity_offer).
--
-- accept_intercity_offer/confirm_intercity_booking are SECURITY INVOKER
-- today and rely entirely on this table's RLS to both authorize the caller
-- and permit their own internal UPDATEs. Since the policy below no longer
-- permits direct writes to 'confirmed'/'paid'/'completed', those functions
-- are redefined as SECURITY DEFINER (bypassing RLS for their own writes)
-- with an explicit participant check added so removing the implicit
-- RLS-based authorization doesn't open a new hole.

DROP POLICY IF EXISTS "Allow request participants to read/write" ON public.intercity_requests;

-- 1. SELECT: unchanged participant visibility.
CREATE POLICY "Allow request participants to view requests" ON public.intercity_requests
FOR SELECT TO authenticated
USING (
    sender_id = auth.uid()
    OR EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = traveller_id AND r.user_id = auth.uid()
    )
);

-- 2. INSERT: participant predicate, restricted to the safe initial statuses
-- and leaving the legacy confirmation flags at their default.
CREATE POLICY "Allow request participants to create requests" ON public.intercity_requests
FOR INSERT TO authenticated
WITH CHECK (
    (
        sender_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.riders r
            WHERE r.id = traveller_id AND r.user_id = auth.uid()
        )
    )
    AND status IN ('request_sent', 'discussion_started')
    AND sender_confirmed = false
    AND traveller_confirmed = false
);

-- 3. UPDATE: participant predicate, restricted to the specific safe direct
-- transitions/columns. Confirmation ('confirmed'/'paid'/'completed') must
-- go through accept_intercity_offer()/confirm_intercity_booking().
CREATE POLICY "Allow request participants to update safe fields" ON public.intercity_requests
FOR UPDATE TO authenticated
USING (
    sender_id = auth.uid()
    OR EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = traveller_id AND r.user_id = auth.uid()
    )
)
WITH CHECK (
    (
        sender_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.riders r
            WHERE r.id = traveller_id AND r.user_id = auth.uid()
        )
    )
    AND status IN ('request_sent', 'discussion_started', 'in_progress')
    AND sender_confirmed = false
    AND traveller_confirmed = false
);

-- 4. Redefine accept_intercity_offer as SECURITY DEFINER with an explicit
-- participant check (previously provided implicitly by the now-removed
-- permissive RLS policy).
CREATE OR REPLACE FUNCTION public.accept_intercity_offer(
    p_request_id uuid,
    p_actor_type text
)
RETURNS jsonb AS $$
DECLARE
    v_request RECORD;
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Redefine confirm_intercity_booking the same way.
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
$$ LANGUAGE plpgsql SECURITY DEFINER;
