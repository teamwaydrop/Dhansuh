-- =============================================================================
-- TEMPORARY BUSINESS DECISION: Platform GST effective amount = 0 for all current rides/parcels.
-- Date: 2026-09-05
--
-- CONTEXT (from the completed accounting audit): orders.gst_amount ("Platform GST") is a
-- GST-inclusive decomposition of the customer-paid fare -- base_fare = fare / (1 + gst%/100),
-- gst_amount = fare - base_fare -- computed by calculate_fare_breakdown() and used in two places:
--   1. complete_order_and_settle(): v_company_cod_share = commission_amount + gst_amount, which
--      becomes riders.cod_pending_amount ("Cash to be Paid") for a direct-collection (Personal
--      QR/Cash) ride.
--   2. The rider-facing completion-screen display formula (Dart,
--      rider_active_order_screen.dart:3977-3979): riderEarning + gstAmount - governmentTaxAmount.
-- Pending CA/GST-practitioner confirmation on whether this Platform GST bucket is a genuine
-- separate liability or should not be charged to the rider at all (see the accounting
-- clarification note prepared the same day), business has decided: charge NOTHING for Platform
-- GST for now, while keeping every column/function/downstream consumer fully intact so this can
-- be reverted with a one-line change once CA guidance is received.
--
-- SCOPE: calculate_fare_breakdown() ONLY -- the single shared function behind accept-order,
-- boost-order-fare, confirm_intercity_booking(), the free-trial/WayDrop-MAX commission-waiver
-- branch of complete_order_and_settle(), and complete_intercity_parcel_delivery(). This covers
-- every NON-subscription-PG-charge ride and parcel uniformly, with zero duplicated formulas.
--
-- EXPLICITLY NOT TOUCHED (per the business requirement's own exclusions):
--   - The eligible-Cashfree-ride PG-charge branch inside complete_order_and_settle() (migration
--     20260901000038) computes its OWN v_gst_amount inline (v_fare * 5%, recorded but never
--     deducted from the wallet even today) -- that is subscription-gated logic (requires an
--     active WayDrop MAX/free-trial subscription) and is left completely unchanged, per "Do NOT
--     change subscription logic."
--   - Government Tax (apply_order_government_tax, tax_rate_config) -- untouched, still 5% of the
--     gross fare, still written to government_tax_ledger / government_tax_due_balance exactly as
--     before.
--   - WayDrop commission -- the FORMULA and its BASE (v_base_fare, still decomposed at the real
--     configured GST rate purely to derive the commission base) are byte-for-byte unchanged, so
--     the commission RESULT is identical to before this migration (e.g. ₹2.00 on a ₹21 ride at
--     10%/5%, exactly as audited).
--   - Ride fare / customer payment amount / Cashfree order amount -- none of these read
--     gst_amount or rider_earning; all are driven by orders.final_fare/current_fare, untouched.
--   - orders.gst_amount the COLUMN, and every schema/trigger/index around it -- untouched. Only
--     the VALUE calculate_fare_breakdown() now returns for it changes (0 instead of the decomposed
--     amount).
--
-- EXACT CHANGE (2 lines inside calculate_fare_breakdown(), everything else byte-for-byte
-- identical to the live definition in 20260901000018_whole_rupee_fare_rounding.sql):
--   1. v_gst_amount := 0;                                            -- was: ROUND(v_new_total_fare - v_base_fare, 2)
--   2. v_rider_earning := ROUND(v_new_total_fare - v_commission_amount, 2);  -- was: ROUND(v_base_fare - v_commission_amount, 2)
-- Effect of #2: the GST portion that used to stay with the base-fare decomposition (and was
-- therefore silently excluded from the rider's credited/settled earning) is now included in
-- rider_earning instead -- i.e. the ₹1.00 that Platform GST used to keep out of the rider's
-- earning is now given back to the rider, which is the direct monetary meaning of "Platform GST
-- is 0": nothing is withheld for it anywhere downstream.
--   For a ₹21 ride (10% commission, 5% GST config, 5% government tax):
--     base_fare (internal only, commission base)  = 20.00   (UNCHANGED formula/value)
--     commission_amount                            = 2.00    (UNCHANGED)
--     gst_amount                                   = 0.00    (was 1.00)
--     rider_earning                                = 21.00 - 2.00 = 19.00   (was 20.00 - 2.00 = 18.00)
--   Direct-collection (Personal QR/Cash): cod_pending_amount += commission_amount + gst_amount
--     = 2.00 + 0.00 = 2.00 (was 3.00). government_tax_due_balance unaffected, still += 1.05.
--   Cashfree (non-subscription): government tax is withheld from rider_earning in
--     complete_order_and_settle() exactly as before: 19.00 - 1.05 = 17.95 net (was 18.00 - 1.05 =
--     16.95) -- credited to wallet_balance.
--   Completion-screen display (Dart, unchanged formula): riderEarning + gstAmount - govTax
--     = 19.00 + 0.00 - 1.05 = 17.95 -- now equal to the ACTUAL wallet credit, not just a display
--     reconstruction, since Platform GST no longer creates a gap between the two.
--
-- TO RE-ENABLE Platform GST later: revert exactly these 2 lines back to their commented "was"
-- values in a new migration (or restore this function from 20260901000018) -- no other file, no
-- data repair, and no schema change is needed either way.
-- =============================================================================

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
    -- WHOLE-RUPEE ROUNDING (20260901000018, unchanged): single point for every post-booking fare
    -- change: boost, intercity negotiation acceptance, plain accept-order re-derivation, and the
    -- fresh commission/GST/rider_earning recompute complete_order_and_settle() and
    -- complete_intercity_parcel_delivery() both run at ride completion.
    v_new_total_fare := ROUND(COALESCE(p_new_total_fare, 0), 0);

    -- Commission base: UNCHANGED -- still the real GST-inclusive decomposition at the order's
    -- actual configured gst_percentage, so the commission RESULT below is identical to before
    -- this migration. This is intentionally NOT set to 0 -- only the amount CHARGED as Platform
    -- GST (v_gst_amount, below) and rider_earning's source are affected.
    v_base_fare := ROUND(v_new_total_fare / (1 + (COALESCE(p_gst_percentage, 5.0) / 100.0)), 2);

    -- PLATFORM GST TEMPORARILY DISABLED (business decision, pending CA/GST confirmation -- see
    -- migration header). Effective amount is 0 -- the column/formula capability is fully
    -- preserved; only the value returned here changes. Re-enable by restoring:
    --   v_gst_amount := ROUND(v_new_total_fare - v_base_fare, 2);
    v_gst_amount := 0;

    -- Signed delta vs. the order's original base fare -- unchanged, still uses v_base_fare (the
    -- commission base), independent of the Platform GST toggle above.
    v_boost_amount := ROUND(v_base_fare - COALESCE(p_actual_fare, 0), 2);
    v_boost_percentage := CASE
        WHEN COALESCE(p_actual_fare, 0) > 0 THEN ROUND((v_boost_amount / p_actual_fare) * 100, 2)
        ELSE 0
    END;
    v_boost_rider_earning := ROUND(v_boost_amount * 0.80, 2);
    v_boost_company_earning := ROUND(v_boost_amount * 0.20, 2);

    -- Commission: UNCHANGED formula and base -- same result as before this migration.
    v_commission_amount := ROUND(v_base_fare * (COALESCE(p_commission_percentage, 0) / 100.0), 2);

    -- RIDER EARNING: was `v_base_fare - v_commission_amount` (which silently excluded the Platform
    -- GST portion from the rider). Now `v_new_total_fare - v_commission_amount` -- with Platform
    -- GST charged at 0, nothing is withheld from the rider for it; the full fare minus commission
    -- only (Government Tax is handled separately, unchanged, in complete_order_and_settle()).
    -- Re-enable Platform GST by restoring: v_rider_earning := ROUND(v_base_fare - v_commission_amount, 2);
    v_rider_earning := ROUND(v_new_total_fare - v_commission_amount, 2);

    -- Whole-rupee here too: a promo-discounted final_fare is still the customer's actual payable
    -- amount and must never carry paise either. Unchanged.
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
