-- Migration: fix a production 500 in complete_order_and_settle() (20260813000000) --
-- "COALESCE types text and fare_payment_method_enum cannot be matched".
-- Date: 2026-08-14
--
-- ROOT CAUSE #1 (the reported production error): orders.fare_payment_method is a real Postgres
-- enum, public.fare_payment_method_enum (labels: 'personal_upi', 'cashfree', 'cash' -- confirmed
-- live via `SELECT enumlabel FROM pg_enum WHERE enumtypid = 'public.fare_payment_method_enum'::
-- regtype`). The function's p_fare_payment_method_to_set parameter is declared `text`. The line
--   fare_payment_method = COALESCE(p_fare_payment_method_to_set, fare_payment_method)
-- mixes a DECLARED `text` value with an enum-typed column reference inside COALESCE. Postgres's
-- type-resolution rule that lets an UNTYPED string literal ('cash') silently adopt a neighboring
-- enum's type does NOT apply here, because p_fare_payment_method_to_set already has a concrete,
-- non-unknown type (text) -- COALESCE(text, fare_payment_method_enum) has no common type and
-- Postgres refuses to guess, producing exactly the reported error the instant this line runs for
-- any completion that sets fare_payment_method (the driver's "SWIPE TO CONFIRM ₹__ RECEIVED" path
-- on a payment_pending ride, i.e. every Personal QR / Cash / Cashfree confirmation).
--
-- WHY THE OLD (PRE-PHASE-1) JS CODE NEVER HIT THIS: it never ran raw SQL against the enum column at
-- all. `supabase.from("orders").update({ fare_payment_method: resolvedDirectSettlementMethod, ... })`
-- goes through PostgREST, which reads the target column's type from its own schema cache and casts
-- the JSON string value to the matching Postgres enum type as part of building the UPDATE statement
-- -- an implicit cast performed entirely at the PostgREST/HTTP layer, invisible to the SQL author.
-- complete_order_and_settle() writes the same column via a raw SQL UPDATE inside PL/pgSQL, where
-- that layer doesn't exist -- Postgres's own, stricter type-resolution rules for COALESCE apply
-- instead. Phase 1 lost that implicit cast by moving the write from PostgREST's JSON-in/typed-out
-- path to a raw SQL statement without adding the equivalent explicit cast back.
--
-- ROOT CAUSE #2 (found by a read-only probe while investigating #1, NOT reported by the incident
-- yet, but proven to fail identically for every completion, not just the fare_payment_method
-- branch): `v_payment_mode := lower(COALESCE(v_order.payment_mode, 'cash'));` -- orders.payment_mode
-- is also a real enum, public.payment_mode_enum. Here COALESCE itself resolves fine (the untyped
-- literal 'cash' happily adopts the enum type), but the OUTER lower(...) call then fails --
-- `lower(payment_mode_enum)` has no matching overload (confirmed live: `SELECT lower('cash'::
-- payment_mode_enum)` raises `function lower(payment_mode_enum) does not exist`). This line is
-- copied verbatim from complete_intercity_parcel_delivery() (20260730000004), where it has the
-- IDENTICAL latent bug -- that function has simply never been exercised by a real completion yet
-- (confirmed via this investigation's own order-history query: zero intercity_parcel deliveries in
-- the relevant window), so it hasn't surfaced there either. This is a pre-existing schema/code
-- mismatch that predates Phase 1, not something Phase 1 introduced -- Phase 1 only newly exposed it
-- by copying the same pattern into a code path (ordinary ride/parcel completion) that real traffic
-- actually exercises. complete_intercity_parcel_delivery() itself is NOT modified by this migration
-- (out of scope for this fix; flagged for separate follow-up) -- only complete_order_and_settle().
--
-- THE FIX, deliberately minimal -- two explicit casts, nothing else in the function body changes:
--   1. p_fare_payment_method_to_set::public.fare_payment_method_enum inside the COALESCE at the
--      UPDATE's fare_payment_method assignment. When NULL (no direct-settlement declaration this
--      request), COALESCE still falls through to the current column value -- IDENTICAL behavior to
--      before: a null parameter leaves the column exactly as-is (matching the old JS's conditional
--      `if (isCompleting && resolvedDirectSettlementMethod) { updatePayload.fare_payment_method =
--      ... }`, which likewise never touched the column when there was nothing to set). The 3
--      accepted enum labels ('personal_upi', 'cashfree', 'cash') are exactly the same 2 values
--      resolvedDirectSettlementMethod can ever hold ('personal_upi' | 'cash') plus 'cashfree'
--      (never set by this parameter, only ever pre-existing on the row) -- no new/rejected value.
--   2. v_order.payment_mode::text inside the COALESCE feeding lower(...) -- makes the whole
--      expression resolve as text (matching the old JS's `(updatedOrder.payment_mode || 'cash').
--      toLowerCase()`, which always operated on a plain string), so lower() finds its normal
--      lower(text) overload. v_payment_mode was already declared `text`; this only fixes how its
--      value is produced, not its type or any downstream comparison.
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
    -- FIX: p_fare_payment_method_to_set cast to public.fare_payment_method_enum -- see migration
    -- header (ROOT CAUSE #1).
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
    -- FIX: v_order.payment_mode cast to text before lower() -- see migration header (ROOT CAUSE #2).
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
    -- 5. GOVERNMENT TAX DUE -- identical call, identical withholding adjustment for a
    -- Cashfree-collected (non-direct) settlement.
    --
    -- NON-FATAL BY DESIGN, same as the JS it replaces ("Never block an otherwise-legitimate
    -- ride/parcel completion on tax-ledger bookkeeping -- log loudly for investigation instead").
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

-- Re-assert unchanged: service_role ONLY. CREATE OR REPLACE FUNCTION preserves existing grants in
-- Postgres, but re-stating this explicitly documents the invariant and is a no-op if already correct.
REVOKE ALL ON FUNCTION public.complete_order_and_settle(uuid, text, text, text, text, boolean, boolean, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.complete_order_and_settle(uuid, text, text, text, text, boolean, boolean, text, text) TO service_role;
