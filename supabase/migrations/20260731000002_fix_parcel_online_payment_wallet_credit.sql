-- =====================================================================
-- P0 FIX: parcel payment_mode='online' could complete delivery and credit the
-- driver's wallet as if Cashfree had collected the fare, even though no
-- Cashfree payment was ever created or verified for parcels (no
-- payment_pending gate exists for parcels, and no client codepath calls
-- create-payment/create-fare-qr for a parcel order).
-- =====================================================================
-- ROOT CAUSE: v_is_direct_collection fell back to
-- `v_payment_mode IN ('cash', 'upi')` whenever fare_payment_method was unset
-- (always true for parcels) -- 'online' matched neither, so it defaulted to
-- FALSE ("platform collected"), crediting the wallet with zero real payment
-- ever having occurred. The identical pattern in
-- supabase/functions/update-order-status/index.ts (local parcels + rides) is
-- fixed in the same deploy as this migration.
--
-- FIX: 'online' (or anything else unmatched) is only ever treated as
-- platform-collected if the order's payment_status is ALREADY 'paid' --
-- which can only happen via a real, server-verified Cashfree
-- webhook/verify-payment success (never client-trusted, never set by this
-- function). cash/upi behavior is unchanged (the added condition is
-- OR'd after them, so short-circuits identically to before for those two
-- values). No other logic in this function is touched.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.complete_intercity_parcel_delivery(
    p_order_id uuid,
    p_delivery_otp text
)
RETURNS jsonb AS $$
DECLARE
    v_rider RECORD;
    v_order RECORD;
    v_has_active_subscription boolean;
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

    IF v_order.order_status::text <> 'rider_at_drop' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Mark arrival at drop-off and generate the completion OTP first.');
    END IF;

    IF v_order.delivery_otp IS NULL OR p_delivery_otp IS NULL OR v_order.delivery_otp <> p_delivery_otp THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_OTP', 'message', 'Invalid delivery OTP. Please check with the receiver and try again.');
    END IF;

    SELECT (
        v_rider.subscription_active IS TRUE
        AND v_rider.subscription_expires_at IS NOT NULL
        AND v_rider.subscription_expires_at > v_now
    ) INTO v_has_active_subscription;

    v_fare := COALESCE(v_order.final_fare, v_order.current_fare, 0);
    IF v_fare <= 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order has no payable fare.');
    END IF;

    v_promo_discount := GREATEST(0, COALESCE(v_order.current_fare, 0) - COALESCE(v_order.final_fare, v_order.current_fare, 0));
    v_commission_pct := CASE WHEN v_has_active_subscription THEN 0 ELSE COALESCE(v_order.commission_percentage, 0) END;

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

    v_payment_mode := lower(COALESCE(v_order.payment_mode, 'cash'));
    v_fare_method := v_order.fare_payment_method::text;
    -- P0 FIX: 'online' (or any unmatched payment_mode) is only ever treated as
    -- platform-collected if payment_status is already 'paid' -- i.e. a real, server-verified
    -- Cashfree payment actually exists for this order. Never fabricate wallet credit for an
    -- online payment that was never made.
    v_is_direct_collection := CASE
        WHEN v_fare_method IS NOT NULL THEN v_fare_method IN ('personal_upi', 'cash')
        ELSE (v_payment_mode IN ('cash', 'upi') OR v_order.payment_status::text IS DISTINCT FROM 'paid')
    END;

    v_rider_net_earning := v_rider_earning;
    v_company_cod_share := ROUND(v_commission_amount + v_gst_amount, 2);

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

    -- This single UPDATE touches columns guarded by BOTH protect_order_financial_columns
    -- (commission_amount/gst_amount/rider_earning/payment_status) AND the new
    -- protect_order_state_columns (order_status) -- both bypass flags are required, or this
    -- would be blocked by whichever guard doesn't see its flag set.
    PERFORM set_config('app.bypass_financial_guard', 'true', true);
    PERFORM set_config('app.bypass_order_state_guard', 'true', true);

    UPDATE public.orders
    SET order_status = 'delivered'::public.order_status_enum,
        commission_amount = v_commission_amount,
        gst_amount = v_gst_amount,
        rider_earning = v_rider_earning,
        subscription_commission_waived = v_has_active_subscription,
        payment_status = CASE WHEN v_is_direct_collection THEN 'paid'::public.payment_status_enum ELSE payment_status END,
        completed_at = v_now,
        updated_at = v_now
    WHERE id = v_order.id
      AND order_status = 'rider_at_drop';

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
          AND o.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop')
    ) THEN
        UPDATE public.rider_travel_plans
        SET status = 'completed'
        WHERE rider_id = v_rider.id
          AND status = 'active'
          AND pickup_city = v_order.pickup_city
          AND destination_city = v_order.destination_city;
    END IF;

    INSERT INTO public.order_status_history (order_id, previous_status, new_status, changed_by, changed_by_rider_id, changed_by_user_id)
    VALUES (v_order.id, 'rider_at_drop', 'delivered', 'rider', v_rider.id, v_rider.user_id);

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
