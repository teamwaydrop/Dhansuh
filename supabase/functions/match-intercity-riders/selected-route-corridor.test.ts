// Regression tests for the FROZEN traveller-selected-route corridor spec
// (docs/13_Business_Logic.md, section 5 "Intercity Selected-Route Corridor Matching").
//
// Waypoint coordinates are the SAME real, previously-geocoded points already used and
// documented in geometric-corridor.test.ts (Bhadrachalam/Guntur are the real device-captured
// route-diagnostic coordinates; Vijayawada/Kothagudem/Tiruvuru are Ola's own geocoder results)
// -- no new coordinates are invented here. along_track_km values are the cumulative
// straight-line (haversine) distance between consecutive waypoints in this test's chosen
// order -- a deterministic input for testing the snap/ordering algorithm, NOT a claim about
// real road distance along any actual route.
//
// Run with: deno test supabase/functions/match-intercity-riders/selected-route-corridor.test.ts
import { assert, assertEquals, assertFalse } from "https://deno.land/std@0.168.0/testing/asserts.ts";
import {
  computeSelectedRouteMatch,
  DEFAULT_SELECTED_ROUTE_CONFIG,
  snapToNearestWaypoint,
  type RouteWaypoint,
  type SelectedRouteConfig,
} from "./selected-route-corridor.ts";

// Selected route: Bhadrachalam -> Kothagudem -> Tiruvuru -> Vijayawada -> Guntur.
// along_track_km computed via haversine cumulative distance between consecutive waypoints
// above (not invented): 0, 33.121, 74.971, 139.389, 171.018.
const SELECTED_ROUTE_WAYPOINTS: RouteWaypoint[] = [
  { label: "Bhadrachalam", lat: 17.67234, lng: 80.89694, alongTrackKm: 0 },
  { label: "Kothagudem", lat: 17.483227, lng: 80.655534, alongTrackKm: 33.121 },
  { label: "Tiruvuru", lat: 17.109278, lng: 80.61101, alongTrackKm: 74.971 },
  { label: "Vijayawada", lat: 16.530371, lng: 80.634165, alongTrackKm: 139.389 },
  { label: "Guntur", lat: 16.314005, lng: 80.441673, alongTrackKm: 171.018 },
];
const TOTAL_DISTANCE_KM = 171.018;

function wp(label: string): RouteWaypoint {
  const found = SELECTED_ROUTE_WAYPOINTS.find((w) => w.label === label);
  if (!found) throw new Error(`unknown test waypoint: ${label}`);
  return found;
}

// =====================================================================
// 1-3. FORWARD MATCHES (exact endpoints, intermediate, intermediate-to-intermediate)
// =====================================================================
Deno.test("1. exact endpoints (Bhadrachalam -> Guntur) match", () => {
  const r = computeSelectedRouteMatch(
    SELECTED_ROUTE_WAYPOINTS,
    TOTAL_DISTANCE_KM,
    wp("Bhadrachalam"),
    wp("Guntur")
  );
  assert(r.isMatch, `expected MATCH, got NO_MATCH (${r.reason})`);
  assertEquals(r.snappedP, "Bhadrachalam");
  assertEquals(r.snappedQ, "Guntur");
});

Deno.test("2. intermediate waypoint (Bhadrachalam -> Vijayawada) matches", () => {
  const r = computeSelectedRouteMatch(
    SELECTED_ROUTE_WAYPOINTS,
    TOTAL_DISTANCE_KM,
    wp("Bhadrachalam"),
    wp("Vijayawada")
  );
  assert(r.isMatch, `expected MATCH, got NO_MATCH (${r.reason})`);
});

Deno.test("3. intermediate-to-intermediate (Kothagudem -> Vijayawada) matches", () => {
  const r = computeSelectedRouteMatch(
    SELECTED_ROUTE_WAYPOINTS,
    TOTAL_DISTANCE_KM,
    wp("Kothagudem"),
    wp("Vijayawada")
  );
  assert(r.isMatch, `expected MATCH, got NO_MATCH (${r.reason})`);
});

// =====================================================================
// 3b/3c. Remaining mandatory business scenarios (parity with geometric-corridor.test.ts's
// six-scenario convention: D = Tiruvuru->Guntur, E = Vijayawada->Guntur)
// =====================================================================
Deno.test("3b. Tiruvuru -> Guntur matches (mandatory scenario D)", () => {
  const r = computeSelectedRouteMatch(
    SELECTED_ROUTE_WAYPOINTS,
    TOTAL_DISTANCE_KM,
    wp("Tiruvuru"),
    wp("Guntur")
  );
  assert(r.isMatch, `expected MATCH, got NO_MATCH (${r.reason})`);
});

Deno.test("3c. Vijayawada -> Guntur matches (mandatory scenario E)", () => {
  const r = computeSelectedRouteMatch(
    SELECTED_ROUTE_WAYPOINTS,
    TOTAL_DISTANCE_KM,
    wp("Vijayawada"),
    wp("Guntur")
  );
  assert(r.isMatch, `expected MATCH, got NO_MATCH (${r.reason})`);
});

// =====================================================================
// 3d. NEAR-A-VIA (mandatory scenario 6): a passenger whose pickup is in the surrounding area of
// a Via (not exactly on the Via coordinate) still matches -- the snap radius (default 15 km)
// provides the tolerance, exactly as the existing intercity corridor check does.
// =====================================================================
Deno.test("3d. pickup ~8 km off Tiruvuru still snaps to Tiruvuru and matches -> Guntur", () => {
  // ~0.072 deg latitude north of Tiruvuru ~= 8 km; well inside the 15 km snap radius, well
  // outside any "exactly equal" tolerance.
  const nearTiruvuru = { lat: wp("Tiruvuru").lat + 0.072, lng: wp("Tiruvuru").lng };
  const offsetKm = Math.round(
    2 * 6371.0088 * Math.asin(Math.sqrt(Math.sin((0.072 * Math.PI / 180) / 2) ** 2))
  );
  assert(offsetKm >= 6 && offsetKm <= 10, `test point should be ~8 km off, was ${offsetKm} km`);
  const r = computeSelectedRouteMatch(
    SELECTED_ROUTE_WAYPOINTS,
    TOTAL_DISTANCE_KM,
    nearTiruvuru,
    wp("Guntur")
  );
  assert(r.isMatch, `expected MATCH, got NO_MATCH (${r.reason})`);
  assertEquals(r.snappedP, "Tiruvuru");
});

// =====================================================================
// 4. REVERSE DIRECTION
// =====================================================================
Deno.test("4. reverse direction (Guntur -> Bhadrachalam) is REJECTED", () => {
  const r = computeSelectedRouteMatch(
    SELECTED_ROUTE_WAYPOINTS,
    TOTAL_DISTANCE_KM,
    wp("Guntur"),
    wp("Bhadrachalam")
  );
  assertFalse(r.isMatch, "expected NO_MATCH, got MATCH");
  assertEquals(r.reason, "reverse_of_selected_route");
});

// =====================================================================
// 5/6. OUTSIDE SNAP RADIUS
// =====================================================================
Deno.test("5. pickup far outside snap radius of every waypoint is REJECTED", () => {
  const farAway = { lat: 12.9716, lng: 77.5946 }; // Bengaluru -- ~500km+ from every waypoint
  const r = computeSelectedRouteMatch(
    SELECTED_ROUTE_WAYPOINTS,
    TOTAL_DISTANCE_KM,
    farAway,
    wp("Guntur")
  );
  assertFalse(r.isMatch);
  assertEquals(r.reason, "outside_selected_route_corridor");
});

Deno.test("6. destination far outside snap radius of every waypoint is REJECTED", () => {
  const farAway = { lat: 12.9716, lng: 77.5946 }; // Bengaluru
  const r = computeSelectedRouteMatch(
    SELECTED_ROUTE_WAYPOINTS,
    TOTAL_DISTANCE_KM,
    wp("Bhadrachalam"),
    farAway
  );
  assertFalse(r.isMatch);
  assertEquals(r.reason, "outside_selected_route_corridor");
});

// =====================================================================
// 7. TOO-SHORT PASSENGER LEG
// =====================================================================
Deno.test("7. too-short passenger leg (both points snap near the same waypoint) is REJECTED", () => {
  const cfg: SelectedRouteConfig = { ...DEFAULT_SELECTED_ROUTE_CONFIG, minSegmentKm: 5 };
  // Both pickup and destination snap to the same waypoint (Kothagudem) -> tQ - tP == 0 < minSegmentKm.
  const r = computeSelectedRouteMatch(
    SELECTED_ROUTE_WAYPOINTS,
    TOTAL_DISTANCE_KM,
    wp("Kothagudem"),
    wp("Kothagudem"),
    cfg
  );
  assertFalse(r.isMatch);
  assertEquals(r.reason, "leg_too_short");
});

// =====================================================================
// 8. AUTO-SELECTED VS MANUALLY-SELECTED MATH IS IDENTICAL
// =====================================================================
Deno.test("8. the matching function has no notion of auto_selected -- identical waypoints always produce identical results", () => {
  // auto_selected/user_selected is metadata that lives OUTSIDE this pure module (in
  // selected_route_meta) -- computeSelectedRouteMatch's signature takes no such flag, so a
  // route that was auto-selected produces byte-for-byte the same result as one that was
  // manually selected, given the same waypoints.
  const a = computeSelectedRouteMatch(SELECTED_ROUTE_WAYPOINTS, TOTAL_DISTANCE_KM, wp("Bhadrachalam"), wp("Vijayawada"));
  const b = computeSelectedRouteMatch(SELECTED_ROUTE_WAYPOINTS, TOTAL_DISTANCE_KM, wp("Bhadrachalam"), wp("Vijayawada"));
  assertEquals(a, b);
});

// =====================================================================
// 9. ROUTE ORDERING (dedicated, mirrors geometric-corridor.test.ts's ORDERING section)
// =====================================================================
Deno.test("9. ordering: tP must not exceed tQ", () => {
  const forward = computeSelectedRouteMatch(SELECTED_ROUTE_WAYPOINTS, TOTAL_DISTANCE_KM, wp("Tiruvuru"), wp("Guntur"));
  assert(forward.isMatch);
  const reversed = computeSelectedRouteMatch(SELECTED_ROUTE_WAYPOINTS, TOTAL_DISTANCE_KM, wp("Guntur"), wp("Tiruvuru"));
  assertFalse(reversed.isMatch);
  assertEquals(reversed.reason, "reverse_of_selected_route");
});

// =====================================================================
// 10. MALFORMED / MISSING ROUTE GEOMETRY
// =====================================================================
Deno.test("10. empty waypoint list is REJECTED without throwing", () => {
  const r = computeSelectedRouteMatch([], TOTAL_DISTANCE_KM, wp("Bhadrachalam"), wp("Guntur"));
  assertFalse(r.isMatch);
  assertEquals(r.reason, "no_selected_route_waypoints");
});

Deno.test("10b. snapToNearestWaypoint returns null waypoint (not a throw) for an empty list", () => {
  const r = snapToNearestWaypoint([], wp("Bhadrachalam"));
  assertEquals(r.waypoint, null);
  assertEquals(r.distanceKm, Infinity);
});

// =====================================================================
// STRUCTURAL: independence from geometric-corridor.ts and index.ts (mirrors the equivalent
// section in geometric-corridor.test.ts)
// =====================================================================
Deno.test("STRUCTURAL: selected-route-corridor.ts does not import geometric-corridor.ts or reference route_geometry", () => {
  const source = Deno.readTextFileSync(new URL("./selected-route-corridor.ts", import.meta.url));
  const executableLines = source
    .split("\n")
    .filter((line) => !line.trim().startsWith("//"))
    .join("\n");
  assertFalse(executableLines.includes("geometric-corridor.ts"));
  assertFalse(executableLines.toLowerCase().includes("route_geometry"));
});
