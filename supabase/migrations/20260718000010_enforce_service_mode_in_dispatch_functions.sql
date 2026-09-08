-- Migration: Enforce Partner Service Mode in both dispatch candidate-selection functions.
-- Date: 2026-07-18
--
-- Query-level filtering layer (efficiency/correctness of candidate pools —
-- don't even propose a wrong-mode rider). This is NOT the security
-- boundary by itself; the guard triggers added in
-- 20260718000011_add_rider_assignment_service_mode_guard_triggers.sql are
-- the non-bypassable enforcement. This migration just stops wrong-mode
-- riders from ever being offered the job in the first place.
--
-- 1. find_nearby_riders: latest prior definition is
--    20260620000000_fix_weight_category_matching_and_intercity.sql. This RPC
--    is polled directly by ride_searching_screen.dart / parcel_searching_screen.dart
--    for local order_types, but a plain 'ride' order over 20km is already
--    treated as intercity elsewhere in this codebase today (see
--    lib/models/transport_order.dart's OrderFlowType getter,
--    intercity_tracking_screen.dart's re-search branch, and
--    intercity_rides_screen.dart's customer order list) — so this filter
--    uses the same canonical get_required_service_mode() classification
--    (added in 20260718000009) rather than a blanket 'local' filter, to
--    stay consistent with the orders.rider_id guard trigger
--    (20260718000011) and avoid a rider passing this candidate filter only
--    to be rejected downstream with a raw exception. distance_meters is
--    added to the order lookup purely to feed that function; every other
--    line is preserved byte-for-byte from the 20260620000000 definition.
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
        -- No active orders filter
        AND NOT EXISTS (
            SELECT 1
            FROM orders o
            WHERE
                o.rider_id = r.id
                AND o.order_status IN (
                    'accepted',
                    'rider_arrived',
                    'picked_up',
                    'ongoing'
                )
        )
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

-- 2. assign_nearby_searching_orders_to_rider: latest prior definition is
--    the one restored in 20260716000000_fix_dispatch_trigger_self_match_and_weight.sql
--    (search_path hardening applied on top in 20260716000007). This trigger
--    fires on every rider location/status update and is the most serious
--    cross-contamination path today: it loops ALL searching orders with no
--    order_type exclusion, so any rider moving/going online could be
--    assigned an intercity_ride/intercity_parcel job regardless of intent.
--    Fixed by requiring the order's canonical required mode
--    (get_required_service_mode) to equal the updating rider's own
--    service_mode. A NULL service_mode (not yet chosen) matches nothing,
--    by SQL NULL semantics, so unset riders receive zero dispatch until
--    they choose — fail-safe, not a silent misclassification.
--    distance_meters is added to the v_order cursor SELECT (previously
--    absent) purely to feed get_required_service_mode(); every other line
--    is preserved byte-for-byte from the 20260716000000/000007 definition.
CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_to_rider()
RETURNS TRIGGER AS $$
DECLARE
    v_order RECORD;
    v_radius_km double precision;
    v_stale_sec integer;
    v_dist_km double precision;
    v_timeout_sec integer;
    v_existing_id uuid;
    v_existing_status text;
    v_rider_vehicle text;
BEGIN
    -- 1. If coordinates are missing, bypass
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    -- 2. Fetch active dispatch config values
    SELECT
        COALESCE(round_2_radius_km, 5.0),
        COALESCE(rider_location_stale_sec, 60),
        COALESCE(rider_response_timeout_sec, 120)
    INTO
        v_radius_km,
        v_stale_sec,
        v_timeout_sec
    FROM public.dispatch_config
    WHERE is_active = true
    LIMIT 1;

    -- Fallbacks if config is missing or null
    v_radius_km := COALESCE(v_radius_km, 5.0);
    v_stale_sec := COALESCE(v_stale_sec, 60);
    v_timeout_sec := COALESCE(v_timeout_sec, 120);

    -- 3. Fetch rider's vehicle type (for weight/vehicle-aware matching)
    SELECT COALESCE(rk.vehicle_type::text, '') INTO v_rider_vehicle
    FROM public.rider_kyc rk
    WHERE rk.user_id = NEW.user_id
    LIMIT 1;

    FOR v_order IN (
        SELECT
            o.id,
            o.pickup_lat,
            o.pickup_lng,
            o.vehicle_type::text AS vehicle_type,
            o.order_type::text AS order_type,
            o.rider_earning,
            o.distance_meters,
            COALESCE(
                o.actual_weight_kg,
                COALESCE(NULLIF(regexp_replace(o.weight_category::text, '[^0-9.]', '', 'g'), ''), '0')::double precision
            )::double precision AS weight_kg
        FROM public.orders o
        WHERE o.order_status = 'searching'
          AND o.user_id != NEW.user_id
    ) LOOP
        -- Calculate distance between rider and order pickup location
        v_dist_km := 6371 * acos(
            LEAST(GREATEST(
                cos(radians(v_order.pickup_lat))
                * cos(radians(NEW.current_lat))
                * cos(
                    radians(NEW.current_lng)
                    - radians(v_order.pickup_lng)
                )
                + sin(radians(v_order.pickup_lat))
                * sin(radians(NEW.current_lat))
            , -1.0), 1.0)
        );

        -- If the rider is within the max radius, matches the vehicle/weight
        -- filter, AND the order's required service mode equals this rider's
        -- own service mode (NULL rider service_mode matches nothing).
        IF v_dist_km <= v_radius_km
           AND public.get_required_service_mode(v_order.order_type, v_order.distance_meters) = NEW.service_mode
           AND (
            ((v_order.order_type = 'ride' OR v_order.order_type = 'intercity_ride' OR v_order.order_type = 'intercity') AND
             v_rider_vehicle = v_order.vehicle_type)
            OR
            (v_order.order_type = 'ride_sharing' AND v_rider_vehicle IN ('auto', 'cab'))
            OR
            -- Local Parcels / Deliveries
            (
                (v_order.order_type = 'local_parcel' OR v_order.order_type LIKE '%parcel%' OR v_order.order_type LIKE '%delivery%')
                AND v_order.order_type != 'intercity_parcel'
                AND
                (
                    (v_order.weight_kg < 10.0 AND v_rider_vehicle = 'bike')
                    OR
                    (v_order.weight_kg >= 10.0 AND v_rider_vehicle = 'auto')
                )
            )
            OR
            -- Intercity Parcels
            (
                v_order.order_type = 'intercity_parcel'
                AND
                (
                    (v_order.weight_kg < 10.0 AND v_rider_vehicle = 'bike')
                    OR
                    (v_order.weight_kg >= 10.0 AND v_rider_vehicle IN ('auto', 'cab'))
                )
            )
            OR
            (v_order.order_type NOT IN ('ride', 'intercity_ride', 'intercity', 'ride_sharing', 'local_parcel', 'intercity_parcel') AND v_order.order_type NOT LIKE '%parcel%' AND v_order.order_type NOT LIKE '%delivery%')
        ) THEN
            -- Check if this rider doesn't already have an assignment for this order
            v_existing_id := NULL;
            v_existing_status := NULL;

            SELECT id, assignment_status INTO v_existing_id, v_existing_status
            FROM public.rider_assignments
            WHERE order_id = v_order.id
              AND rider_id = NEW.id
            LIMIT 1;

            BEGIN
                IF v_existing_id IS NULL THEN
                    -- Insert assignment
                    INSERT INTO public.rider_assignments (
                        order_id,
                        rider_id,
                        assignment_round,
                        assignment_status,
                        distance_km,
                        estimated_earnings,
                        sent_at,
                        expires_at,
                        last_seen_at,
                        last_seen_fare
                    ) VALUES (
                        v_order.id,
                        NEW.id,
                        1,
                        'sent',
                        v_dist_km,
                        v_order.rider_earning,
                        NOW(),
                        NOW() + (v_timeout_sec || ' seconds')::interval,
                        NOW(),
                        v_order.rider_earning
                    );

                    -- Also insert into logs
                    INSERT INTO public.order_assignment_logs (
                        order_id,
                        rider_id,
                        assignment_round,
                        assignment_status,
                        rider_distance_km,
                        estimated_pickup_time_min,
                        sent_at
                    ) VALUES (
                        v_order.id,
                        NEW.id,
                        1,
                        'sent',
                        v_dist_km,
                        v_order.rider_earning,
                        NOW()
                    );
                ELSIF v_existing_status = 'expired' THEN
                    -- Only show again if the fare is boosted
                    IF EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND v_order.rider_earning > COALESCE(last_seen_fare, estimated_earnings, 0)
                    ) THEN
                        -- Update existing assignment back to 'sent' with fresh expiry
                        UPDATE public.rider_assignments
                        SET
                            assignment_status = 'sent',
                            distance_km = v_dist_km,
                            sent_at = NOW(),
                            expires_at = NOW() + (v_timeout_sec || ' seconds')::interval,
                            updated_at = NOW(),
                            responded_at = NULL,
                            response_type = NULL,
                            hidden_until = NULL,
                            last_seen_at = NOW(),
                            last_seen_fare = v_order.rider_earning
                        WHERE id = v_existing_id;

                        -- Log the update
                        INSERT INTO public.order_assignment_logs (
                            order_id,
                            rider_id,
                            assignment_round,
                            assignment_status,
                            rider_distance_km,
                            estimated_pickup_time_min,
                            sent_at
                        ) VALUES (
                            v_order.id,
                            NEW.id,
                            1,
                            'sent',
                            v_dist_km,
                            CEIL(v_dist_km * 3),
                            NOW()
                        );
                    END IF;
                ELSIF v_existing_status = 'rejected' THEN
                    -- Only show again if 4-minute cooldown is over AND the fare is boosted
                    IF EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND NOW() >= COALESCE(hidden_until, NOW())
                          AND v_order.rider_earning > COALESCE(last_seen_fare, estimated_earnings, 0)
                    ) THEN
                        -- Update existing assignment back to 'sent' with fresh expiry
                        UPDATE public.rider_assignments
                        SET
                            assignment_status = 'sent',
                            distance_km = v_dist_km,
                            sent_at = NOW(),
                            expires_at = NOW() + (v_timeout_sec || ' seconds')::interval,
                            updated_at = NOW(),
                            responded_at = NULL,
                            response_type = NULL,
                            hidden_until = NULL,
                            last_seen_at = NOW(),
                            last_seen_fare = v_order.rider_earning
                        WHERE id = v_existing_id;

                        -- Log the update
                        INSERT INTO public.order_assignment_logs (
                            order_id,
                            rider_id,
                            assignment_round,
                            assignment_status,
                            rider_distance_km,
                            estimated_pickup_time_min,
                            sent_at
                        ) VALUES (
                            v_order.id,
                            NEW.id,
                            1,
                            'sent',
                            v_dist_km,
                            CEIL(v_dist_km * 3),
                            NOW()
                        );
                    END IF;
                END IF;
            EXCEPTION WHEN unique_violation THEN
                -- Safely ignore duplicate key constraint violations
                NULL;
            END;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
