// Provider-independent intercity matching corridor -- FROZEN SPEC implementation.
//
// This module is the primary matching gate's pure math: it decides whether a passenger leg
// (P -> Q) is geometrically plausible along a traveller's own straight-line corridor (O -> D),
// using ONLY the four endpoint coordinates every rider_travel_plans/orders row already has.
//
// It is deliberately provider-independent: no route_geometry, no Ola call, no polyline decode.
// route_geometry stays a separate, secondary, non-blocking signal -- see index.ts's shadow-log
// wiring, which never lets this module's output (or route_geometry) turn a MATCH into a
// NO_MATCH for anything user-visible during Phase 1.
//
// Exact spherical cross-track/along-track formulas (mean Earth radius), the same class of
// formula used in aviation/marine navigation -- not a flat-plane approximation.

export interface LatLng {
  lat: number;
  lng: number;
}

export interface GeometricCorridorConfig {
  widthRatio: number; // corridor half-width as a fraction of the O-D great-circle distance
  minWidthKm: number; // floor, so short corridors aren't given a near-zero width
  maxWidthKm: number; // cap, so long corridors aren't given an unreasonably wide berth
  tTolerance: number; // fraction of corridor length; absorbs GPS/geocoding noise near t=0/t=1
  minOverlapRatio: number; // minimum t(Q)-t(P) fraction of corridor length to be a meaningful leg
  reverseOrderTolerance: number; // slack allowed on t(P) <= t(Q) before treating as reverse
  maxDetourRatio: number; // detourKm / d12Km ceiling used only to compute detourPass (non-gating)
}

// Evidence-anchored initial values (see FINAL MATCHING ARCHITECTURE DECISION / FINAL TECHNICAL
// SPECIFICATION reports): widthRatio is set just above the 11.3% maximum cross-track/d12 ratio
// observed for the three real, Ola-geocoder-verified Bhadrachalam-Guntur corridor waypoints
// (Vijayawada 7.7%, Kothagudem 11.3%, Tiruvuru 6.1%). All other values are REASONABLE DESIGN
// estimates explicitly marked in the spec as requiring shadow-mode calibration -- none of these
// are final production numbers, and every one of them is overridable via production_config
// (see getIntercityGeometricConfig() in index.ts) without a code change.
export const DEFAULT_GEOMETRIC_CORRIDOR_CONFIG: GeometricCorridorConfig = {
  widthRatio: 0.15,
  minWidthKm: 4,
  maxWidthKm: 50,
  tTolerance: 0.015,
  minOverlapRatio: 0.03,
  reverseOrderTolerance: 0.01,
  maxDetourRatio: 0.20,
};

const EARTH_RADIUS_KM = 6371.0088;

function toRad(deg: number): number {
  return (deg * Math.PI) / 180;
}

function toDeg(rad: number): number {
  return (rad * 180) / Math.PI;
}

export function haversineDistanceKm(a: LatLng, b: LatLng): number {
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const la1 = toRad(a.lat);
  const la2 = toRad(b.lat);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(la1) * Math.cos(la2) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.min(1, Math.sqrt(h)));
}

export function initialBearingRadians(a: LatLng, b: LatLng): number {
  const la1 = toRad(a.lat);
  const la2 = toRad(b.lat);
  const dLng = toRad(b.lng - a.lng);
  const y = Math.sin(dLng) * Math.cos(la2);
  const x =
    Math.cos(la1) * Math.sin(la2) -
    Math.sin(la1) * Math.cos(la2) * Math.cos(dLng);
  return Math.atan2(y, x);
}

// Exact spherical cross-track (signed perpendicular offset, km) and along-track (distance from
// `origin` to the point on the O-D great circle closest to `point`, km) distances.
export function crossTrackAlongTrackKm(
  origin: LatLng,
  destination: LatLng,
  point: LatLng
): { crossTrackKm: number; alongTrackKm: number } {
  const d13 = haversineDistanceKm(origin, point) / EARTH_RADIUS_KM;
  const theta13 = initialBearingRadians(origin, point);
  const theta12 = initialBearingRadians(origin, destination);

  const crossTrackKm =
    Math.asin(Math.sin(d13) * Math.sin(theta13 - theta12)) * EARTH_RADIUS_KM;

  let cosAlong = Math.cos(d13) / Math.cos(crossTrackKm / EARTH_RADIUS_KM);
  cosAlong = Math.min(1, Math.max(-1, cosAlong));
  const alongTrackKm = Math.acos(cosAlong) * EARTH_RADIUS_KM;

  return { crossTrackKm, alongTrackKm };
}

export function corridorWidthKm(
  d12Km: number,
  cfg: GeometricCorridorConfig
): number {
  const raw = d12Km * cfg.widthRatio;
  return Math.min(cfg.maxWidthKm, Math.max(cfg.minWidthKm, raw));
}

export interface GeometricMatchResult {
  isMatch: boolean;
  d12Km: number;
  widthKm: number;
  tP: number;
  tQ: number;
  crossTrackPKm: number;
  crossTrackQKm: number;
  orderingPass: boolean;
  overlapPass: boolean;
  corridorPass: boolean;
  detourKm: number;
  maxDetourKm: number;
  detourPass: boolean;
  reason: string;
}

// Passenger geometric validity -- the exact 6-rule conjunction from the frozen spec:
//   1. t(P) in [0-epsilon_t, 1+epsilon_t]
//   2. t(Q) in [0-epsilon_t, 1+epsilon_t]
//   3. t(Q)-t(P) >= MIN_OVERLAP
//   4. t(P) <= t(Q)+epsilon_order
//   5. |crossTrack(P)| <= width(d12)
//   6. |crossTrack(Q)| <= width(d12)
//
// detourKm/detourPass are computed and returned for shadow-mode inspection ONLY. The frozen
// spec explicitly left the detour guard's fail-action (hard-reject vs. soft-deprioritize) as an
// open product decision -- `isMatch` therefore reflects ONLY rules 1-6 above, never detourPass.
// This function never inspects route_geometry and never can: it does not accept it as an input.
export function computeGeometricCorridorMatch(
  origin: LatLng,
  destination: LatLng,
  passengerPickup: LatLng,
  passengerDestination: LatLng,
  cfg: GeometricCorridorConfig = DEFAULT_GEOMETRIC_CORRIDOR_CONFIG
): GeometricMatchResult {
  const d12Km = haversineDistanceKm(origin, destination);

  if (!(d12Km > 0.001)) {
    return {
      isMatch: false,
      d12Km,
      widthKm: 0,
      tP: NaN,
      tQ: NaN,
      crossTrackPKm: NaN,
      crossTrackQKm: NaN,
      orderingPass: false,
      overlapPass: false,
      corridorPass: false,
      detourKm: NaN,
      maxDetourKm: NaN,
      detourPass: false,
      reason: "degenerate_traveller_corridor",
    };
  }

  const widthKm = corridorWidthKm(d12Km, cfg);

  const p = crossTrackAlongTrackKm(origin, destination, passengerPickup);
  const q = crossTrackAlongTrackKm(origin, destination, passengerDestination);
  const tP = p.alongTrackKm / d12Km;
  const tQ = q.alongTrackKm / d12Km;

  const tLow = 0 - cfg.tTolerance;
  const tHigh = 1 + cfg.tTolerance;
  const tPInRange = tP >= tLow && tP <= tHigh;
  const tQInRange = tQ >= tLow && tQ <= tHigh;

  const overlapPass = tQ - tP >= cfg.minOverlapRatio;
  const orderingPass = tP <= tQ + cfg.reverseOrderTolerance;

  const corridorPass =
    Math.abs(p.crossTrackKm) <= widthKm && Math.abs(q.crossTrackKm) <= widthKm;

  const detourKm =
    haversineDistanceKm(origin, passengerPickup) +
    haversineDistanceKm(passengerPickup, passengerDestination) +
    haversineDistanceKm(passengerDestination, destination) -
    d12Km;
  const maxDetourKm = d12Km * cfg.maxDetourRatio;
  const detourPass = detourKm <= maxDetourKm;

  const isMatch =
    tPInRange && tQInRange && overlapPass && orderingPass && corridorPass;

  let reason = "match";
  if (!isMatch) {
    if (!orderingPass) reason = "reverse_or_out_of_order";
    else if (!tPInRange || !tQInRange) reason = "outside_corridor_span";
    else if (!overlapPass) reason = "leg_too_short";
    else if (!corridorPass) reason = "outside_corridor_width";
  }

  return {
    isMatch,
    d12Km,
    widthKm,
    tP,
    tQ,
    crossTrackPKm: p.crossTrackKm,
    crossTrackQKm: q.crossTrackKm,
    orderingPass,
    overlapPass,
    corridorPass,
    detourKm,
    maxDetourKm,
    detourPass,
    reason,
  };
}
