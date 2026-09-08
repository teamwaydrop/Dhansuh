-- Migration: Extend the Service Mode switch guard to also cover an active Travel Plan, not just
-- an active trip.
-- Date: 2026-07-21
--
-- ROOT CAUSE (Bug 3, "Traveller still cannot see Available Users" -- reproduced live against the
-- linked project, not assumed): the RLS/query layer added in 20260721000000
-- (open_intercity_order_visibility_for_travellers) is confirmed correctly deployed and correct --
-- verified directly against the live database (pg_policies shows both new policies present and
-- matching the migration text). The actual remaining blocker is one layer up:
-- IntercityBookingsScreen._initializeData() (lib/features/rider/intercity/intercity_bookings_screen.dart)
-- is the sole entry point to AvailableTravelersScreen, and it hard-gates on the rider's CURRENT
-- riders.service_mode == 'intercity', showing "Switch to Intercity Traveller mode..." and
-- returning early otherwise -- so AvailableTravelersScreen is never even reached.
--
-- prevent_service_mode_switch_during_active_order() already blocks a Service Mode switch while
-- rider_is_on_active_trip() is true, but nothing blocked switching away while the rider merely has
-- an active, posted, not-yet-matched *Travel Plan* -- rider_travel_plans requires
-- service_mode = 'intercity' to INSERT (20260718000012), but a rider can freely flip back to
-- 'local' immediately afterwards with the plan still sitting there 'active', silently locking
-- themselves out of their own Available Travelers screen for that exact plan.
--
-- Verified directly against live production data before writing this fix (via `supabase db query
-- --linked`, not the migration files, since this trigger has already drifted from its own
-- migration history once -- the live body uses rider_is_on_active_trip(), not the raw orders COUNT
-- the 20260718000013 migration file shows): of the 6 riders currently in the database, 2 have an
-- ACTIVE rider_travel_plans row while service_mode is NOT 'intercity' (one 'local', one NULL) -- a
-- live, reproducible instance of exactly this lockout, not a hypothetical.
--
-- FIX: extend the existing trigger function (same BEFORE UPDATE OF service_mode trigger, same
-- "reject with a clear message" pattern, live body otherwise preserved byte-for-byte) to also
-- reject switching AWAY FROM 'intercity' while an active travel plan exists. Deliberately
-- direction-scoped (checked only when NEW.service_mode is distinct from 'intercity') so switching
-- INTO intercity mode is never blocked by this check -- unlike the active-trip check above, an
-- active Travel Plan only ever exists because the rider was already in intercity mode, so there is
-- no direction to guard except leaving it.
CREATE OR REPLACE FUNCTION public.prevent_service_mode_switch_during_active_order()
RETURNS TRIGGER AS $$
DECLARE
    v_active_plans_count integer;
BEGIN
    IF NEW.service_mode IS NOT DISTINCT FROM OLD.service_mode THEN
        RETURN NEW;
    END IF;

    IF public.rider_is_on_active_trip(NEW.id) THEN
        RAISE EXCEPTION 'Cannot switch Service Mode while a trip is active. Complete or cancel your current trip first.'
            USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.service_mode IS DISTINCT FROM 'intercity'::public.partner_service_mode_enum THEN
        SELECT COUNT(*) INTO v_active_plans_count
        FROM public.rider_travel_plans
        WHERE rider_id = NEW.id
          AND status = 'active';

        IF v_active_plans_count > 0 THEN
            RAISE EXCEPTION 'Cannot switch Service Mode while you have an active Travel Plan. Delete or complete it first.'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- =====================================================================
-- Data repair: the guard above only stops *future* switches -- it doesn't retroactively fix the
-- riders already stranded by the gap it closes. Both riders identified above created their Travel
-- Plan while legitimately in Intercity Traveller mode (rider_travel_plans' own INSERT policy,
-- 20260718000012, already required service_mode = 'intercity' at creation time), so restoring
-- service_mode to 'intercity' for exactly this set -- active plan + service_mode currently
-- anything else -- reflects what they were already doing, not a new grant. Safe to run under the
-- new trigger above: this UPDATE switches INTO 'intercity', the direction the new check never
-- blocks.
UPDATE public.riders r
SET service_mode = 'intercity'
WHERE service_mode IS DISTINCT FROM 'intercity'
  AND EXISTS (
      SELECT 1 FROM public.rider_travel_plans tp
      WHERE tp.rider_id = r.id AND tp.status = 'active'
  );
