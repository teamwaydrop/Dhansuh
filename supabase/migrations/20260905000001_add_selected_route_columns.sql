-- Migration: Add declared-route (Via-locations) corridor columns to rider_travel_plans
-- Date: 2026-09-05
--
-- docs/13_Business_Logic.md, section 5 "Intercity Declared-Route Corridor Matching":
-- additive-only storage for the ordered route a traveller explicitly declares at plan creation
-- time by adding optional Via locations (Origin -> Via 1 -> Via 2 -> ... -> Destination).
--
-- Purely additive, nullable, no default -- every existing row is unaffected (all three columns
-- are NULL for every plan created before this migration, and matching for those plans is
-- untouched, see docs/13_Business_Logic.md section 5.6). No destructive change, no backfill.

ALTER TABLE public.rider_travel_plans
ADD COLUMN IF NOT EXISTS selected_route_geometry JSONB;

ALTER TABLE public.rider_travel_plans
ADD COLUMN IF NOT EXISTS selected_route_meta JSONB;

ALTER TABLE public.rider_travel_plans
ADD COLUMN IF NOT EXISTS route_selection_status TEXT;

COMMENT ON COLUMN public.rider_travel_plans.selected_route_geometry IS 'JSON array of [lat, lng] pairs for the traveller''s DECLARED route -- one polyline stitched from the ordered Origin -> Via... -> Destination legs (multi-leg build via OlaMapService.getMultiStopRoute). Same point-array shape as route_geometry, but traveller-declared corridor intent rather than a raw provider polyline for the O-D pair. NULL for plans created before this feature, and for any plan where the traveller added no Via locations.';

COMMENT ON COLUMN public.rider_travel_plans.selected_route_meta IS 'JSON object: {waypoints:[{order,type,label,lat,lng,along_track_km}], total_distance_km, provider, built_via, leg_count, selected_at}. waypoints is the ordered Origin/Via/Destination sequence; type is one of ''origin''|''via''|''destination''; along_track_km is the cumulative multi-leg road distance from the origin to that waypoint. total_distance_km is the declared route distance and is used ONLY for matching -- never for pricing/fare. NULL for plans without a declared route.';

COMMENT ON COLUMN public.rider_travel_plans.route_selection_status IS 'One of ''via_declared'' (traveller added >=1 Via location and the declared route was built and stored) | ''none'' (direct Origin->Destination plan, no Via locations). NULL for plans created before this feature.';
