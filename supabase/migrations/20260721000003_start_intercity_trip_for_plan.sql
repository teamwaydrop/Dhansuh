-- Migration: Redesign Start Trip to operate at the Travel Plan level instead of per passenger.
-- Date: 2026-07-21
--
-- ROOT CAUSE: start_intercity_trip(p_order_id) (20260720000000/20260720000004) operates on
-- exactly one `orders` row. The UI wired it up as a per-passenger-row button (inside each
-- matched passenger's own bottom sheet on TravelPlanDetailsScreen, and again inside
-- RiderActiveOrderScreen, which is itself scoped to a single orderId). A travel plan with several
-- accepted/paid passengers therefore required the traveller to press "Start Transit" once per
-- passenger, and only that one passenger's intercity_requests row transitioned to 'in_progress'
-- (and only they got notified) -- the others stayed 'paid' until separately started.
--
-- FIX: a new plan-level RPC, start_intercity_trip_for_plan(p_route_id), batch-starts every
-- passenger under that plan who has paid and hasn't started yet, in one call. Because
-- on_intercity_request_change() is a FOR EACH ROW trigger, a single multi-row UPDATE fires it once
-- per affected passenger automatically -- every accepted passenger gets their own "Trip Started"
-- push notification via the exact same, already-correct notification code, with no new
-- notification-sending logic needed.
--
-- start_intercity_trip(p_order_id) itself is left in place, unmodified (existing DB-object
-- convention in this codebase is additive, not destructive) but Dart no longer calls it directly
-- for the traveller-facing Start Trip action -- see the accompanying Dart changes.

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

    -- Every order under this plan whose negotiation has reached 'paid' and hasn't been started
    -- yet (idempotent: a repeat call only picks up passengers who paid since the last press, it
    -- never re-touches already-started ones).
    SELECT array_agg(o.id) INTO v_order_ids
    FROM public.orders o
    INNER JOIN public.intercity_requests ir ON ir.parcel_id = o.id
    WHERE ir.route_id = p_route_id
      AND ir.traveller_id = v_rider.id
      AND ir.status = 'paid'
      AND o.trip_started_at IS NULL;

    IF v_order_ids IS NULL OR array_length(v_order_ids, 1) IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'NO_PASSENGERS_READY', 'message', 'No paid passengers are ready to start yet.');
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
      AND status = 'paid';

    RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_ids', to_jsonb(v_order_ids));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
