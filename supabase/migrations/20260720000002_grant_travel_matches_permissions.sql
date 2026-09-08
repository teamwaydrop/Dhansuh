-- Migration: Fix missing table-level GRANT on travel_matches.
-- Date: 2026-07-20
--
-- 20260720000000_traveller_available_and_trip_lifecycle.sql created travel_matches with RLS
-- enabled and a SELECT policy for authenticated participants, but omitted the table-level GRANT
-- this project relies on instead of default privileges (see the same note in
-- 20260717000000_add_rider_vehicles_table.sql). Without it, PostgREST rejects every request
-- against travel_matches with "permission denied for table travel_matches" (42501) regardless of
-- RLS, for both anon and authenticated roles.
GRANT ALL ON TABLE public.travel_matches TO postgres, service_role, authenticated, anon;
