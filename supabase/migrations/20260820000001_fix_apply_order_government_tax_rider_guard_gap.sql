-- Migration: fix a SECOND, deeper guard-interaction gap in the same intercity parcel completion
-- chain that 20260820000000 only partially fixed.
--
-- ROOT CAUSE (confirmed live against production, not assumed): 20260820000000 added a bypass for
-- protect_rider_financial_columns() and used it inside credit_rider_for_completed_order() -- but a
-- live re-test after deploying that migration still failed with the exact same
-- "Direct modification of rider financial/subscription columns is not permitted" error.
-- Investigation traced the actual failure to a DIFFERENT, earlier call in the same execution:
-- complete_intercity_parcel_delivery() calls public.apply_order_government_tax(...) BEFORE it ever
-- reaches credit_rider_for_completed_order(). For a cash/personal_upi ("direct collection")
-- delivery -- true for this test order, and for every intercity parcel paid in cash or personal
-- UPI -- apply_order_government_tax()'s direct-collection branch does:
--     UPDATE public.riders SET government_tax_due_balance = government_tax_due_balance + v_tax_amount ...
-- government_tax_due_balance is itself one of the columns protect_rider_financial_columns() guards,
-- and apply_order_government_tax() has never set any bypass flag before this write -- it simply
-- never needed to until complete_intercity_parcel_delivery (an authenticated-client-callable RPC)
-- started calling it as part of the same 2026-07-30 work that introduced the completion RPC itself.
--
-- IMPORTANT SECURITY NOTE (why the fix lives in the CALLER, not in apply_order_government_tax
-- itself): apply_order_government_tax() is GRANTed to authenticated AND anon (confirmed live via
-- has_function_privilege), and performs no ownership/authorization check of its own -- it trusts
-- its p_rider_id/p_taxable_base parameters completely. Today, the protect_rider_financial_columns
-- guard is the ONLY thing stopping an arbitrary direct call to this function (with a guessed/
-- targeted rider_id) from actually writing an inflated government_tax_due_balance onto any rider.
-- Adding a bypass INSIDE apply_order_government_tax itself would silently remove that incidental
-- protection for every future direct caller, not just the legitimate one -- a real regression this
-- migration must not introduce. Instead, the bypass is set by complete_intercity_parcel_delivery
-- (the caller), exactly mirroring the pattern it already uses for the ORDERS-table guards two lines
-- later in its own body (app.bypass_financial_guard / app.bypass_order_state_guard, both set by
-- this same function right before its own guarded UPDATE, never by a shared callee). A direct call
-- to apply_order_government_tax from outside this vetted call chain still hits the guard exactly as
-- before -- nothing about its own authorization surface changes.
--
-- complete_order_and_settle (the local ride/local parcel/intercity ride settlement path) is
-- unaffected and untouched: it is GRANTed to service_role only, so auth.role() = 'service_role'
-- there and the guard already passes trivially regardless of any bypass flag, exactly as before.
--
-- SCOPE: only complete_intercity_parcel_delivery changes, one added line, everything else
-- byte-for-byte identical to the live definition. apply_order_government_tax,
-- protect_rider_financial_columns, and credit_rider_for_completed_order (already fixed by
-- 20260820000000) are not touched by this migration.

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

    -- FIX: v_order.payment_mode cast to text before lower() -- see migration header.
    v_payment_mode := lower(COALESCE(v_order.payment_mode::text, 'cash'));
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

    -- FIX (this migration): apply_order_government_tax()'s direct-collection branch writes
    -- riders.government_tax_due_balance, one of protect_rider_financial_columns()'s guarded
    -- columns. Set the bypass here, in the caller -- never inside apply_order_government_tax
    -- itself, which stays fully guarded against being called directly by anything other than an
    -- already-vetted settlement path like this one. See migration header for the full reasoning.
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

-- GRANT unchanged (CREATE OR REPLACE preserves existing grants for an unchanged signature) --
-- restated here only for clarity/auditability, not because it needs to be re-applied.
GRANT EXECUTE ON FUNCTION public.complete_intercity_parcel_delivery(uuid, text) TO authenticated;
