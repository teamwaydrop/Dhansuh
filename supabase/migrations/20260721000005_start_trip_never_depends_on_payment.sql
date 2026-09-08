-- Migration: Business rule correction -- Start Trip must never depend on payment.
-- Date: 2026-07-21
--
-- ROOT CAUSE (verified against the live function body via pg_get_functiondef, not just the
-- migration file): start_intercity_trip_for_plan(p_route_id) (20260721000003) only selects and
-- starts passengers whose intercity_requests.status has reached 'paid':
--
--   WHERE ir.route_id = p_route_id AND ir.traveller_id = v_rider.id
--     AND ir.status = 'paid' AND o.trip_started_at IS NULL
--
-- This assumed intercity payment is collected BEFORE the trip (mirroring the earlier
-- confirmed -> paid -> in_progress design comment on the status column). The actual business
-- model is the opposite: the passenger pays the traveller AFTER the ride completes. Under that
-- model, a negotiation legitimately never reaches 'paid' before travel day, so this WHERE clause
-- silently prevented Start Trip from EVER picking up any passenger, for every intercity booking --
-- not an edge case, the normal path. (The Flutter-side fix in the same deploy removes the client
-- UI's now-also-incorrect payment gate on the same screen.)
--
-- FIX: accept the negotiation the moment it reaches 'confirmed' (traveller accepted the
-- passenger) -- exactly the state the corrected flow describes as the only precondition, together
-- with the travel-date/1-hour gate immediately above this block (unchanged) and o.rider_id
-- ownership (unchanged, enforced earlier in the function). 'paid' is kept in the accepted set
-- (rather than removed) purely so the RPC stays idempotent/harmless if a negotiation is ever
-- marked paid early for any reason -- it is no longer a requirement, just no longer excluded.
CREATE OR REPLACE FUNCTION public.start_intercity_trip_for_plan(
    p_route_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_rider RECORD;
    v_plan RECORD;
    v_scheduled_departure timestamptz;
    v_order_ids uuid[];
BEGIN
    SELECT * INTO v_rider FROM public.riders WHERE user_id = auth.uid();
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Rider profile not found for user.');
    END IF;

    SELECT * INTO v_plan FROM public.rider_travel_plans WHERE id = p_route_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Travel plan not found.');
    END IF;

    IF v_plan.rider_id IS DISTINCT FROM v_rider.id THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This travel plan is not assigned to you.');
    END IF;

    -- Same early-start gate as start_intercity_trip(): allow Start Trip any time from 1 hour
    -- before the scheduled departure onward, comparing timestamptz instants directly.
    -- rider_travel_plans.travel_date is NOT NULL (unlike orders.travel_date), so no fallback is
    -- needed here -- and rider_travel_plans.created_at is `text`, not timestamptz, so it would be
    -- the wrong type to fall back to regardless.
    v_scheduled_departure := v_plan.travel_date;
    IF now() < (v_scheduled_departure - INTERVAL '1 hour') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'TRAVEL_DATE_NOT_ARRIVED',
            'message', 'You can start this trip up to 1 hour before the scheduled departure time.'
        );
    END IF;

    -- Every order under this plan the traveller has accepted ('confirmed') and hasn't started yet
    -- (idempotent: a repeat call only picks up passengers accepted since the last press, it never
    -- re-touches already-started ones). Payment is NOT a precondition -- the passenger pays the
    -- traveller after the trip completes, not before (see migration header).
    SELECT array_agg(o.id) INTO v_order_ids
    FROM public.orders o
    INNER JOIN public.intercity_requests ir ON ir.parcel_id = o.id
    WHERE ir.route_id = p_route_id
      AND ir.traveller_id = v_rider.id
      AND ir.status IN ('confirmed', 'paid')
      AND o.trip_started_at IS NULL;

    IF v_order_ids IS NULL OR array_length(v_order_ids, 1) IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'NO_PASSENGERS_READY', 'message', 'No accepted passengers are ready to start yet.');
    END IF;

    UPDATE public.orders
    SET trip_started_at = now(),
        updated_at = now()
    WHERE id = ANY(v_order_ids);

    -- Mirrors the trip-start into every linked negotiation row -- FOR EACH ROW means
    -- on_intercity_request_change fires once per passenger here, sending each their own
    -- "Trip Started" notification exactly as the single-order path always has.
    UPDATE public.intercity_requests
    SET status = 'in_progress',
        updated_at = now()
    WHERE parcel_id = ANY(v_order_ids)
      AND traveller_id = v_rider.id
      AND status IN ('confirmed', 'paid');

    RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_ids', to_jsonb(v_order_ids));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
