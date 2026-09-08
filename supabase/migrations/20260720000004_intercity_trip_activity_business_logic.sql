-- Migration: Intercity workflow business-logic fixes (Task 3).
-- Date: 2026-07-20
--
-- Three business-logic problems reported after Task 1/Task 2 (the Waiting-for-Travel-Day / Start
-- Trip lifecycle) shipped, plus a regression surfaced while testing the fix:
--
-- 1. Start Trip was gated to the literal travel date (IST calendar-day comparison), so a
--    traveller leaving earlier than their scheduled time (very common in practice) had no way to
--    start. Fixed by comparing timestamptz instants directly and allowing Start Trip from 1 hour
--    before the scheduled departure onward.
--
-- 2. accept_intercity_request()'s "is this rider busy" check counted ANY order in
--    ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing') as busy, including an
--    intercity booking that is merely "Waiting for Travel Day" (accepted, trip not yet started).
--    That made a rider who accepted one future trip unable to accept any other future trip at
--    all. A rider must only be considered busy while a trip is ACTUALLY under way: for a local
--    job that's the moment it's accepted (rider is already en route to pickup); for an intercity
--    job that's only once trip_started_at is set (Start Trip pressed) through completion.
--
-- 3. The same over-broad "busy" definition was also baked into
--    prevent_service_mode_switch_during_active_order() (blocking a rider from switching to Local
--    Service Mode while merely waiting for a future intercity travel day) and into
--    find_nearby_riders() (excluding such a rider from local dispatch candidate pools even after
--    switching mode).
--
-- 4. Regression found in manual testing: start_intercity_trip() (20260720000000) compared
--    v_order.order_type -- of type order_type_enum -- directly against a LIKE pattern
--    ('intercity%'). Postgres has no ~~ (LIKE) operator for enum types (the same class of bug
--    fixed for a different function in 20260718000001), so every Start Trip press failed with
--    "operator does not exist: order_type_enum ~~ unknown" before any of the gating logic below
--    even ran. Fixed by casting to text first, consistent with the existing pattern elsewhere in
--    this codebase.
--
-- All four fixes share one new canonical helper, rider_is_on_active_trip(), so the "is this rider
-- actually busy right now" rule lives in exactly one place instead of being copy-pasted (and
-- drifting) across the RPC, the trigger, and the dispatch candidate query.

-- =====================================================================
-- 1. Canonical "is this rider currently occupied by an active trip" predicate.
--    - rider_arrived / picked_up / rider_at_drop / ongoing: always active, regardless of order
--      type -- the rider is physically mid-trip.
--    - accepted: active only if the order is a local job (local jobs are "busy" the instant
--      they're accepted, since the rider is already committed and en route to pickup) OR the
--      order is an intercity/long-distance booking whose trip_started_at has been set (i.e. the
--      traveller already pressed Start Trip). An intercity booking that is merely "Waiting for
--      Travel Day" (accepted, trip_started_at NULL) is a future reservation, not active work, and
--      must never count as busy.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.rider_is_on_active_trip(p_rider_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.orders o
        WHERE o.rider_id = p_rider_id
          AND (
                o.order_status::text IN ('rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing')
                OR (
                    o.order_status::text = 'accepted'
                    AND (
                        public.get_required_service_mode(o.order_type::text, o.distance_meters) = 'local'
                        OR o.trip_started_at IS NOT NULL
                    )
                )
              )
    );
$$;

COMMENT ON FUNCTION public.rider_is_on_active_trip(uuid) IS
    'Canonical "is this rider busy right now" check. A local order is busy from acceptance; an intercity/long-distance order is only busy once trip_started_at is set (Start Trip pressed), never while merely accepted and Waiting for Travel Day. Reused by accept_intercity_request, prevent_service_mode_switch_during_active_order, and find_nearby_riders so this rule lives in one place.';

-- =====================================================================
-- 2. start_intercity_trip(): fix the order_type_enum LIKE regression (cast to text first) and
--    replace the IST calendar-day gate with a direct timestamptz comparison that allows starting
--    up to 1 hour before the scheduled departure. Base definition: 20260720000000. Every other
--    line preserved.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.start_intercity_trip(
    p_order_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_rider RECORD;
    v_order RECORD;
    v_scheduled_departure timestamptz;
BEGIN
    SELECT * INTO v_rider FROM public.riders WHERE user_id = auth.uid();
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Rider profile not found for user.');
    END IF;

    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order not found.');
    END IF;

    IF v_order.rider_id IS DISTINCT FROM v_rider.id THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This trip is not assigned to you.');
    END IF;

    -- Bug fix: order_type is order_type_enum, which has no LIKE (~~) operator -- must cast to
    -- text before pattern-matching it (same class of bug as 20260718000001).
    IF NOT (v_order.order_type::text LIKE 'intercity%' OR (v_order.order_type::text = 'ride' AND COALESCE(v_order.distance_meters, 0) > 20000)) THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Start Trip only applies to intercity bookings.');
    END IF;

    IF v_order.order_status IS DISTINCT FROM 'accepted' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Trip is not in an accepted state.');
    END IF;

    IF v_order.trip_started_at IS NOT NULL THEN
        RETURN jsonb_build_object('success', true, 'code', 'ALREADY_STARTED', 'order_id', v_order.id);
    END IF;

    -- Early-start gate: allow Start Trip any time from 1 hour before the scheduled departure
    -- onward, instead of requiring the exact travel date/time -- real travellers routinely leave
    -- earlier than the exact booked slot. Comparing timestamptz instants directly (rather than
    -- IST calendar dates) is also correct across a day boundary, e.g. a 12:30 AM departure
    -- unlocks at 11:30 PM the previous day, and this is the same rule enforced client-side by
    -- WaitingForTravelDayCard so the button is never shown before the server would accept it.
    -- COALESCE mirrors the pre-existing fallback for orders with no travel_date (a plain >20km
    -- ride booked for immediate travel): such an order's departure is effectively "now", so it is
    -- always startable.
    v_scheduled_departure := COALESCE(v_order.travel_date, v_order.created_at);

    IF now() < (v_scheduled_departure - INTERVAL '1 hour') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'TRAVEL_DATE_NOT_ARRIVED',
            'message', 'You can start this trip up to 1 hour before the scheduled departure time.'
        );
    END IF;

    UPDATE public.orders
    SET trip_started_at = now(),
        updated_at = now()
    WHERE id = v_order.id;

    -- Mirror the trip-start into the linked negotiation row so the existing
    -- on_intercity_request_change 'in_progress' notification copy (unchanged) fires for the
    -- passenger, exactly as the previous client-side "Start Transit" write intended.
    UPDATE public.intercity_requests
    SET status = 'in_progress',
        updated_at = now()
    WHERE parcel_id = v_order.id
      AND traveller_id = v_rider.id
      AND status IN ('confirmed', 'paid');

    RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_id', v_order.id);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- =====================================================================
-- 3. accept_intercity_request(): replace the raw active-orders-count busy check with
--    rider_is_on_active_trip(), so accepting a future intercity request is never blocked by
--    another booking that is only "Waiting for Travel Day". Base definition: 20260718000012 (the
--    latest -- carries the WRONG_SERVICE_MODE gate). Also restores the passenger double-booking
--    guard (PASSENGER_ALREADY_CONFIRMED) that 20260717000005 added but 20260718000012 dropped by
--    being cut from an earlier base -- both checks are needed and are not in tension with each
--    other. Every other line preserved.
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
    v_passenger_active_count int;
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

    -- 4. Validate traveler plan active status
    SELECT * INTO v_travel_plan
    FROM public.rider_travel_plans
    WHERE id = v_request.route_id;

    IF v_travel_plan IS NULL OR v_travel_plan.status::text != 'active' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'TRAVEL_PLAN_INACTIVE',
            'message', 'Travel plan is no longer active.'
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

    -- 5b. Validate passenger is not already confirmed on another active trip (Part 15)
    SELECT COUNT(*) INTO v_passenger_active_count
    FROM public.orders
    WHERE user_id = v_order.user_id
      AND order_status IN ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing')
      AND id IS DISTINCT FROM v_order.id;

    IF v_passenger_active_count > 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'PASSENGER_ALREADY_CONFIRMED',
            'message', 'Passenger already confirmed another trip.'
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
-- 4. prevent_service_mode_switch_during_active_order(): use rider_is_on_active_trip() instead of
--    the raw active-orders-count query, so a rider "Waiting for Travel Day" on a future intercity
--    booking can freely switch to Local Service Mode (and back) right up until they press Start
--    Trip. Base definition: 20260718000013. Trigger definition itself is unchanged (still fires
--    BEFORE UPDATE OF service_mode ON riders), only the function body changes.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.prevent_service_mode_switch_during_active_order()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.service_mode IS NOT DISTINCT FROM OLD.service_mode THEN
        RETURN NEW;
    END IF;

    IF public.rider_is_on_active_trip(NEW.id) THEN
        RAISE EXCEPTION 'Cannot switch Service Mode while a trip is active. Complete or cancel your current trip first.'
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- =====================================================================
-- 5. find_nearby_riders(): same busy-definition fix applied to the dispatch candidate query, so a
--    rider who switched to Local Service Mode while "Waiting for Travel Day" on a future
--    intercity booking is actually offered local jobs (previously excluded by the same
--    over-broad "any accepted order" filter this migration fixes everywhere else). Base
--    definition: 20260718000010. Every other line preserved.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.find_nearby_riders(
    p_order_id uuid,
    p_pickup_lat double precision,
    p_pickup_lng double precision,
    p_radius_km double precision,
    p_limit integer
)
RETURNS TABLE(
    rider_id uuid,
    user_id uuid,
    full_name text,
    vehicle_type text,
    vehicle_number text,
    current_lat double precision,
    current_lng double precision,
    distance_km numeric
)
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
    v_order_type text;
    v_vehicle_type text;
    v_stale_sec integer;
    v_creator_user_id uuid;
    v_weight_kg double precision;
    v_distance_meters integer;
    v_required_mode public.partner_service_mode_enum;
BEGIN
    -- Fetch order details, prioritizing actual_weight_kg (numeric) over weight_category
    SELECT
        o.order_type,
        o.vehicle_type,
        o.user_id,
        COALESCE(
            o.actual_weight_kg,
            COALESCE(NULLIF(regexp_replace(o.weight_category::text, '[^0-9.]', '', 'g'), ''), '0')::double precision
        )::double precision,
        o.distance_meters
    INTO
        v_order_type,
        v_vehicle_type,
        v_creator_user_id,
        v_weight_kg,
        v_distance_meters
    FROM orders o
    WHERE o.id = p_order_id;

    v_required_mode := public.get_required_service_mode(v_order_type, v_distance_meters);

    -- Fetch stale timeout from active dispatch config, fallback to 60 seconds
    SELECT COALESCE(rider_location_stale_sec, 60)
    INTO v_stale_sec
    FROM dispatch_config
    WHERE is_active = true
    LIMIT 1;

    RETURN QUERY
    SELECT
        r.id AS rider_id,
        r.user_id,
        rk.full_name,
        rk.vehicle_type::text AS vehicle_type,
        rk.vehicle_number,
        r.current_lat,
        r.current_lng,
        ROUND(
            (
                6371 * acos(
                    LEAST(GREATEST(
                        cos(radians(p_pickup_lat))
                        * cos(radians(r.current_lat))
                        * cos(
                            radians(r.current_lng)
                            - radians(p_pickup_lng)
                        )
                        + sin(radians(p_pickup_lat))
                        * sin(radians(r.current_lat))
                    , -1.0), 1.0)
                )
            )::numeric,
            2
        ) AS distance_km
    FROM riders r
    INNER JOIN rider_kyc rk
        ON rk.user_id = r.user_id
    WHERE
        r.account_status = 'online'
        -- Partner Service Mode filter: only candidates whose chosen mode
        -- matches this specific order's canonical required mode.
        AND r.service_mode = v_required_mode
        AND r.current_lat IS NOT NULL
        AND r.current_lng IS NOT NULL
        -- Enforce creator user exclusion
        AND r.user_id != v_creator_user_id
        AND (rk.kyc_status::text IN ('approved', 'pending', 'under_review', 'resubmitted') OR rk.kyc_status IS NULL)
        AND (rk.activation_status::text IN ('active', 'pending', 'inactive') OR rk.activation_status IS NULL)
        AND (
            r.last_location_updated_at >= (NOW() - (v_stale_sec || ' seconds')::interval)
            OR
            r.last_location_updated_at >= (NOW() - INTERVAL '24 hours')
            OR
            r.last_location_updated_at IS NULL
        )
        -- Vehicle filter
        AND (
            -- Ride / Intercity Ride
            ((v_order_type = 'ride' OR v_order_type = 'intercity_ride' OR v_order_type = 'intercity') AND
             rk.vehicle_type::text = v_vehicle_type)
            OR
            -- Ride Sharing
            (v_order_type = 'ride_sharing' AND rk.vehicle_type::text IN ('auto', 'cab'))
            OR
            -- Parcels / Deliveries
            -- Local Parcels / Deliveries
            (
                (v_order_type = 'local_parcel' OR v_order_type LIKE '%parcel%' OR v_order_type LIKE '%delivery%')
                AND v_order_type != 'intercity_parcel'
                AND
                (
                    (v_weight_kg < 10.0 AND rk.vehicle_type::text = 'bike')
                    OR
                    (v_weight_kg >= 10.0 AND rk.vehicle_type::text = 'auto')
                )
            )
            OR
            -- Intercity Parcels
            (
                v_order_type = 'intercity_parcel'
                AND
                (
                    (v_weight_kg < 10.0 AND rk.vehicle_type::text = 'bike')
                    OR
                    (v_weight_kg >= 10.0 AND rk.vehicle_type::text IN ('auto', 'cab'))
                )
            )
            OR
            -- Others
            (v_order_type NOT IN ('ride', 'intercity_ride', 'intercity', 'ride_sharing', 'local_parcel', 'intercity_parcel') AND v_order_type NOT LIKE '%parcel%' AND v_order_type NOT LIKE '%delivery%')
        )
        -- Busy filter: excludes only riders with an ACTUALLY active trip (see
        -- rider_is_on_active_trip) -- a rider merely Waiting for Travel Day on a different
        -- intercity booking remains a valid candidate.
        AND NOT public.rider_is_on_active_trip(r.id)
        -- Search radius filter
        AND (
            6371 * acos(
                LEAST(GREATEST(
                    cos(radians(p_pickup_lat))
                    * cos(radians(r.current_lat))
                    * cos(
                        radians(r.current_lng)
                        - radians(p_pickup_lng)
                    )
                    + sin(radians(p_pickup_lat))
                    * sin(radians(r.current_lat))
                , -1.0), 1.0)
            )
        ) <= p_radius_km
    ORDER BY distance_km ASC
    LIMIT p_limit;
END;
$$;
