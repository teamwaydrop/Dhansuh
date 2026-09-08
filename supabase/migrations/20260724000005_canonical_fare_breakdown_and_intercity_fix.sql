-- Migration: Canonical server-side fare-breakdown calculation, reused by every place that ever
-- needs to turn "a new total fare" into a full commission/GST/rider-earning breakdown -- and the
-- fix for the one remaining place that was setting current_fare/final_fare without it.
-- Date: 2026-07-24
--
-- CONTEXT: boost-order-fare (the Deno edge function added for the fare-boost-while-searching fix)
-- computes this breakdown inline in TypeScript. Auditing every other place an order's fare
-- changes turned up confirm_intercity_booking(): when both parties agree a negotiated fare in the
-- intercity chat flow, this SECURITY DEFINER function sets orders.current_fare/final_fare to the
-- agreed amount but leaves commission_amount/gst_amount/rider_earning/boost_* exactly as they were
-- computed at booking time (against a different, pre-negotiation fare) -- those columns go stale
-- the moment a fare is renegotiated.
--
-- Fix: extract the "given a new total fare + this order's own rates, compute the full breakdown"
-- formula into ONE canonical SQL function (calculate_fare_breakdown), and have
-- confirm_intercity_booking() call it. boost-order-fare is updated in the same deploy to call this
-- same function via RPC instead of duplicating the formula in TypeScript -- there is now exactly
-- one place, in the database, where this calculation exists.
-- =====================================================================
-- 1. CANONICAL FARE BREAKDOWN CALCULATION
-- Pure function: no table access, no side effects, safe to call from any trusted context.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.calculate_fare_breakdown(
    p_new_total_fare numeric,
    p_actual_fare numeric,
    p_gst_percentage numeric,
    p_commission_percentage numeric,
    p_promo_discount numeric DEFAULT 0
)
RETURNS jsonb AS $$
DECLARE
    v_base_fare numeric;
    v_gst_amount numeric;
    v_boost_amount numeric;
    v_boost_percentage numeric;
    v_boost_rider_earning numeric;
    v_boost_company_earning numeric;
    v_commission_amount numeric;
    v_rider_earning numeric;
    v_final_fare numeric;
BEGIN
    v_base_fare := ROUND(p_new_total_fare / (1 + (COALESCE(p_gst_percentage, 5.0) / 100.0)), 2);
    v_gst_amount := ROUND(p_new_total_fare - v_base_fare, 2);

    -- Signed delta vs. the order's original base fare -- callers that only ever increase the fare
    -- (boost-order-fare) will always see this as positive; confirm_intercity_booking() may see a
    -- negative value if the negotiated fare came in lower than the original estimate, which is a
    -- legitimate outcome of haggling, not an error.
    v_boost_amount := ROUND(v_base_fare - COALESCE(p_actual_fare, 0), 2);
    v_boost_percentage := CASE
        WHEN COALESCE(p_actual_fare, 0) > 0 THEN ROUND((v_boost_amount / p_actual_fare) * 100, 2)
        ELSE 0
    END;
    v_boost_rider_earning := ROUND(v_boost_amount * 0.80, 2);
    v_boost_company_earning := ROUND(v_boost_amount * 0.20, 2);

    v_commission_amount := ROUND(v_base_fare * (COALESCE(p_commission_percentage, 0) / 100.0), 2);
    v_rider_earning := ROUND(v_base_fare - v_commission_amount, 2);

    v_final_fare := GREATEST(0, ROUND(p_new_total_fare - COALESCE(p_promo_discount, 0), 2));

    RETURN jsonb_build_object(
        'current_fare', p_new_total_fare,
        'final_fare', v_final_fare,
        'gst_amount', v_gst_amount,
        'boost_amount', v_boost_amount,
        'boost_percentage', v_boost_percentage,
        'boost_rider_earning', v_boost_rider_earning,
        'boost_company_earning', v_boost_company_earning,
        'commission_amount', v_commission_amount,
        'rider_earning', v_rider_earning
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.calculate_fare_breakdown(numeric, numeric, numeric, numeric, numeric) TO authenticated, service_role;

-- =====================================================================
-- 2. protect_order_financial_columns(): allow a narrow, explicit, transaction-local bypass for
-- trusted SECURITY DEFINER functions (like confirm_intercity_booking() below) that legitimately
-- need to update these columns on behalf of an 'authenticated' caller after doing their own
-- participant/authorization checks -- auth.role() alone can't distinguish "called via a trusted,
-- already-authorized RPC" from "a raw direct PATCH", since SECURITY DEFINER doesn't change what
-- auth.role() reports (it reflects the original request's role, not the function owner's).
-- =====================================================================
CREATE OR REPLACE FUNCTION public.protect_order_financial_columns()
RETURNS TRIGGER AS $$
BEGIN
    IF auth.role() <> 'service_role'
       AND current_setting('app.bypass_financial_guard', true) IS DISTINCT FROM 'true'
    THEN
        IF NEW.commission_amount IS DISTINCT FROM OLD.commission_amount
           OR NEW.gst_amount IS DISTINCT FROM OLD.gst_amount
           OR NEW.rider_earning IS DISTINCT FROM OLD.rider_earning
           OR NEW.commission_percentage IS DISTINCT FROM OLD.commission_percentage
           OR NEW.gst_percentage IS DISTINCT FROM OLD.gst_percentage
           OR NEW.actual_fare IS DISTINCT FROM OLD.actual_fare
           OR NEW.boost_rider_earning IS DISTINCT FROM OLD.boost_rider_earning
           OR NEW.boost_company_earning IS DISTINCT FROM OLD.boost_company_earning
        THEN
            RAISE EXCEPTION 'Direct modification of order financial columns is not permitted. Use the appropriate server-side function.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- =====================================================================
-- 3. confirm_intercity_booking(): recompute the full fare breakdown from the agreed fare instead
-- of only setting current_fare/final_fare. Base definition: 20260718000007. Every other line
-- (capacity checks, double-booking guard, weight capacity, snapshot metadata) preserved exactly.
-- =====================================================================
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
    v_order_actual_fare NUMERIC;
    v_order_current_fare NUMERIC;
    v_order_final_fare NUMERIC;
    v_order_gst_percentage NUMERIC;
    v_order_commission_percentage NUMERIC;
    v_promo_discount NUMERIC;
    v_breakdown jsonb;
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
      AND status IN ('confirmed', 'paid', 'in_progress')
      AND id IS DISTINCT FROM p_request_id;

    IF v_active_bookings >= v_max_bookings THEN
        RAISE EXCEPTION 'This travel plan is fully booked. (Current: %, Max limit: %)', v_active_bookings, v_max_bookings;
    END IF;

    SELECT actual_weight_kg, order_type, pickup_city, destination_city, user_id,
           actual_fare, current_fare, final_fare, gst_percentage, commission_percentage
    INTO v_order_weight, v_order_type, v_pickup_city, v_dest_city, v_order_user_id,
         v_order_actual_fare, v_order_current_fare, v_order_final_fare, v_order_gst_percentage, v_order_commission_percentage
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

    -- Preserve any promo discount already locked in (final_fare is only ever current_fare minus a
    -- promo discount, otherwise equal to it) and recompute the FULL breakdown for the newly agreed
    -- fare via the same canonical calculation boost-order-fare uses -- never just current_fare/
    -- final_fare alone, which is exactly what left commission_amount/gst_amount/rider_earning
    -- stale before this fix.
    v_promo_discount := GREATEST(0, COALESCE(v_order_current_fare, 0) - COALESCE(v_order_final_fare, v_order_current_fare, 0));
    v_breakdown := public.calculate_fare_breakdown(
        v_request.proposed_fare,
        v_order_actual_fare,
        v_order_gst_percentage,
        v_order_commission_percentage,
        v_promo_discount
    );

    PERFORM set_config('app.bypass_financial_guard', 'true', true);

    UPDATE public.orders
    SET order_status = 'accepted'::public.order_status_enum,
        rider_id = v_request.traveller_id,
        current_fare = (v_breakdown->>'current_fare')::numeric,
        final_fare = (v_breakdown->>'final_fare')::numeric,
        gst_amount = (v_breakdown->>'gst_amount')::numeric,
        boost_amount = (v_breakdown->>'boost_amount')::numeric,
        boost_percentage = (v_breakdown->>'boost_percentage')::numeric,
        boost_rider_earning = (v_breakdown->>'boost_rider_earning')::numeric,
        boost_company_earning = (v_breakdown->>'boost_company_earning')::numeric,
        commission_amount = (v_breakdown->>'commission_amount')::numeric,
        rider_earning = (v_breakdown->>'rider_earning')::numeric,
        updated_at = now()
    WHERE id = v_request.parcel_id;

    RETURN json_build_object('success', true, 'status', 'confirmed')::jsonb;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
