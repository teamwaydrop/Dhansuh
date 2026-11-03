-- Migration: Add selected-route corridor columns to rider_travel_plans table
-- Date: 2026-09-05
--
-- FROZEN SPEC (docs/13_Business_Logic.md, section 5 "Intercity Selected-Route
-- Corridor Matching (Architecture C)"): additive-only storage for a
-- traveller's explicitly-selected route among Ola's route alternatives.
-- Purely additive, nullable, no default -- every existing row is
-- unaffected (all three columns are NULL for every plan created before
-- this migration, and matching for those plans is untouched, see
-- docs/13_Business_Logic.md section 5.6).

ALTER TABLE public.rider_travel_plans
ADD COLUMN IF NOT EXISTS selected_route_geometry JSONB;

ALTER TABLE public.rider_travel_plans
ADD COLUMN IF NOT EXISTS selected_route_meta JSONB;

ALTER TABLE public.rider_travel_plans
ADD COLUMN IF NOT EXISTS route_selection_status TEXT;

COMMENT ON COLUMN public.rider_travel_plans.selected_route_geometry IS 'JSON array of [lat, lng] pairs for the traveller-selected route among Ola alternatives -- same shape as route_geometry, but traveller-confirmed intent rather than a raw provider polyline. NULL for plans created before this feature, and for any plan where selection was not captured.';

COMMENT ON COLUMN public.rider_travel_plans.selected_route_meta IS 'JSON object: {waypoints, total_distance_km, provider, route_label, auto_selected, selected_at}. route_label is a synthesized ordinal id (e.g. "route_0") -- Ola does not provide a native per-route id. NULL for plans without a selection.';

COMMENT ON COLUMN public.rider_travel_plans.route_selection_status IS 'One of ''user_selected'' | ''auto_selected'' | ''none''. NULL for plans created before this feature.';
