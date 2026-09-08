import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  computeGeometricCorridorMatch,
  DEFAULT_GEOMETRIC_CORRIDOR_CONFIG,
  type GeometricCorridorConfig,
} from "./geometric-corridor.ts";
import {
  computeSelectedRouteMatch,
  DEFAULT_SELECTED_ROUTE_CONFIG,
  type RouteWaypoint,
  type SelectedRouteConfig,
} from "./selected-route-corridor.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function haversineDistance(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371; // km
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
    Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

function vehicleMatches(planVehicle: string | null, orderVehicle: string | null): boolean {
  let pv = (planVehicle || "").toLowerCase().trim();
  let ov = (orderVehicle || "").toLowerCase().trim();
  if (pv === "car") pv = "cab";
  if (ov === "car") ov = "cab";
  return pv === ov;
}

// FROZEN SPEC (docs/13_Business_Logic.md section 5.2/5.3): selected_route_meta.waypoints is
// caller-supplied JSON (jsonb column, or a raw JS object when passed through Mode 2's request
// body) -- this must never throw on malformed/missing data. Returns null (not []) whenever the
// shape isn't usable, which callers treat identically to "no selected route" (see the
// `selected_route_geometry`/`selected_route_meta` presence guard at each shadow-log call site).
function parseSelectedRouteWaypoints(meta: unknown): RouteWaypoint[] | null {
  try {
    const m = typeof meta === "string" ? JSON.parse(meta) : meta;
    const waypoints = (m as { waypoints?: unknown } | null)?.waypoints;
    if (!Array.isArray(waypoints) || waypoints.length === 0) return null;
    const parsed: RouteWaypoint[] = [];
    for (const w of waypoints) {
      const wp = w as { label?: unknown; lat?: unknown; lng?: unknown; along_track_km?: unknown };
      if (
        typeof wp?.lat !== "number" ||
        typeof wp?.lng !== "number" ||
        typeof wp?.along_track_km !== "number"
      ) {
        continue; // FROZEN SPEC: safely discard a malformed individual waypoint, don't throw.
      }
      parsed.push({
        label: typeof wp.label === "string" ? wp.label : "",
        lat: wp.lat,
        lng: wp.lng,
        alongTrackKm: wp.along_track_km,
      });
    }
    return parsed.length > 0 ? parsed : null;
  } catch (_err) {
    return null;
  }
}

// Formats a date as "20 Jul" for notification copy (Part 4 template's {{date}}).
function formatNotificationDate(dateInput: string | null | undefined): string {
  const d = dateInput ? new Date(dateInput) : new Date();
  if (isNaN(d.getTime())) return new Date().toLocaleDateString("en-IN", { day: "2-digit", month: "short" });
  return d.toLocaleDateString("en-IN", { day: "2-digit", month: "short" });
}

// Part 4: aggregate "matching occurred" notification, inserted directly into public.notifications
// (this edge function already runs as service-role, which bypasses RLS, so no new RPC is needed).
// The existing on_notification_insert trigger delivers the push automatically, reusing the exact
// same pipe as every other notification in the app.
async function sendMatchAvailableNotification(
  supabase: any,
  userId: string | null,
  notificationType: "travel_partners_available" | "new_travelers_available",
  count: number,
  pickup: string,
  destination: string,
  dateText: string,
  dateIso: string,
  orderId: string | null,
  planId: string | null
) {
  if (!userId || count <= 0) return;

  const isPartnerSide = notificationType === "new_travelers_available";
  const title = isPartnerSide ? "New Travelers Available" : "Travel Partners Available";
  const body = isPartnerSide
    ? `Good news! ${count} traveler(s) are looking to travel from ${pickup} to ${destination} on ${dateText}. Tap to view requests.`
    : `Great! ${count} verified travel partner(s) are travelling on your selected route. Tap to view available partners.`;

  const { error } = await supabase.from("notifications").insert({
    user_id: userId,
    title,
    body,
    notification_type: notificationType,
    payload: {
      type: notificationType,
      count,
      pickup,
      destination,
      travel_date: dateIso,
      order_id: orderId,
      plan_id: planId,
    },
  });

  if (error) {
    console.error(`[MatchIntercity] Failed to insert aggregate match notification for user ${userId}:`, error);
  }
}

// Feature 1 (Automatic Traveller Available Notification): records a (order_id, plan_id) match in
// the travel_matches idempotency ledger. Returns true only if this exact pair was NOT already
// recorded — i.e. this is a genuinely new match, so the caller should notify. The UNIQUE(order_id,
// plan_id) constraint is the source of truth for "the same traveller must never appear twice for
// the same trip"; a unique-violation here just means another matching run (from either direction)
// already recorded this pair, which is expected and not an error.
async function recordMatchIfNew(
  supabase: any,
  orderId: string,
  planId: string,
  direction: "order_first" | "plan_first"
): Promise<boolean> {
  const { error } = await supabase.from("travel_matches").insert({
    order_id: orderId,
    plan_id: planId,
    matched_direction: direction,
  });

  if (!error) return true;
  // 23505 = unique_violation (Postgres). Any other error is unexpected and should be logged, but
  // must not block the rest of the matching run for a single bad row.
  if (error.code !== "23505") {
    console.error(`[MatchIntercity] travel_matches insert error for order=${orderId} plan=${planId}:`, error);
  }
  return false;
}

// Feature 1: per-match "Traveller Available" notification to the passenger (order.user_id) —
// fired the first time a specific verified traveller's Travel Plan is found to match a specific
// Trip, in EITHER direction (Trip created first and a Plan appears later, or Plan created first
// and a Trip appears later). Distinct from sendMatchAvailableNotification's aggregate count
// notification, which is kept as-is for backward compatibility.
async function sendTravellerAvailableNotification(
  supabase: any,
  orderUserId: string,
  orderId: string,
  planId: string,
  riderId: string,
  pickup: string,
  destination: string,
  dateIso: string
) {
  const { error } = await supabase.from("notifications").insert({
    user_id: orderUserId,
    title: "Traveller Available",
    body: "A verified traveller is available for your trip. Tap to view traveller details.",
    notification_type: "traveller_available",
    payload: {
      type: "traveller_available",
      order_id: orderId,
      plan_id: planId,
      rider_id: riderId,
      pickup,
      destination,
      travel_date: dateIso,
    },
  });

  if (error) {
    console.error(`[MatchIntercity] Failed to insert traveller_available notification for user ${orderUserId}:`, error);
  }
}

// FROZEN SPEC (Phase 0 -- configuration wiring): previously a dead stub that ignored `supabase`
// and always returned the same two hardcoded strings. Now reads production_config.extra_flags --
// the live successor to the old `feature_flags` table (dropped 2026-07-02, see
// 20260702000000_drop_feature_flags.sql; production_config's extra_flags jsonb column, added
// 2026-09-01, is its intended escape hatch for exactly this kind of tunable value -- see
// 20260901000034_production_config.sql's own comment). No new configuration system is created.
//
// The two pre-existing keys keep their exact original fallback values ("25"/"15") so a
// production_config row with no matching extra_flags entries yet reproduces today's live matcher
// bit-for-bit -- this function's rewiring is itself required to be behavior-invisible.
async function getIntercitySettings(supabase: any) {
  const defaults = {
    "matching_radius_km": "25",
    "intercity_corridor_radius_km": "15",
    "intercity_matching_mode": "shadow",
  };

  let extraFlags: Record<string, unknown> = {};
  try {
    const { data, error } = await supabase
      .from("production_config")
      .select("extra_flags")
      .eq("is_active", true)
      .maybeSingle();
    if (!error && data?.extra_flags && typeof data.extra_flags === "object") {
      extraFlags = data.extra_flags as Record<string, unknown>;
    }
  } catch (err) {
    console.error("[MatchIntercity] Failed to read production_config.extra_flags, using defaults:", err);
  }

  const asString = (key: string, fallback: string): string => {
    const v = extraFlags[key];
    return v === undefined || v === null ? fallback : String(v);
  };
  const asNumber = (key: string, fallback: number): number => {
    const v = extraFlags[key];
    const n = v === undefined || v === null ? NaN : Number(v);
    return Number.isFinite(n) ? n : fallback;
  };

  const geometricCorridorConfig: GeometricCorridorConfig = {
    widthRatio: asNumber("intercity_corridor_width_ratio", DEFAULT_GEOMETRIC_CORRIDOR_CONFIG.widthRatio),
    minWidthKm: asNumber("intercity_corridor_width_min_km", DEFAULT_GEOMETRIC_CORRIDOR_CONFIG.minWidthKm),
    maxWidthKm: asNumber("intercity_corridor_width_max_km", DEFAULT_GEOMETRIC_CORRIDOR_CONFIG.maxWidthKm),
    tTolerance: asNumber("intercity_t_tolerance", DEFAULT_GEOMETRIC_CORRIDOR_CONFIG.tTolerance),
    minOverlapRatio: asNumber("intercity_min_overlap_ratio", DEFAULT_GEOMETRIC_CORRIDOR_CONFIG.minOverlapRatio),
    reverseOrderTolerance: asNumber("intercity_reverse_order_tolerance", DEFAULT_GEOMETRIC_CORRIDOR_CONFIG.reverseOrderTolerance),
    maxDetourRatio: asNumber("intercity_max_detour_ratio", DEFAULT_GEOMETRIC_CORRIDOR_CONFIG.maxDetourRatio),
  };

  // docs/13_Business_Logic.md section 5: declared-route (Via-locations) corridor config,
  // same production_config.extra_flags override pattern as geometricCorridorConfig above.
  const selectedRouteConfig: SelectedRouteConfig = {
    snapRadiusKm: asNumber("selected_route_snap_radius_km", DEFAULT_SELECTED_ROUTE_CONFIG.snapRadiusKm),
    minSegmentKm: asNumber("selected_route_min_segment_km", DEFAULT_SELECTED_ROUTE_CONFIG.minSegmentKm),
  };

  return {
    "matching_radius_km": asString("matching_radius_km", defaults["matching_radius_km"]),
    "intercity_corridor_radius_km": asString("intercity_corridor_radius_km", defaults["intercity_corridor_radius_km"]),
    "intercity_matching_mode": asString("intercity_matching_mode", defaults["intercity_matching_mode"]),
    "geometric_corridor_config": geometricCorridorConfig,
    "selected_route_config": selectedRouteConfig,
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const body = await req.json();
    const { order_id, plan, is_background } = body;

    if (!order_id && !plan) {
      return Response.json(
        { success: false, message: "Either order_id or plan is required" },
        { status: 400, headers: corsHeaders }
      );
    }

    // =====================================================
    // AUTH
    // create-order invokes this function in the background using the
    // service role key (order_id mode) — that is trusted as-is. Any other
    // caller must be an authenticated user; in plan mode they may only
    // request matches for their own registered rider account.
    // =====================================================
    const token = req.headers.get("Authorization")?.replace("Bearer ", "");
    if (!token) {
      return Response.json(
        { success: false, message: "Missing auth token" },
        { status: 401, headers: corsHeaders }
      );
    }

    const isTrustedServerCaller = token === Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    let callerUserId: string | null = null;

    if (!isTrustedServerCaller) {
      const { data: authData, error: authError } = await supabase.auth.getUser(token);
      if (authError || !authData.user) {
        return Response.json(
          { success: false, message: "Unauthorized" },
          { status: 401, headers: corsHeaders }
        );
      }
      callerUserId = authData.user.id;
    }

    const settings = await getIntercitySettings(supabase);
    const radiusKm = parseFloat(settings["matching_radius_km"] || "25");
    const corridorRadiusKm = parseFloat(settings["intercity_corridor_radius_km"] || "15");
    // FROZEN SPEC Phase 1 (shadow mode): computed and logged alongside every existing matching
    // decision below, never used to alter isMatched/candidatePlans/matchedOrders/the response, or
    // any notification. See geometric-corridor.ts for the provider-independent formulas.
    const geometricCorridorConfig = settings["geometric_corridor_config"] as GeometricCorridorConfig;
    // docs/13_Business_Logic.md section 5: declared-route (Via-locations) corridor. Unlike the
    // geometric shadow above, this one IS gating -- but strictly ADDITIVELY: the block that uses
    // it (both modes) can only ever set isMatched=true, and only for a plan that has a
    // traveller-declared route (selected_route_geometry NOT NULL). See selected-route-corridor.ts.
    const selectedRouteConfig = settings["selected_route_config"] as SelectedRouteConfig;

    if (order_id) {
      // ----------------------------------------------------
      // MODE 1: MATCH RIDERS (TRAVEL PLANS) FOR A PASSENGER ORDER
      // ----------------------------------------------------
      const { data: order, error: orderError } = await supabase
        .from("orders")
        .select("id, user_id, pickup_city, destination_city, pickup_address, destination_address, pickup_lat, pickup_lng, destination_lat, destination_lng, travel_date, created_at, order_type, vehicle_type, actual_weight_kg, weight_category, current_fare, actual_fare, seats_requested")
        .eq("id", order_id)
        .single();

      if (orderError || !order) {
        return Response.json(
          { success: false, message: "Order not found or database error" },
          { status: 404, headers: corsHeaders }
        );
      }

      // A non-service-role caller may only request matches for their own
      // order, not an arbitrary order_id belonging to someone else.
      if (!isTrustedServerCaller && order.user_id !== callerUserId) {
        return Response.json(
          { success: false, message: "Forbidden: order_id does not belong to the authenticated caller" },
          { status: 403, headers: corsHeaders }
        );
      }

      const {
        pickup_city: orderPickup, 
        destination_city: orderDest, 
        pickup_address: orderPickupAddr,
        destination_address: orderDestAddr,
        pickup_lat: orderPickupLat,
        pickup_lng: orderPickupLng,
        destination_lat: orderDestLat,
        destination_lng: orderDestLng,
        travel_date: orderTravelDate,
        created_at: orderCreatedAt,
        actual_weight_kg: orderWeight,
        weight_category: orderWeightCat,
        seats_requested: orderSeatsRequested
      } = order;

      const requiredSeats = Number(orderSeatsRequested) >= 1 ? Number(orderSeatsRequested) : 1;

      const parsedOrderDate = orderTravelDate ? new Date(orderTravelDate) : (orderCreatedAt ? new Date(orderCreatedAt) : new Date());
      const orderDate = isNaN(parsedOrderDate.getTime()) ? new Date() : parsedOrderDate;
      const now = new Date().toISOString();

      // Candidate-discovery expiry check: orders.travel_date is the authoritative, timezone-safe
      // (timestamptz) field for "when the passenger intends to travel" -- once it has passed, this
      // request can never legally be accepted (accept_intercity_request's own
      // search_expires_at < now() check, where search_expires_at is initialized from travel_date at
      // creation, already enforces this at accept-time). Without this check here, a request whose
      // travel time already passed kept showing up as a live candidate for every compatible plan
      // until someone tried and failed to accept it. Returning zero matches immediately also skips
      // the plans query entirely -- strictly cheaper than today, not a new full-table scan.
      if (orderTravelDate && new Date(orderTravelDate).getTime() < Date.now()) {
        return Response.json(
          {
            success: true,
            order: { id: order.id, pickup_city: orderPickup, destination_city: orderDest },
            matches: [],
          },
          { headers: corsHeaders }
        );
      }

      const minDate = new Date(orderDate.getTime() - 1.5 * 24 * 60 * 60 * 1000).toISOString();
      const maxDate = new Date(orderDate.getTime() + 1.5 * 24 * 60 * 60 * 1000).toISOString();

      const isRideOrder = order.order_type === "intercity_ride" || order.order_type === "intercity" || (order.order_type === "ride" && (order.distance_meters || 0) > 20000);
      const isParcelOrder = order.order_type === "intercity_parcel";

      let orderWeightKg = 0;
      const rawWeight = orderWeight ?? orderWeightCat;
      if (rawWeight !== undefined && rawWeight !== null) {
        orderWeightKg = parseFloat(rawWeight.toString()) || 0;
      }

      // Query active, non-expired travel plans
      const { data: plans, error: plansError } = await supabase
        .from("rider_travel_plans")
        .select(`
          id,
          pickup_city,
          destination_city,
          pickup_lat,
          pickup_lng,
          destination_lat,
          destination_lng,
          travel_date,
          status,
          rider_id,
          max_weight_kg,
          weight_preference,
          max_bookings,
          travel_plan_type,
          vehicle_type,
          route_geometry,
          selected_route_geometry,
          selected_route_meta,
          route_selection_status,
          price_per_seat,
          rider:riders!inner(
            id,
            account_status,
            user_id,
            rating,
            service_mode
          )
        `)
        .eq("status", "active")
        .eq("rider.service_mode", "intercity")
        .gte("travel_date", minDate)
        .lte("travel_date", maxDate);

      if (plansError) {
        console.error(`[MatchIntercity] Mode 1 plans fetch error:`, plansError);
        return Response.json(
          { success: false, message: "Error fetching travel plans: " + plansError.message },
          { status: 500, headers: corsHeaders }
        );
      }

      console.log(`[MatchIntercity] Mode 1 DB query returned ${plans?.length || 0} active plans in range [${minDate} to ${maxDate}].`);
      const candidatePlans: any[] = [];
      for (const p of plans || []) {
        if (p.rider.user_id === order.user_id) {
          console.log(`[MatchIntercity] Mode 1 Plan ${p.id}: skipping self-matching.`);
          continue;
        }

        // Defense-in-depth: the query above already filters
        // rider.service_mode = 'intercity' via the embedded-resource
        // filter, but re-check here too in case that filter is ever
        // dropped/changed without this loop being updated.
        if (p.rider.service_mode !== "intercity") {
          console.log(`[MatchIntercity] Mode 1 Plan ${p.id}: skipping because rider is not in Intercity Traveller mode.`);
          continue;
        }

        // Skip mismatch in plan type
        if (isRideOrder && p.travel_plan_type === "parcel") {
          console.log(`[MatchIntercity] Mode 1 Plan ${p.id}: skipping because order is ride but plan is parcel.`);
          continue;
        }
        if (isParcelOrder && p.travel_plan_type === "ride") {
          console.log(`[MatchIntercity] Mode 1 Plan ${p.id}: skipping because order is parcel but plan is ride.`);
          continue;
        }

        // Date Check (+/- 1.5 days window of order travel date)
        const planDate = new Date(p.travel_date);
        const diffTime = Math.abs(planDate.getTime() - orderDate.getTime());
        const diffDays = diffTime / (1000 * 60 * 60 * 24);
        if (diffDays > 1.5) {
          console.log(`[MatchIntercity] Mode 1 Plan ${p.id}: skipping due to date difference: ${diffDays.toFixed(2)} days (limit=1.5).`);
          continue;
        }

        let isMatched = false;
        let routeMatchDetails = null;

        const cityMatched = 
          (orderPickup && p.pickup_city.trim().toLowerCase() === orderPickup.trim().toLowerCase()) &&
          (orderDest && p.destination_city.trim().toLowerCase() === orderDest.trim().toLowerCase());

        let coordinatesMatched = false;
        let distPickup = 0;
        let distDest = 0;
        if (orderPickupLat && orderPickupLng && orderDestLat && orderDestLng && p.pickup_lat && p.pickup_lng && p.destination_lat && p.destination_lng) {
          distPickup = haversineDistance(orderPickupLat, orderPickupLng, p.pickup_lat, p.pickup_lng);
          distDest = haversineDistance(orderDestLat, orderDestLng, p.destination_lat, p.destination_lng);
          coordinatesMatched = (distPickup <= radiusKm) && (distDest <= radiusKm);
        }

        if (cityMatched || coordinatesMatched) {
          isMatched = true;
          console.log(`[MatchIntercity] Mode 1 Plan ${p.id}: matched by city/coordinates. cityMatched=${cityMatched}, coordinatesMatched=${coordinatesMatched} (distPickup=${distPickup.toFixed(2)}km, distDest=${distDest.toFixed(2)}km)`);
        }

        // Optimized route corridor 10km proximity check
        if (p.route_geometry) {
          try {
            const points = typeof p.route_geometry === "string" ? JSON.parse(p.route_geometry) : p.route_geometry;
            if (Array.isArray(points) && points.length > 0) {
              let minPickupDist = Infinity;
              let pickupIdx = -1;
              let minDestDist = Infinity;
              let destIdx = -1;

              for (let i = 0; i < points.length; i++) {
                const pt = points[i];
                let ptLat = 0;
                let ptLng = 0;
                if (Array.isArray(pt) && pt.length >= 2) {
                  // Robust parsing: detect swapped lat/lng for India coordinates
                  if (pt[0] > 60.0 && pt[0] < 100.0 && pt[1] > 6.0 && pt[1] < 38.0) {
                    ptLat = pt[1];
                    ptLng = pt[0];
                  } else {
                    ptLat = pt[0];
                    ptLng = pt[1];
                  }
                } else if (pt && typeof pt === "object") {
                  ptLat = pt.lat;
                  ptLng = pt.lng;
                } else {
                  continue;
                }

                if (orderPickupLat && orderPickupLng) {
                  const dP = haversineDistance(orderPickupLat, orderPickupLng, ptLat, ptLng);
                  if (dP < minPickupDist) {
                    minPickupDist = dP;
                    pickupIdx = i;
                  }
                }

                if (orderDestLat && orderDestLng) {
                  const dD = haversineDistance(orderDestLat, orderDestLng, ptLat, ptLng);
                  if (dD < minDestDist) {
                    minDestDist = dD;
                    destIdx = i;
                  }
                }
              }

              if (minPickupDist <= corridorRadiusKm && minDestDist <= corridorRadiusKm && pickupIdx <= destIdx) {
                isMatched = true;
                routeMatchDetails = {
                  pickupDistance: minPickupDist,
                  destinationDistance: minDestDist,
                  pickupIndex: pickupIdx,
                  destinationIndex: destIdx,
                  routeLength: points.length,
                };
                console.log(`[MatchIntercity] Mode 1 Plan ${p.id}: matched by route geometry corridor! minPickupDist=${minPickupDist.toFixed(2)}km, minDestDist=${minDestDist.toFixed(2)}km, pickupIdx=${pickupIdx}, destIdx=${destIdx}`);
              } else {
                console.log(`[MatchIntercity] Mode 1 Plan ${p.id}: Route corridor check failed. minPickupDist=${minPickupDist.toFixed(2)}km (limit=${corridorRadiusKm}km), minDestDist=${minDestDist.toFixed(2)}km (limit=${corridorRadiusKm}km), pickupIdx=${pickupIdx}, destIdx=${destIdx}`);
              }
            }
          } catch (err) {
            console.error(`Error parsing route_geometry for plan ${p.id}:`, err);
          }
        } else {
          console.log(`[MatchIntercity] Mode 1 Plan ${p.id} has no route geometry, skipping corridor check.`);
        }

        // FROZEN SPEC Phase 1 (shadow mode) -- provider-independent geometric corridor, computed
        // for every candidate that reached this point (i.e. already passed self-match/plan-type/
        // date filtering above, unrelated to this spec and left untouched). Read-only: never
        // reassigns `isMatched`, never affects candidatePlans/matchedRiders/the response/
        // notifications. route_geometry is NOT passed in and cannot participate -- see
        // geometric-corridor.ts.
        if (orderPickupLat && orderPickupLng && orderDestLat && orderDestLng && p.pickup_lat && p.pickup_lng && p.destination_lat && p.destination_lng) {
          const shadow = computeGeometricCorridorMatch(
            { lat: p.pickup_lat, lng: p.pickup_lng },
            { lat: p.destination_lat, lng: p.destination_lng },
            { lat: orderPickupLat, lng: orderPickupLng },
            { lat: orderDestLat, lng: orderDestLng },
            geometricCorridorConfig
          );
          console.log(
            `[MatchIntercity][ShadowGeometric] mode=1 planId=${p.id} orderId=${order_id} ` +
            `oldDecision=${isMatched} newDecision=${shadow.isMatch} reason=${shadow.reason} ` +
            `tP=${shadow.tP.toFixed(4)} tQ=${shadow.tQ.toFixed(4)} ` +
            `crossTrackP=${shadow.crossTrackPKm.toFixed(2)} crossTrackQ=${shadow.crossTrackQKm.toFixed(2)} ` +
            `d12=${shadow.d12Km.toFixed(2)} width=${shadow.widthKm.toFixed(2)} ` +
            `detourKm=${shadow.detourKm.toFixed(2)} detourPass=${shadow.detourPass}`
          );
        }

        // DECLARED-ROUTE CORRIDOR (docs/13_Business_Logic.md section 5) -- the traveller's
        // explicitly declared Origin -> Via 1 -> ... -> Destination corridor.
        //
        // ADDITIVE-ONLY: this can only ever SET isMatched to true (a directional match on the
        // declared route). It never sets isMatched to false and never AND-composes -- so it can
        // never veto a legacy city/coordinate/route_geometry match, and every existing plan
        // (selected_route_geometry NULL) skips this block entirely and is 100% unchanged
        // (section 5.6). Direction is enforced inside computeSelectedRouteMatch: pickup must snap
        // to a waypoint at or before the destination's snapped waypoint (tP <= tQ), so a reversed
        // passenger pair (e.g. Guntur -> Tiruvuru against a Bhadrachalam..Guntur plan) is
        // rejected with reason "reverse_of_selected_route".
        if (p.selected_route_geometry && orderPickupLat && orderPickupLng && orderDestLat && orderDestLng) {
          const selectedWaypoints = parseSelectedRouteWaypoints(p.selected_route_meta);
          if (selectedWaypoints) {
            const totalDistanceKm =
              typeof (p.selected_route_meta as any)?.total_distance_km === "number"
                ? (p.selected_route_meta as any).total_distance_km
                : 0;
            const declaredRoute = computeSelectedRouteMatch(
              selectedWaypoints,
              totalDistanceKm,
              { lat: orderPickupLat, lng: orderPickupLng },
              { lat: orderDestLat, lng: orderDestLng },
              selectedRouteConfig
            );
            const oldDecision = isMatched;
            if (declaredRoute.isMatch) {
              isMatched = true;
            }
            console.log(
              `[MatchIntercity][SelectedRoute] mode=1 planId=${p.id} orderId=${order_id} ` +
              `oldDecision=${oldDecision} newDecision=${declaredRoute.isMatch} reason=${declaredRoute.reason} ` +
              `tP=${declaredRoute.tP ?? "null"} tQ=${declaredRoute.tQ ?? "null"} ` +
              `snappedP=${declaredRoute.snappedP ?? "null"} snappedQ=${declaredRoute.snappedQ ?? "null"} ` +
              `routeKm=${totalDistanceKm}`
            );
          }
        }

        if (isMatched) {
          p.routeMatchDetails = routeMatchDetails;
          candidatePlans.push(p);
        } else {
          console.log(`[MatchIntercity] Mode 1 Plan ${p.id}: skipping because no city, coordinates or route corridor match.`);
        }
      }

      const matchedRiders: any[] = [];
      if (candidatePlans.length > 0) {
        const planIds = candidatePlans.map((p) => p.id);
        const userIds = candidatePlans.map((p) => p.rider.user_id);
        const riderIds = candidatePlans.map((p) => p.rider.id);

        // Fetch active bookings, KYCs, reliability views, and capacity views in parallel
        const [bookingsRes, kycsRes, reliabilityRes, capacityRes] = await Promise.all([
          supabase
            .from("intercity_requests")
            .select("route_id")
            .in("route_id", planIds)
            .in("status", ["confirmed", "paid", "in_progress"]),
          supabase
            .from("rider_kyc")
            .select("user_id, full_name, vehicle_type, vehicle_number, rider_image, kyc_status")
            .in("user_id", userIds),
          supabase
            .from("rider_reliability_view")
            .select("*")
            .in("rider_id", riderIds),
          supabase
            .from("travel_plan_capacity_view")
            .select("*")
            .in("plan_id", planIds)
        ]);

        const activeBookingCounts: Record<string, number> = {};
        if (bookingsRes.data) {
          for (const b of bookingsRes.data) {
            if (b.route_id) {
              activeBookingCounts[b.route_id] = (activeBookingCounts[b.route_id] || 0) + 1;
            }
          }
        }

        const kycMap: Record<string, any> = {};
        if (kycsRes.data) {
          for (const k of kycsRes.data) {
            kycMap[k.user_id] = k;
          }
        }

        const reliabilityMap: Record<string, any> = {};
        if (reliabilityRes.data) {
          for (const r of reliabilityRes.data) {
            reliabilityMap[r.rider_id] = r;
          }
        }

        const capacityMap: Record<string, any> = {};
        if (capacityRes.data) {
          for (const c of capacityRes.data) {
            capacityMap[c.plan_id] = c;
          }
        }

        for (const p of candidatePlans) {
          const activeCount = activeBookingCounts[p.id] || 0;
          const maxBookings = p.max_bookings || 3;

          // Enforce capacity filter (slots) — for ride orders a passenger
          // may request more than one seat (seats_requested), so there
          // must be at least that many free seats, not just one.
          const availableSeats = maxBookings - activeCount;
          if (isRideOrder ? availableSeats < requiredSeats : activeCount >= maxBookings) {
            console.log(`[MatchIntercity] Mode 1 Plan ${p.id}: skipping because available seats (${availableSeats}) are fewer than required (${isRideOrder ? requiredSeats : 1}).`);
            continue;
          }

          const kyc = kycMap[p.rider.user_id];
          const planVehicle = p.vehicle_type || kyc?.vehicle_type || null;

          // Enforce vehicle matching for ride orders — a Travel Request
          // created with no vehicle preference (order.vehicle_type is null,
          // i.e. the passenger didn't lock to a vehicle) matches any
          // vehicle type, since bike/auto/cab all price identically.
          if (isRideOrder && order.vehicle_type && !vehicleMatches(planVehicle, order.vehicle_type)) {
            console.log(`[MatchIntercity] Mode 1 Plan ${p.id}: skipping due to vehicle type mismatch. planVehicle=${planVehicle}, orderVehicle=${order.vehicle_type}`);
            continue;
          }

          // Fetch capacity and weight metrics from view map
          const capacityDetails = capacityMap[p.id];
          const planWeightLimit = p.max_weight_kg ? parseFloat(p.max_weight_kg.toString()) : (p.weight_preference ? parseFloat(p.weight_preference.toString()) : 0);
          const remainingWeight = capacityDetails ? parseFloat(capacityDetails.remaining_capacity_kg) : planWeightLimit;

          // Enforce remaining capacity weight filter
          if (isParcelOrder && orderWeightKg > remainingWeight) {
            console.log(`[MatchIntercity] Mode 1 Plan ${p.id}: skipping because order weight (${orderWeightKg}kg) exceeds remaining capacity (${remainingWeight}kg).`);
            continue;
          }

          // Enforce weight/vehicle restriction: parcels >= 10kg cannot match bike plans
          if (isParcelOrder && orderWeightKg >= 10.0 && planVehicle === "bike") {
            console.log(`[MatchIntercity] Mode 1 Plan ${p.id}: skipping because parcel weight (${orderWeightKg}kg) >= 10kg is not allowed on bike plans.`);
            continue;
          }

          // Fetch reliability stats from view map
          const relStats = reliabilityMap[p.rider.id];
          const reliability = relStats ? parseFloat(relStats.reliability_score) : 100.0;
          const rating = relStats ? parseFloat(relStats.rating) : (p.rider.rating || 5.0);
          const completionRate = relStats ? parseFloat(relStats.completion_rate) : 100.0;
          const onTimeRate = relStats ? parseFloat(relStats.on_time_rate) : 100.0;
          const totalCompleted = relStats ? parseInt(relStats.total_completed) : 0;

          // Match Score Calculation:
          // 1. Route Overlap (50 pts): deviation distance compared to matching radius/deviation limit
          let distScore = 50.0;
          if (p.routeMatchDetails) {
            const deviation = p.routeMatchDetails.pickupDistance + p.routeMatchDetails.destinationDistance;
            distScore = Math.max(0, 50.0 - (deviation / 20.0) * 50.0);
          } else if (orderPickupLat && orderPickupLng && orderDestLat && orderDestLng && p.pickup_lat && p.pickup_lng && p.destination_lat && p.destination_lng) {
            const distPickup = haversineDistance(orderPickupLat, orderPickupLng, p.pickup_lat, p.pickup_lng);
            const distDest = haversineDistance(orderDestLat, orderDestLng, p.destination_lat, p.destination_lng);
            const deviation = distPickup + distDest;
            distScore = Math.max(0, 50.0 - (deviation / (2 * radiusKm)) * 50.0);
          }

          // 2. Reliability Score (25 pts)
          const reliabilityScore = (reliability / 100.0) * 25.0;

          // 3. Capacity fit (15 pts): check fit ratio
          let capacityScore = 15.0;
          if (isParcelOrder && remainingWeight > 0) {
            capacityScore = Math.max(0, 15.0 - (orderWeightKg / remainingWeight) * 15.0);
          }

          // 4. Response Rate / Online Status (10 pts)
          const onlineScore = p.rider.account_status === "online" ? 10.0 : 8.0;

          const score = distScore + reliabilityScore + capacityScore + onlineScore;

          matchedRiders.push({
            plan_id: p.id,
            rider_id: p.rider.id,
            rider_user_id: p.rider.user_id,
            full_name: kyc?.full_name || "Rider Partner",
            vehicle_type: planVehicle || "delivery",
            vehicle_number: kyc?.vehicle_number || "",
            rider_image: kyc?.rider_image || "",
            travel_date: p.travel_date,
            max_weight_kg: p.max_weight_kg,
            travel_plan_type: p.travel_plan_type,
            max_bookings: p.max_bookings,
            active_bookings: activeCount,
            rating: rating,
            reliability_score: reliability,
            completion_rate: completionRate,
            on_time_rate: onTimeRate,
            total_completed: totalCompleted,
            remaining_capacity_kg: remainingWeight,
            account_status: p.rider.account_status,
            score: score,
            route_match_details: p.routeMatchDetails,
            price_per_seat: p.price_per_seat,
            is_verified: kyc?.kyc_status === "approved",
            available_seats: availableSeats,
            travel_time: p.travel_date
          });
        }
      }

      // Sort matches descending by score
      matchedRiders.sort((a, b) => b.score - a.score);

      if (is_background) {
        console.log(`[MatchIntercity] Background processing active for order ${order_id}. Found ${matchedRiders.length} matched riders.`);

        // Background matching is discovery-only: it must NEVER auto-create an intercity_requests
        // negotiation row or send an automated chat message on the user's behalf. Doing so used
        // to silently pre-create a 'discussion_started' negotiation for up to 5 matches the
        // instant an order was created, which hijacked the explicit "Travel Together" button flow
        // (Travel Together -> Confirmation Dialog -> Request Sent -> Traveller Accept/Reject) —
        // the button would show a request as already sent/negotiating before the user ever
        // pressed anything. A negotiation is now only ever created by an explicit user action via
        // IntercityMatchingService.sendTravelTogetherRequest (AvailablePartnersScreen /
        // AvailableTravelersScreen / travel_plan_details_screen.dart's _sendProposal). This branch
        // only sends the aggregate "matches are available, go browse" notification below.

        // Part 4: notify the passenger that travel partners are available for their route,
        // once per matching run.
        await sendMatchAvailableNotification(
          supabase,
          order.user_id,
          "travel_partners_available",
          matchedRiders.length,
          orderPickup,
          orderDest,
          formatNotificationDate(orderTravelDate),
          orderDate.toISOString(),
          order_id,
          null
        );

        // Feature 1: per-traveller "Traveller Available" notification — this is the direction
        // where the Trip already existed and a matching (verified) Travel Plan was just
        // discovered against it. Only genuinely new (order_id, plan_id) pairs notify, so a
        // traveller who already matched this trip in a previous run is never re-notified.
        for (const m of matchedRiders) {
          if (!m.is_verified) continue;
          const isNew = await recordMatchIfNew(supabase, order_id, m.plan_id, "order_first");
          if (isNew) {
            await sendTravellerAvailableNotification(
              supabase,
              order.user_id,
              order_id,
              m.plan_id,
              m.rider_id,
              orderPickup,
              orderDest,
              orderDate.toISOString()
            );
          }
        }
      }

      return Response.json(
        {
          success: true,
          order: {
            id: order.id,
            pickup_city: orderPickup,
            destination_city: orderDest,
          },
          matches: matchedRiders,
        },
        { headers: corsHeaders }
      );
    } else {
      // ----------------------------------------------------
      // MODE 2: MATCH ORDERS (PARCELS/RIDES) FOR A RIDER PLAN
      // ----------------------------------------------------
      let riderUserId: string | null = null;
      let riderServiceMode: string | null = null;
      if (plan.rider_id) {
        const { data: riderData } = await supabase
          .from("riders")
          .select("user_id, service_mode")
          .eq("id", plan.rider_id)
          .maybeSingle();
        if (riderData) {
          riderUserId = riderData.user_id;
          riderServiceMode = riderData.service_mode;
        }
      }

      // A non-service-role caller may only request matches for their own
      // registered rider account, not an arbitrary/synthetic plan.rider_id.
      if (!isTrustedServerCaller && (!riderUserId || riderUserId !== callerUserId)) {
        return Response.json(
          { success: false, message: "Forbidden: plan.rider_id does not belong to the authenticated caller" },
          { status: 403, headers: corsHeaders }
        );
      }

      // Only Intercity Traveller-mode partners can be matched against
      // intercity orders. A local-mode (or not-yet-chosen) rider requesting
      // matches for a travel plan is a defense-in-depth guard: the RLS
      // policy on rider_travel_plans (20260718000012) already prevents a
      // local-mode rider from having created the plan in the first place.
      if (plan.rider_id && riderServiceMode !== "intercity") {
        return Response.json(
          { success: false, code: "WRONG_SERVICE_MODE", message: "Switch to Intercity Traveller mode to view matching orders." },
          { status: 403, headers: corsHeaders }
        );
      }

      let planVehicle = plan.vehicle_type || null;
      // Feature 1: fetched unconditionally (not just when planVehicle is missing) since
      // kyc_status is also needed below to gate the "Traveller Available" notification to
      // verified travellers only.
      let riderIsVerified = false;
      if (riderUserId) {
        const { data: kycData } = await supabase
          .from("rider_kyc")
          .select("vehicle_type, kyc_status")
          .eq("user_id", riderUserId)
          .maybeSingle();
        if (kycData) {
          if (!planVehicle) planVehicle = kycData.vehicle_type;
          riderIsVerified = kycData.kyc_status === "approved";
        }
      }

      const planPickup = plan.pickup_city;
      const planDest = plan.destination_city;
      const planDate = new Date(plan.travel_date || new Date());
      const planWeight = plan.max_weight_kg 
        ? parseFloat(plan.max_weight_kg.toString()) 
        : (plan.weight_preference ? parseFloat(plan.weight_preference.toString()) : 0);
      const planType = plan.travel_plan_type || "both";
      const now = new Date().toISOString();

      // Query searching intercity orders that are not expired
      const { data: orders, error: ordersError } = await supabase
        .from("orders")
        .select(`
          id,
          user_id,
          order_code,
          order_type,
          vehicle_type,
          pickup_city,
          destination_city,
          pickup_address,
          destination_address,
          pickup_lat,
          pickup_lng,
          destination_lat,
          destination_lng,
          distance_km,
          distance_meters,
          weight_category,
          actual_weight_kg,
          current_fare,
          rider_earning,
          travel_date,
          created_at,
          seats_requested,
          users(full_name, phone, rating, total_ratings, profile_completed),
          special_instructions,
          parcel_images
        `)
        .eq("order_status", "searching")
        // Candidate-discovery expiry check: excludes any order whose own requested travel_date has
        // already passed (the comment above already said "not expired" -- this was never actually
        // implemented). NULL travel_date is left unfiltered (defensive -- matches
        // accept_intercity_request's own "IS NOT NULL AND ... < now()" pattern), same authoritative
        // timezone-safe (timestamptz) field as Mode 1's check above.
        .or(`travel_date.is.null,travel_date.gte.${now}`);

      if (ordersError) {
        return Response.json(
          { success: false, message: "Error fetching searching orders: " + ordersError.message },
          { status: 500, headers: corsHeaders }
        );
      }

      const filteredOrders = (orders || []).filter(o =>
        o.order_type === "intercity_ride" || 
        o.order_type === "intercity_parcel" || 
        o.order_type === "intercity" || 
        (o.order_type === "ride" && (o.distance_meters || 0) > 20000)
      );

      const matchedOrders: any[] = [];
      for (const order of filteredOrders) {
        if (riderUserId && order.user_id === riderUserId) continue;

        // Skip mismatch in plan type (e.g. plan is parcel, order is ride)
        const isParcelOrder = order.order_type === "intercity_parcel";
        const isRideOrder = order.order_type === "intercity_ride" || order.order_type === "intercity" || (order.order_type === "ride" && (order.distance_meters || 0) > 20000);
        if (planType !== "both" && planType !== "all") {
          if (planType === "ride" && isParcelOrder) {
            console.log(`[MatchIntercity] Skipping order ${order.order_code || order.id}: plan type is ride, order is parcel.`);
            continue;
          }
          if (planType === "parcel" && isRideOrder) {
            console.log(`[MatchIntercity] Skipping order ${order.order_code || order.id}: plan type is parcel, order is ride.`);
            continue;
          }
        }

        // Enforce vehicle matching for ride orders -- mirrors Mode 1's identical
        // `order.vehicle_type &&` guard above (search "Enforce vehicle matching for ride orders"
        // in Mode 1): an order created with no vehicle preference (order.vehicle_type null/empty)
        // didn't lock to a vehicle, so it matches any compatible Traveller vehicle, exactly like
        // Mode 1 already treats the same field. Without this guard, vehicleMatches() coerces a
        // null orderVehicle to "", which can never equal a real planVehicle like "cab" -- silently
        // rejecting every no-preference order in this direction only.
        if (isRideOrder && order.vehicle_type && planVehicle !== "both" && planVehicle !== "all" && planVehicle !== null && planVehicle !== "") {
          if (!vehicleMatches(planVehicle, order.vehicle_type)) {
            console.log(`[MatchIntercity] Skipping order ${order.order_code || order.id}: vehicle mismatch. planVehicle=${planVehicle}, orderVehicle=${order.vehicle_type}`);
            continue;
          }
        }

        const orderPickup = order.pickup_city;
        const orderDest = order.destination_city;

        let isMatched = false;
        let routeMatchDetails = null;

        const cityMatched = 
          (orderPickup && planPickup.trim().toLowerCase() === orderPickup.trim().toLowerCase()) &&
          (orderDest && planDest.trim().toLowerCase() === orderDest.trim().toLowerCase());

        let coordinatesMatched = false;
        let distPickup = 0;
        let distDest = 0;
        if (order.pickup_lat && order.pickup_lng && order.destination_lat && order.destination_lng && plan.pickup_lat && plan.pickup_lng && plan.destination_lat && plan.destination_lng) {
          distPickup = haversineDistance(order.pickup_lat, order.pickup_lng, plan.pickup_lat, plan.pickup_lng);
          distDest = haversineDistance(order.destination_lat, order.destination_lng, plan.destination_lat, plan.destination_lng);
          coordinatesMatched = (distPickup <= radiusKm) && (distDest <= radiusKm);
        }

        if (cityMatched || coordinatesMatched) {
          isMatched = true;
          console.log(`[MatchIntercity] Order ${order.order_code || order.id} matched by city/coordinates. cityMatched=${cityMatched}, coordinatesMatched=${coordinatesMatched} (distPickup=${distPickup.toFixed(2)}km, distDest=${distDest.toFixed(2)}km)`);
        }

        // Optimized route corridor 10km proximity check
        if (plan.route_geometry) {
          try {
            const points = typeof plan.route_geometry === "string" ? JSON.parse(plan.route_geometry) : plan.route_geometry;
            if (Array.isArray(points) && points.length > 0) {
              let minPickupDist = Infinity;
              let pickupIdx = -1;
              let minDestDist = Infinity;
              let destIdx = -1;

              for (let i = 0; i < points.length; i++) {
                const pt = points[i];
                let ptLat = 0;
                let ptLng = 0;
                if (Array.isArray(pt) && pt.length >= 2) {
                  // Robust parsing: detect swapped lat/lng for India coordinates
                  if (pt[0] > 60.0 && pt[0] < 100.0 && pt[1] > 6.0 && pt[1] < 38.0) {
                    ptLat = pt[1];
                    ptLng = pt[0];
                  } else {
                    ptLat = pt[0];
                    ptLng = pt[1];
                  }
                } else if (pt && typeof pt === "object") {
                  ptLat = pt.lat;
                  ptLng = pt.lng;
                } else {
                  continue;
                }

                if (order.pickup_lat && order.pickup_lng) {
                  const dP = haversineDistance(order.pickup_lat, order.pickup_lng, ptLat, ptLng);
                  if (dP < minPickupDist) {
                    minPickupDist = dP;
                    pickupIdx = i;
                  }
                }

                if (order.destination_lat && order.destination_lng) {
                  const dD = haversineDistance(order.destination_lat, order.destination_lng, ptLat, ptLng);
                  if (dD < minDestDist) {
                    minDestDist = dD;
                    destIdx = i;
                  }
                }
              }

              if (minPickupDist <= corridorRadiusKm && minDestDist <= corridorRadiusKm && pickupIdx <= destIdx) {
                isMatched = true;
                routeMatchDetails = {
                  pickupDistance: minPickupDist,
                  destinationDistance: minDestDist,
                  pickupIndex: pickupIdx,
                  destinationIndex: destIdx,
                  routeLength: points.length,
                };
                console.log(`[MatchIntercity] Order ${order.order_code || order.id} matched by route geometry corridor! minPickupDist=${minPickupDist.toFixed(2)}km, minDestDist=${minDestDist.toFixed(2)}km, pickupIdx=${pickupIdx}, destIdx=${destIdx}`);
              } else {
                console.log(`[MatchIntercity] Route corridor check failed for ${order.order_code || order.id}. minPickupDist=${minPickupDist.toFixed(2)}km (limit=${corridorRadiusKm}km), minDestDist=${minDestDist.toFixed(2)}km (limit=${corridorRadiusKm}km), pickupIdx=${pickupIdx}, destIdx=${destIdx}`);
              }
            }
          } catch (err) {
            console.error(`Error parsing route_geometry in Mode 2:`, err);
          }
        } else {
          console.log(`[MatchIntercity] Plan has no route geometry, skipping corridor check.`);
        }

        // FROZEN SPEC Phase 1 (shadow mode) -- mirrors the Mode 1 insertion above. Read-only:
        // never reassigns `isMatched`, never affects matchedOrders/the response/notifications.
        // route_geometry is NOT passed in and cannot participate -- see geometric-corridor.ts.
        if (order.pickup_lat && order.pickup_lng && order.destination_lat && order.destination_lng && plan.pickup_lat && plan.pickup_lng && plan.destination_lat && plan.destination_lng) {
          const shadow = computeGeometricCorridorMatch(
            { lat: plan.pickup_lat, lng: plan.pickup_lng },
            { lat: plan.destination_lat, lng: plan.destination_lng },
            { lat: order.pickup_lat, lng: order.pickup_lng },
            { lat: order.destination_lat, lng: order.destination_lng },
            geometricCorridorConfig
          );
          console.log(
            `[MatchIntercity][ShadowGeometric] mode=2 planId=${plan.id} orderId=${order.id} ` +
            `oldDecision=${isMatched} newDecision=${shadow.isMatch} reason=${shadow.reason} ` +
            `tP=${shadow.tP.toFixed(4)} tQ=${shadow.tQ.toFixed(4)} ` +
            `crossTrackP=${shadow.crossTrackPKm.toFixed(2)} crossTrackQ=${shadow.crossTrackQKm.toFixed(2)} ` +
            `d12=${shadow.d12Km.toFixed(2)} width=${shadow.widthKm.toFixed(2)} ` +
            `detourKm=${shadow.detourKm.toFixed(2)} detourPass=${shadow.detourPass}`
          );
        }

        // DECLARED-ROUTE CORRIDOR (docs/13_Business_Logic.md section 5) -- mirrors the Mode 1
        // block above. ADDITIVE-ONLY: only ever sets isMatched to true, never false, never
        // AND-composed. Guarded by selected_route_geometry presence; every existing plan has
        // this NULL (section 5.6). Note: the `plan` object here is whatever the caller supplied
        // in the request body (Mode 2 does not re-query rider_travel_plans); the
        // on_rider_travel_plan_insert() trigger forwards these three columns
        // (20260905000002_forward_selected_route_fields_to_mode2_trigger.sql).
        if (plan.selected_route_geometry && order.pickup_lat && order.pickup_lng && order.destination_lat && order.destination_lng) {
          const selectedWaypoints = parseSelectedRouteWaypoints(plan.selected_route_meta);
          if (selectedWaypoints) {
            const totalDistanceKm =
              typeof (plan.selected_route_meta as any)?.total_distance_km === "number"
                ? (plan.selected_route_meta as any).total_distance_km
                : 0;
            const declaredRoute = computeSelectedRouteMatch(
              selectedWaypoints,
              totalDistanceKm,
              { lat: order.pickup_lat, lng: order.pickup_lng },
              { lat: order.destination_lat, lng: order.destination_lng },
              selectedRouteConfig
            );
            const oldDecision = isMatched;
            if (declaredRoute.isMatch) {
              isMatched = true;
            }
            console.log(
              `[MatchIntercity][SelectedRoute] mode=2 planId=${plan.id} orderId=${order.id} ` +
              `oldDecision=${oldDecision} newDecision=${declaredRoute.isMatch} reason=${declaredRoute.reason} ` +
              `tP=${declaredRoute.tP ?? "null"} tQ=${declaredRoute.tQ ?? "null"} ` +
              `snappedP=${declaredRoute.snappedP ?? "null"} snappedQ=${declaredRoute.snappedQ ?? "null"} ` +
              `routeKm=${totalDistanceKm}`
            );
          }
        }

        if (isMatched) {
          // Date Check (+/- 1.5 days window)
          const orderDate = order.travel_date ? new Date(order.travel_date) : new Date(order.created_at);
          const diffTime = Math.abs(orderDate.getTime() - planDate.getTime());
          const diffDays = diffTime / (1000 * 60 * 60 * 24);

          if (diffDays <= 1.5) {
            // Weight Filter (only for parcel orders)
            if (isParcelOrder) {
              let parcelWeight = 0;
              const rawWeight = order.actual_weight_kg ?? order.weight_category;
              if (rawWeight !== undefined && rawWeight !== null) {
                parcelWeight = parseFloat(rawWeight.toString()) || 0;
              }

              if (planVehicle !== "both" && planVehicle !== "all" && planWeight > 0 && parcelWeight > planWeight) {
                console.log(`[MatchIntercity] Skipping order ${order.order_code || order.id}: parcel weight (${parcelWeight}kg) exceeds plan limit (${planWeight}kg).`);
                continue;
              }

              // Enforce weight/vehicle restriction: parcels >= 10kg cannot match bike plans
              if (planVehicle !== "both" && planVehicle !== "all" && parcelWeight >= 10.0 && planVehicle === "bike") {
                console.log(`[MatchIntercity] Skipping order ${order.order_code || order.id}: parcel weight >= 10kg not allowed on bike plans.`);
                continue;
              }
            }

            console.log(`[MatchIntercity] Order ${order.order_code || order.id} matches successfully!`);
            order.routeMatchDetails = routeMatchDetails;
            matchedOrders.push(order);
          } else {
            console.log(`[MatchIntercity] Skipping order ${order.order_code || order.id}: date mismatch. orderDate=${orderDate.toISOString()}, planDate=${planDate.toISOString()}, diffDays=${diffDays.toFixed(2)} (limit=1.5)`);
          }
        } else {
          console.log(`[MatchIntercity] Skipping order ${order.order_code || order.id}: no city, coordinates or route corridor match.`);
        }
      }

      // Sort: closest date first
      matchedOrders.sort((a, b) => {
        const dateA = a.travel_date ? new Date(a.travel_date) : new Date(a.created_at);
        const dateB = b.travel_date ? new Date(b.travel_date) : new Date(b.created_at);
        return Math.abs(dateA.getTime() - planDate.getTime()) - Math.abs(dateB.getTime() - planDate.getTime());
      });

      // Part 2/4: background processing for a newly-posted Travel Plan, mirroring Mode 1's
      // is_background branch above — discovery-only (see the matching comment there for why this
      // must never auto-create an intercity_requests negotiation or automated chat message; that
      // used to hijack the explicit "Travel Together" button flow on the partner side too).
      if (is_background) {
        console.log(`[MatchIntercity] Background processing active for plan ${plan.id}. Found ${matchedOrders.length} matched orders.`);

        // WayDrop Intercity is strictly User-initiated: the "new_travelers_available" aggregate
        // notification to the Traveller (formerly sent here, once per matching run) was removed
        // together with its only tap destination, AvailableTravelersScreen — the Traveller-side
        // browse/invite screen that let a Traveller initiate a "Travel Together" request to a
        // User. The correct-flow "Traveller Available" notification to the User below is
        // unaffected; Mode 1's own "travel_partners_available" notification to the User is also
        // unaffected.

        // Feature 1: per-order "Traveller Available" notification to each matched passenger —
        // this is the direction where the Travel Plan already existed and a matching Trip was
        // just created against it (the mirror of Mode 1's loop above). Only fires for a verified
        // traveller, and only for genuinely new (order_id, plan_id) pairs.
        if (riderIsVerified && plan.id) {
          for (const o of matchedOrders) {
            const isNew = await recordMatchIfNew(supabase, o.id, plan.id, "plan_first");
            if (isNew) {
              await sendTravellerAvailableNotification(
                supabase,
                o.user_id,
                o.id,
                plan.id,
                plan.rider_id,
                planPickup,
                planDest,
                planDate.toISOString()
              );
            }
          }
        }
      }

      return Response.json(
        {
          success: true,
          plan: {
            pickup_city: planPickup,
            destination_city: planDest,
          },
          matches: matchedOrders,
        },
        { headers: corsHeaders }
      );
    }
  } catch (e) {
    return Response.json(
      { success: false, message: e.message },
      { status: 500, headers: corsHeaders }
    );
  }
});
