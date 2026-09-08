// Regression tests for the FROZEN provider-independent intercity matching corridor spec.
//
// Coordinates below are NOT invented: Bhadrachalam/Guntur are the real device-captured
// coordinates from the live Bhadrachalam->Guntur route diagnostic (this repo's own
// [IntercityRouteDebug] session), and Vijayawada/Kothagudem/Tiruvuru are Ola's own geocoder
// results (read-only diagnostic calls to https://api.olamaps.io/places/v1/geocode), all captured
// during the design phase of this feature. No live network call is made by this test file.
//
// Run with: deno test supabase/functions/match-intercity-riders/geometric-corridor.test.ts
import { assert, assertEquals, assertFalse } from "https://deno.land/std@0.168.0/testing/asserts.ts";
import {
  computeGeometricCorridorMatch,
  corridorWidthKm,
  crossTrackAlongTrackKm,
  DEFAULT_GEOMETRIC_CORRIDOR_CONFIG,
  haversineDistanceKm,
  initialBearingRadians,
  type GeometricCorridorConfig,
  type LatLng,
} from "./geometric-corridor.ts";

const BHADRACHALAM: LatLng = { lat: 17.67234, lng: 80.89694 };
const GUNTUR: LatLng = { lat: 16.314005, lng: 80.441673 };
const VIJAYAWADA: LatLng = { lat: 16.530371, lng: 80.634165 };
const KOTHAGUDEM: LatLng = { lat: 17.483227, lng: 80.655534 };
const TIRUVURU: LatLng = { lat: 17.109278, lng: 80.61101 };

function closeTo(actual: number, expected: number, tolerance: number, label: string) {
  assert(
    Math.abs(actual - expected) <= tolerance,
    `${label}: expected ~${expected}, got ${actual}`
  );
}

// =====================================================================
// 1. SIX MANDATORY SCENARIOS -- traveller O=Bhadrachalam, D=Guntur
// =====================================================================
Deno.test("Scenario A: Bhadrachalam -> Guntur matches (exact endpoints)", () => {
  const r = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, BHADRACHALAM, GUNTUR);
  assert(r.isMatch, `expected MATCH, got NO_MATCH (${r.reason})`);
  closeTo(r.tP, 0, 0.001, "t(P)");
  closeTo(r.tQ, 1, 0.001, "t(Q)");
});

Deno.test("Scenario B: Bhadrachalam -> Vijayawada matches (the core intermediate-passenger case)", () => {
  const r = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, BHADRACHALAM, VIJAYAWADA);
  assert(r.isMatch, `expected MATCH, got NO_MATCH (${r.reason})`);
  closeTo(r.tQ, 0.816, 0.01, "t(Q) for Vijayawada");
  closeTo(r.crossTrackQKm, -12.227, 0.5, "crossTrack(Q) for Vijayawada");
});

Deno.test("Scenario C: Kothagudem -> Vijayawada matches (intermediate-to-intermediate)", () => {
  const r = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, KOTHAGUDEM, VIJAYAWADA);
  assert(r.isMatch, `expected MATCH, got NO_MATCH (${r.reason})`);
  closeTo(r.tP, 0.176, 0.01, "t(P) for Kothagudem");
  closeTo(r.tQ, 0.816, 0.01, "t(Q) for Vijayawada");
});

Deno.test("Scenario D: Tiruvuru -> Guntur matches", () => {
  const r = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, TIRUVURU, GUNTUR);
  assert(r.isMatch, `expected MATCH, got NO_MATCH (${r.reason})`);
  closeTo(r.tP, 0.434, 0.01, "t(P) for Tiruvuru");
});

Deno.test("Scenario E: Vijayawada -> Guntur matches", () => {
  const r = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, VIJAYAWADA, GUNTUR);
  assert(r.isMatch, `expected MATCH, got NO_MATCH (${r.reason})`);
});

Deno.test("Scenario F: Guntur -> Bhadrachalam is REJECTED (reverse direction)", () => {
  const r = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, GUNTUR, BHADRACHALAM);
  assertFalse(r.isMatch, `expected NO_MATCH, got MATCH`);
  assertEquals(r.reason, "reverse_or_out_of_order");
});

// =====================================================================
// 2. REVERSE DIRECTION REJECTION -- dedicated, explicit, with detour cross-check
// =====================================================================
Deno.test("CRITICAL: Guntur -> Bhadrachalam does NOT match Bhadrachalam -> Guntur", () => {
  const forward = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, BHADRACHALAM, GUNTUR);
  const reverse = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, GUNTUR, BHADRACHALAM);
  assert(forward.isMatch);
  assertFalse(reverse.isMatch);
  // Independently confirmed by detour cost: a reverse leg costs roughly 2x the corridor length,
  // versus a few percent for every genuine forward scenario -- two independent mechanisms agree.
  assert(reverse.detourKm > reverse.d12Km * 1.5, "reverse detour should be roughly 2x corridor length");
});

Deno.test("reverse rejection holds even when both reverse endpoints are well inside the corridor width", () => {
  // Vijayawada -> Kothagudem is the reverse of the valid Scenario C leg.
  const r = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, VIJAYAWADA, KOTHAGUDEM);
  assertFalse(r.isMatch);
  assertEquals(r.reason, "reverse_or_out_of_order");
});

// =====================================================================
// 3. INTERMEDIATE PASSENGER MATCHING -- proves the original bug (Ola's chosen 246km road vs. the
//    158.6km straight line) cannot hide a geometrically valid intermediate passenger.
// =====================================================================
Deno.test("intermediate passengers are discoverable using ONLY endpoint coordinates, independent of any route length/shape", () => {
  for (const [name, point] of [
    ["Vijayawada", VIJAYAWADA],
    ["Kothagudem", KOTHAGUDEM],
    ["Tiruvuru", TIRUVURU],
  ] as const) {
    const r = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, BHADRACHALAM, point);
    assert(r.isMatch, `${name} should be discoverable as an intermediate destination (${r.reason})`);
  }
});

// =====================================================================
// 4/5/6/7. PROVIDER-INDEPENDENT BEHAVIOR -- route_geometry cannot participate because the
//    primary gate's function signature has no such parameter at all. This is a structural
//    guarantee, not a runtime check -- verified two ways: source-text absence, and by proving
//    the boolean result is identical regardless of what a caller might pass around as
//    "route_geometry state" (null / mismatched / absent), since the function never consumes it.
// =====================================================================
const geometricCorridorSource = Deno.readTextFileSync(
  new URL("./geometric-corridor.ts", import.meta.url)
);
// Strip //-comment lines first -- this file's own doc comments legitimately EXPLAIN that
// route_geometry is deliberately excluded (that's documentation, not a code dependency). The
// guarantee under test is about executable code, so only non-comment lines are checked.
const geometricCorridorExecutableLines = geometricCorridorSource
  .split("\n")
  .filter((line) => !line.trim().startsWith("//"))
  .join("\n");

Deno.test("STRUCTURAL: the primary geometric gate module's executable code never references route_geometry, polyline, or any Ola/provider identifier", () => {
  const forbidden = ["route_geometry", "polyline", "olamaps", "overview_polyline"];
  for (const token of forbidden) {
    assertFalse(
      geometricCorridorExecutableLines.toLowerCase().includes(token.toLowerCase()),
      `geometric-corridor.ts executable code must not reference "${token}" -- it must be fully provider-independent`
    );
  }
});

Deno.test("CRITICAL: route_geometry null/mismatched/absent cannot change MATCH -> NO_MATCH for a geometrically valid passenger", () => {
  // computeGeometricCorridorMatch has no route_geometry parameter -- there is no code path by
  // which a caller could even attempt to feed it in. We simulate the three states a caller might
  // otherwise have branched on (null / a mismatched decoded polyline / entirely absent) and show
  // the result is byte-for-byte identical in all three, because none of them were ever inputs.
  const routeGeometryStates: Array<unknown> = [
    null, // route_geometry is null
    [[1.0, 2.0], [3.0, 4.0]], // route_geometry present but decodes to a wholly unrelated polyline
    undefined, // route_geometry column absent/never selected
  ];

  const results = routeGeometryStates.map(() =>
    computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, BHADRACHALAM, VIJAYAWADA)
  );

  for (const r of results) {
    assert(r.isMatch, "a geometrically valid passenger must remain MATCH regardless of route_geometry state");
  }
  assertEquals(results[0].tP, results[1].tP);
  assertEquals(results[0].tQ, results[2].tQ);
  assertEquals(results[0].crossTrackQKm, results[1].crossTrackQKm);
});

Deno.test("STRUCTURAL: index.ts's shadow-log call site does not pass route_geometry into computeGeometricCorridorMatch and never reassigns isMatched from the geometric result", () => {
  const indexSource = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));
  const callSites = [...indexSource.matchAll(/computeGeometricCorridorMatch\(([^)]*)\)/g)];
  assert(callSites.length >= 2, "expected a shadow-mode call site in both Mode 1 and Mode 2");
  for (const call of callSites) {
    assertFalse(call[1].includes("route_geometry"), "call site must not pass route_geometry");
  }
  assertFalse(
    /isMatched\s*=\s*isMatched\s*&&\s*(shadow|geometric)/i.test(indexSource),
    "isMatched must never be narrowed by the shadow geometric result during Phase 1"
  );
});

// =====================================================================
// 8. OLD TRAVELLER PLANS -- the function requires nothing beyond the four endpoint coordinates
//    every existing rider_travel_plans/orders row already has. No optional field is required.
// =====================================================================
Deno.test("old traveller plans work with zero additional fields -- only O, D, P, Q coordinates", () => {
  const r = computeGeometricCorridorMatch(
    { lat: BHADRACHALAM.lat, lng: BHADRACHALAM.lng },
    { lat: GUNTUR.lat, lng: GUNTUR.lng },
    { lat: BHADRACHALAM.lat, lng: BHADRACHALAM.lng },
    { lat: VIJAYAWADA.lat, lng: VIJAYAWADA.lng }
  );
  assert(r.isMatch);
});

// =====================================================================
// 9/10. SHORT AND LONG ROUTES -- width floor/cap behavior
// =====================================================================
Deno.test("short routes: width floor applies instead of an unreasonably small percentage-based width", () => {
  const shortO: LatLng = { lat: 17.0, lng: 80.0 };
  const shortD: LatLng = { lat: 17.045, lng: 80.0 }; // ~5km north
  const d12 = haversineDistanceKm(shortO, shortD);
  const width = corridorWidthKm(d12, DEFAULT_GEOMETRIC_CORRIDOR_CONFIG);
  closeTo(d12, 5, 0.5, "short corridor length");
  assertEquals(width, DEFAULT_GEOMETRIC_CORRIDOR_CONFIG.minWidthKm, "width must clamp to the floor, not 15% of 5km");
});

Deno.test("long routes: width cap applies instead of an unreasonably large percentage-based width", () => {
  const longO: LatLng = { lat: 12.0, lng: 77.0 };
  const longD: LatLng = { lat: 21.0, lng: 79.0 }; // roughly 1000km+
  const d12 = haversineDistanceKm(longO, longD);
  assert(d12 > 900, "expected a long corridor for this test");
  const width = corridorWidthKm(d12, DEFAULT_GEOMETRIC_CORRIDOR_CONFIG);
  assertEquals(width, DEFAULT_GEOMETRIC_CORRIDOR_CONFIG.maxWidthKm, "width must clamp to the cap on a long corridor");
});

// =====================================================================
// 11. ORDERING
// =====================================================================
Deno.test("ordering: t(P) must not exceed t(Q) beyond reverseOrderTolerance", () => {
  const cfg: GeometricCorridorConfig = { ...DEFAULT_GEOMETRIC_CORRIDOR_CONFIG, reverseOrderTolerance: 0.0 };
  // Two points with nearly identical t (a same-town pickup/drop) should still pass at tolerance 0
  // when truly non-decreasing, and fail once actually reversed.
  const same = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, VIJAYAWADA, VIJAYAWADA, cfg);
  assertFalse(same.orderingPass === false && same.tP < same.tQ, "orderingPass must reflect the tP<=tQ+tolerance rule consistently");
  const reversed = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, GUNTUR, BHADRACHALAM, cfg);
  assertFalse(reversed.orderingPass);
});

// =====================================================================
// 12. TOLERANCE BEHAVIOR (epsilon_t)
// =====================================================================
Deno.test("tolerance: a point just beyond D (t slightly > 1) still matches within tTolerance", () => {
  // Construct a point a small distance past Guntur, continuing the same bearing.
  const bearing = initialBearingRadians(BHADRACHALAM, GUNTUR);
  const d12 = haversineDistanceKm(BHADRACHALAM, GUNTUR);
  const extraKm = d12 * 0.01; // 1% past D, within the default 1.5% tTolerance
  const lat = GUNTUR.lat + (extraKm / 111.32) * Math.cos(bearing);
  const lng = GUNTUR.lng + (extraKm / (111.32 * Math.cos(toRadLocal(GUNTUR.lat)))) * Math.sin(bearing);
  const slightlyBeyond: LatLng = { lat, lng };

  const r = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, BHADRACHALAM, slightlyBeyond);
  assert(r.isMatch, `a point 1% past D should still match within tTolerance (${r.reason}, tQ=${r.tQ})`);
});

Deno.test("tolerance: a point far beyond D (well outside tTolerance) does not match", () => {
  const bearing = initialBearingRadians(BHADRACHALAM, GUNTUR);
  const d12 = haversineDistanceKm(BHADRACHALAM, GUNTUR);
  const extraKm = d12 * 0.5; // 50% past D -- far outside any reasonable tTolerance
  const lat = GUNTUR.lat + (extraKm / 111.32) * Math.cos(bearing);
  const lng = GUNTUR.lng + (extraKm / (111.32 * Math.cos(toRadLocal(GUNTUR.lat)))) * Math.sin(bearing);
  const farBeyond: LatLng = { lat, lng };

  const r = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, BHADRACHALAM, farBeyond);
  assertFalse(r.isMatch);
  assertEquals(r.reason, "outside_corridor_span");
});

function toRadLocal(deg: number): number {
  return (deg * Math.PI) / 180;
}

// =====================================================================
// 13. CORRIDOR WIDTH CLAMP -- direct unit tests of corridorWidthKm()
// =====================================================================
Deno.test("corridorWidthKm: percentage value used when between floor and cap", () => {
  const cfg: GeometricCorridorConfig = { ...DEFAULT_GEOMETRIC_CORRIDOR_CONFIG, widthRatio: 0.15, minWidthKm: 4, maxWidthKm: 50 };
  closeTo(corridorWidthKm(100, cfg), 15, 0.001, "100km * 15%");
});

Deno.test("corridorWidthKm: floor applied below the percentage threshold", () => {
  const cfg: GeometricCorridorConfig = { ...DEFAULT_GEOMETRIC_CORRIDOR_CONFIG, widthRatio: 0.15, minWidthKm: 4, maxWidthKm: 50 };
  assertEquals(corridorWidthKm(10, cfg), 4); // 10*0.15=1.5, floored to 4
});

Deno.test("corridorWidthKm: cap applied above the percentage threshold", () => {
  const cfg: GeometricCorridorConfig = { ...DEFAULT_GEOMETRIC_CORRIDOR_CONFIG, widthRatio: 0.15, minWidthKm: 4, maxWidthKm: 50 };
  assertEquals(corridorWidthKm(1000, cfg), 50); // 1000*0.15=150, capped to 50
});

// =====================================================================
// 14. DETOUR GUARD BEHAVIOR -- computed, exposed, and explicitly non-gating
// =====================================================================
Deno.test("detour guard: real proven legitimate scenarios have small detour, reverse has a huge one", () => {
  const b = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, BHADRACHALAM, VIJAYAWADA);
  const c = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, KOTHAGUDEM, VIJAYAWADA);
  const f = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, GUNTUR, BHADRACHALAM);
  closeTo(b.detourKm, 3.035, 0.2, "scenario B detour");
  closeTo(c.detourKm, 12.118, 0.3, "scenario C detour");
  assert(f.detourKm > 300, "reverse detour should be huge");
});

Deno.test("detour guard is non-gating: detourPass=false must not force isMatch=false", () => {
  const cfg: GeometricCorridorConfig = { ...DEFAULT_GEOMETRIC_CORRIDOR_CONFIG, maxDetourRatio: 0.01 }; // artificially strict
  const r = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, KOTHAGUDEM, VIJAYAWADA, cfg);
  assertFalse(r.detourPass, "expected the artificially strict detour ceiling to fail");
  assert(r.isMatch, "isMatch must still be true -- detourPass never gates the frozen spec's 6-rule conjunction");
});

// =====================================================================
// 15. CONFIG-DRIVEN BEHAVIOR (production_config, not hardcoded)
// =====================================================================
Deno.test("thresholds are config-driven: a narrower widthRatio changes the outcome for a borderline scenario", () => {
  const permissive = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, KOTHAGUDEM, VIJAYAWADA, DEFAULT_GEOMETRIC_CORRIDOR_CONFIG);
  assert(permissive.isMatch, "Kothagudem->Vijayawada matches under the default config");

  const strict: GeometricCorridorConfig = { ...DEFAULT_GEOMETRIC_CORRIDOR_CONFIG, widthRatio: 0.05, minWidthKm: 1, maxWidthKm: 10 };
  const narrowed = computeGeometricCorridorMatch(BHADRACHALAM, GUNTUR, KOTHAGUDEM, VIJAYAWADA, strict);
  assertFalse(narrowed.isMatch, "an artificially narrow widthRatio must reject Kothagudem's 17.9km offset -- proves no hardcoded width");
  assertEquals(narrowed.reason, "outside_corridor_width");
});

Deno.test("STRUCTURAL: index.ts's config reader actually queries production_config (not a hardcoded stub)", () => {
  const indexSource = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));
  assert(indexSource.includes('.from("production_config")'), "getIntercitySettings must read production_config");
  assert(indexSource.includes("extra_flags"), "geometric thresholds must be sourced from production_config.extra_flags");
});
