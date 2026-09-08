-- Migration: Canonical intercity_requests.status lifecycle — add the two genuinely-used but
-- currently-blocked statuses ('in_progress', 'completed'), and update every function/view that
-- encodes an assumption about the status list so the whole system stays consistent.
-- Date: 2026-07-18
--
-- BACKGROUND (verified against the LIVE database via pg_get_constraintdef/pg_get_functiondef/
-- pg_get_viewdef, not just migration files, since this table has drifted from its migration
-- history before — see 20260718000002/20260718000003):
--
--   Live CHECK constraint (before this migration):
--     CHECK (status = ANY (ARRAY['request_sent','discussion_started','fare_agreed','confirmed',
--                                 'paid','expired','cancelled','rejected']))
--
--   travel_plan_details_screen.dart's "Start Transit" button (reqStatus == 'paid') writes
--   status='in_progress' directly (RLS's "Allow request participants to update safe fields"
--   policy already allows this exact value — verified live, WITH CHECK includes 'in_progress').
--   That UPDATE has always violated the CHECK constraint above and thus always failed; the
--   failure was swallowed by a bare `catch (_) {}` (now fixed separately in the same file).
--
--   'in_progress' and 'completed' are independently referenced as real states throughout the
--   app, confirmed by grepping every call site touching intercity_requests.status:
--     - travel_plan_details_screen.dart: writes 'in_progress', displays 'in_progress'/'completed'
--     - intercity_searching_screen.dart: displays 'in_progress'/'completed' badges; filters
--       booked-seat counts with .inFilter('status', ['confirmed','paid','in_progress','completed'])
--     - order_chat_screen.dart: filters active trips with .inFilter('status', ['confirmed','paid','in_progress'])
--     - on_intercity_request_change() trigger (live, unchanged since 20260603000001) already has
--       dedicated notification copy for NEW.status = 'in_progress' and 'completed' — dead code
--       until now because the CHECK constraint never let those values be written.
--   Every other status in the current list (request_sent, discussion_started, fare_agreed,
--   confirmed, paid, expired, cancelled, rejected) has a genuine live write site (accept_intercity_
--   request, accept_intercity_offer, confirm_intercity_booking, _payBooking, expire_stale_
--   intercity_requests, reject_intercity_offer) or is actively read/guarded against (e.g.
--   'cancelled' has no current write site but is actively checked in reject_intercity_offer's
--   terminal-state guard and the RLS visibility filter — kept, not dead).
--
--   No status is invented and none is removed: the canonical list is exactly the live 8 plus
--   'in_progress' and 'completed'.
--
-- DOWNSTREAM CONSISTENCY FIXES (things that would silently misbehave once 'in_progress' actually
-- starts getting written, found by grepping every place that filters intercity_requests by a
-- fixed status list):
--   1. reject_intercity_offer(): its "already too late to reject" guard checked
--      ('confirmed','paid','expired','cancelled','rejected') but NOT 'in_progress'/'completed' —
--      without this fix, a request could be wrongly flipped to 'rejected' after the trip had
--      already started or finished.
--   2. confirm_intercity_booking()'s seat-capacity count (v_active_bookings) and
--      travel_plan_seat_availability_view both only counted ('confirmed','paid') as occupying a
--      seat — once a trip reaches 'in_progress' it would incorrectly free up that seat for a new
--      booking on the same plan while the original trip is still running. Both now also count
--      'in_progress'.
--   3. match-intercity-riders edge function's activeBookingCounts (Mode 1, rider capacity check)
--      has the identical ('confirmed','paid') gap — fixed in the same deploy (separate .ts file).
--   4. Nothing ever wrote 'completed' to intercity_requests (verified: zero write sites in lib/,
--      supabase/functions/, or any SQL function). update-order-status already has an existing,
--      analogous intercity-specific side effect at trip completion (marking the linked
--      rider_travel_plans row 'completed') — extended in the same deploy (separate .ts file) to
--      also mark the linked intercity_requests row 'completed' (and 'cancelled' on order
--      cancellation), the same mechanism, so 'completed' is reachable instead of staying
--      permanently dead UI-only code.

-- =====================================================================
-- 1. Replace the CHECK constraint (old -> new, additive: +in_progress, +completed).
-- =====================================================================
ALTER TABLE public.intercity_requests
    DROP CONSTRAINT IF EXISTS intercity_requests_status_check;

ALTER TABLE public.intercity_requests
    ADD CONSTRAINT intercity_requests_status_check CHECK (status IN (
        'request_sent',
        'discussion_started',
        'fare_agreed',
        'confirmed',
        'paid',
        'in_progress',
        'completed',
        'expired',
        'cancelled',
        'rejected'
    ));

COMMENT ON COLUMN public.intercity_requests.status IS
'Negotiation and booking states:
- request_sent: Initial offer/request sent from rider/user.
- discussion_started: Discussion accepted, chat unlocked.
- fare_agreed: Mutual fare agreed (metadata: sender_agreed = true, traveller_agreed = true).
- confirmed: Booking locked (capacity reserved, snapshots taken, payment due timer set).
- paid: Payment completed (unlocks all media chat features, waiting for transit).
- in_progress: Traveller has started the trip (Start Transit).
- completed: Trip finished (synced from the linked order reaching completed/delivered).
- expired: Expired due to timeout (payment timeout or negotiation timeout).
- cancelled: Cancelled by one of the parties before payment or journey, or the linked order was
  cancelled after confirmation.
- rejected: Booking request rejected.';

-- =====================================================================
-- 2. reject_intercity_offer(): extend the terminal-state guard so an in-progress or completed
--    trip can no longer be flipped to 'rejected'.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.reject_intercity_offer(
    p_request_id uuid,
    p_actor_type text
)
RETURNS jsonb AS $$
DECLARE
    v_request RECORD;
    v_is_participant boolean;
BEGIN
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found';
    END IF;

    SELECT (
        v_request.sender_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.riders r
            WHERE r.id = v_request.traveller_id AND r.user_id = auth.uid()
        )
    ) INTO v_is_participant;

    IF NOT v_is_participant THEN
        RAISE EXCEPTION 'Not authorized to act on this request';
    END IF;

    IF p_actor_type NOT IN ('sender', 'traveller') THEN
        RAISE EXCEPTION 'Invalid actor type: %', p_actor_type;
    END IF;

    IF v_request.status IN ('confirmed', 'paid', 'in_progress', 'completed', 'expired', 'cancelled', 'rejected') THEN
        RETURN json_build_object('success', true, 'status', v_request.status)::jsonb;
    END IF;

    -- Stash who rejected so on_intercity_request_change() can notify only the opposite
    -- party (Part 14), instead of also notifying the actor who just performed the reject.
    UPDATE public.intercity_requests
    SET status = 'rejected',
        metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('rejected_by', p_actor_type),
        updated_at = now()
    WHERE id = p_request_id;

    RETURN json_build_object('success', true, 'status', 'rejected')::jsonb;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- =====================================================================
-- 3. confirm_intercity_booking(): count 'in_progress' bookings as occupying a seat too, not just
--    'confirmed'/'paid'.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.confirm_intercity_booking(
    p_request_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_request RECORD;
    v_active_bookings INT;
    v_max_bookings INT;
    v_plan_pickup TEXT;
    v_plan_dest TEXT;
    v_plan_vehicle public.vehicle_type_enum;
    v_plan_date TIMESTAMPTZ;
    v_plan_weight NUMERIC;
    v_order_weight NUMERIC;
    v_order_type TEXT;
    v_pickup_city TEXT;
    v_dest_city TEXT;
    v_order_user_id uuid;
    v_used_weight_kg NUMERIC;
    v_passenger_active_count INT;
    v_metadata jsonb;
    v_is_participant boolean;
BEGIN
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found';
    END IF;

    SELECT (
        v_request.sender_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.riders r
            WHERE r.id = v_request.traveller_id AND r.user_id = auth.uid()
        )
    ) INTO v_is_participant;

    IF NOT v_is_participant THEN
        RAISE EXCEPTION 'Not authorized to act on this request';
    END IF;

    IF v_request.status = 'confirmed' THEN
        RETURN json_build_object('success', true, 'status', 'confirmed')::jsonb;
    END IF;

    IF COALESCE((v_request.metadata->>'sender_agreed')::boolean, false) IS NOT TRUE
       OR COALESCE((v_request.metadata->>'traveller_agreed')::boolean, false) IS NOT TRUE THEN
        RAISE EXCEPTION 'Cannot confirm booking before both parties agree on the fare.';
    END IF;

    SELECT max_bookings, pickup_city, destination_city, vehicle_type, travel_date, max_weight_kg
    INTO v_max_bookings, v_plan_pickup, v_plan_dest, v_plan_vehicle, v_plan_date, v_plan_weight
    FROM public.rider_travel_plans
    WHERE id = v_request.route_id
    FOR UPDATE;

    SELECT COUNT(*) INTO v_active_bookings
    FROM public.intercity_requests
    WHERE route_id = v_request.route_id
      AND status IN ('confirmed', 'paid', 'in_progress')
      AND id IS DISTINCT FROM p_request_id;

    IF v_active_bookings >= v_max_bookings THEN
        RAISE EXCEPTION 'This travel plan is fully booked. (Current: %, Max limit: %)', v_active_bookings, v_max_bookings;
    END IF;

    SELECT actual_weight_kg, order_type, pickup_city, destination_city, user_id
    INTO v_order_weight, v_order_type, v_pickup_city, v_dest_city, v_order_user_id
    FROM public.orders
    WHERE id = v_request.parcel_id;

    -- Passenger double-booking guard (Part 15): the passenger on this order must not already
    -- be confirmed on a different active trip, mirroring the rider-side capacity checks above.
    SELECT COUNT(*) INTO v_passenger_active_count
    FROM public.orders
    WHERE user_id = v_order_user_id
      AND order_status IN ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing')
      AND id IS DISTINCT FROM v_request.parcel_id;

    IF v_passenger_active_count > 0 THEN
        RAISE EXCEPTION 'Passenger already confirmed another trip.';
    END IF;

    SELECT COALESCE(SUM(
        COALESCE(
            o.actual_weight_kg,
            COALESCE(NULLIF(regexp_replace(o.weight_category::text, '[^0-9.]', '', 'g'), ''), '0')::numeric
        )
    ), 0.0)
    INTO v_used_weight_kg
    FROM public.orders o
    WHERE o.rider_id = v_request.traveller_id
      AND o.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing', 'rider_at_drop')
      AND o.id IS DISTINCT FROM v_request.parcel_id;

    IF v_plan_weight IS NOT NULL AND v_plan_weight > 0
       AND (v_used_weight_kg + COALESCE(v_order_weight, 0)) > v_plan_weight THEN
        RAISE EXCEPTION 'This travel plan does not have enough remaining weight capacity. (Used: %kg, Adding: %kg, Max: %kg)', v_used_weight_kg, COALESCE(v_order_weight, 0), v_plan_weight;
    END IF;

    v_metadata := COALESCE(v_request.metadata, '{}'::jsonb) || jsonb_build_object(
        'travel_plan_snapshot', jsonb_build_object(
            'pickup_city', v_plan_pickup,
            'destination_city', v_plan_dest,
            'vehicle_type', v_plan_vehicle,
            'travel_date', v_plan_date,
            'max_weight_kg', v_plan_weight
        ),
        'booking_snapshot', jsonb_build_object(
            'agreed_fare', v_request.proposed_fare,
            'booking_type', v_request.booking_type,
            'pickup_city', v_pickup_city,
            'destination_city', v_dest_city,
            'weight_kg', v_order_weight
        )
    );

    UPDATE public.intercity_requests
    SET status = 'confirmed',
        metadata = v_metadata,
        updated_at = now()
    WHERE id = p_request_id;

    UPDATE public.orders
    SET order_status = 'accepted'::public.order_status_enum,
        rider_id = v_request.traveller_id,
        final_fare = v_request.proposed_fare,
        current_fare = v_request.proposed_fare,
        updated_at = now()
    WHERE id = v_request.parcel_id;

    RETURN json_build_object('success', true, 'status', 'confirmed')::jsonb;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- =====================================================================
-- 4. travel_plan_seat_availability_view: same 'in_progress' fix as #3, for the read-only listing
--    path (fetchAvailablePartnersForDate / Available Partners screen).
-- =====================================================================
CREATE OR REPLACE VIEW public.travel_plan_seat_availability_view AS
SELECT
    tp.id AS plan_id,
    tp.max_bookings,
    COALESCE(cb.confirmed_count, 0::bigint) AS confirmed_count,
    GREATEST(tp.max_bookings - COALESCE(cb.confirmed_count, 0::bigint), 0::bigint) AS available_seats
FROM public.rider_travel_plans tp
LEFT JOIN (
    SELECT intercity_requests.route_id,
           count(*) AS confirmed_count
    FROM public.intercity_requests
    WHERE intercity_requests.status = ANY (ARRAY['confirmed'::text, 'paid'::text, 'in_progress'::text])
    GROUP BY intercity_requests.route_id
) cb ON cb.route_id = tp.id;
