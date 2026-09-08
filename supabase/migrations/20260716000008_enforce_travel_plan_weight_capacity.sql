-- Migration: Enforce travel-plan weight capacity in confirm_intercity_booking,
-- and harden both intercity RPCs with SET search_path = public.
-- Date: 2026-07-16
--
-- M10: confirm_intercity_booking() snapshotted max_weight_kg and
-- actual_weight_kg into metadata but never compared them — only the
-- booking-count cap was enforced, even though a display-only capacity view
-- (public.travel_plan_capacity_view, 20260622000002_smart_matching_final_
-- production.sql) already computes a rider's currently-committed weight the
-- same way. This adds the same weight-capacity check as a hard gate before
-- confirming, reusing that view's exact weight-parsing logic (actual_weight_kg
-- falling back to a parsed weight_category) and the same "active order"
-- status set.
--
-- M12: accept_intercity_offer() and confirm_intercity_booking() were made
-- SECURITY DEFINER in 20260716000004_narrow_intercity_requests_direct_write_
-- policy.sql (this session's M9 fix) but didn't yet have SET search_path =
-- public. Adding it here rather than in the general hardening migration
-- (20260716000007) to avoid two competing redefinitions of the same
-- functions landing in the same batch.
--
-- accept_intercity_offer has no weight-relevant logic, so only the
-- search_path hardening applies to it; its behavior is otherwise unchanged.

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
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

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
    v_used_weight_kg NUMERIC;
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

    -- M10: enforce weight capacity alongside the booking-count check above,
    -- mirroring public.travel_plan_capacity_view's own weight computation
    -- (actual_weight_kg falling back to a parsed weight_category), summed
    -- across the rider's other currently-active orders.
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
