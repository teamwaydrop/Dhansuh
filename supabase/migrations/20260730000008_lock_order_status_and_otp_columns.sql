-- Migration: close the P0 RLS gap on orders.order_status / pickup_otp / delivery_otp / rider_id.
-- Date: 2026-07-30
--
-- ROOT CAUSE: "Allow passengers and assigned riders to update orders"
-- (20260531000003_fix_find_nearby_riders.sql:232-244) is a row-level-only UPDATE policy -- USING
-- (auth.uid()=user_id OR assigned rider), no WITH CHECK, no column restriction. Combined with the
-- table-level UPDATE grant to `authenticated`, this let any owning passenger or assigned rider
-- PATCH order_status/pickup_otp/delivery_otp/rider_id directly via raw REST, bypassing OTP
-- verification, cancellation cleanup, dispatch bookkeeping, and the entire guarded state machine.
--
-- Every legitimate authenticated-role direct writer of these 4 columns has now been migrated to a
-- SECURITY DEFINER RPC or the cancel-order edge function, verified via an exhaustive grep of every
-- `.from('orders')` call site in lib/ (31 references checked; the only non-SELECT/non-RPC one left
-- touches pickup_verification_completed/pickup_verification_completed_at, neither of which is
-- locked here):
--   - 6 cancellation screens' silent direct-write fallback on any cancel-order exception -> removed,
--     genuine failures now surface as a retryable error instead of bypassing cleanup.
--   - intercity_bookings_screen.dart's _completeParcel/_markRideArrived/_resendOtp ->
--     complete_intercity_parcel_delivery / mark_intercity_trip_at_dropoff /
--     regenerate_intercity_delivery_otp (20260730000004, 20260730000005).
--   - intercity_searching_screen.dart's confirmRider -> confirm_intercity_search_rider (20260730000006).
--   - order_chat_screen.dart's _confirmHandover -> confirm_intercity_handover (20260730000007).
--
-- Those 5 new RPCs are SECURITY DEFINER and called directly by 'authenticated' clients -- exactly
-- the same shape as confirm_intercity_booking() needing app.bypass_financial_guard (see
-- 20260724000005's header: SECURITY DEFINER does not change what auth.role() reports, since it's a
-- session-level JWT claim, not something function execution context elevates). A fresh, separate
-- flag (app.bypass_order_state_guard) is used rather than reusing app.bypass_financial_guard --
-- order_status/OTP/rider_id are state-machine columns, not financial ones, and keeping the two
-- guards independent means a bug in one can never accidentally widen the other's bypass.

-- =====================================================================
-- 1. Retrofit the 5 new RPCs to set the bypass flag before their guarded-column writes.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.mark_intercity_trip_at_dropoff(
    p_order_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_rider RECORD;
    v_order RECORD;
    v_otp text;
BEGIN
    SELECT * INTO v_rider FROM public.riders WHERE user_id = auth.uid();
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Rider profile not found for user.');
    END IF;

    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order not found.');
    END IF;

    IF v_order.order_type::text NOT IN ('intercity_ride', 'intercity_parcel') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This function only applies to intercity Travel Together bookings.');
    END IF;

    IF v_order.rider_id IS DISTINCT FROM v_rider.id THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This trip is not assigned to you.');
    END IF;

    IF v_order.order_status::text = 'rider_at_drop' THEN
        RETURN jsonb_build_object('success', true, 'code', 'ALREADY_AT_DROPOFF', 'order_id', v_order.id, 'delivery_otp', v_order.delivery_otp);
    END IF;

    IF v_order.order_status::text NOT IN ('accepted', 'rider_arrived', 'picked_up') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Trip is not in a state that can be marked at drop-off.');
    END IF;

    LOOP
        v_otp := floor(random() * 9000 + 1000)::text;
        PERFORM 1 FROM public.orders WHERE delivery_otp = v_otp AND order_status = 'rider_at_drop';
        EXIT WHEN NOT FOUND;
    END LOOP;

    PERFORM set_config('app.bypass_order_state_guard', 'true', true);

    UPDATE public.orders
    SET order_status = 'rider_at_drop'::public.order_status_enum,
        delivery_otp = v_otp,
        rider_at_drop_at = now(),
        updated_at = now()
    WHERE id = v_order.id;

    RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_id', v_order.id, 'delivery_otp', v_otp);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.regenerate_intercity_delivery_otp(
    p_order_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_rider RECORD;
    v_order RECORD;
    v_otp text;
BEGIN
    SELECT * INTO v_rider FROM public.riders WHERE user_id = auth.uid();
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Rider profile not found for user.');
    END IF;

    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order not found.');
    END IF;

    IF v_order.order_type::text NOT IN ('intercity_ride', 'intercity_parcel') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This function only applies to intercity Travel Together bookings.');
    END IF;

    IF v_order.rider_id IS DISTINCT FROM v_rider.id THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This trip is not assigned to you.');
    END IF;

    IF v_order.order_status::text <> 'rider_at_drop' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Mark arrival at drop-off before requesting a new OTP.');
    END IF;

    LOOP
        v_otp := floor(random() * 9000 + 1000)::text;
        PERFORM 1 FROM public.orders WHERE delivery_otp = v_otp AND order_status = 'rider_at_drop';
        EXIT WHEN NOT FOUND;
    END LOOP;

    PERFORM set_config('app.bypass_order_state_guard', 'true', true);

    UPDATE public.orders
    SET delivery_otp = v_otp,
        updated_at = now()
    WHERE id = v_order.id;

    RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_id', v_order.id, 'delivery_otp', v_otp);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

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
    v_is_direct_collection := CASE
        WHEN v_fare_method IS NOT NULL THEN v_fare_method IN ('personal_upi', 'cash')
        ELSE v_payment_mode IN ('cash', 'upi')
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

CREATE OR REPLACE FUNCTION public.confirm_intercity_search_rider(
    p_order_id uuid,
    p_rider_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_order RECORD;
    v_now timestamptz := now();
BEGIN
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order not found.');
    END IF;

    IF v_order.user_id IS DISTINCT FROM auth.uid() THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This order does not belong to you.');
    END IF;

    IF v_order.order_status::text = 'accepted' AND v_order.rider_id = p_rider_id THEN
        RETURN jsonb_build_object('success', true, 'code', 'ALREADY_CONFIRMED', 'order_id', v_order.id);
    END IF;

    IF v_order.order_status::text <> 'searching' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'This order is no longer searching for a rider.');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.rider_assignments
        WHERE order_id = p_order_id AND rider_id = p_rider_id AND assignment_status IN ('sent', 'accepted')
    ) THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This rider has not offered on this order.');
    END IF;

    PERFORM set_config('app.bypass_order_state_guard', 'true', true);

    UPDATE public.orders
    SET rider_id = p_rider_id,
        order_status = 'accepted'::public.order_status_enum,
        accepted_at = v_now,
        updated_at = v_now
    WHERE id = p_order_id
      AND order_status = 'searching';

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'CONFLICT', 'message', 'Order status changed by another request. Please retry.');
    END IF;

    UPDATE public.rider_assignments
    SET assignment_status = 'accepted', responded_at = v_now, updated_at = v_now
    WHERE order_id = p_order_id AND rider_id = p_rider_id;

    UPDATE public.rider_assignments
    SET assignment_status = 'rejected', responded_at = v_now, updated_at = v_now
    WHERE order_id = p_order_id AND rider_id IS DISTINCT FROM p_rider_id AND assignment_status = 'sent';

    RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_id', v_order.id, 'rider_id', p_rider_id);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.confirm_intercity_handover(
    p_order_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_order RECORD;
    v_rider RECORD;
    v_request RECORD;
    v_is_sender boolean;
    v_is_rider boolean;
    v_flag_key text;
    v_metadata jsonb;
    v_sender_confirmed boolean;
    v_rider_confirmed boolean;
    v_new_status text;
    v_now timestamptz := now();
BEGIN
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order not found.');
    END IF;

    SELECT * INTO v_rider FROM public.riders WHERE id = v_order.rider_id;

    v_is_sender := (v_order.user_id = auth.uid());
    v_is_rider := (v_rider.user_id IS NOT NULL AND v_rider.user_id = auth.uid());

    IF NOT (v_is_sender OR v_is_rider) THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Not a participant on this order.');
    END IF;

    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE parcel_id = p_order_id
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'No linked booking found for this order.');
    END IF;

    v_flag_key := CASE WHEN v_is_sender THEN 'sender_handover_confirmed' ELSE 'rider_handover_confirmed' END;
    v_metadata := COALESCE(v_request.metadata, '{}'::jsonb) || jsonb_build_object(v_flag_key, true);

    UPDATE public.intercity_requests
    SET metadata = v_metadata, updated_at = v_now
    WHERE id = v_request.id;

    v_sender_confirmed := COALESCE((v_metadata->>'sender_handover_confirmed')::boolean, false);
    v_rider_confirmed := COALESCE((v_metadata->>'rider_handover_confirmed')::boolean, false);

    IF v_sender_confirmed AND v_rider_confirmed
       AND v_order.order_status::text NOT IN ('ongoing', 'picked_up', 'rider_at_drop', 'payment_pending', 'completed', 'delivered')
    THEN
        v_new_status := CASE WHEN v_request.booking_type = 'ride' THEN 'ongoing' ELSE 'picked_up' END;

        PERFORM set_config('app.bypass_order_state_guard', 'true', true);

        UPDATE public.orders
        SET order_status = v_new_status::public.order_status_enum,
            picked_up_at = v_now,
            updated_at = v_now
        WHERE id = p_order_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'code', 'SUCCESS',
        'sender_confirmed', v_sender_confirmed,
        'rider_confirmed', v_rider_confirmed
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- =====================================================================
-- 2. The actual lockdown: reject any authenticated-role write to order_status/pickup_otp/
--    delivery_otp/rider_id unless it's service_role (every edge function: update-order-status,
--    accept-order, cancel-order, create-order, accept_intercity_request via the
--    accept-intercity-request edge function) or one of the 5 RPCs above via the bypass flag.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.protect_order_state_columns()
RETURNS TRIGGER AS $$
BEGIN
    IF auth.role() <> 'service_role'
       AND current_setting('app.bypass_order_state_guard', true) IS DISTINCT FROM 'true'
    THEN
        IF NEW.order_status IS DISTINCT FROM OLD.order_status
           OR NEW.pickup_otp IS DISTINCT FROM OLD.pickup_otp
           OR NEW.delivery_otp IS DISTINCT FROM OLD.delivery_otp
           OR NEW.rider_id IS DISTINCT FROM OLD.rider_id
        THEN
            RAISE EXCEPTION 'Direct modification of order status/OTP/assignment columns is not permitted. Use the appropriate server-side function.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

DROP TRIGGER IF EXISTS protect_order_state_columns_trigger ON public.orders;
CREATE TRIGGER protect_order_state_columns_trigger
BEFORE UPDATE ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.protect_order_state_columns();
