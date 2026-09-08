-- Migration: Issue 4 -- a traveller with two accepted passengers/parcels on the same travel plan
-- had no way to cancel just one of them; the only cancel-like action in the app
-- (_deleteTravelPlan, intercity_bookings_screen.dart) always cancels the ENTIRE travel plan, which
-- correctly (given what it actually does) refused with "Cannot cancel this travel plan while a
-- trip is already in progress" (guard_travel_plan_cancellation, 20260729000003) once any accepted
-- passenger's trip had started -- not a bug in that guard, but the wrong tool for the job the
-- traveller was actually trying to do.
--
-- ROOT CAUSE: no server-side function or client UI action existed for "cancel one accepted
-- request, keep the plan and every other accepted passenger untouched". The only way to attempt it
-- was the whole-plan cancel path, and any direct client-side attempt to flip an individual order's
-- order_status straight to 'cancelled' would (correctly) be rejected by
-- protect_order_state_columns_trigger ("Direct modification of order status/OTP/assignment columns
-- is not permitted. Use the appropriate server-side function.") -- there was no such function to
-- use.
--
-- FIX: a new, narrowly-scoped RPC, cancel_intercity_request_by_traveller(), that:
--   - only ever touches the ONE intercity_requests row (and its linked order) passed in -- never
--     the travel plan itself, never any other passenger's request/order;
--   - is restricted to requests already accepted but not yet started ('confirmed'/'paid') --
--     mirroring guard_travel_plan_cancellation's own philosophy that a trip already 'in_progress'
--     is a different, riskier operation this function deliberately does not attempt;
--   - requires a non-empty cancellation reason, recorded on both the request (metadata) and the
--     order (cancel_reason/order_status_history), exactly like every other cancellation path in
--     this schema;
--   - uses the same set_config('app.bypass_order_state_guard', ...) pattern every other legitimate
--     server-side status-changing function already uses, so the order_status write is authorized
--     the correct way instead of working around the guard;
--   - reuses two ALREADY-EXISTING triggers for the rest: trigger_intercity_request_change (fires
--     on_intercity_request_change(), which already has an unconditional 'cancelled' branch that
--     notifies the passenger -- "Your traveller cancelled this trip...") and
--     trigger_sync_travel_plan_status (revives a 'fully_booked' plan back to 'active' now that a
--     seat freed up). Neither trigger is modified -- this migration adds no new notification
--     logic and no new travel-plan-status logic, it only creates the one missing write path.
--
-- SECURITY: SECURITY DEFINER, but every write is scoped by auth.uid() -> the caller's own rider
-- profile -> v_request.traveller_id must equal that rider's id. A traveller can never cancel
-- another traveller's request through this function.

CREATE OR REPLACE FUNCTION public.cancel_intercity_request_by_traveller(
    p_request_id uuid,
    p_cancel_reason text
)
RETURNS jsonb AS $$
DECLARE
    v_rider RECORD;
    v_request RECORD;
    v_order RECORD;
    v_now timestamptz := now();
BEGIN
    SELECT * INTO v_rider FROM public.riders WHERE user_id = auth.uid();
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Rider profile not found for user.');
    END IF;

    IF p_cancel_reason IS NULL OR btrim(p_cancel_reason) = '' THEN
        RETURN jsonb_build_object('success', false, 'code', 'REASON_REQUIRED', 'message', 'Please provide a reason for cancelling this passenger.');
    END IF;

    SELECT * INTO v_request FROM public.intercity_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Request not found.');
    END IF;

    IF v_request.traveller_id != v_rider.id THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'This request does not belong to you.');
    END IF;

    -- Scoped to already-accepted-but-not-yet-started bookings only. A trip already 'in_progress'
    -- is a different, riskier operation this function deliberately does not attempt -- matching
    -- guard_travel_plan_cancellation's own philosophy for the whole-plan cancel path.
    IF v_request.status NOT IN ('confirmed', 'paid') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_STATUS',
            'message', 'Only an accepted booking that has not started yet can be cancelled this way.'
        );
    END IF;

    SELECT * INTO v_order FROM public.orders WHERE id = v_request.parcel_id FOR UPDATE;

    UPDATE public.intercity_requests
    SET status = 'cancelled',
        metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
            'cancelled_reason', p_cancel_reason,
            'cancelled_by_actor', 'traveller'
        ),
        updated_at = v_now
    WHERE id = p_request_id;

    -- Only this ONE request's own linked order, and only if it's still exactly what this
    -- cancellation expects -- never touches another passenger's order, and never regresses an
    -- order that has already moved past 'accepted' under some other path.
    IF v_order.id IS NOT NULL AND v_order.order_status = 'accepted' AND v_order.rider_id = v_rider.id THEN
        PERFORM set_config('app.bypass_order_state_guard', 'true', true);

        UPDATE public.orders
        SET order_status = 'cancelled'::public.order_status_enum,
            cancelled_at = v_now,
            cancel_reason = p_cancel_reason,
            cancelled_by = 'rider',
            updated_at = v_now
        WHERE id = v_order.id;

        INSERT INTO public.order_status_history (order_id, previous_status, new_status, changed_by, changed_by_rider_id, notes)
        VALUES (
            v_order.id,
            'accepted',
            'cancelled',
            'rider',
            v_rider.id,
            'Traveller cancelled this individual passenger booking: ' || p_cancel_reason
        );
    END IF;

    RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'request_id', p_request_id);

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.cancel_intercity_request_by_traveller(uuid, text) TO authenticated;
