// Regression tests for the whole-rupee fare rounding fix (2026-09-01).
//
// BUG: the app could show a customer a decimal fare during booking (e.g. ₹52.22) that later
// became a different, inconsistently-rounded amount at payment/settlement. This file proves the
// fix at its root: buildPricingResponse() -- the pure function calculate-order-pricing calls, and
// which create-order.ts also relies on indirectly (it copies pricing.final_fare straight into
// orders.current_fare/final_fare) -- now always returns a whole-rupee final_fare, with GST/
// commission/rider_earning derived consistently from it.
//
// Run with: deno test supabase/functions/calculate-order-pricing/pricing-calculations.test.ts
import { assertEquals, assert } from "https://deno.land/std@0.168.0/testing/asserts.ts";
import { buildPricingResponse, roundToWholeRupee } from "./pricing-calculations.ts";

// =====================================================================
// 1. roundToWholeRupee(): exact examples from the bug report.
// =====================================================================
Deno.test("roundToWholeRupee: ₹23.45 -> ₹23 (round down)", () => {
  assertEquals(roundToWholeRupee(23.45), 23);
});

Deno.test("roundToWholeRupee: ₹23.50 -> ₹24 (round half up, not down)", () => {
  assertEquals(roundToWholeRupee(23.50), 24);
});

Deno.test("roundToWholeRupee: ₹45.45 -> ₹45", () => {
  assertEquals(roundToWholeRupee(45.45), 45);
});

Deno.test("roundToWholeRupee: ₹45.60 -> ₹46", () => {
  assertEquals(roundToWholeRupee(45.60), 46);
});

Deno.test("roundToWholeRupee: ₹52.22 -> ₹52 (the exact reported bug)", () => {
  assertEquals(roundToWholeRupee(52.22), 52);
});

Deno.test("roundToWholeRupee: NaN/Infinity never propagate as garbage", () => {
  assertEquals(roundToWholeRupee(NaN), 0);
  assertEquals(roundToWholeRupee(Infinity), 0);
});

// =====================================================================
// 2. buildPricingResponse(): end-to-end -- the customer-payable total is always whole-rupee, and
//    reconciles EXACTLY with base_fare + gst_amount (no silent drift between the primary total and
//    its own breakdown).
// =====================================================================
function minimalConfig(overrides: Record<string, unknown> = {}) {
  return {
    max_boost_percentage: 100,
    cancellation_fee: 0,
    waiting_charge_per_min: 0,
    subscription_commission_waiver: true,
    pricing_code: "TEST",
    id: "test-config-id",
    ...overrides,
  };
}

Deno.test("buildPricingResponse: reported case -- base fare that would naturally total ₹52.22 becomes a whole ₹52, and base_fare + gst_amount reconciles exactly", () => {
  // Chosen so fareAfterDiscount(49.7333...) + 5% GST = 52.22 before rounding.
  const baseFare = 49.7333333333;
  const result = buildPricingResponse(
    baseFare,
    0, // no boost
    10, // commission %
    5, // gst %
    0, // no discount
    "bike",
    "ride",
    minimalConfig(),
    { zone_type: "tier_2", zone_name: "TestZone" },
    "TestCity",
    5.0,
    {},
  );

  const finalFare = Number(result.pricing.final_fare);
  // Both response fields are independently formatted to 2 decimal places (format2()) -- read the
  // RESPONSE's own base_fare (not the raw, full-float-precision JS `baseFare` local) so the
  // reconciliation check compares what a real caller actually receives.
  const responseBaseFare = Number(result.pricing.base_fare);
  const gstAmount = Number(result.pricing.gst_amount);

  // The customer-payable total must be a whole rupee amount -- no paise.
  assertEquals(Number.isInteger(finalFare), true, `final_fare ${finalFare} must be a whole rupee amount`);
  assertEquals(finalFare, 52);

  // base_fare + gst_amount must reconcile EXACTLY with the rounded final_fare (never a residual
  // paisa drift between the primary total and its own breakdown).
  const reconciled = Number((responseBaseFare + gstAmount).toFixed(2));
  assertEquals(reconciled, finalFare);
});

Deno.test("buildPricingResponse: commission_amount and rider_earning are UNCHANGED by the rounding -- still exactly commissionPercent% of the true (unrounded) fareAfterDiscount", () => {
  const baseFare = 49.7333333333;
  const commissionPercent = 10;
  const result = buildPricingResponse(
    baseFare,
    0,
    commissionPercent,
    5,
    0,
    "bike",
    "ride",
    minimalConfig(),
    { zone_type: "tier_2", zone_name: "TestZone" },
    "TestCity",
    5.0,
    {},
  );

  const expectedCommission = Number((baseFare * (commissionPercent / 100)).toFixed(2));
  const expectedRiderEarning = Number((baseFare - baseFare * (commissionPercent / 100)).toFixed(2));

  assertEquals(Number(result.pricing.commission_amount), expectedCommission);
  assertEquals(Number(result.pricing.rider_earning), expectedRiderEarning);
});

Deno.test("buildPricingResponse: free-trial 0% commission is untouched by rounding -- rider_earning still equals fareAfterDiscount when commissionPercent is 0", () => {
  const baseFare = 49.7333333333;
  const result = buildPricingResponse(
    baseFare,
    0,
    0, // free trial: 0% commission
    5,
    0,
    "bike",
    "ride",
    minimalConfig(),
    { zone_type: "tier_2", zone_name: "TestZone" },
    "TestCity",
    5.0,
    {},
  );

  assertEquals(Number(result.pricing.commission_amount), 0);
  assertEquals(Number(result.pricing.rider_earning), Number(baseFare.toFixed(2)));
  // The whole-rupee total is unaffected by commission being 0%.
  assertEquals(Number.isInteger(Number(result.pricing.final_fare)), true);
});

Deno.test("buildPricingResponse: every example fare from the bug report rounds correctly end-to-end (₹23.45, ₹45.45, ₹52.22 style totals)", () => {
  // Reverse-engineer a base fare (at 5% GST) that lands just under each reported total.
  const cases: Array<{ target: number; expectedRounded: number }> = [
    { target: 23.45, expectedRounded: 23 },
    { target: 45.45, expectedRounded: 45 },
    { target: 52.22, expectedRounded: 52 },
  ];

  for (const { target, expectedRounded } of cases) {
    const impliedBase = target / 1.05;
    const result = buildPricingResponse(
      impliedBase,
      0,
      10,
      5,
      0,
      "bike",
      "ride",
      minimalConfig(),
      { zone_type: "tier_2", zone_name: "TestZone" },
      "TestCity",
      5.0,
      {},
    );
    assertEquals(Number(result.pricing.final_fare), expectedRounded, `target ${target} should round to ${expectedRounded}`);
  }
});

Deno.test("buildPricingResponse: result stays whole-rupee even after a discount is applied (discount math itself is unchanged)", () => {
  const baseFare = 100;
  const result = buildPricingResponse(
    baseFare,
    0,
    10,
    5,
    7, // 7% discount, deliberately not a round number
    "bike",
    "ride",
    minimalConfig(),
    { zone_type: "tier_2", zone_name: "TestZone" },
    "TestCity",
    5.0,
    {},
  );
  assert(Number.isInteger(Number(result.pricing.final_fare)));
});
