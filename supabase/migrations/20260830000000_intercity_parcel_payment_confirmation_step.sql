-- Migration: Issue 5 -- intercity parcel delivery had no payment confirmation step. The traveller
-- entered the delivery OTP and the order went straight from 'rider_at_drop' to 'delivered',
-- running full settlement (fare, commission, GST, tax-due, wallet credit) automatically, with no
-- explicit "Payment Received?" confirmation from the traveller at all -- unlike local rides and
-- local parcels, which already stop at 'payment_pending' and require the driver to explicitly
-- confirm (via the existing "Confirm Payment Received" swipe sheet in
-- rider_active_order_screen.dart) before settlement runs.
--
-- ROOT CAUSE (confirmed via live function inspection, not assumed):
-- complete_intercity_parcel_delivery(p_order_id, p_delivery_otp) did BOTH the OTP verification AND
-- the full settlement/completion in one atomic call, transitioning 'rider_at_drop' -> 'delivered'
-- directly -- it never passed through 'payment_pending' at all, so the payment-confirmation UI
-- that already exists for every other order type had nothing to attach to for this one.
--
-- FIX: split into two steps, mirroring the existing local ride/parcel pattern exactly:
--   1. complete_intercity_parcel_delivery() (same name, same call site, same parameters --
--      no client change needed for the OTP-entry step itself) now ONLY verifies the OTP and
--      moves 'rider_at_drop' -> 'payment_pending'. No settlement runs here anymore.
--   2. confirm_intercity_parcel_payment_received(p_order_id) -- NEW -- requires order_status =
--      'payment_pending' and runs the exact same settlement logic complete_intercity_parcel_
--      delivery() used to run inline (fare breakdown via calculate_fare_breakdown, subscription
--      commission waiver, government tax-due application, COD share, credit_rider_for_completed_
--      order, intercity_requests/rider_travel_plans completion sync), reproduced byte-for-byte,
--      only now gated behind this explicit second call -- 'payment_pending' -> 'delivered'.
--
-- FINANCIAL/SETTLEMENT GUARDS: completely unchanged. Both functions still use the same
-- set_config('app.bypass_order_state_guard'/'app.bypass_rider_financial_guard'/
-- 'app.bypass_financial_guard', ...) pattern as the original single function -- nothing here
-- weakens or bypasses protect_order_financial_columns/protect_order_state_columns/
-- protect_rider_financial_columns. The authoritative fare (v_fare := COALESCE(v_order.final_fare,
-- v_order.current_fare, 0)) is read in confirm_intercity_parcel_payment_received exactly as it was
-- in the original function -- final_fare already reflects any boost-order-fare price increase, so
-- this was already correct and is preserved as-is, not changed by this migration.
--
-- CLIENT: rider_active_order_screen.dart's updateStatus() now routes intercity_parcel's
-- payment_pending -> delivered transition through this new RPC instead of the generic
-- update-order-status edge function (which does not run these intercity-specific settlement side
-- effects -- see that function's own comment for the prior dual-completion-path bug this avoids
-- reintroducing), reusing the EXISTING "Confirm Payment Received" swipe-to-confirm sheet UI
-- unchanged (cash/personal_upi collection sheets, reference-number entry, timeout reconciliation)
-- -- no new screen or duplicated UI was built for this.

-- =====================================================================================
-- 1. complete_intercity_parcel_delivery() -- OTP verification only, no settlement.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.complete_intercity_parcel_delivery(p_order_id uuid, p_delivery_otp text)
RETURNS jsonb AS $$
DECLARE
    v_rider RECORD;
    v_order RECORD;
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

    -- Issue 5 fix: idempotent on the new intermediate step too -- a retried OTP-verify call after
    -- the order already reached payment_pending is a safe no-op, not an error.
    IF v_order.order_status::text = 'payment_pending' THEN
        RETURN jsonb_build_object('success', true, 'code', 'AWAITING_PAYMENT_CONFIRMATION', 'order_id', v_order.id);
    END IF;

    IF v_order.order_status::text <> 'rider_at_drop' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Mark arrival at drop-off and generate the completion OTP first.');
    END IF;

    IF v_order.delivery_otp IS NULL OR p_delivery_otp IS NULL OR v_order.delivery_otp <> p_delivery_otp THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_OTP', 'message', 'Invalid delivery OTP. Please check with the receiver and try again.');
    END IF;

    PERFORM set_config('app.bypass_order_state_guard', 'true', true);

    UPDATE public.orders
    SET order_status = 'payment_pending'::public.order_status_enum,
        updated_at = v_now
    WHERE id = v_order.id
      AND order_status = 'rider_at_drop';

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'CONFLICT', 'message', 'Order status changed by another request. Please retry.');
    END IF;

    INSERT INTO public.order_status_history (order_id, previous_status, new_status, changed_by, changed_by_rider_id, changed_by_user_id)
    VALUES (v_order.id, 'rider_at_drop', 'payment_pending', 'rider', v_rider.id, v_rider.user_id);

    RETURN jsonb_build_object('success', true, 'code', 'AWAITING_PAYMENT_CONFIRMATION', 'order_id', v_order.id);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- =====================================================================================
-- 2. confirm_intercity_parcel_payment_received() -- NEW. The traveller's explicit "Payment
--    Received" confirmation. Settlement logic reproduced byte-for-byte from the original
--    complete_intercity_parcel_delivery(), only now gated behind order_status = 'payment_pending'
--    and reached via a separate, explicit call instead of running automatically after OTP entry.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.confirm_intercity_parcel_payment_received(p_order_id uuid)
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

    IF v_order.order_status::text <> 'payment_pending' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Verify the delivery OTP before confirming payment.');
    END IF;

    SELECT (
        v_rider.subscription_active IS TRUE
        AND v_rider.subscription_expires_at IS NOT NULL
        AND v_rider.subscription_expires_at > v_now
    ) INTO v_has_active_subscription;

    -- Authoritative fare: final_fare already reflects any boost-order-fare price increase.
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
        UPDATE public.rider_travel_plans
        SET status = 'completed'
        WHERE rider_id = v_rider.id
          AND status = 'active'
          AND pickup_city = v_order.pickup_city
          AND destination_city = v_order.destination_city;
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
