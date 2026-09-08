// Traveller declared-route (Via-locations) corridor matcher.
// See docs/13_Business_Logic.md, section 5 "Intercity Declared-Route Corridor Matching",
// subsection 5.3 "Matching algorithm" -- that document is authoritative; this module implements
// it exactly, without redesign.
//
// Unlike geometric-corridor.ts (which uses the traveller's straight-line O-D geodesic), this
// module snaps a passenger's pickup/destination onto the traveller's EXPLICITLY DECLARED route
// -- the ordered Origin -> Via 1 -> ... -> Destination waypoint sequence the traveller entered
// at plan creation time (see docs/13_Business_Logic.md section 5.1/5.2), each waypoint carrying
// its cumulative multi-leg road distance from the origin (`alongTrackKm`). It is deliberately
// independent: no DB access, no network call, no import from index.ts or geometric-corridor.ts,
// pure computation only, so it is trivial to unit test.
//
// Integration (see index.ts, both modes, guarded by `selected_route_geometry IS NOT NULL`):
// this module's `isMatch` result is ADDITIVE -- it can promote a candidate to matched, but it
// never demotes one and is never AND-composed, so a plan with no declared route
// (selected_route_geometry NULL) is completely unaffected -- docs/13_Business_Logic.md
// section 5.3/5.6.

export interface LatLng {
  lat: number;
  lng: number;
}

export interface RouteWaypoint extends LatLng {
  label: string;
  alongTrackKm: number;
}

export interface SelectedRouteConfig {
  // Max distance (km) from a waypoint for a passenger point to "snap" onto the route.
  snapRadiusKm: number;
  // Minimum along-route separation (km) between snapped P and Q to count as a meaningful leg.
  minSegmentKm: number;
}

// Matches the existing intercity_corridor_radius_km default (index.ts's getIntercitySettings)
// per docs/13_Business_Logic.md section 5.3.
export const DEFAULT_SELECTED_ROUTE_CONFIG: SelectedRouteConfig = {
  snapRadiusKm: 15,
  minSegmentKm: 5,
};

const EARTH_RADIUS_KM = 6371.0088;

function toRad(deg: number): number {
  return (deg * Math.PI) / 180;
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

export interface SnapResult {
  waypoint: RouteWaypoint | null;
  distanceKm: number;
}

// Phase 1 approximation (docs/13_Business_Logic.md section 5.3 explicitly allows this cheaper
// approximation over full-polyline nearest-point search): snaps to the nearest WAYPOINT only.
// Deterministic and cheap -- a future phase may snap to the nearest point on any leg instead.
export function snapToNearestWaypoint(
  waypoints: RouteWaypoint[],
  point: LatLng
): SnapResult {
  let best: RouteWaypoint | null = null;
  let bestDistanceKm = Infinity;
  for (const wp of waypoints) {
    const d = haversineDistanceKm(wp, point);
    if (d < bestDistanceKm) {
      bestDistanceKm = d;
      best = wp;
    }
  }
  return { waypoint: best, distanceKm: bestDistanceKm };
}

export interface SelectedRouteMatchResult {
  isMatch: boolean;
  tP: number | null; // along-track km position of the passenger pickup's snap, or null if no snap
  tQ: number | null;
  snappedP: string | null; // label of the nearest waypoint snapped to, or null
  snappedQ: string | null;
  snapDistancePKm: number | null;
  snapDistanceQKm: number | null;
  reason: string;
}

// Passenger validity against the traveller's SELECTED route -- the frozen spec's 5-step
// sequence (docs/13_Business_Logic.md section 5.3):
//   1. snap P within snapRadiusKm -> tP (no snap => outside_selected_route_corridor)
//   2. snap Q within snapRadiusKm -> tQ (no snap => outside_selected_route_corridor)
//   3. tQ - tP >= minSegmentKm required (else => leg_too_short)
//   4. tP <= tQ required (else => reverse_of_selected_route)
//   5. otherwise => match
//
// Reason-priority note: when a passenger pair is genuinely reversed, tQ-tP is negative and
// therefore ALSO fails step 3's minSegmentKm check -- so step 3 and step 4 are evaluated as
// independent conditions (both required for isMatch), and the `reason` label prioritizes
// "reverse_of_selected_route" over "leg_too_short" when both fail. This mirrors
// geometric-corridor.ts's already-established, already-tested reason-priority convention
// (orderingPass is checked before overlapPass there too) -- it changes only the diagnostic
// `reason` string, never the isMatch outcome.
export function computeSelectedRouteMatch(
  waypoints: RouteWaypoint[],
  totalDistanceKm: number,
  passengerPickup: LatLng,
  passengerDestination: LatLng,
  cfg: SelectedRouteConfig = DEFAULT_SELECTED_ROUTE_CONFIG
): SelectedRouteMatchResult {
  if (!waypoints || waypoints.length === 0) {
    return {
      isMatch: false,
      tP: null,
      tQ: null,
      snappedP: null,
      snappedQ: null,
      snapDistancePKm: null,
      snapDistanceQKm: null,
      reason: "no_selected_route_waypoints",
    };
  }

  const snapP = snapToNearestWaypoint(waypoints, passengerPickup);
  if (!snapP.waypoint || snapP.distanceKm > cfg.snapRadiusKm) {
    return {
      isMatch: false,
      tP: null,
      tQ: null,
      snappedP: null,
      snappedQ: null,
      snapDistancePKm: snapP.distanceKm,
      snapDistanceQKm: null,
      reason: "outside_selected_route_corridor",
    };
  }

  const snapQ = snapToNearestWaypoint(waypoints, passengerDestination);
  if (!snapQ.waypoint || snapQ.distanceKm > cfg.snapRadiusKm) {
    return {
      isMatch: false,
      tP: snapP.waypoint.alongTrackKm,
      tQ: null,
      snappedP: snapP.waypoint.label,
      snappedQ: null,
      snapDistancePKm: snapP.distanceKm,
      snapDistanceQKm: snapQ.distanceKm,
      reason: "outside_selected_route_corridor",
    };
  }

  const tP = snapP.waypoint.alongTrackKm;
  const tQ = snapQ.waypoint.alongTrackKm;

  const orderingPass = tP <= tQ;
  const overlapPass = tQ - tP >= cfg.minSegmentKm;
  const isMatch = orderingPass && overlapPass;

  let reason = "match";
  if (!isMatch) {
    reason = !orderingPass ? "reverse_of_selected_route" : "leg_too_short";
  }

  return {
    isMatch,
    tP,
    tQ,
    snappedP: snapP.waypoint.label,
    snappedQ: snapQ.waypoint.label,
    snapDistancePKm: snapP.distanceKm,
    snapDistanceQKm: snapQ.distanceKm,
    reason,
  };
}
