-- =============================================================================
-- ELIGIBLE CASHFREE RIDE — SINGLE-PHASE 2% PG-CHARGE RIDER EARNING
-- Date: 2026-09-01
--
-- BUSINESS RULE (approved). Applies ONLY when ALL FOUR are true at completion:
--   1. orders.order_type            = 'ride'
--   2. rider has an active Free Trial OR active WayDrop MAX
--      (riders.subscription_active = true AND subscription_expires_at > now())
--   3. orders.fare_payment_method   = 'cashfree'   (← PAYMENT-METHOD GUARD — set ONLY by
--                                                  cashfree-webhook / verify-payment on a real,
--                                                  server-verified Cashfree SUCCESS; cash /
--                                                  personal_upi / legacy-upi rides never equal it,
--                                                  update-order-status can never set it)
--   4. orders.payment_status        = 'paid'
--
-- For an eligible ride, AT COMPLETION (synchronous, inside this same transaction — the rider sees
-- the FINAL amount in the wallet immediately, in seconds):
--
--     Rider Net = Customer Paid Fare − (5% of fare, as GST) − (2% of fare, as PG Charge)
--
--     ₹100 → −₹5.00 GST − ₹2.00 PG = ₹93.00
--     ₹21  → −₹1.05 GST − ₹0.42 PG = ₹19.53
--     ₹200 → −₹10.00 GST − ₹4.00 PG = ₹186.00
--
--   • GST is a DIRECT 5% of the customer-paid fare — NOT the GST-inclusive back-calculation
--     (fare/1.05) that calculate_fare_breakdown() produces. ₹100 → ₹5.00 exactly.
--   • PG Charge is a BUSINESS-RULE charge, ALWAYS auto-calculated as 2% of the customer-paid fare.
--     It is NOT Cashfree's actual settlement fee. It is NEVER hardcoded. There is NO T+1/T+2 wait,
--     NO provisional credit, NO settlement reconciliation, NO ledger for rider earnings.
--   • Commission stays 0%.
--   • The additional Government Tax (apply_order_government_tax) is NOT applied for this eligible
--     ride — the single 5% GST above is the only tax line (no double-charge).
--
-- EXPLICITLY UNCHANGED (verified): non-subscriber rides; cash / COD / personal-UPI / direct rides;
-- local parcel; intercity rides; intercity parcels; every non-eligible commission/tax path. Those
-- take the existing `ELSIF v_has_active_subscription AND order_type IN ('ride','local_parcel')`
-- waiver branch (byte-for-byte preserved) or neither branch, and apply_order_government_tax still
-- runs for all of them exactly as before.
--
-- ADDITIVE ONLY: one new nullable-default column (orders.pg_charge_amount), the guard function +
-- its trigger extended by one column, and one CREATE OR REPLACE of complete_order_and_settle
-- (base: 20260901000019_gate_free_trial_waiver_to_local_orders.sql — every pre-existing line
-- preserved; the ONLY additions are the eligible-Cashfree-ride branch, the government-tax skip
-- gate, and the pg_charge_amount write). No enum change. apply_order_government_tax,
-- calculate_fare_breakdown, credit_rider_for_completed_order, and every intercity function are
-- NOT touched.
--
-- This migration also DEFENSIVELY removes the earlier (now-cancelled) two-phase settlement objects
-- (cashfree_fee_ledger / apply_cashfree_fee_adjustment / get_stale_pending_cashfree_fee_provisionals
-- / trigger_reconcile_cashfree_settlements / the reconcile-cashfree-settlements cron job). Those
-- were authored in an earlier draft of this feature and were NEVER applied to any database — the
-- DROP/unschedule statements below are no-ops in that expected case, and a clean removal if a
-- draft migration was somehow applied anywhere. There must be no parallel wallet-credit path.
-- =============================================================================


-- =====================================================================
-- 0. DEFENSIVE CLEANUP of the cancelled two-phase settlement design (no-op if never applied).
-- =====================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
       AND EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'reconcile-cashfree-settlements') THEN
        PERFORM cron.unschedule('reconcile-cashfree-settlements');
    END IF;
END $$;

DROP FUNCTION IF EXISTS public.trigger_reconcile_cashfree_settlements();
DROP FUNCTION IF EXISTS public.apply_cashfree_fee_adjustment(uuid, uuid, numeric, jsonb);
DROP FUNCTION IF EXISTS public.get_stale_pending_cashfree_fee_provisionals(integer);
DROP TABLE IF EXISTS public.cashfree_fee_ledger CASCADE;


-- =====================================================================
-- 1. orders.pg_charge_amount — static breakdown field (like commission_amount / gst_amount).
--    Records the exact PG charge deducted (2% of the fare) for audit/support/reporting and gives
--    the client an unambiguous signal that this order used the new formula. NOT a provisional,
--    NOT a ledger, NOT reconciliation — written once at completion, read only for display.
-- =====================================================================
ALTER TABLE public.orders
    ADD COLUMN IF NOT EXISTS pg_charge_amount numeric NOT NULL DEFAULT 0;


-- =====================================================================
-- 2. protect_order_financial_columns() — extend by ONE column (pg_charge_amount).
--    Base body: 20260730000002_protect_order_fare_columns.sql (the current live definition —
--    nothing after it redefines the body; 20260801000003 only re-scoped the TRIGGER). Reproduced
--    verbatim here + one added OR condition, so the app.bypass_financial_guard escape hatch and
--    the auth.role() <> 'service_role' check are preserved exactly (see 20260725000002 /
--    20260730000002 headers for why this function must never be rebased off a stale body).
--
--    complete_order_and_settle runs as service_role, so auth.role() = 'service_role' there and it
--    writes pg_charge_amount with no bypass flag — identical to how it already writes
--    commission_amount / gst_amount / rider_earning today.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.protect_order_financial_columns()
RETURNS TRIGGER AS $$
BEGIN
    IF auth.role() <> 'service_role'
       AND current_setting('app.bypass_financial_guard', true) IS DISTINCT FROM 'true'
    THEN
        IF NEW.commission_amount IS DISTINCT FROM OLD.commission_amount
           OR NEW.gst_amount IS DISTINCT FROM OLD.gst_amount
           OR NEW.rider_earning IS DISTINCT FROM OLD.rider_earning
           OR NEW.commission_percentage IS DISTINCT FROM OLD.commission_percentage
           OR NEW.gst_percentage IS DISTINCT FROM OLD.gst_percentage
           OR NEW.actual_fare IS DISTINCT FROM OLD.actual_fare
           OR NEW.boost_rider_earning IS DISTINCT FROM OLD.boost_rider_earning
           OR NEW.boost_company_earning IS DISTINCT FROM OLD.boost_company_earning
           OR NEW.payment_status IS DISTINCT FROM OLD.payment_status
           OR NEW.fare_payment_method IS DISTINCT FROM OLD.fare_payment_method
           OR NEW.current_fare IS DISTINCT FROM OLD.current_fare
           OR NEW.final_fare IS DISTINCT FROM OLD.final_fare
           OR NEW.boost_amount IS DISTINCT FROM OLD.boost_amount
           OR NEW.boost_percentage IS DISTINCT FROM OLD.boost_percentage
           -- Added by this migration: the 2% PG-charge breakdown field is server-written only.
           OR NEW.pg_charge_amount IS DISTINCT FROM OLD.pg_charge_amount
        THEN
            RAISE EXCEPTION 'Direct modification of order financial columns is not permitted. Use the appropriate server-side function.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- Re-scope the column-guarded trigger to also fire when pg_charge_amount is in the SET list.
-- Column list = the exact list from 20260801000003_scope_order_protection_triggers_to_guarded_
-- columns.sql + pg_charge_amount. Trigger only; function body already handled above.
DROP TRIGGER IF EXISTS protect_order_financial_columns_trigger ON public.orders;
CREATE TRIGGER protect_order_financial_columns_trigger
BEFORE UPDATE OF
    commission_amount, gst_amount, rider_earning, commission_percentage, gst_percentage,
    actual_fare, boost_rider_earning, boost_company_earning, payment_status, fare_payment_method,
    current_fare, final_fare, boost_amount, boost_percentage, pg_charge_amount
ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.protect_order_financial_columns();


-- =====================================================================
-- 3. complete_order_and_settle() — base: 20260901000019. Every pre-existing line preserved.
--    ADDITIONS ONLY, marked "NEW (pg-charge)":
--      a) v_is_eligible_cashfree_ride / v_skip_government_tax / v_pg_charge declarations
--      b) the eligible-Cashfree-ride branch in step 3 (BEFORE the existing waiver ELSIF, so a
--         cash / QR / non-Cashfree / parcel / intercity / non-subscriber order can NEVER enter it)
--      c) the "IF NOT v_skip_government_tax" gate around the step-5 government-tax call
--    NO provisional. NO ledger. NO phase 2. Step 6 credits the FINAL amount immediately.
-- =====================================================================
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
    -- NEW (pg-charge)
    v_is_eligible_cashfree_ride boolean := false;
    v_skip_government_tax boolean := false;
    v_pg_charge numeric;
BEGIN
    -- =====================================================
    -- 1. THE COMPLETION UPDATE ITSELF -- unchanged from 20260814000000 / 20260901000019.
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
    -- 3. RIDER SUBSCRIPTION LOOKUP + COMMISSION WAIVER.
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

    -- NEW (pg-charge): PAYMENT-METHOD GUARD. All four conditions must hold. fare_payment_method =
    -- 'cashfree' is set ONLY by cashfree-webhook / verify-payment on a real, server-verified
    -- Cashfree SUCCESS -- update-order-status structurally cannot set it, and cash / personal_upi /
    -- legacy-upi rides never equal it. So a direct/cash/QR ride, a parcel, an intercity order, or a
    -- non-subscriber CANNOT enter this branch.
    v_is_eligible_cashfree_ride := (
            v_order.order_type::text = 'ride'
        AND v_has_active_subscription
        AND v_order.fare_payment_method::text = 'cashfree'
        AND v_order.payment_status::text = 'paid'
    );

    IF v_is_eligible_cashfree_ride THEN
        -- ---- NEW RULE: eligible Cashfree ride (Free Trial OR WayDrop MAX) ----
        -- Rider Net = fare - 5% GST - 2% PG charge. Both are a DIRECT % of the customer-paid fare.
        -- Commission 0%. NO government tax. FINAL and immediate -- no provisional, no reconciliation.
        v_gst_amount := ROUND(v_fare * 5.0 / 100.0, 2);              -- ₹100 -> ₹5.00 ; ₹21 -> ₹1.05
        v_pg_charge := ROUND(v_fare * 2.0 / 100.0, 2);               -- ₹100 -> ₹2.00 ; ₹21 -> ₹0.42 (auto, never hardcoded)
        v_commission_amount := 0.0;                                   -- 0% commission preserved
        v_rider_earning := ROUND(v_fare - v_gst_amount - v_pg_charge, 2);  -- ₹100 -> ₹93.00 ; ₹21 -> ₹19.53 (FINAL)
        v_skip_government_tax := true;                                -- apply_order_government_tax NOT called

        UPDATE public.orders
        SET commission_amount = 0.0,
            gst_amount = v_gst_amount,
            pg_charge_amount = v_pg_charge,
            rider_earning = v_rider_earning,
            subscription_commission_waived = true
        WHERE id = p_order_id;

        v_order.commission_amount := v_commission_amount;
        v_order.gst_amount := v_gst_amount;
        v_order.pg_charge_amount := v_pg_charge;
        v_order.rider_earning := v_rider_earning;
        v_order.subscription_commission_waived := true;

    ELSIF v_has_active_subscription AND v_order.order_type::text IN ('ride', 'local_parcel') THEN
        -- ---- EXISTING waiver branch -- byte-for-byte unchanged from 20260901000019 ----
        -- covers: ride + sub + (cash | personal_upi | legacy-upi | unpaid), and
        --         local_parcel + sub + ANY collection method. Still calls calculate_fare_breakdown
        -- (GST-inclusive) and still lets government tax run below, exactly as today.
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
    -- 5. GOVERNMENT TAX DUE -- unchanged, EXCEPT skipped for an eligible Cashfree ride (the single
    --    5% GST line above is that ride's only tax deduction -- no double-charge). Every other
    --    order type / payment method / non-subscriber still runs it exactly as before.
    -- =====================================================
    IF NOT v_skip_government_tax THEN
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
    END IF;

    -- =====================================================
    -- 6. WALLET/EARNINGS CREDIT -- unchanged call. For an eligible Cashfree ride:
    --    v_is_direct_collection = false => the FINAL net (₹93 on ₹100) is credited to wallet_balance
    --    NOW, in this same transaction (seconds). v_rider_net_earning == v_rider_earning because the
    --    government-tax subtraction was skipped. No provisional, no later adjustment.
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
