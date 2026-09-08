-- Migration: Server-side OTP-gated completion + full settlement for intercity Travel Together
-- deliveries, replacing intercity_bookings_screen.dart's direct table writes.
-- Date: 2026-07-30
--
-- ROOT CAUSE (P0, verified by direct code trace, not assumed):
-- intercity_bookings_screen.dart's _completeParcel() (lines 272-296) marks an intercity_parcel
-- Travel-Together delivery 'completed' via a raw `orders.update(...)` call, with NO delivery-OTP
-- check at all -- reachable from any active status, not just after drop-off. Because it never
-- calls update-order-status (the only place credit_rider_for_completed_order,
-- apply_order_government_tax, the intercity_requests/travel-plan completion sync, and the
-- order_status_history audit insert are triggered), every intercity parcel delivery through this
-- screen pays the rider nothing, applies no tax, leaves the linked negotiation stuck at
-- confirmed/paid/in_progress forever, and has no completion audit trail.
--
-- _markRideArrived() (lines 298-325, shared by BOTH ride and parcel bookings in this same screen)
-- has the same class of bug one step earlier: it also writes order_status/delivery_otp directly,
-- and generates that OTP with `(1000 + (9000 * (DateTime.now().millisecond / 1000))).round()` --
-- client-side, and drawn from a space of only ~1000 possible values seeded by a clock reading, not
-- cryptographically random.
--
-- FIX: two new RPCs, replacing both direct writes. Neither changes existing, working behavior for
-- local rides/parcels (update-order-status is untouched) or for the intercity RIDE completion path
-- (_verifyOtp -> update-order-status 'payment_pending' -> ... -> 'completed', unchanged) -- only
-- what sets 'rider_at_drop' beforehand, and what completes an intercity PARCEL, change.
--
-- 1. mark_intercity_trip_at_dropoff(p_order_id): replaces _markRideArrived's direct write for BOTH
--    intercity_ride and intercity_parcel bookings. Generates a real, collision-checked, random
--    4-digit OTP server-side (same generation pattern already used by accept_intercity_request for
--    pickup_otp), sets order_status='rider_at_drop'. No money moves here for either order type --
--    this step is a pure state transition + OTP issuance, so it's safe to share between both
--    flows without touching either one's settlement logic.
--
-- 2. complete_intercity_parcel_delivery(p_order_id, p_delivery_otp): the actual P0 fix. Requires
--    the order to already be at 'rider_at_drop' (i.e. routed through function 1 above) and the
--    caller-supplied OTP to match orders.delivery_otp exactly -- real server-side verification,
--    not a client-side pre-check that can be skipped. On success, applies the IDENTICAL settlement
--    sequence update-order-status/index.ts's completion block applies for every other order type:
--    releases the rider's assignment, recomputes the full commission/GST/rider-earning breakdown
--    via the same canonical calculate_fare_breakdown() confirm_intercity_booking() already uses
--    (deliberately NOT trusting orders.rider_earning/commission_amount/gst_amount as already
--    correct -- accept_intercity_request sets final_fare/current_fare from the negotiated
--    proposed_fare but does not itself recompute this breakdown, so those columns can be stale
--    from order-creation time for exactly this booking path), applies the Waydrop MAX
--    commission-waiver rule identically, applies government tax via apply_order_government_tax,
--    credits the rider via credit_rider_for_completed_order, syncs the linked intercity_requests
--    and rider_travel_plans rows to completed (mirroring update-order-status's own sync blocks),
--    and inserts an order_status_history row. Intercity RIDE completion is untouched -- this
--    function explicitly rejects any order_type other than 'intercity_parcel'.

-- =====================================================================
-- 1. mark_intercity_trip_at_dropoff()
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

    -- Idempotent: a repeat press while already at rider_at_drop just returns the existing OTP
    -- instead of erroring or silently regenerating a different one underneath an in-progress
    -- handover.
    IF v_order.order_status::text = 'rider_at_drop' THEN
        RETURN jsonb_build_object('success', true, 'code', 'ALREADY_AT_DROPOFF', 'order_id', v_order.id, 'delivery_otp', v_order.delivery_otp);
    END IF;

    IF v_order.order_status::text NOT IN ('accepted', 'rider_arrived', 'picked_up') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Trip is not in a state that can be marked at drop-off.');
    END IF;

    -- Cryptographically-irrelevant but real, server-side, collision-checked 4-digit OTP -- same
    -- generation pattern already used by accept_intercity_request for pickup_otp, replacing the
    -- old client-side `DateTime.now().millisecond`-seeded value (~1000 possible outcomes, guessable).
    LOOP
        v_otp := floor(random() * 9000 + 1000)::text;
        PERFORM 1 FROM public.orders WHERE delivery_otp = v_otp AND order_status = 'rider_at_drop';
        EXIT WHEN NOT FOUND;
    END LOOP;

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

GRANT EXECUTE ON FUNCTION public.mark_intercity_trip_at_dropoff(uuid) TO authenticated;

-- =====================================================================
-- 2. complete_intercity_parcel_delivery()
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

    -- Idempotency: a retried call against an already-completed order is a harmless no-op success,
    -- never a re-credit -- mirrors update-order-status's own optimistic-lock pattern.
    IF v_order.order_status::text = 'delivered' THEN
        RETURN jsonb_build_object('success', true, 'code', 'ALREADY_DELIVERED', 'order_id', v_order.id);
    END IF;

    IF v_order.order_status::text <> 'rider_at_drop' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Mark arrival at drop-off and generate the completion OTP first.');
    END IF;

    -- The actual P0 fix: real server-side OTP verification. Never trust a client-side pre-check.
    IF v_order.delivery_otp IS NULL OR p_delivery_otp IS NULL OR v_order.delivery_otp <> p_delivery_otp THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_OTP', 'message', 'Invalid delivery OTP. Please check with the receiver and try again.');
    END IF;

    -- =================================================
    -- SETTLEMENT (mirrors update-order-status/index.ts's completion block exactly)
    -- =================================================

    SELECT (
        v_rider.subscription_active IS TRUE
        AND v_rider.subscription_expires_at IS NOT NULL
        AND v_rider.subscription_expires_at > v_now
    ) INTO v_has_active_subscription;

    v_fare := COALESCE(v_order.final_fare, v_order.current_fare, 0);
    IF v_fare <= 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order has no payable fare.');
    END IF;

    -- Never trust orders.commission_amount/gst_amount/rider_earning as already correct here --
    -- accept_intercity_request (the only way this order reached 'accepted') sets final_fare/
    -- current_fare from the negotiated proposed_fare but does not itself call
    -- calculate_fare_breakdown, so those three columns can still reflect the pre-negotiation
    -- quoted fare from order creation. Always recompute fresh from the current fare, exactly like
    -- confirm_intercity_booking() does for the ride-negotiation path.
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

    -- Government tax (independent of the subscription waiver -- see apply_order_government_tax's
    -- own documentation). Withheld from the wallet credit when Cashfree-collected; added to the
    -- rider's standing due balance when directly collected (handled inside the function itself).
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

    -- Release the rider's assignment for this order so they're no longer blocked from new
    -- dispatches -- mirrors update-order-status/index.ts's identical step.
    UPDATE public.rider_assignments
    SET assignment_status = 'expired', updated_at = v_now, responded_at = v_now
    WHERE order_id = v_order.id AND rider_id = v_rider.id AND assignment_status = 'accepted';

    -- Persist the recomputed breakdown back onto the order (reporting/audit consistency, same as
    -- update-order-status's subscription-waiver branch) and flip the order to its terminal state,
    -- optimistically locked on it still being 'rider_at_drop'.
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

    -- Sync the linked intercity_requests negotiation row to completed -- mirrors
    -- update-order-status/index.ts's identical sync block (the only other place that ever writes
    -- 'completed' to this table), which is what makes on_intercity_request_change() fire the
    -- correctly-worded "Parcel Delivered" passenger notification (20260730000001).
    UPDATE public.intercity_requests
    SET status = 'completed', updated_at = v_now
    WHERE parcel_id = v_order.id
      AND status IN ('confirmed', 'paid', 'in_progress');

    -- Auto-complete the travel plan once no other booking against it is still active -- mirrors
    -- update-order-status/index.ts's identical sync block.
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

GRANT EXECUTE ON FUNCTION public.complete_intercity_parcel_delivery(uuid, text) TO authenticated;
