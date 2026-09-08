-- Migration: gate the WayDrop free-trial / WayDrop MAX 0% commission waiver to LOCAL orders only.
-- Date: 2026-08-21
--
-- BUSINESS RULE (explicit, verbatim): the 30-day free-trial / 0% WayDrop commission benefit
-- applies ONLY to local rides and local parcels. It must NEVER waive WayDrop commission for
-- intercity passenger rides or intercity parcel deliveries -- those keep their standard rates
-- (intercity passenger ride: 10% commission + 5% GST; intercity parcel delivery: 10% commission +
-- 18% GST) unconditionally, whether or not the rider has an active local free trial / WayDrop MAX
-- subscription.
--
-- ROOT CAUSE: two settlement functions waive commission based purely on
-- riders.subscription_active / subscription_expires_at, with no order_type check at all --
-- meaning an intercity order settled while a rider's LOCAL free trial happens to be active
-- incorrectly gets 0% commission, 0 GST-on-commission adjustment, and a misleading
-- subscription_commission_waived=true flag.
--
-- 1. public.complete_order_and_settle() (20260814000000) -- the general completion path, used by
--    BOTH local ride/parcel completions AND intercity_ride completions (intercity_parcel instead
--    goes through confirm_intercity_parcel_payment_received(), fixed separately below). The only
--    change: the existing `IF v_has_active_subscription THEN` waiver branch gains
--    `AND v_order.order_type::text IN ('ride', 'local_parcel')` -- local order types only. Nothing
--    else in the function changes; a local completion with an active subscription behaves
--    identically to before.
--
-- 2. public.confirm_intercity_parcel_payment_received() (20260830000000) -- already only ever
--    processes order_type = 'intercity_parcel' (enforced at the top of the function), so no
--    order_type check is even needed here -- the fix is to stop deriving commission from
--    v_has_active_subscription at all. v_commission_pct now always uses the order's actual
--    commission_percentage, and subscription_commission_waived is always written as false (this
--    function can never legitimately waive commission). v_has_active_subscription and its lookup
--    are removed entirely since nothing else in the function used them.

CREATE OR REPLACE FUNCTION public.complete_order_and_settle(
    p_order_id uuid,
    p_new_status text,                          -- 'completed' | 'delivered'
    p_previous_status text,                     -- expected current status (optimistic lock)
    p_changed_by text,                          -- already resolved by the caller: changed_by || order.user_id || 'system'
    p_fare_payment_method_to_set text DEFAULT NULL,   -- resolvedDirectSettlementMethod, if any
    p_mark_paid boolean DEFAULT false,                -- isCompleting && isDirectSettlement
    p_stamp_fare_paid_at boolean DEFAULT false,       -- isCompleting && fareMethod IN ('personal_upi','cash')
    p_fare_payment_reference text DEFAULT NULL,
    p_fare_payment_screenshot_url text DEFAULT NULL
)
RETURNS jsonb AS $$
DECLARE
    v_now timestamptz := now();
    v_order RECORD;
    v_rider RECORD;
    v_has_active_subscription boolean;
    v_fare numeric;
    v_rider_earning numeric;
    v_commission_amount numeric;
    v_gst_amount numeric;
    v_breakdown jsonb;
    v_payment_mode text;
    v_fare_method text;
    v_is_direct_collection boolean;
    v_rider_net_earning numeric;
    v_company_cod_share numeric;
    v_tax_result jsonb;
    v_tax_amount numeric;
BEGIN
    -- =====================================================
    -- 1. THE COMPLETION UPDATE ITSELF -- unchanged from 20260814000000.
    -- =====================================================
    UPDATE public.orders
    SET order_status = p_new_status::public.order_status_enum,
        completed_at = v_now,
        updated_at = v_now,
        fare_payment_method = COALESCE(p_fare_payment_method_to_set::public.fare_payment_method_enum, fare_payment_method),
        payment_status = CASE WHEN p_mark_paid THEN 'paid'::public.payment_status_enum ELSE payment_status END,
        fare_paid_at = CASE WHEN p_stamp_fare_paid_at THEN v_now ELSE fare_paid_at END,
        fare_payment_reference = COALESCE(p_fare_payment_reference, fare_payment_reference),
        fare_payment_screenshot_url = COALESCE(p_fare_payment_screenshot_url, fare_payment_screenshot_url)
    WHERE id = p_order_id
      AND order_status = p_previous_status::public.order_status_enum
    RETURNING * INTO v_order;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'CONFLICT', 'message', 'Order status changed by another request. Please retry.');
    END IF;

    IF v_order.rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Rider ID is missing on the order');
    END IF;

    -- =====================================================
    -- 2. SETTLE ACTIVE ACCEPTED ASSIGNMENT -- unchanged.
    -- =====================================================
    UPDATE public.rider_assignments
    SET assignment_status = 'expired', updated_at = v_now, responded_at = v_now
    WHERE order_id = p_order_id AND rider_id = v_order.rider_id AND assignment_status = 'accepted';

    -- =====================================================
    -- 3. RIDER SUBSCRIPTION LOOKUP + WAYDROP MAX COMMISSION WAIVER -- LOCAL ORDERS ONLY.
    -- FIX: added `AND v_order.order_type::text IN ('ride', 'local_parcel')` to the waiver
    -- condition -- see migration header. Everything else in this block is unchanged.
    -- =====================================================
    SELECT subscription_active, subscription_expires_at INTO v_rider
    FROM public.riders WHERE id = v_order.rider_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', format('Rider record not found for ID: %s', v_order.rider_id));
    END IF;

    v_has_active_subscription := (
        v_rider.subscription_active IS TRUE
        AND v_rider.subscription_expires_at IS NOT NULL
        AND v_rider.subscription_expires_at > v_now
    );

    v_fare := COALESCE(v_order.final_fare, v_order.current_fare, 0);
    v_rider_earning := COALESCE(v_order.rider_earning, 0);
    v_commission_amount := COALESCE(v_order.commission_amount, 0);
    v_gst_amount := COALESCE(v_order.gst_amount, 0);

    IF v_has_active_subscription AND v_order.order_type::text IN ('ride', 'local_parcel') THEN
        v_breakdown := public.calculate_fare_breakdown(
            v_fare,
            COALESCE(v_order.actual_fare, 0),
            COALESCE(v_order.gst_percentage, 5.0),
            0,
            0
        );

        v_commission_amount := 0.0;
        v_rider_earning := (v_breakdown->>'rider_earning')::numeric;
        v_gst_amount := (v_breakdown->>'gst_amount')::numeric;

        UPDATE public.orders
        SET commission_amount = 0.0,
            rider_earning = v_rider_earning,
            gst_amount = v_gst_amount,
            subscription_commission_waived = true
        WHERE id = p_order_id;

        v_order.commission_amount := v_commission_amount;
        v_order.rider_earning := v_rider_earning;
        v_order.gst_amount := v_gst_amount;
        v_order.subscription_commission_waived := true;
    END IF;

    -- =====================================================
    -- 4. DIRECT-COLLECTION DETERMINATION -- unchanged.
    -- =====================================================
    v_payment_mode := lower(COALESCE(v_order.payment_mode::text, 'cash'));
    v_fare_method := v_order.fare_payment_method::text;
    v_is_direct_collection := CASE
        WHEN v_fare_method IS NOT NULL THEN v_fare_method IN ('personal_upi', 'cash')
        ELSE (v_payment_mode IN ('cash', 'upi') OR v_order.payment_status::text IS DISTINCT FROM 'paid')
    END;

    v_rider_net_earning := v_rider_earning;
    v_company_cod_share := ROUND(v_commission_amount + v_gst_amount, 2);

    -- =====================================================
    -- 5. GOVERNMENT TAX DUE -- unchanged.
    -- =====================================================
    BEGIN
        v_tax_result := public.apply_order_government_tax(
            p_order_id,
            v_order.rider_id,
            v_order.order_type::text,
            v_fare,
            v_is_direct_collection
        );
    EXCEPTION
        WHEN OTHERS THEN
            v_tax_result := NULL;
            RAISE WARNING 'complete_order_and_settle: apply_order_government_tax failed for order %: %', p_order_id, SQLERRM;
    END;

    IF v_tax_result IS NOT NULL AND (v_tax_result->>'applied')::boolean IS TRUE AND NOT v_is_direct_collection THEN
        v_tax_amount := COALESCE((v_tax_result->>'tax_amount')::numeric, 0);
        IF v_tax_amount > 0 THEN
            v_rider_net_earning := ROUND(v_rider_net_earning - v_tax_amount, 2);
        END IF;
    END IF;

    -- =====================================================
    -- 6. WALLET/EARNINGS CREDIT -- unchanged.
    -- =====================================================
    PERFORM public.credit_rider_for_completed_order(
        v_order.rider_id,
        v_rider_net_earning,
        v_is_direct_collection,
        v_company_cod_share
    );

    -- =====================================================
    -- 7. AUDIT HISTORY -- unchanged.
    -- =====================================================
    INSERT INTO public.order_status_history (order_id, previous_status, new_status, changed_by)
    VALUES (p_order_id, p_previous_status, p_new_status, p_changed_by);

    RETURN jsonb_build_object(
        'success', true,
        'code', 'SUCCESS',
        'order', to_jsonb(v_order)
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INTERNAL_ERROR', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

REVOKE ALL ON FUNCTION public.complete_order_and_settle(uuid, text, text, text, text, boolean, boolean, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.complete_order_and_settle(uuid, text, text, text, text, boolean, boolean, text, text) TO service_role;


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
