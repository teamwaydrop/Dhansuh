-- =====================================================================
-- FIX: Live intercity_parcel per-km rate drift (production charges ₹3/km, must be ₹2.50/km)
-- =====================================================================
-- CONFIRMED LIVE (fresh read-only production check, 2026-09-06):
--   The two active, zone-specific intercity_parcel pricing_config rows both carry
--   pricing_rules = {"base_km":0,"min_fare":0,"base_fare":0,"per_km_rate":3,"pricing_type":"per_km_flat"}
--     3fa07f40-8c9c-49ae-83a8-00dcbfc8f625  INTERCITY_PARCEL_AUTO_ZONE_WARANGAL  (auto, zone Warangal)
--     61c9db87-d99e-4da2-b099-2044876d35ad  INTERCITY_PARCEL_BIKE_ZONE_WARANGAL  (bike, zone Warangal)
--   A live HTTP call to calculate-order-pricing returns base_fare = 300.00 for a 100 km
--   intercity_parcel route (= 3 × 100) from both rows.
--
-- ROOT CAUSE:
--   calculate-order-pricing/pricing-calculations.ts calculateFare() reads the per-km rate as
--       rules.after_base_per_km ?? rules.per_km_charge ?? rules.per_km ?? rules.per_km_rate ?? 0
--   These two rows contain ONLY `per_km_rate` among those keys, so the operative rate is
--   per_km_rate = 3. pricing_type is "per_km_flat" (not "slab"), base_km = 0, and no
--   base_price/minimum_fare key is set, so baseFare reduces to exactly distance × per_km_rate.
--   Authoritative rate is ₹2.50/km, established by
--   20260728000000_fix_intercity_parcel_pricing_and_fare_guard.sql (which set the same key to 2.5
--   with `jsonb_set(pricing_rules,'{per_km_rate}','2.5')`); production has since drifted back to 3
--   (dashboard edit — not reproducible from any migration). This migration re-applies the
--   authoritative value, forward-only.
--
-- SCOPE — this migration changes ONLY the numeric per_km_rate value on those two rows:
--   * The generic row 060ee360-25ea-4530-b65b-95c14a014fb9 (PRICE_INTERCITY_PARCEL_V1,
--     vehicle_type NULL, pricing_zone_id NULL) is deliberately NOT touched. It is never resolved
--     by calculate-order-pricing (resolvePricingConfig() requires pricing_zone_id === matchedZoneId
--     and the only active zone, Warangal, has explicit rows), and it already computes ₹2.50/km
--     anyway because it carries `per_km` = 2.5, which outranks its stale `per_km_rate` = 3 in the
--     precedence chain above. Reconciling its leftover `per_km_rate` is out of scope here.
--   * No other JSON field is modified (jsonb_set preserves base_km / min_fare / base_fare /
--     pricing_type). No GST, commission, discount, boost, wallet, subscription, travel-plan,
--     intercity_ride, or local pricing is touched. No other city/zone has an intercity_parcel row.
--   * No previously-applied migration is edited (forward-only; 20260728000000 stays as-is).
--
-- FAIL-SAFE: the UPDATE only matches rows that are (a) active, (b) zone-specific, (c) currently at
--   per_km_rate = 3, and (d) carry NONE of the higher-precedence rate keys. If production has
--   since gained a shadowing key (after_base_per_km / per_km_charge / per_km) on these rows, the
--   UPDATE no-ops and the post-condition assertion below fails loudly (transaction rolls back)
--   rather than silently writing a value the pricing engine would ignore. Re-running after a
--   successful apply is a clean no-op (clause (c) no longer matches).
-- =====================================================================

UPDATE public.pricing_config
SET pricing_rules = jsonb_set(pricing_rules, '{per_km_rate}', '2.5'::jsonb),
    updated_at = now()
WHERE service_type = 'intercity_parcel'
  AND is_active = true
  AND pricing_zone_id IS NOT NULL
  AND vehicle_type IN ('bike', 'auto')
  AND (pricing_rules ->> 'per_km_rate') = '3'
  AND NOT (pricing_rules ? 'after_base_per_km')
  AND NOT (pricing_rules ? 'per_km_charge')
  AND NOT (pricing_rules ? 'per_km');

-- Post-condition: every active, zone-specific intercity_parcel row must now resolve to exactly
-- ₹2.50/km through the same precedence chain calculateFare() uses. Fails the migration otherwise.
DO $$
DECLARE
    v_bad_count int;
    v_bad_detail text;
BEGIN
    SELECT count(*),
           string_agg(pricing_code || '=' || COALESCE(
               pricing_rules ->> 'after_base_per_km',
               pricing_rules ->> 'per_km_charge',
               pricing_rules ->> 'per_km',
               pricing_rules ->> 'per_km_rate',
               '0'), ', ')
      INTO v_bad_count, v_bad_detail
      FROM public.pricing_config
     WHERE service_type = 'intercity_parcel'
       AND is_active = true
       AND pricing_zone_id IS NOT NULL
       AND COALESCE(
               (pricing_rules ->> 'after_base_per_km')::numeric,
               (pricing_rules ->> 'per_km_charge')::numeric,
               (pricing_rules ->> 'per_km')::numeric,
               (pricing_rules ->> 'per_km_rate')::numeric,
               0) <> 2.5;

    IF v_bad_count > 0 THEN
        RAISE EXCEPTION 'intercity_parcel per-km rate drift NOT fixed for % row(s): %', v_bad_count, v_bad_detail;
    END IF;

    RAISE NOTICE 'intercity_parcel per-km rate: all active zone-specific rows now resolve to 2.5/km';
END $$;
