-- Migration: two independent intercity fixes approved after investigation.
-- Date: 2026-08-21
--
-- =====================================================================================
-- FIX 1 -- intercity_ride government tax (Section 9(5)) category/rate.
--
-- ROOT CAUSE: apply_order_government_tax() (20260726000004) has always classified
-- intercity_ride as NULL/unclassified ("v_category := NULL -- includes 'intercity_ride'"),
-- so government tax was never applied for any intercity passenger ride, by design, pending a
-- business decision. tax_rate_config (20260726000003) deliberately never seeded a rate for it
-- either, for the same reason.
--
-- BUSINESS DECISION (explicit, this session): intercity_ride now gets its own
-- 'intercity_passenger_ride' government-tax category at 5.0% -- mirroring local_passenger_ride's
-- rate (matching the stated business rule that intercity passenger rides carry 5% GST), but kept
-- as its own category (not reusing 'local_passenger_ride' directly) so a future rate change to one
-- never silently changes the other. This is a NEW row, not an edit to the existing
-- local_passenger_ride/parcel_delivery rows -- the additive/forward-only tax_rate_config
-- versioning (effective_from) is unaffected.
--
-- intercity_parcel is NOT touched by this migration -- it was already correctly classified under
-- 'parcel_delivery' at 18.0%.
--
-- =====================================================================================
-- FIX 2 -- accept_intercity_request(): stale commission_amount/gst_amount/rider_earning after a
-- negotiated fare is accepted.
--
-- ROOT CAUSE (traced, not assumed): accept_intercity_request() (latest: 20260901000018) writes
-- the negotiated, rounded proposed_fare directly into orders.final_fare/current_fare, but never
-- recomputes commission_amount/gst_amount/rider_earning -- those stay at whatever
-- create-order/index.ts estimated at booking time, before negotiation. A rider accepting a
-- negotiated fare different from the original estimate (the entire point of Travel Together
-- chat negotiation) ends up with a commission/GST/rider_earning split computed against the WRONG
-- base fare.
--
-- This is not a new bug pattern -- it is the SAME class of bug confirm_intercity_booking()
-- (20260724000005) already hit and fixed, via the exact same canonical fix: route the new total
-- fare through calculate_fare_breakdown() (the single "given a new total fare, compute the full
-- breakdown" function) instead of writing final_fare/current_fare alone. accept_intercity_request()
-- was simply never given the same fix when it was introduced as (per
-- 20260730000002_protect_order_fare_columns.sql's own investigation) a separate, parallel
-- acceptance path.
--
-- FIX: reproduces accept_intercity_request() byte-for-byte from its live definition
-- (20260901000018), except: (a) v_rounded_fare is replaced with a calculate_fare_breakdown() call
-- (which does its own whole-rupee rounding internally, identical to before) using the order's own
-- actual_fare/gst_percentage/commission_percentage -- these rates themselves are untouched by this
-- fix; only the AMOUNTS derived from them are recomputed against the negotiated fare -- and a
-- promo_discount preserved the same way confirm_intercity_booking() already does; (b) the final
-- UPDATE now also writes gst_amount/boost_amount/boost_percentage/boost_rider_earning/
-- boost_company_earning/commission_amount/rider_earning from that breakdown, alongside the
-- unchanged order_status/rider_id/pickup_otp/updated_at writes.
--
-- No app.bypass_financial_guard bypass is needed here (unlike confirm_intercity_booking(), which
-- needs it): accept_intercity_request() is granted ONLY to service_role
-- (20260808000006_secure_accept_intercity_request_authz.sql) and is only ever invoked via
-- accept-intercity-request/index.ts using SUPABASE_SERVICE_ROLE_KEY -- auth.role() = 'service_role'
-- there already satisfies protect_order_financial_columns()'s guard, exactly as
-- 20260730000002's own safety-check investigation already confirmed for this function's existing
-- final_fare/current_fare writes.

-- =====================================================================
-- FIX 1
-- =====================================================================
INSERT INTO "public"."tax_rate_config" ("service_category", "rate_percent")
VALUES ('intercity_passenger_ride', 5.0);

CREATE OR REPLACE FUNCTION public.apply_order_government_tax(
    p_order_id uuid,
    p_rider_id uuid,
    p_order_type text,
    p_taxable_base numeric,
    p_is_direct_collection boolean
)
RETURNS jsonb AS $$
DECLARE
    v_category text;
    v_rate numeric;
    v_tax_amount numeric;
    v_existing record;
BEGIN
    -- Idempotency fast-path: already applied for this order (any retry/duplicate completion call).
    SELECT amount, service_category, rate_percent INTO v_existing
    FROM public.government_tax_ledger
    WHERE order_id = p_order_id AND entry_type = 'ORDER_TAX';

    IF FOUND THEN
        RETURN jsonb_build_object(
            'applied', true,
            'already_existed', true,
            'tax_amount', v_existing.amount,
            'service_category', v_existing.service_category,
            'rate_percent', v_existing.rate_percent
        );
    END IF;

    -- FIX (this migration): intercity_ride now resolves to its own category instead of falling
    -- through to NULL/unclassified -- see header for the business decision behind the rate.
    -- Every other line in this function is byte-for-byte identical to the live definition
    -- (20260726000004).
    v_category := CASE
        WHEN p_order_type IN ('ride', 'ride_sharing') THEN 'local_passenger_ride'
        WHEN p_order_type = 'intercity_ride' THEN 'intercity_passenger_ride'
        WHEN p_order_type IN ('local_parcel', 'batch_delivery', 'food_delivery', 'grocery_delivery', 'intercity_parcel') THEN 'parcel_delivery'
        ELSE NULL -- anything not explicitly classified above
    END;

    IF v_category IS NULL THEN
        RAISE NOTICE 'apply_order_government_tax: order % (type=%) has no resolved tax category -- no liability created. Needs business classification.', p_order_id, p_order_type;
        RETURN jsonb_build_object('applied', false, 'reason', 'unclassified_order_type', 'order_type', p_order_type);
    END IF;

    IF p_taxable_base IS NULL OR p_taxable_base <= 0 THEN
        RAISE NOTICE 'apply_order_government_tax: order % has no positive taxable_base (%) -- no liability created.', p_order_id, p_taxable_base;
        RETURN jsonb_build_object('applied', false, 'reason', 'no_taxable_base');
    END IF;

    SELECT rate_percent INTO v_rate
    FROM public.tax_rate_config
    WHERE service_category = v_category
      AND is_active = true
      AND effective_from <= now()
    ORDER BY effective_from DESC
    LIMIT 1;

    IF v_rate IS NULL THEN
        RAISE NOTICE 'apply_order_government_tax: no active tax_rate_config row for category % -- no liability created for order %.', v_category, p_order_id;
        RETURN jsonb_build_object('applied', false, 'reason', 'no_active_rate_config', 'service_category', v_category);
    END IF;

    v_tax_amount := ROUND(p_taxable_base * v_rate / 100.0, 2);

    -- Insert the liability. ON CONFLICT DO NOTHING is the DB-level backstop against a genuine
    -- concurrent duplicate call (the SELECT check above already caught the common sequential-retry
    -- case) -- if this loses the race, re-read what the winner recorded and return that instead of
    -- erroring.
    INSERT INTO public.government_tax_ledger (
        rider_id, order_id, entry_type, service_category, taxable_base, rate_percent, amount
    ) VALUES (
        p_rider_id, p_order_id, 'ORDER_TAX', v_category, p_taxable_base, v_rate, v_tax_amount
    )
    ON CONFLICT (order_id) WHERE entry_type = 'ORDER_TAX' DO NOTHING;

    IF NOT FOUND THEN
        SELECT amount, service_category, rate_percent INTO v_existing
        FROM public.government_tax_ledger
        WHERE order_id = p_order_id AND entry_type = 'ORDER_TAX';

        RETURN jsonb_build_object(
            'applied', true,
            'already_existed', true,
            'tax_amount', v_existing.amount,
            'service_category', v_existing.service_category,
            'rate_percent', v_existing.rate_percent
        );
    END IF;

    IF p_is_direct_collection THEN
        -- Personal QR / Cash: WayDrop never held this fare, so the tax becomes a genuine
        -- outstanding liability the Drop Partner owes separately.
        UPDATE public.riders
        SET government_tax_due_balance = government_tax_due_balance + v_tax_amount,
            updated_at = now()
        WHERE id = p_rider_id;
    ELSE
        -- Cashfree-collected: the caller (update-order-status) withholds this same amount from the
        -- rider_earning it credits to the wallet, so nothing is actually owed on top of that --
        -- record the offsetting entry for auditability ("tax was created, and here is exactly how
        -- it was recovered") without touching the cached balance a second time.
        INSERT INTO public.government_tax_ledger (
            rider_id, order_id, entry_type, service_category, taxable_base, rate_percent, amount
        ) VALUES (
            p_rider_id, p_order_id, 'ORDER_TAX_WITHHELD', v_category, p_taxable_base, v_rate, -v_tax_amount
        )
        ON CONFLICT (order_id) WHERE entry_type = 'ORDER_TAX_WITHHELD' DO NOTHING;
    END IF;

    RETURN jsonb_build_object(
        'applied', true,
        'already_existed', false,
        'tax_amount', v_tax_amount,
        'service_category', v_category,
        'rate_percent', v_rate
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.apply_order_government_tax(uuid, uuid, text, numeric, boolean) TO service_role;


-- =====================================================================
-- FIX 2
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
    v_promo_discount numeric;
    v_breakdown jsonb;
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

    -- FIX (this migration): recompute the FULL breakdown for the negotiated fare via the same
    -- canonical calculate_fare_breakdown() confirm_intercity_booking() already uses, instead of
    -- writing final_fare/current_fare alone -- which is exactly what left commission_amount/
    -- gst_amount/rider_earning stale against the ORIGINAL booking-time estimate rather than the
    -- negotiated fare. calculate_fare_breakdown() does its own whole-rupee rounding internally
    -- (ROUND(p_new_total_fare, 0)), so v_request.proposed_fare is passed through unrounded, same
    -- as confirm_intercity_booking() already does.
    v_promo_discount := GREATEST(0, COALESCE(v_order.current_fare, 0) - COALESCE(v_order.final_fare, v_order.current_fare, 0));
    v_breakdown := public.calculate_fare_breakdown(
        v_request.proposed_fare,
        v_order.actual_fare,
        v_order.gst_percentage,
        v_order.commission_percentage,
        v_promo_discount
    );

    UPDATE public.orders
    SET order_status = 'accepted'::public.order_status_enum,
        rider_id = v_rider.id,
        current_fare = (v_breakdown->>'current_fare')::numeric,
        final_fare = (v_breakdown->>'final_fare')::numeric,
        gst_amount = (v_breakdown->>'gst_amount')::numeric,
        boost_amount = (v_breakdown->>'boost_amount')::numeric,
        boost_percentage = (v_breakdown->>'boost_percentage')::numeric,
        boost_rider_earning = (v_breakdown->>'boost_rider_earning')::numeric,
        boost_company_earning = (v_breakdown->>'boost_company_earning')::numeric,
        commission_amount = (v_breakdown->>'commission_amount')::numeric,
        rider_earning = (v_breakdown->>'rider_earning')::numeric,
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

GRANT EXECUTE ON FUNCTION public.accept_intercity_request(uuid, uuid) TO service_role;
