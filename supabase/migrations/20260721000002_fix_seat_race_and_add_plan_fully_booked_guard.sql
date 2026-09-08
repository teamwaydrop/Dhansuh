-- Migration: Close the seat-capacity race in accept_intercity_request() and stop new
-- "Travel Together" requests from being created once a plan has zero seats left.
-- Date: 2026-07-21
--
-- PART 1 — accept_intercity_request() seat race:
-- accept_intercity_request() only blocked overbooking as a side effect of
-- sync_travel_plan_status_after() having already flipped rider_travel_plans.status to
-- 'fully_booked' in a PRIOR, already-committed transaction. It never took an authoritative locked
-- read of its own, unlike confirm_intercity_booking() (20260718000007), which does
-- `SELECT max_bookings ... FOR UPDATE` + a live `COUNT(*)` before allowing a confirm. Two accepts
-- processed concurrently when only one seat remains could both pass the stale `status = 'active'`
-- check before either commits, and both succeed -- overbooking past max_bookings. This migration
-- adds the identical locked capacity check confirm_intercity_booking() already uses (same status
-- set: confirmed/paid/in_progress) directly into accept_intercity_request(), and returns a
-- dedicated 'PLAN_FULLY_BOOKED' code instead of overloading 'TRAVEL_PLAN_INACTIVE' (which no
-- longer accurately describes "the plan is active but out of seats").
--
-- PART 2 — stop new requests (and their notifications) once a plan is full:
-- sendTravelTogetherRequest() (the single INSERT path for both traveller-initiated and
-- sender-initiated "Travel Together" requests -- intercity_matching_service.dart) had no
-- seat/capacity check at all. A traveller whose plan was already full could still open Available
-- Users and send a brand-new invitation; the passenger would be notified for a trip that has no
-- room. A new BEFORE INSERT trigger rejects any new intercity_requests row targeting a plan with
-- zero available seats (read from the existing travel_plan_seat_availability_view), for both
-- directions symmetrically -- no row is ever inserted, so on_intercity_request_change never fires
-- and no notification is ever sent for a full plan.

-- =====================================================================
-- 1. accept_intercity_request(): add the locked seat-capacity guard. Base definition: 20260721000001
--    (the passenger-conflict fix). Every other line preserved; new step "4b" inserted right after
--    the existing travel-plan-active-status check.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.accept_intercity_request(
    p_request_id uuid,
    p_rider_user_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_request RECORD;
    v_order RECORD;
    v_rider RECORD;
    v_travel_plan RECORD;
    v_otp text;
    v_active_bookings int;
BEGIN
    -- 1. Get rider details and validate active status
    SELECT * INTO v_rider
    FROM public.riders
    WHERE user_id = p_rider_user_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Rider profile not found for user.'
        );
    END IF;

    -- 1b. Service mode gate: only Intercity Traveller-mode partners may
    -- accept intercity requests.
    IF v_rider.service_mode IS DISTINCT FROM 'intercity'::public.partner_service_mode_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'WRONG_SERVICE_MODE',
            'message', 'Switch to Intercity Traveller mode to accept this request.'
        );
    END IF;

    -- 2. Fetch request to find the order ID (read-only for now)
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Intercity request not found.'
        );
    END IF;

    -- Ownership check: Request traveller_id must match rider id
    IF v_request.traveller_id != v_rider.id THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Request does not belong to this traveller.'
        );
    END IF;

    -- 3. Lock and fetch order (Order is source of truth, lock first)
    SELECT * INTO v_order
    FROM public.orders
    WHERE id = v_request.parcel_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Associated order not found.'
        );
    END IF;

    -- Idempotency check: If order is already assigned to this rider and accepted
    IF v_order.rider_id = v_rider.id AND v_order.order_status = 'accepted' THEN
        RETURN jsonb_build_object(
            'success', true,
            'code', 'ALREADY_ACCEPTED',
            'order_id', v_order.id,
            'request_id', v_request.id
        );
    END IF;

    -- Validate order availability
    IF v_order.order_status != 'searching' OR v_order.rider_id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ORDER_ALREADY_ASSIGNED',
            'message', 'Booking no longer available.'
        );
    END IF;

    -- Validate order search expiration
    IF v_order.search_expires_at IS NOT NULL AND v_order.search_expires_at < now() THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REQUEST_EXPIRED',
            'message', 'Order search has expired.'
        );
    END IF;

    -- Lock request now for update
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;

    -- Validate request expiration
    IF v_request.expires_at IS NOT NULL AND v_request.expires_at < now() THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REQUEST_EXPIRED',
            'message', 'Request negotiation has expired.'
        );
    END IF;

    -- Validate request status is eligible
    IF v_request.status NOT IN ('request_sent', 'discussion_started', 'fare_agreed') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Request status is not eligible for acceptance.'
        );
    END IF;

    -- 4. Validate traveler plan active status (locked -- also the row this step's seat count
    -- reads from, so acquire the lock once and reuse it below).
    SELECT * INTO v_travel_plan
    FROM public.rider_travel_plans
    WHERE id = v_request.route_id
    FOR UPDATE;

    IF v_travel_plan IS NULL OR v_travel_plan.status::text != 'active' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'TRAVEL_PLAN_INACTIVE',
            'message', 'Travel plan is no longer active.'
        );
    END IF;

    -- 4b. Authoritative locked seat-capacity check -- mirrors confirm_intercity_booking()'s guard
    -- exactly (same status set: confirmed/paid/in_progress). The plan row is already locked above
    -- (FOR UPDATE), so this COUNT is race-free: a concurrent accept on the same plan blocks on
    -- that row lock until this transaction commits or rolls back, instead of both readers seeing
    -- the same stale "still active" snapshot the way the old status-only check could.
    SELECT COUNT(*) INTO v_active_bookings
    FROM public.intercity_requests
    WHERE route_id = v_request.route_id
      AND status IN ('confirmed', 'paid', 'in_progress')
      AND id IS DISTINCT FROM p_request_id;

    IF v_active_bookings >= v_travel_plan.max_bookings THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'PLAN_FULLY_BOOKED',
            'message', 'This travel plan is fully booked.'
        );
    END IF;

    -- 5. Validate rider is not currently occupied by an ACTIVE trip (not merely a future
    -- "Waiting for Travel Day" acceptance -- see rider_is_on_active_trip()).
    IF public.rider_is_on_active_trip(v_rider.id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'RIDER_ALREADY_BUSY',
            'message', 'Rider is already handling another active trip.'
        );
    END IF;

    -- 5b. Validate the passenger doesn't have a conflicting trip -- a local job is busy the
    -- moment it's accepted, an intercity job only conflicts if its scheduled window overlaps this
    -- order's window. Different-date future bookings must be allowed.
    IF public.passenger_has_conflicting_trip(
        v_order.user_id,
        v_order.id,
        COALESCE(v_order.travel_date, v_order.created_at),
        COALESCE(v_order.travel_date, v_order.created_at)
            + make_interval(mins => COALESCE(v_order.estimated_duration_min, 240))
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'PASSENGER_ALREADY_CONFIRMED',
            'message', 'Passenger already has a conflicting trip at this time.'
        );
    END IF;

    -- 6. Generate cryptographically safe 4-digit OTP (loop to avoid collisions on orders)
    LOOP
        v_otp := floor(random() * 9000 + 1000)::text;
        -- Check collision in orders table
        PERFORM 1 FROM public.orders WHERE pickup_otp = v_otp AND order_status IN ('accepted', 'picked_up');
        EXIT WHEN NOT FOUND;
    END LOOP;

    -- 7. Update Request Status to 'confirmed'
    UPDATE public.intercity_requests
    SET status = 'confirmed',
        updated_at = now()
    WHERE id = p_request_id;

    -- 8. Update Order (assigned, otp, pricing)
    UPDATE public.orders
    SET order_status = 'accepted'::public.order_status_enum,
        rider_id = v_rider.id,
        final_fare = v_request.proposed_fare,
        current_fare = v_request.proposed_fare,
        pickup_otp = v_otp,
        updated_at = now()
    WHERE id = v_order.id;

    -- 9. Insert chat system notification message
    -- sender_id must be the rider's auth user id (order_chat_messages_sender_id_fkey
    -- references auth.users(id)), NOT v_rider.id which is the riders table's own PK.
    INSERT INTO public.order_chat_messages(
        sender_id,
        sender_type,
        message,
        user_id,
        is_support,
        order_id,
        rider_id,
        created_at
    ) VALUES (
        v_rider.user_id,
        'rider',
        '[AGREED] Rider accepted the request. Booking is confirmed.',
        v_order.user_id,
        false,
        v_order.id,
        v_rider.id,
        now()
    );

    RETURN jsonb_build_object(
        'success', true,
        'code', 'SUCCESS',
        'order_id', v_order.id,
        'request_id', v_request.id
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', SQLERRM
        );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- =====================================================================
-- 2. Reject new intercity_requests rows targeting an already-full plan. Reuses the existing
--    travel_plan_seat_availability_view (already 'in_progress'-aware) as the single source of
--    truth for "how many seats are left" -- no duplicated counting logic.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.prevent_request_on_full_travel_plan()
RETURNS TRIGGER AS $$
DECLARE
    v_available_seats int;
BEGIN
    IF NEW.route_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT available_seats INTO v_available_seats
    FROM public.travel_plan_seat_availability_view
    WHERE plan_id = NEW.route_id;

    IF v_available_seats IS NOT NULL AND v_available_seats <= 0 THEN
        RAISE EXCEPTION 'PLAN_FULLY_BOOKED: This travel plan is fully booked.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SET search_path = public;

DROP TRIGGER IF EXISTS trigger_prevent_request_on_full_plan ON public.intercity_requests;
CREATE TRIGGER trigger_prevent_request_on_full_plan
BEFORE INSERT ON public.intercity_requests
FOR EACH ROW
EXECUTE FUNCTION public.prevent_request_on_full_travel_plan();
