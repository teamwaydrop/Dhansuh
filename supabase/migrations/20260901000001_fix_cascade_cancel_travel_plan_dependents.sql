-- Migration: Issue 2 root cause fix -- whole travel-plan cancellation silently fails (traveller
-- home still shows the plan as active after a cancellation attempt, seats stay at "0/1").
--
-- ROOT CAUSE (confirmed via live function inspection, not assumed): cascade_cancel_travel_plan_
-- dependents() (AFTER UPDATE trigger on rider_travel_plans, base migration 20260729000003) writes
-- orders.order_status directly when cascading a plan cancellation to a dependent accepted order,
-- but never sets app.bypass_order_state_guard first. protect_order_state_columns_trigger correctly
-- rejects that write ("Direct modification of order status/OTP/assignment columns is not
-- permitted..."), which ABORTS THE ENTIRE TRIGGERING TRANSACTION -- including the
-- rider_travel_plans.status = 'cancelled' UPDATE that fired this trigger in the first place. Net
-- effect: any whole-plan cancellation attempt that reaches this cascade (i.e. any plan with at
-- least one accepted passenger) rolls back completely and silently -- the plan reverts to
-- 'active' with no error surfaced to explain why, exactly matching the reported symptom.
--
-- This exact bug was already diagnosed once before, in the still-pending, unapproved
-- 20260823000000_phase3_intercity_fixes.sql (its own "ISSUE 6" section) -- that file is NOT
-- touched or deployed by this migration (per instructions); this migration independently applies
-- the equivalent, verified fix as new, standalone, forward-only SQL. If 20260823000000 is later
-- approved and deployed, its own CREATE OR REPLACE of this same function is idempotent with this
-- one (identical fix, harmless redundant reapplication).
--
-- ADDITIONAL CHANGES beyond the bypass fix (for Issues 1/2's reason-propagation requirement):
--   - reads NEW.cancel_reason (rider_travel_plans, just set by cancel_travel_plan_by_traveller()
--     in the same statement that fired this trigger) instead of hardcoding a fixed string, so the
--     traveller's actual reason reaches both intercity_requests.cancelled_reason and
--     orders.cancel_reason.
--   - tags each cascaded intercity_requests row with metadata->>'cancelled_scope' = 'travel_plan'
--     so on_intercity_request_change() (updated separately in this same migration set) can send a
--     distinct, route-aware, reason-aware notification instead of the generic per-request message.
-- Every other clause (which requests/orders are touched, the terminal-state exclusion, the
-- order_status_history audit insert) is preserved exactly as before.

CREATE OR REPLACE FUNCTION public.cascade_cancel_travel_plan_dependents()
RETURNS TRIGGER AS $$
DECLARE
    v_now timestamptz := now();
    v_reason text := COALESCE(NEW.cancel_reason, 'Traveller cancelled the travel plan.');
BEGIN
    IF NEW.status = 'cancelled'::public.travel_plan_status_enum
       AND OLD.status IS DISTINCT FROM 'cancelled'::public.travel_plan_status_enum THEN

        -- Every still-open negotiation/booking on this plan -- never a row already in a terminal
        -- state (completed/cancelled/rejected/expired), and never in_progress (the guard trigger
        -- already refused the update if one exists, and cancel_travel_plan_by_traveller() performs
        -- its own, more thorough trip_started_at-based check before ever reaching this point).
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

        -- FIX: the write below touches orders.order_status (protect_order_state_columns_trigger)
        -- -- this bypass was missing before, which is the root cause this migration closes.
        PERFORM set_config('app.bypass_order_state_guard', 'true', true);

        -- The underlying order for each request just cancelled above, but only if it's still this
        -- exact plan's own rider and still sitting at 'accepted' (never touches an order that has
        -- already moved past acceptance under some other status, or belongs to a different rider).
        UPDATE public.orders o
        SET order_status = 'cancelled'::public.order_status_enum,
            cancelled_at = v_now,
            cancel_reason = v_reason,
            cancelled_by = 'rider',
            updated_at = v_now
        FROM public.intercity_requests ir
        WHERE ir.route_id = NEW.id
          AND ir.parcel_id = o.id
          AND ir.status = 'cancelled'
          AND o.order_status = 'accepted'
          AND o.rider_id = NEW.rider_id;

        INSERT INTO public.order_status_history (order_id, previous_status, new_status, changed_by, notes)
        SELECT o.id, 'accepted', 'cancelled', 'system_travel_plan_cancelled',
               'Cancelled because the linked travel plan was cancelled by the traveller: ' || v_reason
        FROM public.orders o
        WHERE o.rider_id = NEW.rider_id
          AND o.order_status = 'cancelled'
          AND o.cancelled_at = v_now
          AND EXISTS (
              SELECT 1 FROM public.intercity_requests ir
              WHERE ir.route_id = NEW.id AND ir.parcel_id = o.id AND ir.status = 'cancelled'
          );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
