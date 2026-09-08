-- Migration: server-side guarantee that a rider already on an active LOCAL RIDE never receives
-- another local ride offer.
-- Date: 2026-08-05
--
-- ROOT CAUSE: find_nearby_riders() (20260729000001) already excludes a rider with an active order
-- from being SELECTED as a dispatch candidate, but that predicate and the resulting INSERT into
-- rider_assignments (start-dispatch/index.ts) are two separate statements/round-trips with no
-- shared transaction -- a rider who accepts a different local ride in the moments between those two
-- statements (or whose stale 'sent'/'expired' assignment row for another order gets re-upserted by
-- a later dispatch round via the order_id,rider_id onConflict) can still end up with a fresh 'sent'
-- rider_assignments row while already busy. The client already surfaced this as "busy rider still
-- gets a new ride popup".
--
-- FIX: a BEFORE INSERT OR UPDATE trigger on rider_assignments is the only place that can guarantee
-- this regardless of which code path writes the row (start-dispatch's bulk upsert, any future
-- dispatch path, etc.) -- mirrors the existing enforce_rider_assignment_service_mode() trigger
-- pattern (20260718000011) which is this codebase's established "hard backstop" approach.
--
-- Scope is deliberately narrow: ONLY local rides (order_type = 'ride' with distance_meters <=
-- 20000, i.e. not an intercity/long-distance 'ride' and not intercity_ride/intercity_parcel/
-- local_parcel/ride_sharing) are checked -- both for the incoming offer and for what counts as the
-- rider's "busy" order. Parcel and intercity dispatch/matching are completely untouched.
--
-- On conflict the row is silently dropped (RETURN NULL) instead of raising -- start-dispatch inserts
-- several riders in a single upsert call; a hard exception on one row would abort the whole batch and
-- block every OTHER (non-busy) candidate rider in that same round from receiving the offer.
--
-- RECONCILIATION NOTE (2026-08-04): applied directly to the linked Supabase project but never
-- committed to this repo; reconstructed verbatim from supabase_migrations.schema_migrations.
-- Independently verified against the dispatch-staleness fix in this same reconciliation
-- (20260806000002_bound_dispatch_trigger_ttl_and_online_transition_only.sql): this trigger fires on
-- INSERT/UPDATE of public.rider_assignments; that migration only changes
-- assign_nearby_searching_orders_to_rider() (a trigger ON public.riders that INSERTs/UPDATEs
-- rider_assignments rows exactly as it always did) and does not touch rider_assignments' own
-- schema or triggers -- so every INSERT/UPDATE that function performs continues to pass through
-- this busy-rider guard exactly as before. No conflict, no ordering dependency.

CREATE OR REPLACE FUNCTION public.prevent_local_ride_assignment_to_busy_rider()
RETURNS TRIGGER AS $$
DECLARE
    v_new_order_type text;
    v_new_distance integer;
BEGIN
    IF NEW.assignment_status IS DISTINCT FROM 'sent' THEN
        RETURN NEW;
    END IF;

    SELECT o.order_type::text, o.distance_meters
    INTO v_new_order_type, v_new_distance
    FROM public.orders o
    WHERE o.id = NEW.order_id;

    -- Only local rides are in scope for this guard.
    IF v_new_order_type IS DISTINCT FROM 'ride' OR COALESCE(v_new_distance, 0) > 20000 THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.orders bo
        WHERE bo.rider_id = NEW.rider_id
          AND bo.id != NEW.order_id
          AND bo.order_type = 'ride'
          AND COALESCE(bo.distance_meters, 0) <= 20000
          AND bo.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing')
    ) THEN
        RETURN NULL;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

DROP TRIGGER IF EXISTS trigger_prevent_local_ride_assignment_to_busy_rider ON public.rider_assignments;

CREATE TRIGGER trigger_prevent_local_ride_assignment_to_busy_rider
    BEFORE INSERT OR UPDATE ON public.rider_assignments
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_local_ride_assignment_to_busy_rider();
