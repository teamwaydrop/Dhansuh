/**
 * Shared pure calculation functions extracted from the
 * calculate-order-pricing edge function so they can be
 * unit-tested without Deno or Supabase dependencies.
 */

// ──────────────────────────────────────────────
// Haversine distance
// ──────────────────────────────────────────────

export function calculateHaversineDistance(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number,
): number {
  const R = 6371; // Radius of the earth in km
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLon = ((lon2 - lon1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos((lat1 * Math.PI) / 180) *
      Math.cos((lat2 * Math.PI) / 180) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

// ──────────────────────────────────────────────
// Fare calculator
// ──────────────────────────────────────────────

export function calculateFare(
  rules: any,
  rawDistance: number,
  weightKg?: any,
  weightCategory?: string,
): { baseFare: number; extraData: any } {
  let baseFare = 0;
  const extraData: any = {};

  const basePrice = Number(
    rules.base_price ?? rules.minimum_fare ?? rules.base_fare ?? 0,
  );
  const minFare = Number(rules.minimum_fare ?? basePrice ?? 0);

  let distanceCharge = 0;
  if (
    rules.pricing_type === "slab" &&
    Array.isArray(rules.slabs) &&
    rules.slabs.length > 0
  ) {
    const sortedSlabs = [...rules.slabs]
      .map((s: any) => ({
        from_km: Number(s.from_km ?? 0),
        per_km: Number(s.per_km ?? 0),
      }))
      .sort((a, b) => a.from_km - b.from_km);

    for (let i = 0; i < sortedSlabs.length; i++) {
      const slab = sortedSlabs[i];
      const upperBound =
        i + 1 < sortedSlabs.length ? sortedSlabs[i + 1].from_km : rawDistance;
      const kmInSlab = Math.max(
        0,
        Math.min(rawDistance, upperBound) - slab.from_km,
      );
      distanceCharge += kmInSlab * slab.per_km;
    }
  } else {
    const baseDist = Number(
      rules.base_km ?? rules.minimum_distance ?? rules.base_distance ?? 0,
    );
    const perKmCharge = Number(
      rules.after_base_per_km ??
        rules.per_km_charge ??
        rules.per_km ??
        rules.per_km_rate ??
        0,
    );
    distanceCharge = Math.max(0, rawDistance - baseDist) * perKmCharge;
  }

  baseFare = Math.max(minFare, basePrice + distanceCharge);

  // Weight charges
  let weightCharge = 0;
  let inputWeight = 0;
  if (weightKg !== undefined && weightKg !== null && weightKg !== "") {
    inputWeight = Number(String(weightKg).trim());
  } else if (
    weightCategory !== undefined &&
    weightCategory !== null &&
    weightCategory !== ""
  ) {
    inputWeight = Number(String(weightCategory).trim());
  }
  if (isNaN(inputWeight)) {
    inputWeight = 0;
  }

  if (rules.weight_charges && Array.isArray(rules.weight_charges) && inputWeight > 0) {
    const sortedWeightCharges = [...rules.weight_charges].sort(
      (a: any, b: any) => Number(a.max_kg ?? 0) - Number(b.max_kg ?? 0),
    );
    const match = sortedWeightCharges.find(
      (wc: any) => inputWeight <= Number(wc.max_kg ?? 0),
    );
    if (match) {
      weightCharge = Number(match.extra_charge ?? 0);
    } else if (sortedWeightCharges.length > 0) {
      weightCharge = Number(
        sortedWeightCharges[sortedWeightCharges.length - 1].extra_charge ?? 0,
      );
    }
    baseFare += weightCharge;
    extraData.weight_charge = weightCharge;
  }

  return { baseFare, extraData };
}

// ──────────────────────────────────────────────
// Pricing response builder
// ──────────────────────────────────────────────

export interface PricingResponse {
  success: boolean;
  pricing: {
    vehicle_type: string | null;
    order_type: string;
    city_tier: string;
    detected_city: string;
    distance_km: number;
    distance_from_zone_center_km: number | null;
    base_fare: string;
    boost_amount: string;
    subtotal: string;
    commission_percent: number;
    commission_amount: string;
    gst_percentage: number;
    gst_amount: string;
    rider_earning: string;
    final_fare: string;
    discount_percentage: number;
    discount_amount: string;
    fare_after_discount: string;
    [key: string]: any;
  };
}

/**
 * Format a number to 2 decimal places, returning "0.00" for NaN/Infinity.
 */
export function format2(n: number): string {
  if (isNaN(n) || !isFinite(n)) return "0.00";
  return n.toFixed(2);
}

/**
 * Round a fare to the nearest whole rupee (normal half-up rounding: 23.45 -> 23, 23.50 -> 24).
 *
 * This is THE single point where a customer-payable total becomes whole-rupee. Everything that
 * currently reads a fare -- the booking screen, create-order (which calls this same pricing
 * engine server-side and copies its final_fare straight into orders.current_fare), create-payment
 * (which reads orders.final_fare/current_fare for the Cashfree amount), the completed-ride screen,
 * and government-tax/commission calculation at settlement (which all key off
 * orders.final_fare/current_fare) -- inherits whatever value is written here. Rounding a second
 * time anywhere downstream would either be a no-op (the value is already whole) or, worse, a
 * second SOURCE of truth that could disagree with this one -- so nothing downstream should ever
 * re-round a fare it read from the order/pricing response; it should only ever display it.
 */
export function roundToWholeRupee(amount: number): number {
  if (isNaN(amount) || !isFinite(amount)) return 0;
  return Math.round(amount);
}

export function buildPricingResponse(
  baseFare: number,
  maxBoostAmount: number,
  commissionPercent: number,
  gstPercent: number,
  discountPercent: number,
  vehicleType: string,
  orderType: string,
  matchedConfig: any,
  matchedZone: any,
  matchedCity: string,
  rawDistance: number,
  extraData: any,
  matchedDistance?: number,
): PricingResponse {
  // Apply max_boost_percentage limit if configured
  let boost = Number(maxBoostAmount || 0);
  const maxBoostPercent =
    matchedConfig.max_boost_percentage !== null &&
    matchedConfig.max_boost_percentage !== undefined
      ? Number(matchedConfig.max_boost_percentage)
      : 100;
  const maxBoostAllowed = baseFare * (maxBoostPercent / 100);
  if (boost > maxBoostAllowed) {
    boost = maxBoostAllowed;
  }

  // Apply category-specific discount
  const subtotalBeforeDiscount = baseFare + boost;
  const discountAmount =
    subtotalBeforeDiscount * (discountPercent / 100);
  const fareAfterDiscount = Math.max(
    0,
    subtotalBeforeDiscount - discountAmount,
  );

  // All subsequent calculations use the discounted fare. Commission and rider-earning formulas
  // are UNCHANGED (still exactly commissionPercent% / gstPercent% of fareAfterDiscount) --
  // rounding below only affects which bucket absorbs the sub-rupee remainder once the customer-
  // payable total becomes a whole rupee amount.
  const commissionAmount = fareAfterDiscount * (commissionPercent / 100);
  const rawGstAmount = fareAfterDiscount * (gstPercent / 100);
  const riderEarning = fareAfterDiscount - commissionAmount;
  const rawFinalFare = fareAfterDiscount + rawGstAmount;

  // WHOLE-RUPEE ROUNDING (fixes: customer sees ₹52.22 during booking, gets charged ₹52 at
  // payment, partner completion screen shows a third, different figure). finalFare is the ONE
  // customer-payable total -- rounded here, once, at the root of the pricing engine every other
  // system reads from (create-order copies this straight into orders.current_fare; create-payment
  // reads orders.final_fare/current_fare for the Cashfree amount; the completed-ride screen and
  // government-tax/commission settlement both key off the same order columns). The rounding
  // remainder is absorbed into gstAmount (an internal, platform-side bucket never itemized as a
  // separate deduction on the partner-facing completed-ride screen -- see
  // rider_earnings_and_dispatch_fixes_regression_test.dart) so that base_fare + gst_amount always
  // reconciles EXACTLY with the rounded final_fare, the same invariant calculate_fare_breakdown()
  // (the Postgres function used for boost/negotiated fares) already guarantees by construction.
  // Commission and rider_earning are untouched -- still exactly commissionPercent% of the true,
  // unrounded fareAfterDiscount, per the existing (unchanged) commission business logic.
  const finalFare = roundToWholeRupee(rawFinalFare);
  const gstAmount = finalFare - fareAfterDiscount;

  // Additional config-specific extra data
  const finalExtraData = {
    cancellation_fee: format2(
      Number(matchedConfig.cancellation_fee ?? 0),
    ),
    waiting_charge_per_min: format2(
      Number(matchedConfig.waiting_charge_per_min ?? 0),
    ),
    subscription_commission_waiver:
      matchedConfig.subscription_commission_waiver ?? true,
    pricing_code: matchedConfig.pricing_code,
    config_id: matchedConfig.id,
    discount_percentage: discountPercent,
    discount_amount: format2(discountAmount),
    fare_after_discount: format2(fareAfterDiscount),
    ...extraData,
  };

  return {
    success: true,
    pricing: {
      vehicle_type: vehicleType === "delivery" ? null : vehicleType,
      order_type: orderType,
      city_tier:
        matchedConfig.city_tier || matchedZone.zone_type || "tier_2",
      detected_city: matchedCity || matchedZone.zone_name,
      distance_km: rawDistance,
      distance_from_zone_center_km:
        matchedDistance !== undefined
          ? Number(matchedDistance.toFixed(2))
          : null,
      base_fare: format2(baseFare),
      boost_amount: format2(boost),
      subtotal: format2(subtotalBeforeDiscount),
      commission_percent: commissionPercent,
      commission_amount: format2(commissionAmount),
      gst_percentage: gstPercent,
      gst_amount: format2(gstAmount),
      rider_earning: format2(riderEarning),
      final_fare: format2(finalFare),
      ...finalExtraData,
    },
  };
}
