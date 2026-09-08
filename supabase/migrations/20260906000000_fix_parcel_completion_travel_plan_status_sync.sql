-- Migration: fix Intercity PARCEL completion leaving the traveller's Travel Plan stuck on Home.
-- Date: 2026-09-06
--
-- ROOT CAUSE (confirmed by reading the live function definition and every call site):
-- confirm_intercity_parcel_payment_received() (latest definition:
-- 20260901000019_gate_free_trial_waiver_to_local_orders.sql) is the ONLY server-side path that
-- transitions a PARCEL travel plan to 'completed'. It did so with:
--
--     UPDATE public.rider_travel_plans
--     SET status = 'completed'
--     WHERE rider_id = v_rider.id
--       AND status = 'active'                              -- (1)
--       AND pickup_city = v_order.pickup_city              -- (2)
--       AND destination_city = v_order.destination_city;
--
--   (1) A plan is auto-flipped 'active' -> 'fully_booked' by the booking-count trigger
--       (20260617000001_intercity_workflow_updates.sql) the moment confirmed/paid bookings reach
--       max_bookings -- for a single-seat plan that is the FIRST acceptance. So by parcel-delivery
--       completion time the plan is almost never still 'active', the UPDATE matches zero rows, and
--       the plan stays 'fully_booked' forever. rider_home_tab.dart lists plans with
--       status IN ('active','fully_booked'), so the completed trip's plan never leaves Home.
--   (2) With the Via-locations feature the parcel sender frequently books at an intermediate town,
--       so v_order.pickup_city no longer equals the plan's pickup_city and the match never fires.
--
-- This exactly mirrors the same two defects just fixed on the RIDE path in
-- update-order-status/index.ts and client-side in rider_active_order_screen.dart's
-- _deleteMatchingTravelPlan(); this migration applies the equivalent, minimal fix to the PARCEL
-- server path for defense-in-depth (survives the rider's app being killed at completion, RLS
-- edge cases, or the passenger-driven confirmation flow).
--
-- SCOPE: confirm_intercity_parcel_payment_received() ONLY. The function body below is reproduced
-- BYTE-FOR-BYTE from 20260901000019 with a SINGLE change -- the rider_travel_plans UPDATE inside
-- the existing `IF NOT EXISTS (... other in-flight parcel orders ...)` guard. EXPLICITLY NOT
-- TOUCHED: the fare (v_fare / final_fare / current_fare), calculate_fare_breakdown() call,
-- commission / GST / rider_earning / government tax, credit_rider_for_completed_order(),
-- apply_order_government_tax(), the orders UPDATE, rider_assignments expiry, intercity_requests
-- 'completed' sync, order_status_history insert, every guard/bypass set_config, the EXCEPTION
-- handler, SECURITY DEFINER, search_path, and the GRANT. Only which rider_travel_plans rows a
-- status='completed' write targets changes.
--
-- FORWARD-ONLY: CREATE OR REPLACE FUNCTION, no schema change, no data change, no backfill.

CREATE OR REPLACE FUNCTION public.confirm_intercity_parcel_payment_received(p_order_id uuid)
RETURNS jsonb AS $$
DECLARE
    v_rider RECORD;
    v_order RECORD;
    v_fare numeric;
    v_promo_discount numeric;
    v_commission_pct numeric;
    v_breakdown jsonb;
    v_commission_amount numeric;
    v_gst_amount numeric;
    v_rider_earning numeric;
    v_rider_net_earning numeric;
    v_company_cod_share numeric;
    v_payment_mode text;
    v_fare_method text;
    v_is_direct_collection boolean;
    v_tax_result jsonb;
    v_tax_amount numeric;
    v_now timestamptz := now();
BEGIN
    SELECT * INTO v_rider FROM public.riders WHERE user_id = auth.uid();
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Rider profile not found for user.');
    END IF;

    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order not found.');
    END IF;

    IF v_order.order_type::text <> 'intercity_parcel' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This function only completes intercity parcel deliveries.');
    END IF;

    IF v_order.rider_id IS DISTINCT FROM v_rider.id THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This delivery is not assigned to you.');
    END IF;

    IF v_order.order_status::text = 'delivered' THEN
        RETURN jsonb_build_object('success', true, 'code', 'ALREADY_DELIVERED', 'order_id', v_order.id);
    END IF;

    IF v_order.order_status::text <> 'payment_pending' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Verify the delivery OTP before confirming payment.');
    END IF;

    -- Authoritative fare: final_fare already reflects any boost-order-fare price increase.
    v_fare := COALESCE(v_order.final_fare, v_order.current_fare, 0);
    IF v_fare <= 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order has no payable fare.');
    END IF;

    v_promo_discount := GREATEST(0, COALESCE(v_order.current_fare, 0) - COALESCE(v_order.final_fare, v_order.current_fare, 0));

    -- FIX: this function only ever processes order_type = 'intercity_parcel' (enforced above), and
    -- the LOCAL-ONLY free-trial / WayDrop MAX waiver must never apply to it -- see migration
    -- header. Commission is now always the order's actual commission_percentage (standard
    -- intercity parcel rate: 10% commission + 18% GST), regardless of the rider's local
    -- subscription/free-trial state. The old v_has_active_subscription lookup and its use here are
    -- removed entirely.
    v_commission_pct := COALESCE(v_order.commission_percentage, 0);

    v_breakdown := public.calculate_fare_breakdown(
        v_fare,
        COALESCE(v_order.actual_fare, 0),
        COALESCE(v_order.gst_percentage, 5.0),
        v_commission_pct,
        v_promo_discount
    );

    v_commission_amount := (v_breakdown->>'commission_amount')::numeric;
    v_gst_amount := (v_breakdown->>'gst_amount')::numeric;
    v_rider_earning := (v_breakdown->>'rider_earning')::numeric;

    v_payment_mode := lower(COALESCE(v_order.payment_mode::text, 'cash'));
    v_fare_method := v_order.fare_payment_method::text;
    v_is_direct_collection := CASE
        WHEN v_fare_method IS NOT NULL THEN v_fare_method IN ('personal_upi', 'cash')
        ELSE (v_payment_mode IN ('cash', 'upi') OR v_order.payment_status::text IS DISTINCT FROM 'paid')
    END;

    v_rider_net_earning := v_rider_earning;
    v_company_cod_share := ROUND(v_commission_amount + v_gst_amount, 2);

    PERFORM set_config('app.bypass_rider_financial_guard', 'true', true);

    v_tax_result := public.apply_order_government_tax(
        v_order.id,
        v_rider.id,
        v_order.order_type::text,
        v_fare,
        v_is_direct_collection
    );

    IF (v_tax_result->>'applied')::boolean IS TRUE AND NOT v_is_direct_collection THEN
        v_tax_amount := COALESCE((v_tax_result->>'tax_amount')::numeric, 0);
        IF v_tax_amount > 0 THEN
            v_rider_net_earning := ROUND(v_rider_net_earning - v_tax_amount, 2);
        END IF;
    END IF;

    UPDATE public.rider_assignments
    SET assignment_status = 'expired', updated_at = v_now, responded_at = v_now
    WHERE order_id = v_order.id AND rider_id = v_rider.id AND assignment_status = 'accepted';

    PERFORM set_config('app.bypass_financial_guard', 'true', true);
    PERFORM set_config('app.bypass_order_state_guard', 'true', true);

    -- FIX: subscription_commission_waived is always written as false here -- this function can
    -- never legitimately waive commission (see header). Everything else in this UPDATE is
    -- unchanged.
    UPDATE public.orders
    SET order_status = 'delivered'::public.order_status_enum,
        commission_amount = v_commission_amount,
        gst_amount = v_gst_amount,
        rider_earning = v_rider_earning,
        subscription_commission_waived = false,
        payment_status = CASE WHEN v_is_direct_collection THEN 'paid'::public.payment_status_enum ELSE payment_status END,
        completed_at = v_now,
        updated_at = v_now
    WHERE id = v_order.id
      AND order_status = 'payment_pending';

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'CONFLICT', 'message', 'Order status changed by another request. Please retry.');
    END IF;

    PERFORM public.credit_rider_for_completed_order(
        v_rider.id,
        v_rider_net_earning,
        v_is_direct_collection,
        v_company_cod_share
    );

    UPDATE public.intercity_requests
    SET status = 'completed', updated_at = v_now
    WHERE parcel_id = v_order.id
      AND status IN ('confirmed', 'paid', 'in_progress');

    IF NOT EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.rider_id = v_rider.id
          AND o.order_type = 'intercity_parcel'
          AND o.id IS DISTINCT FROM v_order.id
          AND o.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'payment_pending')
    ) THEN
        -- ============================ THE ONLY CHANGE IN THIS MIGRATION ============================
        -- Was:
        --   UPDATE public.rider_travel_plans SET status = 'completed'
        --   WHERE rider_id = v_rider.id AND status = 'active'
        --     AND pickup_city = v_order.pickup_city AND destination_city = v_order.destination_city;
        -- Now: resolve THIS parcel's own plan by its intercity_requests link (route_id) -- Via
        -- senders board at an intermediate town, so the order's pickup_city != the plan's -- and
        -- also transition plans already flipped 'active' -> 'fully_booked' by the booking-count
        -- trigger (20260617000001). Endpoint-city match kept as a fallback, also widened to
        -- 'fully_booked'. No other line of this function changes.
        UPDATE public.rider_travel_plans tp
        SET status = 'completed'
        WHERE tp.rider_id = v_rider.id
          AND tp.status IN ('active', 'fully_booked')
          AND tp.id IN (
              SELECT ir.route_id
              FROM public.intercity_requests ir
              WHERE ir.parcel_id = v_order.id
                AND ir.route_id IS NOT NULL
          );

        IF NOT FOUND THEN
            UPDATE public.rider_travel_plans
            SET status = 'completed'
            WHERE rider_id = v_rider.id
              AND status IN ('active', 'fully_booked')
              AND pickup_city = v_order.pickup_city
              AND destination_city = v_order.destination_city;
        END IF;
        -- =========================================================================================
    END IF;

    INSERT INTO public.order_status_history (order_id, previous_status, new_status, changed_by, changed_by_rider_id, changed_by_user_id)
    VALUES (v_order.id, 'payment_pending', 'delivered', 'rider', v_rider.id, v_rider.user_id);

    RETURN jsonb_build_object(
        'success', true,
        'code', 'SUCCESS',
        'order_id', v_order.id,
        'rider_earning', v_rider_net_earning,
        'commission_amount', v_commission_amount,
        'gst_amount', v_gst_amount
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.confirm_intercity_parcel_payment_received(uuid) TO authenticated;
