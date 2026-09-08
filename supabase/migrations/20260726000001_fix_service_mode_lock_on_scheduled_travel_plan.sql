-- Migration: Stop locking Service Mode on a merely-created/scheduled Travel Plan.
-- Date: 2026-07-26
--
-- BUG REPORT: immediately after creating an intercity Travel Plan (before pressing Start Trip),
-- a Drop Partner could no longer switch back to Local Service. Reproduced by tracing the exact
-- write path:
--   post_travel_plan_screen.dart -> INSERT INTO rider_travel_plans (..., status: 'active', ...)
--   -> prevent_service_mode_switch_during_active_order() (BEFORE UPDATE OF service_mode ON riders)
--      -- added by 20260721000004 -- rejects the switch whenever
--      SELECT COUNT(*) FROM rider_travel_plans WHERE rider_id = NEW.id AND status = 'active' > 0.
--
-- ROOT CAUSE: rider_travel_plans.status is set to 'active' at INSERT time (see
-- post_travel_plan_screen.dart) and stays 'active' through the entire lifetime of the plan --
-- including after Start Trip is pressed. start_intercity_trip_for_plan() / start_intercity_trip()
-- (20260721000003 / 20260720000004) never touch rider_travel_plans.status at all; the only
-- server-side signal that a trip has actually STARTED is orders.trip_started_at on the individual
-- passenger order rows under that plan. travel_plan_status_enum only distinguishes
-- active/completed/cancelled (created vs. terminal), it has no separate "started" state. So the
-- 20260721000004 check ("any active travel plan row exists") was actually testing "has this rider
-- ever created a plan that hasn't been deleted/completed", not "has this rider's trip started" --
-- true the instant a plan is posted, and still true while it is merely scheduled for tomorrow.
--
-- The canonical "is this rider actually busy right now" predicate already exists and is already
-- correct: rider_is_on_active_trip() (20260720000004) treats an intercity/long-distance order as
-- busy only once trip_started_at is set (Start Trip pressed) -- exactly the distinction this bug
-- needs. prevent_service_mode_switch_during_active_order() already calls it. The 20260721000004
-- travel-plan-count block was a second, independent (and wrong) gate layered on top of that
-- correct check, not a replacement for it.
--
-- FIX: drop the travel-plan-count block entirely and restore this trigger function to exactly the
-- rider_is_on_active_trip() check from 20260720000004. Existing DB-object convention in this
-- codebase is additive (CREATE OR REPLACE), so this migration only replaces the function body, not
-- the trigger definition (still BEFORE UPDATE OF service_mode ON riders, unchanged).
--
-- This does not require re-solving the "traveller can't see Available Travelers after switching
-- away" problem 20260721000004 was chasing: switching INTO 'intercity' mode is never blocked by
-- this trigger (only switching AWAY was ever gated), so a traveller can always flip back to
-- Intercity mode to view their own plan's bookings -- they are simply no longer trapped there.
CREATE OR REPLACE FUNCTION public.prevent_service_mode_switch_during_active_order()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.service_mode IS NOT DISTINCT FROM OLD.service_mode THEN
        RETURN NEW;
    END IF;

    IF public.rider_is_on_active_trip(NEW.id) THEN
        RAISE EXCEPTION 'Cannot switch Service Mode while a trip is active. Complete or cancel your current trip first.'
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
