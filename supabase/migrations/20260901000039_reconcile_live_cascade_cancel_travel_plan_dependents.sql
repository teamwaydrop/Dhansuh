-- =============================================================================
-- RECONCILIATION MIGRATION -- documents (does not change) production's CURRENT LIVE
-- definition of public.cascade_cancel_travel_plan_dependents().
--
-- CONTEXT (Phase 12 drift investigation, read-only): production's live body of this
-- AFTER-UPDATE trigger function on rider_travel_plans does NOT match any migration file ever
-- committed to this repository -- confirmed by an exhaustive `git log --all -S`/`-G` search
-- across every local branch, every origin/* remote-tracking branch, and every dangling/
-- unreachable commit object (`git fsck --unreachable`) for this function's name and for
-- distinctive fragments of its live body ("returned to searching for a new traveller",
-- "passenger's own request/travel-time intent never ended", "updated_orders AS ("). Zero
-- matches anywhere. The two closest known-in-git versions --
-- 20260823000000_phase3_intercity_fixes.sql (its "ISSUE 6" section, never applied remotely) and
-- 20260901000001_fix_cascade_cancel_travel_plan_dependents.sql (applied remotely) -- both still
-- hard-terminate every dependent order to order_status = 'cancelled'. Neither is what is live.
--
-- The live body was recovered read-only, byte-for-byte, from two independent sources that
-- agree exactly: `pg_get_functiondef('public.cascade_cancel_travel_plan_dependents'::regproc)`
-- against the linked production project, and a surviving `pg_stat_statements` entry (calls: 5,
-- headed by the same "-- 2. cascade_cancel_travel_plan_dependents -- every affected passenger's
-- order now reverts to searching/expired instead of cancelled" comment reproduced below) --
-- pg_stat_statements has not been reset since 2026-05-07, before this project's first migration.
-- That entry's own text references "20260901000006" as an already-applied prior fix, which is
-- itself one of three ledger versions (20260901000005/000006/000007,
-- *_orphaned_remote_ledger_reconciliation_stub.sql) this repository had ALREADY discovered and
-- documented, in an earlier session, as versions applied directly to production with no
-- corresponding committed file -- the strongest available evidence for where this specific
-- function's current body actually came from, without being able to name an exact version or
-- actor (see that investigation's own report for the full evidence chain).
--
-- PURPOSE OF THIS MIGRATION: make the committed schema match observed production reality, so a
-- future `db push`/diff never proposes reverting live behavior back to the old hard-cancel
-- version. This is a pure `CREATE OR REPLACE` of the CURRENT live body -- a no-op if ever run
-- against production (production already has this exact definition), and the first time this
-- exact SQL has ever been committed to git. It does not change behavior, and it does not touch
-- cancel_intercity_request_by_traveller() (the sibling function from the same recovered
-- pg_stat_statements pair) -- that is explicitly out of scope for this migration.
--
-- CURRENT LIVE BEHAVIOR (documented, not changed by this migration):
--   - a dependent passenger order that is still 'accepted' and has not yet started reverts to
--     order_status = 'searching' (rider_id/accepted_at/pickup_otp/delivery_otp cleared) so it is
--     immediately re-matchable to a different traveller -- never hard-cancelled.
--   - if that passenger's own travel_date has already passed, the order goes to 'expired'
--     instead (a genuine terminal state, not "searching" forever with no realistic match).
--   - the intercity_requests row itself is still set to 'cancelled', with the same
--     cancelled_reason / cancelled_scope='travel_plan' / cancelled_by_actor='traveller' metadata
--     tagging as the known-in-git 20260901000001 version.
--   - the app.bypass_order_state_guard bypass (the original 20260823000000/20260901000001 fix)
--     is preserved.
--   - order_status_history is written via a WITH updated_orders AS (...) CTE, reflecting
--     whichever of 'searching'/'expired' each order actually landed on.
--
-- THIS MIGRATION DOES NOT:
--   - restore order_status = 'cancelled' for dependent orders (the old, superseded behavior).
--   - touch any other function, table, trigger, RLS policy, or grant.
--   - touch cancel_intercity_request_by_traveller() (separate, out of scope here).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.cascade_cancel_travel_plan_dependents()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_now timestamptz := now();
    v_reason text := COALESCE(NEW.cancel_reason, 'Traveller cancelled the travel plan.');
BEGIN
    IF NEW.status = 'cancelled'::public.travel_plan_status_enum
       AND OLD.status IS DISTINCT FROM 'cancelled'::public.travel_plan_status_enum THEN

        -- Every still-open negotiation/booking on this plan -- never a row already in a terminal
        -- state (completed/cancelled/rejected/expired), and never in_progress (the guard trigger
        -- already refused the update if one exists, and cancel_travel_plan_by_traveller() performs
        -- its own, more thorough current-state check before ever reaching this point).
        UPDATE public.intercity_requests
        SET status = 'cancelled',
            cancelled_reason = v_reason,
            metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
                'cancelled_reason', v_reason,
                'cancelled_scope', 'travel_plan',
                'cancelled_by_actor', 'traveller'
            ),
            updated_at = v_now
        WHERE route_id = NEW.id
          AND status IN ('request_sent', 'discussion_started', 'fare_agreed', 'confirmed', 'paid');

        PERFORM set_config('app.bypass_order_state_guard', 'true', true);

        -- FIX (this migration): each passenger's own request/travel-time intent never ended --
        -- only their relationship with THIS traveller did. Return each order to a matchable state
        -- (or 'expired' if that specific passenger's own travel_date has already passed) instead
        -- of terminating it -- never a blanket 'cancelled' for the whole cascade. Scoped exactly as
        -- before: only this plan's own rider, only orders still sitting at 'accepted'.
        WITH updated_orders AS (
            UPDATE public.orders o
            SET order_status = CASE
                    WHEN o.travel_date IS NOT NULL AND o.travel_date <= v_now
                        THEN 'expired'::public.order_status_enum
                    ELSE 'searching'::public.order_status_enum
                END,
                rider_id = NULL,
                accepted_at = NULL,
                pickup_otp = NULL,
                delivery_otp = NULL,
                updated_at = v_now
            FROM public.intercity_requests ir
            WHERE ir.route_id = NEW.id
              AND ir.parcel_id = o.id
              AND ir.status = 'cancelled'
              AND o.order_status = 'accepted'
              AND o.rider_id = NEW.rider_id
            RETURNING o.id, o.order_status
        )
        INSERT INTO public.order_status_history (order_id, previous_status, new_status, changed_by, notes)
        SELECT id, 'accepted', order_status::text, 'system_travel_plan_cancelled',
               CASE WHEN order_status = 'expired' THEN
                   'Travel plan cancelled by traveller; this passenger''s travel time had already passed: ' || v_reason
               ELSE
                   'Traveller cancelled the travel plan; passenger returned to searching for a new traveller: ' || v_reason
               END
        FROM updated_orders;
    END IF;
    RETURN NEW;
END;
$function$;
