-- Migration: Travel plan seat availability view
-- Date: 2026-07-17
--
-- The Available Partners browsing screen (User side) needs "N seats available" per Travel Plan
-- for the date-switcher counts and Partner Card. match-intercity-riders/index.ts already computes
-- this inline (active bookings count vs max_bookings) for its own scoring pass, but re-deriving
-- that same count for every date a user browses would either mean re-invoking the edge function
-- per date (expensive, and it also does corridor-scoring work the browsing screen does not need)
-- or duplicating the counting logic a second time in Dart. This view mirrors the existing
-- travel_plan_capacity_view (weight capacity, 20260622000002_smart_matching_final_production.sql)
-- pattern for seats instead, so both the edge function and the Dart browsing screen can eventually
-- read from one place.

CREATE OR REPLACE VIEW public.travel_plan_seat_availability_view AS
SELECT
    tp.id AS plan_id,
    tp.max_bookings,
    COALESCE(cb.confirmed_count, 0) AS confirmed_count,
    GREATEST(tp.max_bookings - COALESCE(cb.confirmed_count, 0), 0) AS available_seats
FROM public.rider_travel_plans tp
LEFT JOIN (
    SELECT route_id, COUNT(*) AS confirmed_count
    FROM public.intercity_requests
    WHERE status IN ('confirmed', 'paid')
    GROUP BY route_id
) cb ON cb.route_id = tp.id;

GRANT SELECT ON public.travel_plan_seat_availability_view TO authenticated;
