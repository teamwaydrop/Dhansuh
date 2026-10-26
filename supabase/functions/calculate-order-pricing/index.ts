// supabase/functions/calculate-order-pricing/index.ts

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
// Shared pure calculation functions (local import for Deno deployment)
import {
  calculateHaversineDistance,
  calculateFare,
  buildPricingResponse,
} from "./pricing-calculations.ts";
import { getActivePricingConfigs } from "../_shared/pricing_config_cache.ts";
import { getActivePricingZones } from "../_shared/pricing_zones_cache.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

async function resolveZone(
  supabase: any,
  pickupAddress: string,
  pickupLat?: number,
  pickupLng?: number,
  pickupCity?: string,
  activeZonesPromise?: ReturnType<typeof getActivePricingZones>,
): Promise<{ matchedZone: any; matchedCity: string; distance?: number } | null> {
  // Cached (Phase 10E 2D) -- see _shared/pricing_zones_cache.ts. Isolate-scoped, 30s TTL, in-flight
  // de-dup; returns null on a fetch error exactly as the old inline query's `if (zoneError)` path
  // did. The full active-zone set is fetched once and the geofence / city / address matching below
  // runs over it in memory, returning the identical rows the old `WHERE is_active = true` query
  // did.
  const activeZones = await (activeZonesPromise ?? getActivePricingZones(supabase));

  if (activeZones === null) {
    return null;
  }

  // 1. Try Geofencing first (if coordinates are present)
  if (pickupLat !== undefined && pickupLat !== null && pickupLng !== undefined && pickupLng !== null) {
    let bestZone: any = null;
    let minDistance: number | null = null;

    for (const zone of activeZones || []) {
      if (zone.center_lat === null || zone.center_lng === null || zone.radius_km === null) {
        continue;
      }

      const dist = calculateHaversineDistance(
        pickupLat,
        pickupLng,
        zone.center_lat,
        zone.center_lng
      );

      if (dist <= zone.radius_km) {
        if (minDistance === null || dist < minDistance) {
          minDistance = dist;
          bestZone = zone;
        }
      }
    }

    if (bestZone) {
      console.log(`Matched pricing zone via geofencing: "${bestZone.zone_name}" (distance: ${minDistance?.toFixed(2)} km)`);
      return { matchedZone: bestZone, matchedCity: bestZone.zone_name, distance: minDistance ?? undefined };
    }
  }

  // 2. Fallback: Match by city name if pickupCity is provided
  if (pickupCity) {
    const cleanCity = pickupCity.trim().toLowerCase();
    for (const zone of activeZones || []) {
      if (zone.cities && Array.isArray(zone.cities)) {
        if (zone.cities.some((c: string) => c.trim().toLowerCase() === cleanCity)) {
          console.log(`Matched pricing zone via city name fallback: "${zone.zone_name}" (city: "${pickupCity}")`);
          return { matchedZone: zone, matchedCity: pickupCity, distance: 0.0 };
        }
      }
    }
  }

  // 3. Fallback: Match if pickupAddress contains any city in the zone
  if (pickupAddress) {
    const cleanAddress = pickupAddress.toLowerCase();
    for (const zone of activeZones || []) {
      if (zone.cities && Array.isArray(zone.cities)) {
        for (const c of zone.cities) {
          const cleanC = c.trim().toLowerCase();
          if (cleanC && cleanAddress.includes(cleanC)) {
            console.log(`Matched pricing zone via address fallback: "${zone.zone_name}" (city detected: "${c}")`);
            return { matchedZone: zone, matchedCity: c, distance: 0.0 };
          }
        }
      }
    }
  }

  console.log("resolveZone => No matching zone found");
  return null;
}

// =====================================================
// 2. PRICING CONFIG RESOLVER
// =====================================================
async function resolvePricingConfig(
  supabase: any,
  orderType: string,
  vehicleType: string,
  matchedZoneId: string,
  weightKg?: any,
  weightCategory?: string,
  activeConfigsPromise?: ReturnType<typeof getActivePricingConfigs>,
): Promise<any | null> {
  // Cached (Performance Roadmap P0 Task 1) -- see _shared/pricing_config_cache.ts. Fetches every
  // active+approved pricing_config row once (isolate-scoped, 30s TTL) instead of issuing a fresh
  // query per service_type/zone combination on every request; filtering in memory below returns
  // exactly the same rows the original per-combination WHERE clause did.
  const allConfigs = await (activeConfigsPromise ?? getActivePricingConfigs(supabase));
  if (allConfigs === null) {
    console.error("Error fetching pricing config");
    return null;
  }

  let targetServiceType = orderType;
  let dbConfigs = allConfigs.filter(
    (c: any) => c.service_type === targetServiceType && c.pricing_zone_id === matchedZoneId,
  );

  // Fallback to base service type if no configs found for intercity/sharing types
  if (!dbConfigs || dbConfigs.length === 0) {
    if (orderType === "intercity_ride" || orderType === "ride_sharing") {
      targetServiceType = "ride";
    } else if (orderType === "intercity_parcel" || orderType === "batch_delivery") {
      targetServiceType = "local_parcel";
    }

    if (targetServiceType !== orderType) {
      dbConfigs = allConfigs.filter(
        (c: any) => c.service_type === targetServiceType && c.pricing_zone_id === matchedZoneId,
      );
    }
  }

  if (!dbConfigs || dbConfigs.length === 0) {
    return null;
  }

  // Handle generic 'delivery' request vehicle type by dynamically checking max_weight_kg rules
  if (vehicleType === "delivery") {
    let inputWeight = 0;
    if (weightKg !== undefined && weightKg !== null && weightKg !== "") {
      inputWeight = Number(String(weightKg).trim());
    } else if (weightCategory !== undefined && weightCategory !== null && weightCategory !== "") {
      inputWeight = Number(String(weightCategory).trim());
    }
    if (isNaN(inputWeight)) {
      inputWeight = 0;
    }

    const eligibleConfigs = dbConfigs.filter((c: any) => {
      const rules = typeof c.pricing_rules === "string" ? JSON.parse(c.pricing_rules) : (c.pricing_rules || {});
      const maxWeight = rules.max_weight_kg !== undefined ? Number(rules.max_weight_kg) : Infinity;
      return inputWeight <= maxWeight;
    });

    if (eligibleConfigs.length === 0) {
      return null;
    }

    // Sort eligible configs by base price to select the cheapest vehicle config
    eligibleConfigs.sort((a: any, b: any) => {
      const rulesA = typeof a.pricing_rules === "string" ? JSON.parse(a.pricing_rules) : (a.pricing_rules || {});
      const rulesB = typeof b.pricing_rules === "string" ? JSON.parse(b.pricing_rules) : (b.pricing_rules || {});
      
      const priceA = Number(rulesA.base_price ?? rulesA.minimum_fare ?? rulesA.base_fare ?? 0);
      const priceB = Number(rulesB.base_price ?? rulesB.minimum_fare ?? rulesB.base_fare ?? 0);
      
      return priceA - priceB;
    });

    return eligibleConfigs[0];
  }

  // No vehicle preference (e.g. an intercity Travel Request, which matches
  // travellers across bike/auto/cab rather than locking to one vehicle):
  // every vehicle-type config for intercity_ride/intercity_parcel is priced
  // identically (see the *_pricing_config seed migrations) — only
  // commission_percentage differs, which doesn't affect the passenger's
  // fare. Prefer 'bike' for a deterministic pick, else fall back to any
  // active config for this service type/zone.
  if (
    (vehicleType === "any" || !vehicleType) &&
    (orderType === "intercity_ride" || orderType === "intercity_parcel")
  ) {
    return (
      dbConfigs.find((c: any) => c.vehicle_type === "bike") ||
      dbConfigs[0] ||
      null
    );
  }

  // Otherwise, match the specific vehicle type config
  const matchedConfig = dbConfigs.find(
    (c) => c.vehicle_type === vehicleType
  );

  return matchedConfig || null;
}

// Developer Test Mode is relevant only when normal zone matching fails. Keeping this lookup out of
// the in-zone critical path avoids making every production quote wait for auth + users reads while
// preserving the existing unmatched-zone bypass and developer_test_mode response semantics.
async function resolveDeveloperAccount(
  supabase: Parameters<typeof getActivePricingZones>[0],
  req: Request,
): Promise<boolean> {
  let isDev = false;
  try {
    const authToken = req.headers.get("Authorization")?.replace("Bearer ", "");
    if (authToken) {
      const { data: authData } = await supabase.auth.getUser(authToken);
      if (authData?.user) {
        const { data: callerProfile } = await supabase
          .from("users")
          .select("is_developer, role")
          .eq("id", authData.user.id)
          .maybeSingle();
        isDev = callerProfile?.is_developer === true || callerProfile?.role === "admin";
      }
    }
  } catch (identityError) {
    console.error("Developer mode identity check failed (non-fatal):", identityError);
  }
  return isDev;
}

// =====================================================
// SERVER ENTRY POINT
// =====================================================
serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: corsHeaders,
    });
  }

  try {
    const body = await req.json();
    console.log(
      "calculate-order-pricing request:",
      JSON.stringify(body, null, 2)
    );

    const {
      order_type,
      vehicle_type,
      distance_km,
      pickup_address,
      pickup_city,
      max_boost_amount = 0,
      weight_category,
      weight_kg,
    } = body;

    const pickupLat = body.pickup_lat ?? body.pickup_latitude ?? body.latitude;
    const pickupLng = body.pickup_lng ?? body.pickup_longitude ?? body.longitude;

    if (
      pickupLat === undefined || pickupLat === null ||
      pickupLng === undefined || pickupLng === null ||
      !order_type ||
      !vehicle_type ||
      distance_km === undefined || distance_km === null
    ) {
      const missing = [];
      if (pickupLat === undefined || pickupLat === null) missing.push("pickup_lat");
      if (pickupLng === undefined || pickupLng === null) missing.push("pickup_lng");
      if (!order_type) missing.push("order_type");
      if (!vehicle_type) missing.push("vehicle_type");
      if (distance_km === undefined || distance_km === null) missing.push("distance_km");
      
      const reason = `Missing required fields: ${missing.join(", ")}`;
      console.error("Pricing validation failed:", reason);

      return new Response(
        JSON.stringify({
          success: false,
          error: `pickup_lat, pickup_lng, order_type, vehicle_type, and distance_km are required parameters. ${reason}`,
        }),
        {
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json",
          },
          status: 400,
        }
      );
    }

    const rawDistance = Number(distance_km || 0);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Developer Test Mode: resolve the caller's identity (best-effort — a
    // missing/invalid token just means "not a developer", it never blocks
    // normal pricing requests) and check if they're flagged is_developer or
    // role = 'admin'. Mirrors the same rule as DeveloperModeService on the
    // client, kept in sync intentionally.
    //
    // The identity result is only needed if normal zone matching fails. Resolve it lazily below so
    // ordinary in-zone pricing never waits for auth + users reads.
    // Zone/config rows are independent immutable configuration reads. Start both together so the
    // config fetch progresses while zone matching runs instead of stacking their backend waits.
    // Passing the original promises into the existing resolvers preserves their cache, filtering,
    // and error behavior.
    const activeZonesPromise = getActivePricingZones(supabase);
    const activeConfigsPromise = getActivePricingConfigs(supabase);
    // An unmatched zone can return before config is needed. Observe a possible rejection to avoid
    // an abandoned promise becoming unhandled; awaiting the original promise below still preserves
    // its existing rejection/500 behavior on paths that require pricing config.
    void activeConfigsPromise.catch(() => undefined);

    let isDeveloperAccount = false;
    // 1. Resolve Zone & City. Normal in-zone pricing does not need developer identity.
    let zoneInfo = await resolveZone(
      supabase,
      pickup_address,
      pickupLat,
      pickupLng,
      pickup_city,
      activeZonesPromise,
    );
    const matchedNormally = zoneInfo !== null;
    let usedDeveloperZoneBypass = false;
    if (!zoneInfo) {
      // Preserve the existing developer-only fallback and developer_test_mode flag. Identity is
      // still best-effort, but it is now paid only on the unmatched-zone path where it can matter.
      isDeveloperAccount = await resolveDeveloperAccount(supabase, req);

      // For intercity services (cross-zone by design) or Developer Test Mode
      // accounts (testing outside configured zones), fallback to any active
      // zone so pricing can still be calculated.
      if (
        isDeveloperAccount ||
        order_type === "intercity_ride" ||
        order_type === "intercity_parcel" ||
        (order_type === "ride" && rawDistance > 20.0)
      ) {
        // Cached (Phase 10E 2D) -- same active-zone set resolveZone() reads. The old query used
        // `.limit(1)` with no ORDER BY, i.e. "any active zone" (as the comment above states); the
        // cached list's [0] satisfies that contract and is deterministic within the 30s window.
        // Keep the original helper call here rather than reusing the first promise: a successful
        // read is still an immediate cache hit, while a transient first-read error retains the
        // previous fallback-path retry semantics.
        const fallbackZones = await getActivePricingZones(supabase);
        if (fallbackZones && fallbackZones.length > 0) {
          zoneInfo = { matchedZone: fallbackZones[0], matchedCity: fallbackZones[0].zone_name };
          usedDeveloperZoneBypass = isDeveloperAccount;
        }
      }
    }

    if (!zoneInfo) {
      console.log(`No active pricing zone matches pickup location.`);
      return new Response(
        JSON.stringify({
          success: false,
          error: "not found",
        }),
        {
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json",
          },
          status: 404,
        }
      );
    }

    const { matchedZone, matchedCity, distance } = zoneInfo;

    let resolvedVehicleType = vehicle_type;
    if (order_type === "local_parcel" || order_type === "intercity_parcel") {
      let inputWeight = 0;
      if (weight_kg !== undefined && weight_kg !== null && weight_kg !== "") {
        inputWeight = Number(String(weight_kg).trim());
      } else if (weight_category !== undefined && weight_category !== null && weight_category !== "") {
        inputWeight = Number(String(weight_category).trim());
      }

      if (!resolvedVehicleType || resolvedVehicleType === "delivery") {
        resolvedVehicleType = inputWeight > 10 ? "auto" : "bike";
      } else if (order_type === "local_parcel" && resolvedVehicleType === "bike" && inputWeight > 10) {
        // Never price (or let the user see a fare for) a Bike/weight combination the order would
        // later be rejected for at create-order -- reject it here too so the client can steer the
        // user back to Auto before they even reach the booking button.
        return new Response(
          JSON.stringify({
            success: false,
            error: "Bike cannot carry a parcel over 10kg. Please select Auto.",
          }),
          {
            headers: {
              ...corsHeaders,
              "Content-Type": "application/json",
            },
            status: 400,
          }
        );
      }
    }

    // 2. Resolve Pricing Config
    // Normal in-zone pricing reuses the config read that started alongside the zone read. A
    // fallback match starts a fresh config read here, preserving the pre-concurrency recovery
    // behavior when the initial zone/config reads failed during the same transient incident.
    const configsForPricingPromise = matchedNormally
      ? activeConfigsPromise
      : getActivePricingConfigs(supabase);
    const matchedConfig = await resolvePricingConfig(
      supabase,
      order_type,
      resolvedVehicleType,
      matchedZone.id,
      weight_kg,
      weight_category,
      configsForPricingPromise,
    );

    if (!matchedConfig) {
      console.log(`No active pricing config found for service: "${order_type}", vehicle: "${resolvedVehicleType}" in zone: "${matchedZone.zone_code}"`);
      return new Response(
        JSON.stringify({
          success: false,
          error: "not found",
        }),
        {
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json",
          },
          status: 404,
        }
      );
    }

    const rules = typeof matchedConfig.pricing_rules === "string"
      ? JSON.parse(matchedConfig.pricing_rules)
      : (matchedConfig.pricing_rules || {});

    // 3. Calculate Fare
    const { baseFare, extraData } = calculateFare(rules, rawDistance, weight_kg, weight_category);

    // 4. ★ Extract discount_percentage from pricing_config (set dynamically from Admin Settings UI)
    //    Replaces the old distance_discounts table lookup.
    const discountPercent = Number(matchedConfig.discount_percentage ?? 0);

    // 5. Build Response (now includes discount in the calculation)
    const commissionPercent = Number(matchedConfig.commission_percentage ?? 0);
    const gstPercent = Number(matchedConfig.gst_percentage ?? 0);

    const result = buildPricingResponse(
      baseFare,
      max_boost_amount,
      commissionPercent,
      gstPercent,
      discountPercent,     // ★ pass discount percentage
      resolvedVehicleType,
      order_type,
      matchedConfig,
      matchedZone,
      matchedCity,
      rawDistance,
      extraData,
      distance
    );

    if (usedDeveloperZoneBypass && result?.pricing) {
      result.pricing.developer_test_mode = true;
    }

    return new Response(JSON.stringify(result), {
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json",
      },
      status: 200,
    });
  } catch (error) {
    console.error("PRICING ERROR =>", error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error ? error.message : "Unknown error",
      }),
      {
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
        status: 500,
      }
    );
  }
});
