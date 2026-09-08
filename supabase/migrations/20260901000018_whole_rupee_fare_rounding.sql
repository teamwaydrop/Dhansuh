-- Migration: whole-rupee rounding for the customer-payable fare.
-- Date: 2026-09-01
--
-- BUG REPORT: the app sometimes computes a fare with paise (e.g. ₹52.22). The customer sees this
-- decimal amount during booking, but by the time payment/order-completion runs, a DIFFERENT
-- rounded/truncated figure can end up authoritative -- producing a mismatch between what the
-- customer was shown, what they were charged, the partner's "Ride Fare", and the government-tax/
-- commission figures derived from it.
--
-- ROOT CAUSE (traced end to end before writing this migration):
--   1. Base fare is computed in supabase/functions/calculate-order-pricing/pricing-calculations.ts
--      (calculateFare()) from pricing_config rules + distance.
--   2. GST is added in the same file's buildPricingResponse(): finalFare = fareAfterDiscount +
--      gstAmount (fareAfterDiscount * gst_percentage/100) -- a decimal, e.g. 52.22.
--   3. That decimal `pricing.final_fare` is what the passenger's booking screen displays
--      (PricingController.getFinalFare -> `estimatedFare` on every booking screen), AND is what
--      create-order/index.ts copies verbatim into orders.current_fare (and, if a promo applies,
--      into orders.final_fare) when the order is actually created -- NEVER re-derived from
--      distance/rules again, just copied through.
--   4. orders.final_fare ?? orders.current_fare is THE single authoritative "customer payable
--      fare" column, read by: create-payment/index.ts (the amount sent to Cashfree),
--      FareBreakdown.customerPaid (every Flutter completed-ride/order-history/earnings screen),
--      calculate_fare_breakdown() (re-derives commission/Platform-GST/rider_earning from this
--      exact column at accept-order, boost-order-fare, and ride completion), and
--      apply_order_government_tax()'s p_taxable_base (via
--      COALESCE(final_fare, current_fare) in complete_order_and_settle /
--      complete_intercity_parcel_delivery).
--   5. Nothing along this chain ever rounded the amount to a whole rupee -- each downstream reader
--      just forwarded or (in a couple of UI-only spots) DISPLAY-rounded the same underlying
--      decimal value independently and inconsistently, which is exactly how a customer could see
--      one number and be charged/settled against a different one.
--
-- FIX: round the customer-payable total to the nearest whole rupee at the two SQL-side places a
-- new authoritative total_fare is ever produced, so every downstream reader (already unchanged --
-- see files below) automatically inherits a whole-rupee amount:
--   (a) calculate_fare_breakdown() -- the single canonical "given a new total fare, compute the
--       full breakdown" function, called by boost-order-fare, accept-order, confirm_intercity_
--       booking(), complete_order_and_settle(), and complete_intercity_parcel_delivery(). Rounds
--       p_new_total_fare to a whole rupee as its very first step; v_final_fare's own rounding
--       changes from 2 decimal places to 0. GST-inclusive-base derivation (base_fare =
--       new_total_fare / (1 + gst%/100)), commission calculation, and rider_earning calculation
--       are otherwise BYTE-FOR-BYTE UNCHANGED -- they simply now operate on a whole-rupee input,
--       which is exactly the same "derive everything from the authoritative total" pattern this
--       function already used. No GST rate, commission rate, or government-tax formula changes.
--   (b) accept_intercity_request() -- the one remaining place that wrote a new total_fare directly
--       (v_request.proposed_fare, from Travel Together chat negotiation) without going through
--       calculate_fare_breakdown() at all. Rounds proposed_fare to a whole rupee immediately before
--       writing it into orders.final_fare/current_fare. Every other clause is reproduced byte-for-
--       byte from the live definition (20260827000000) -- only this one value changes.
--
-- The companion TypeScript-side fix (calculate-order-pricing/pricing-calculations.ts:
-- buildPricingResponse(), and create-order/index.ts's promo-discount branch) is deployed alongside
-- this migration and rounds the INITIAL booking-time estimate the same way, so the passenger's
-- booking screen already shows the exact whole-rupee figure this migration's functions will later
-- reconcile to -- see rider_fare_whole_rupee_rounding_regression_test.dart and
-- pricing-calculations.test.ts for the full proof.
--
-- GST / GOVERNMENT TAX / COMMISSION / FREE-TRIAL: none of these formulas change. Government tax
-- (apply_order_government_tax) already rounds to 2 decimal places (ROUND(taxable_base *
-- rate/100, 2)) and is UNCHANGED here -- it simply now computes off a whole-rupee taxable_base
-- instead of a fractional one, exactly as the existing "Rounding rule" comment in
-- 20260726000004_government_tax_due_functions.sql already documents. The free-trial 0% commission
-- waiver (subscription_commission_waived) and the Section 9(5)/paid-commission percentage
-- calculation are read exactly as before -- calculate_fare_breakdown() never decided commission
-- eligibility, only the arithmetic once a rate is supplied by its caller.

-- =====================================================================
-- 1. calculate_fare_breakdown(): round p_new_total_fare to a whole rupee as the first step.
--    Signature, RETURNS type, and every downstream formula shape are unchanged.
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
    v_new_total_fare numeric;
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
    -- WHOLE-RUPEE ROUNDING (single point for every post-booking fare change: boost, intercity
    -- negotiation acceptance, plain accept-order re-derivation, and the fresh commission/GST/
    -- rider_earning recompute complete_order_and_settle() and complete_intercity_parcel_delivery()
    -- both run at ride completion). ROUND(numeric, 0) is PostgreSQL's standard commercial rounding
    -- (half away from zero) -- 23.45 -> 23, 23.50 -> 24, matching the app's required behavior.
    v_new_total_fare := ROUND(COALESCE(p_new_total_fare, 0), 0);

    v_base_fare := ROUND(v_new_total_fare / (1 + (COALESCE(p_gst_percentage, 5.0) / 100.0)), 2);
    v_gst_amount := ROUND(v_new_total_fare - v_base_fare, 2);

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

    -- Whole-rupee here too (was ROUND(..., 2)): a promo-discounted final_fare is still the
    -- customer's actual payable amount (FareBreakdown.customerPaid = final_fare ?? current_fare)
    -- and must never carry paise either.
    v_final_fare := GREATEST(0, ROUND(v_new_total_fare - COALESCE(p_promo_discount, 0), 0));

    RETURN jsonb_build_object(
        'current_fare', v_new_total_fare,
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
-- 2. accept_intercity_request(): round the negotiated proposed_fare to a whole rupee before it
--    ever becomes orders.final_fare/current_fare -- the one remaining direct-write path that
--    bypassed calculate_fare_breakdown() entirely. Every other clause reproduced byte-for-byte
--    from the live definition (20260827000000_fix_travel_plan_seats_full_vs_inactive_message.sql).
-- =====================================================================
CREATE OR REPLACE FUNCTION public.accept_intercity_request(p_request_id uuid, p_rider_user_id uuid)
RETURNS jsonb AS $$
DECLARE
    v_request RECORD;
    v_order RECORD;
    v_rider RECORD;
    v_travel_plan RECORD;
    v_otp text;
    v_active_bookings int;
    v_rounded_fare numeric;
BEGIN
    -- SECURITY: reject impersonation on any direct/authenticated RPC call. No-op
    -- for the Edge Function's service-role call path (auth.uid() is NULL there).
    IF auth.uid() IS NOT NULL AND auth.uid() != p_rider_user_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'UNAUTHORIZED',
            'message', 'You are not authorized to accept this request.'
        );
    END IF;

    SELECT * INTO v_rider
    FROM public.riders
    WHERE user_id = p_rider_user_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Rider profile not found for user.'
        );
    END IF;

    IF v_rider.service_mode IS DISTINCT FROM 'intercity'::public.partner_service_mode_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'WRONG_SERVICE_MODE',
            'message', 'Switch to Intercity Traveller mode to accept this request.'
        );
    END IF;

    -- GOVERNMENT TAX DUE: a rider at/above the configured threshold cannot accept new work
    -- through this path either -- the block applies to all new assignments, not just local ones.
    IF public.is_rider_blocked_by_tax_due(v_rider.id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'TAX_DUE_THRESHOLD_BLOCKED',
            'message', 'New orders are paused because your Government Tax Due has reached the limit. Pay the due amount to continue receiving orders.'
        );
    END IF;

    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Intercity request not found.'
        );
    END IF;

    IF v_request.traveller_id != v_rider.id THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Request does not belong to this traveller.'
        );
    END IF;

    SELECT * INTO v_order
    FROM public.orders
    WHERE id = v_request.parcel_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Associated order not found.'
        );
    END IF;

    IF v_order.rider_id = v_rider.id AND v_order.order_status = 'accepted' THEN
        RETURN jsonb_build_object(
            'success', true,
            'code', 'ALREADY_ACCEPTED',
            'order_id', v_order.id,
            'request_id', v_request.id
        );
    END IF;

    IF v_order.order_status != 'searching' OR v_order.rider_id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ORDER_ALREADY_ASSIGNED',
            'message', 'Booking no longer available.'
        );
    END IF;

    IF v_order.search_expires_at IS NOT NULL AND v_order.search_expires_at < now() THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REQUEST_EXPIRED',
            'message', 'Order search has expired.'
        );
    END IF;

    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;

    IF v_request.expires_at IS NOT NULL AND v_request.expires_at < now() THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REQUEST_EXPIRED',
            'message', 'Request negotiation has expired.'
        );
    END IF;

    IF v_request.status NOT IN ('request_sent', 'discussion_started', 'fare_agreed') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Request status is not eligible for acceptance.'
        );
    END IF;

    -- Never install a zero/negative fare onto a real order. Server-side check --
    -- proposed_fare is client-influenced (set at Travel Together request time from a Drop
    -- Partner's own price_per_seat, or via later in-chat negotiation) and was never
    -- previously validated here.
    IF v_request.proposed_fare IS NULL OR v_request.proposed_fare <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_FARE',
            'message', 'This request has no valid fare and cannot be accepted. Please ask the sender to resend the request.'
        );
    END IF;

    -- WHOLE-RUPEE ROUNDING (this migration): proposed_fare is a client-influenced, possibly
    -- decimal, negotiated amount -- round it to a whole rupee before it becomes the order's
    -- authoritative final_fare/current_fare, the same figure the passenger, the payment amount,
    -- the partner's Ride Fare, and government-tax/commission settlement all read.
    v_rounded_fare := ROUND(v_request.proposed_fare, 0);

    SELECT * INTO v_travel_plan
    FROM public.rider_travel_plans
    WHERE id = v_request.route_id
    FOR UPDATE;

    -- 'fully_booked' is a distinct, transient, seat-driven status (set/revived automatically as
    -- bookings change -- see 20260617000001), never a genuine cancelled/completed/expired plan.
    -- It must fall through to the seat-count check below instead of being treated the same as a
    -- truly inactive plan here.
    IF v_travel_plan IS NULL OR v_travel_plan.status::text NOT IN ('active', 'fully_booked') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'TRAVEL_PLAN_INACTIVE',
            'message', 'Travel plan is no longer active.'
        );
    END IF;

    SELECT COUNT(*) INTO v_active_bookings
    FROM public.intercity_requests
    WHERE route_id = v_request.route_id
      AND status IN ('confirmed', 'paid', 'in_progress')
      AND id IS DISTINCT FROM p_request_id;

    IF v_active_bookings >= v_travel_plan.max_bookings THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'PLAN_FULLY_BOOKED',
            'message', 'All available seats have already been booked.'
        );
    END IF;

    IF public.rider_is_on_active_trip(v_rider.id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'RIDER_ALREADY_BUSY',
            'message', 'Rider is already handling another active trip.'
        );
    END IF;

    IF public.passenger_has_conflicting_trip(
        v_order.user_id,
        v_order.id,
        COALESCE(v_order.travel_date, v_order.created_at),
        COALESCE(v_order.travel_date, v_order.created_at)
            + make_interval(mins => COALESCE(v_order.estimated_duration_min, 240))
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'PASSENGER_ALREADY_CONFIRMED',
            'message', 'Passenger already has a conflicting trip at this time.'
        );
    END IF;

    LOOP
        v_otp := floor(random() * 9000 + 1000)::text;
        PERFORM 1 FROM public.orders WHERE pickup_otp = v_otp AND order_status IN ('accepted', 'picked_up');
        EXIT WHEN NOT FOUND;
    END LOOP;

    UPDATE public.intercity_requests
    SET status = 'confirmed',
        updated_at = now()
    WHERE id = p_request_id;

    UPDATE public.orders
    SET order_status = 'accepted'::public.order_status_enum,
        rider_id = v_rider.id,
        final_fare = v_rounded_fare,
        current_fare = v_rounded_fare,
        pickup_otp = v_otp,
        updated_at = now()
    WHERE id = v_order.id;

    INSERT INTO public.order_chat_messages(
        sender_id,
        sender_type,
        message,
        user_id,
        is_support,
        order_id,
        rider_id,
        created_at
    ) VALUES (
        v_rider.user_id,
        'rider',
        '[AGREED] Rider accepted the request. Booking is confirmed.',
        v_order.user_id,
        false,
        v_order.id,
        v_rider.id,
        now()
    );

    RETURN jsonb_build_object(
        'success', true,
        'code', 'SUCCESS',
        'order_id', v_order.id,
        'request_id', v_request.id
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', SQLERRM
        );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
