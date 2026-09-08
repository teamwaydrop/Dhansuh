-- Migration: consolidate update-order-status's ride/parcel completion settlement chain into one
-- atomic, service_role-only RPC.
-- Date: 2026-08-13
--
-- ROOT CAUSE (WayDrop P1/P2 performance pass, forensic incident on order 66759dad-b386-4814-8065-
-- c6f9182e5c01, WDPHI3039): a single "complete this order" request from a rider was observed
-- spending ~82 seconds of pure server-side time across 5 SEPARATE sequential Postgres round trips
-- (settle_rider_assignment update, rider subscription fetch, apply_order_government_tax RPC,
-- credit_rider_for_completed_order RPC, order_status_history insert) -- each individually 10-70x its
-- expected cost under the exact backend contention this whole investigation has been tracing. The
-- client's own 25s timeout, and the timeout-reconciliation grace window built to handle it, both
-- expired before the chain finished -- not because any single step was slow in isolation, but
-- because 5 independent network round trips to Postgres (each separately queueing for a connection
-- under contention) compound multiplicatively, not additively.
--
-- FIX: this function already exists as a proven-safe pattern in this codebase --
-- complete_intercity_parcel_delivery() (20260730000004) already does exactly this consolidation
-- for intercity parcels: one PL/pgSQL function, one client round trip, every sub-step a local
-- function/statement call inside the SAME already-open transaction instead of a fresh HTTP/PostgREST
-- round trip each. This migration generalizes that exact pattern to the ORDINARY (non-intercity-
-- parcel) completion path that every local ride, local parcel, and intercity ride goes through --
-- the one actually implicated in the forensic incident above.
--
-- SCOPE, DELIBERATELY MINIMAL: this function performs ONLY the mechanical "apply this
-- already-authorized, already-validated completion" work. It does NOT re-derive or re-check:
--   - auth/JWT identity, ownership (isPassenger/isDriver), or the role-scoped transition guard
--   - the payment-pending completion guards (cashfree/legacy-upi/direct-settlement authorization)
--   - OTP verification
-- All of that stays exactly where it already is, unchanged, in update-order-status/index.ts --
-- this function is only ever reached AFTER every one of those checks has already passed, mirroring
-- exactly how complete_intercity_parcel_delivery is only ever reached after intercity_bookings_
-- screen.dart's own OTP entry. GRANT is service_role-only (NOT authenticated) for exactly this
-- reason: unlike complete_intercity_parcel_delivery (designed for direct authenticated-client calls,
-- with its own auth.uid() ownership check built in), this function trusts its caller's
-- authorization entirely -- it must only ever be reachable via update-order-status's service-role
-- context, never directly from a client.
--
-- Every individual sub-step (settle_rider_assignment, subscription-waiver fare_breakdown, tax,
-- wallet credit, history insert) is copied verbatim from update-order-status/index.ts's current
-- logic -- same filters, same field names, same order of operations, same optimistic-lock guard on
-- the initial UPDATE, same idempotency characteristics (apply_order_government_tax is already
-- idempotent via its own ledger check; credit_rider_for_completed_order's safety comes, as it
-- already did before this change, entirely from this function's own optimistic-lock UPDATE running
-- at most once per real transition -- unchanged).
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
    -- 1. THE COMPLETION UPDATE ITSELF -- identical optimistic-lock shape to the JS it replaces
    -- (`.eq("id", order_id).eq("order_status", currentStatus)`), same columns, same conditional
    -- fare_payment_method/payment_status/fare_paid_at/reference/screenshot writes.
    -- =====================================================
    UPDATE public.orders
    SET order_status = p_new_status::public.order_status_enum,
        completed_at = v_now,
        updated_at = v_now,
        fare_payment_method = COALESCE(p_fare_payment_method_to_set, fare_payment_method),
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
    -- 2. SETTLE ACTIVE ACCEPTED ASSIGNMENT -- identical filter to the JS "settle_rider_assignment" step.
    -- =====================================================
    UPDATE public.rider_assignments
    SET assignment_status = 'expired', updated_at = v_now, responded_at = v_now
    WHERE order_id = p_order_id AND rider_id = v_order.rider_id AND assignment_status = 'accepted';

    -- =====================================================
    -- 3. RIDER SUBSCRIPTION LOOKUP + WAYDROP MAX COMMISSION WAIVER -- identical to the JS
    -- "rider_fetch_for_completion" + conditional calculate_fare_breakdown + waiver UPDATE.
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

    IF v_has_active_subscription THEN
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
    -- 4. DIRECT-COLLECTION DETERMINATION -- byte-for-byte the same rule as update-order-status's
    -- own isDirectCollection computation (walletFareMethod ?? paymentMode/payment_status fallback).
    -- =====================================================
    v_payment_mode := lower(COALESCE(v_order.payment_mode, 'cash'));
    v_fare_method := v_order.fare_payment_method::text;
    v_is_direct_collection := CASE
        WHEN v_fare_method IS NOT NULL THEN v_fare_method IN ('personal_upi', 'cash')
        ELSE (v_payment_mode IN ('cash', 'upi') OR v_order.payment_status::text IS DISTINCT FROM 'paid')
    END;

    v_rider_net_earning := v_rider_earning;
    v_company_cod_share := ROUND(v_commission_amount + v_gst_amount, 2);

    -- =====================================================
    -- 5. GOVERNMENT TAX DUE -- identical call, identical withholding adjustment for a
    -- Cashfree-collected (non-direct) settlement.
    --
    -- NON-FATAL BY DESIGN, same as the JS it replaces ("Never block an otherwise-legitimate
    -- ride/parcel completion on tax-ledger bookkeeping -- log loudly for investigation instead").
    -- The old JS code got this for free (a caught error there just skipped the withholding
    -- adjustment; the order was already committed by an earlier, separate .update() call). Inside
    -- ONE atomic transaction that guarantee has to be explicit: without this nested block, an
    -- unexpected error here would roll back the ENTIRE completion via the function's own outer
    -- EXCEPTION handler -- undoing the order_status write and the wallet credit below over a
    -- tax-ledger problem, which is a strictly worse outcome than before this consolidation.
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
    -- 6. WALLET/EARNINGS CREDIT -- identical call.
    -- =====================================================
    PERFORM public.credit_rider_for_completed_order(
        v_order.rider_id,
        v_rider_net_earning,
        v_is_direct_collection,
        v_company_cod_share
    );

    -- =====================================================
    -- 7. AUDIT HISTORY -- identical shape (no changed_by_rider_id/changed_by_user_id, matching the
    -- general update-order-status insert exactly, NOT the intercity-specific RPC's richer insert).
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

-- service_role ONLY -- see header. This function trusts its caller's authorization entirely and
-- must never be reachable directly from an authenticated client.
REVOKE ALL ON FUNCTION public.complete_order_and_settle(uuid, text, text, text, text, boolean, boolean, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.complete_order_and_settle(uuid, text, text, text, text, boolean, boolean, text, text) TO service_role;
