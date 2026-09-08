-- Migration: Add route_geometry column to rider_travel_plans table
-- Date: 2026-06-22

ALTER TABLE public.rider_travel_plans
ADD COLUMN IF NOT EXISTS route_geometry TEXT;

COMMENT ON COLUMN public.rider_travel_plans.route_geometry IS 'JSON string representing the list of route coordinates [[lat, lng], ...] for corridor matching.';
