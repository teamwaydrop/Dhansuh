-- Create Migration: Fix Weight Category Matching
-- Date: 2026-06-20
-- Description: Redefine find_nearby_riders and assign_nearby_searching_orders_to_rider to parse weight categories ('0_5', '6_15', '16_25', '26_50') to correct double precision values instead of using raw regex replacement which yields astronomical values (like 615 for '6_15').

-- 1. Re-define public.find_nearby_riders
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
AS $$
DECLARE
    v_order_type text;
    v_vehicle_type text;
    v_stale_sec integer;
    v_creator_user_id uuid;
    v_weight_kg double precision;
BEGIN
    -- Fetch order details, prioritizing actual_weight_kg (numeric) over weight_category
    SELECT
        o.order_type,
        o.vehicle_type,
        o.user_id,
        COALESCE(
            o.actual_weight_kg,
            COALESCE(NULLIF(regexp_replace(o.weight_category::text, '[^0-9.]', '', 'g'), ''), '0')::double precision
        )::double precision
    INTO
        v_order_type,
        v_vehicle_type,
        v_creator_user_id,
        v_weight_kg
    FROM orders o
    WHERE o.id = p_order_id;

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

-- 2. Re-define public.assign_nearby_searching_orders_to_rider
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
    v_timeout_cooldown_sec integer;
BEGIN
    -- 1. If coordinates are missing, bypass
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    -- 2. Fetch active dispatch config values
    SELECT 
        COALESCE(round_2_radius_km, 5.0),
        COALESCE(rider_location_stale_sec, 60),
        COALESCE(rider_response_timeout_sec, 30),
        COALESCE(timeout_cooldown_sec, 120)
    INTO 
        v_radius_km, 
        v_stale_sec, 
        v_timeout_sec,
        v_timeout_cooldown_sec
    FROM public.dispatch_config
    WHERE is_active = true
    LIMIT 1;

    -- Fallbacks
    v_radius_km := COALESCE(v_radius_km, 5.0);
    v_stale_sec := COALESCE(v_stale_sec, 60);
    v_timeout_sec := COALESCE(v_timeout_sec, 30);
    v_timeout_cooldown_sec := COALESCE(v_timeout_cooldown_sec, 120);

    -- 3. Fetch rider's vehicle type
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

        -- If the rider is within the max radius, and matches the vehicle type / weight filter
        IF v_dist_km <= v_radius_km AND (
            ((v_order.order_type::text = 'ride' OR v_order.order_type::text = 'intercity_ride' OR v_order.order_type::text = 'intercity') AND 
             v_rider_vehicle = v_order.vehicle_type)
            OR
            (v_order.order_type::text = 'ride_sharing' AND v_rider_vehicle IN ('auto', 'cab'))
            OR
            -- Local Parcels / Deliveries
            (
                (v_order.order_type::text = 'local_parcel' OR v_order.order_type::text LIKE '%parcel%' OR v_order.order_type::text LIKE '%delivery%')
                AND v_order.order_type::text != 'intercity_parcel'
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
                v_order.order_type::text = 'intercity_parcel'
                AND
                (
                    (v_order.weight_kg < 10.0 AND v_rider_vehicle = 'bike')
                    OR
                    (v_order.weight_kg >= 10.0 AND v_rider_vehicle IN ('auto', 'cab'))
                )
            )
            OR
            (v_order.order_type::text NOT IN ('ride', 'intercity_ride', 'intercity', 'ride_sharing', 'local_parcel', 'intercity_parcel') AND v_order.order_type::text NOT LIKE '%parcel%' AND v_order.order_type::text NOT LIKE '%delivery%')
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
                        expires_at
                    ) VALUES (
                        v_order.id,
                        NEW.id,
                        1,
                        'sent',
                        v_dist_km,
                        v_order.rider_earning,
                        NOW(),
                        NOW() + (v_timeout_sec || ' seconds')::interval
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
                    -- Check if they just went online (OLD.account_status was not 'online')
                    -- OR if they have been online and the assignment has been expired for at least 1 minute (60 seconds)
                    IF OLD.account_status IS DISTINCT FROM 'online' OR EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND responded_at <= NOW() - (v_timeout_cooldown_sec || ' seconds')::interval
                    ) THEN
                        -- Update existing assignment back to 'sent' with fresh expiry
                        UPDATE public.rider_assignments
                        SET 
                            assignment_status = 'sent',
                            distance_km = v_dist_km,
                            sent_at = NOW(),
                            expires_at = NOW() + (v_timeout_sec || ' seconds')::interval,
                            updated_at = NOW(),
                            responded_at = NULL
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
                NULL;
            END;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. Update active dispatch config values to match the new 60s timeout and 120s cooldowns
UPDATE public.dispatch_config
SET 
    rider_response_timeout_sec = 60,
    reject_cooldown_sec = 120,
    timeout_cooldown_sec = 120
WHERE config_code = 'DEFAULT_V1';
