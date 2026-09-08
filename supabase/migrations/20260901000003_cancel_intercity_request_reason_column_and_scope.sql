-- Migration: Issue 1 -- cancel_intercity_request_by_traveller() (deployed 20260829000000)
-- already records the traveller's cancellation reason, but only inside intercity_requests.metadata
-- (jsonb). This migration:
--   1. also writes the new, queryable intercity_requests.cancelled_reason column (added in
--      20260901000000), matching the same column both the whole-plan cascade path
--      (cascade_cancel_travel_plan_dependents, updated in 20260901000001) and the existing
--      expiry_reason precedent already use;
--   2. tags metadata with 'cancelled_scope' = 'individual_request', the same discriminator key the
--      whole-plan path tags its own cascaded rows with ('travel_plan') -- on_intercity_request_change()
--      (updated in 20260901000004) reads this single key to pick between the two distinct,
--      professional notification bodies the two cancellation paths require.
-- Every other clause (auth/ownership checks, status guard, order cancellation, order_status_history
-- insert, function signature) is preserved byte-for-byte from 20260829000000.

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
        cancelled_reason = p_cancel_reason,
        metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
            'cancelled_reason', p_cancel_reason,
            'cancelled_by_actor', 'traveller',
            'cancelled_scope', 'individual_request'
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
