-- =============================================================================
-- ELIGIBLE CASHFREE RIDE — WALLET NET NO LONGER DEDUCTS GST (Phase 12, Part A)
-- Date: 2026-09-01
--
-- BUSINESS RULE CHANGE (approved). Base: 20260901000037_eligible_cashfree_ride_pg_charge.sql.
-- The eligible-Cashfree-ride branch of complete_order_and_settle() previously deducted BOTH the
-- 5% GST and the 2% PG charge from the rider's wallet-credited earning:
--
--     v_rider_earning := ROUND(v_fare - v_gst_amount - v_pg_charge, 2);   -- ₹100 -> ₹93.00 (OLD)
--
-- AUDIT FINDING: this does not match how the existing, correct personal-QR/cash subscriber flow
-- treats GST. In that flow (the unchanged ELSIF branch just below this one in the same function),
-- GST is never subtracted from a wallet credit at all -- for a direct-collection order,
-- credit_rider_for_completed_order() credits wallet_balance with ZERO (the rider already
-- physically holds the customer's payment) and instead adds the GST+commission portion to
-- cod_pending_amount ("Cash to be Paid"), a liability the rider owes the company separately. GST
-- is therefore always a SEPARATE bucket, never a wallet deduction, in the reference-correct flow.
--
-- For an eligible Cashfree ride, the company already holds the full customer payment (Cashfree is
-- NOT direct collection), so there is no equivalent "Cash to be Paid" liability path available --
-- credit_rider_for_completed_order() credits wallet_balance directly with whatever rider_earning
-- is computed here. To keep GST out of the wallet deduction (matching the personal-QR semantics),
-- this migration removes the GST subtraction from the wallet-credited amount for this one branch:
--
--     v_rider_earning := ROUND(v_fare - v_pg_charge, 2);                  -- ₹100 -> ₹98.00 (NEW)
--
-- orders.gst_amount is STILL computed and written exactly as before (v_gst_amount = fare * 5%) --
-- it remains a fully separate, reporting-only figure (per your target diagram's "Government GST ->
-- separate GST/tax amount/bucket"), simply no longer subtracted from what lands in the wallet.
-- cash_to_be_paid (cod_pending_amount) is untouched -- it was already correctly unaffected for
-- Cashfree (non-direct-collection) rides, both before and after this change.
--
-- EXPLICITLY UNCHANGED: GST calculation itself (still fare * 5%, still written to orders.gst_amount
-- unchanged), the Cashfree gross customer payment, commission logic (still 0%), the payment-method
-- eligibility guard (all 4 conditions, byte-for-byte identical), the government-tax skip gate, the
-- personal-QR/cash waiver ELSIF branch (byte-for-byte identical), cashfree-webhook, verify-payment,
-- credit_rider_for_completed_order, payout/withdrawal logic, and every non-eligible order path.
--
-- ADDITIVE ONLY: one CREATE OR REPLACE of complete_order_and_settle (base: 20260901000037 --
-- every pre-existing line preserved byte-for-byte except the single v_rider_earning assignment
-- inside the eligible-Cashfree-ride branch). No new column, no enum change, no other function
-- touched.
-- =============================================================================

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
        -- ---- Eligible Cashfree ride (Free Trial OR WayDrop MAX) ----
        -- GST is still computed and recorded exactly as before (a DIRECT 5% of the customer-paid
        -- fare, written to orders.gst_amount) -- but per Phase 12 Part A, it is a SEPARATE,
        -- reporting-only figure and is no longer subtracted from the wallet-credited rider_earning.
        -- Only the Cashfree PG charge (2% of fare) is deducted from the wallet. Commission stays 0%.
        -- NO government tax (unchanged). FINAL and immediate -- no provisional, no reconciliation.
        v_gst_amount := ROUND(v_fare * 5.0 / 100.0, 2);              -- ₹100 -> ₹5.00 ; ₹21 -> ₹1.05 (recorded, not deducted)
        v_pg_charge := ROUND(v_fare * 2.0 / 100.0, 2);               -- ₹100 -> ₹2.00 ; ₹21 -> ₹0.42 (auto, never hardcoded)
        v_commission_amount := 0.0;                                   -- 0% commission preserved
        v_rider_earning := ROUND(v_fare - v_pg_charge, 2);            -- ₹100 -> ₹98.00 ; ₹21 -> ₹20.58 (FINAL) -- GST no longer subtracted here
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
    -- 5. GOVERNMENT TAX DUE -- unchanged, EXCEPT skipped for an eligible Cashfree ride (unchanged
    --    from 20260901000037). Every other order type / payment method / non-subscriber still runs
    --    it exactly as before.
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
    --    v_is_direct_collection = false => the FINAL net (₹98 on ₹100, PG charge only) is credited
    --    to wallet_balance NOW, in this same transaction (seconds). v_rider_net_earning ==
    --    v_rider_earning because the government-tax subtraction was skipped. No provisional, no
    --    later adjustment.
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
