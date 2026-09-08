-- Migration: Issue 2 -- ONE canonical, secure server-side path for a traveller to cancel their
-- entire pre-trip travel plan, replacing three separate Flutter call sites
-- (rider_home_tab.dart, intercity_bookings_screen.dart, notification_service.dart) that each
-- performed their own direct `UPDATE rider_travel_plans SET status = 'cancelled'`.
--
-- "Genuinely started" determination (explicit, not superficial): this function checks
-- orders.trip_started_at IS NOT NULL for any order linked to this plan -- the same authoritative
-- signal rider_is_on_active_trip() and start_intercity_trip_for_plan() already use as ground
-- truth for "has this trip actually begun" -- rather than trusting only the pre-existing
-- guard_travel_plan_cancellation trigger's intercity_requests.status = 'in_progress' check (which
-- remains in place, unmodified, as a second, defense-in-depth layer -- start_intercity_trip_for_
-- plan() always sets trip_started_at and status='in_progress' together atomically, so the two
-- checks can never disagree for any order created through the canonical Start Trip path).
--
-- PRE-TRIP: no linked order has trip_started_at set -> cancellation proceeds.
-- AFTER TRIP HAS ACTUALLY STARTED: refused with a clear message, exactly matching the existing
-- guard trigger's own business rule -- not bypassed, not weakened.
--
-- On success, this only ever performs ONE write: `UPDATE rider_travel_plans SET status =
-- 'cancelled', cancel_reason = ...`. The already-existing guard_travel_plan_cancellation (BEFORE
-- UPDATE) and the just-fixed cascade_cancel_travel_plan_dependents (AFTER UPDATE) triggers do all
-- the actual cascade work (cancelling open negotiations, cancelling accepted orders, notifying
-- each affected passenger) -- no logic is duplicated here.

CREATE OR REPLACE FUNCTION public.cancel_travel_plan_by_traveller(
    p_route_id uuid,
    p_cancel_reason text
)
RETURNS jsonb AS $$
DECLARE
    v_rider RECORD;
    v_plan RECORD;
    v_has_started boolean;
BEGIN
    SELECT * INTO v_rider FROM public.riders WHERE user_id = auth.uid();
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Rider profile not found for user.');
    END IF;

    IF p_cancel_reason IS NULL OR btrim(p_cancel_reason) = '' THEN
        RETURN jsonb_build_object('success', false, 'code', 'REASON_REQUIRED', 'message', 'Please provide a reason for cancelling this travel plan.');
    END IF;

    SELECT * INTO v_plan FROM public.rider_travel_plans WHERE id = p_route_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Travel plan not found.');
    END IF;

    -- Never allow one traveller to cancel another traveller's plan.
    IF v_plan.rider_id IS DISTINCT FROM v_rider.id THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'This travel plan does not belong to you.');
    END IF;

    -- Idempotent: a retried/duplicate cancel request on an already-cancelled plan is a safe no-op.
    IF v_plan.status = 'cancelled'::public.travel_plan_status_enum THEN
        RETURN jsonb_build_object('success', true, 'code', 'ALREADY_CANCELLED', 'route_id', p_route_id);
    END IF;

    IF v_plan.status NOT IN ('active'::public.travel_plan_status_enum, 'fully_booked'::public.travel_plan_status_enum) THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'This travel plan cannot be cancelled in its current state.');
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM public.orders o
        INNER JOIN public.intercity_requests ir ON ir.parcel_id = o.id
        WHERE ir.route_id = p_route_id
          AND o.trip_started_at IS NOT NULL
    ) INTO v_has_started;

    IF v_has_started THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'TRIP_ALREADY_STARTED',
            'message', 'Cannot cancel this travel plan while a trip is already in progress.'
        );
    END IF;

    -- Triggers this fires (both already deployed/fixed): guard_travel_plan_cancellation (BEFORE,
    -- redundant final safety check) and cascade_cancel_travel_plan_dependents (AFTER, does the
    -- actual cascade + notifications).
    UPDATE public.rider_travel_plans
    SET status = 'cancelled'::public.travel_plan_status_enum,
        cancel_reason = p_cancel_reason
    WHERE id = p_route_id;

    RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'route_id', p_route_id);

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.cancel_travel_plan_by_traveller(uuid, text) TO authenticated;
