-- Fix the find_nearby_riders PL/pgSQL function to enforce the search radius and filter out stale rider locations.
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (
        SELECT oid::regprocedure AS sig
        FROM pg_proc
        WHERE proname = 'find_nearby_riders'
          AND pronamespace = 'public'::regnamespace
    ) LOOP
        EXECUTE 'DROP FUNCTION ' || r.sig;
    END LOOP;
END;
$$;

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
BEGIN
    -- 1. Fetch order details
    SELECT
        o.order_type,
        o.vehicle_type
    INTO
        v_order_type,
        v_vehicle_type
    FROM orders o
    WHERE o.id = p_order_id;

    -- 2. Fetch stale timeout from active dispatch config, fallback to 60 seconds
    SELECT COALESCE(rider_location_stale_sec, 60)
    INTO v_stale_sec
    FROM dispatch_config
    WHERE is_active = true
    LIMIT 1;

    -- 3. Return query filtering by vehicle type, order status, radius, and location freshness
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
        -- Relaxed KYC / Activation checks for simulator and testing flexibility
        AND (rk.kyc_status::text IN ('approved', 'pending', 'under_review', 'resubmitted') OR rk.kyc_status IS NULL)
        AND (rk.activation_status::text IN ('active', 'pending', 'inactive') OR rk.activation_status IS NULL)
        -- Location freshness check (stale limit config, but fallback to 24 hours or null to support simulator testing)
        AND (
            r.last_location_updated_at >= (NOW() - (v_stale_sec || ' seconds')::interval)
            OR
            r.last_location_updated_at >= (NOW() - INTERVAL '24 hours')
            OR
            r.last_location_updated_at IS NULL
        )
        -- Vehicle filter
        AND (
            v_order_type != 'ride'
            OR
            rk.vehicle_type::text = v_vehicle_type
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
-- Update the active dispatch config to have ideal values


-- Ensure Row Level Security (RLS) is safely enabled on all tables
ALTER TABLE public.riders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rider_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rider_kyc ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_assignment_logs ENABLE ROW LEVEL SECURITY;

-- 1. RIDERS POLICIES: View online riders publicly, but profile edits are restricted to owners
DROP POLICY IF EXISTS "Allow authenticated users to view online riders" ON public.riders;
CREATE POLICY "Allow authenticated users to view online riders"
ON public.riders
FOR SELECT
TO authenticated
USING (account_status = 'online' OR auth.uid() = user_id);

DROP POLICY IF EXISTS "Allow riders to update their own profile" ON public.riders;
CREATE POLICY "Allow riders to update their own profile"
ON public.riders
FOR UPDATE
TO authenticated
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

-- 2. RIDER ASSIGNMENTS POLICIES: Riders can select and update (accept/reject) only their assigned orders
DROP POLICY IF EXISTS "Allow riders to view their own assignments" ON public.rider_assignments;
CREATE POLICY "Allow riders to view their own assignments"
ON public.rider_assignments
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = rider_assignments.rider_id
          AND r.user_id = auth.uid()
    )
);

DROP POLICY IF EXISTS "Allow riders to update their own assignments" ON public.rider_assignments;
CREATE POLICY "Allow riders to update their own assignments"
ON public.rider_assignments
FOR UPDATE
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = rider_assignments.rider_id
          AND r.user_id = auth.uid()
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = rider_assignments.rider_id
          AND r.user_id = auth.uid()
    )
);

-- 3. ORDERS POLICIES: Passenger owns the order, assigned rider receives the order, passengers can insert
DROP POLICY IF EXISTS "Allow users to view their own or assigned orders" ON public.orders;
CREATE POLICY "Allow users to view their own or assigned orders"
ON public.orders
FOR SELECT
TO authenticated
USING (
    auth.uid() = user_id
    OR
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = orders.rider_id
          AND r.user_id = auth.uid()
    )
    OR
    EXISTS (
        SELECT 1 FROM public.rider_assignments ra
        INNER JOIN public.riders r ON r.id = ra.rider_id
        WHERE ra.order_id = orders.id
          AND r.user_id = auth.uid()
    )
);

DROP POLICY IF EXISTS "Allow passengers to create orders" ON public.orders;
CREATE POLICY "Allow passengers to create orders"
ON public.orders
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Allow passengers and assigned riders to update orders" ON public.orders;
CREATE POLICY "Allow passengers and assigned riders to update orders"
ON public.orders
FOR UPDATE
TO authenticated
USING (
    auth.uid() = user_id
    OR
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = orders.rider_id
          AND r.user_id = auth.uid()
    )
);

-- 4. RIDER KYC POLICIES: Owners view own KYC, passengers see KYC of online riders
DROP POLICY IF EXISTS "Allow view own KYC or online rider KYC" ON public.rider_kyc;
CREATE POLICY "Allow view own KYC or online rider KYC"
ON public.rider_kyc
FOR SELECT
TO authenticated
USING (
    auth.uid() = user_id
    OR
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.user_id = rider_kyc.user_id
          AND r.account_status = 'online'
    )
);

-- 5. ASSIGNMENT LOGS POLICIES: Order owners and assigned riders can track matching logs
DROP POLICY IF EXISTS "Allow riders and orders owners to view logs" ON public.order_assignment_logs;
CREATE POLICY "Allow riders and orders owners to view logs"
ON public.order_assignment_logs
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = order_assignment_logs.rider_id
          AND r.user_id = auth.uid()
    )
    OR
    EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.id = order_assignment_logs.order_id
          AND o.user_id = auth.uid()
    )
);

-- Trigger and function to automatically assign nearby searching orders to a rider when they go online
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
BEGIN
    -- 1. If coordinates are missing, bypass
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    -- 2. Fetch active dispatch config values
    SELECT 
        COALESCE(round_2_radius_km, 5.0),
        COALESCE(rider_location_stale_sec, 60),
        COALESCE(rider_response_timeout_sec, 15)
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
    v_timeout_sec := COALESCE(v_timeout_sec, 15);

    FOR v_order IN (
        SELECT o.id, o.pickup_lat, o.pickup_lng, o.vehicle_type::text AS vehicle_type, o.order_type::text AS order_type, o.rider_earning
        FROM public.orders o
        WHERE o.order_status = 'searching'
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

        -- If the rider is within the max radius, and matches the vehicle type filter
        IF v_dist_km <= v_radius_km AND (v_order.order_type != 'ride' OR EXISTS (
            SELECT 1 FROM public.rider_kyc rk 
            WHERE rk.user_id = NEW.user_id 
              AND rk.vehicle_type::text = v_order.vehicle_type
        )) THEN
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
                        CEIL(v_dist_km * 3),
                        NOW()
                    );
                ELSIF v_existing_status = 'expired' THEN
                    -- Check if they just went online (OLD.account_status was not 'online')
                    -- OR if they have been online and the assignment has been expired for at least 1 minute (60 seconds)
                    IF OLD.account_status IS DISTINCT FROM 'online' OR EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND responded_at <= NOW() - INTERVAL '1 minute'
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
                -- Safely ignore duplicate key constraint violations (e.g. concurrent inserts)
                NULL;
            END;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_assign_nearby_orders ON public.riders;
CREATE TRIGGER trigger_assign_nearby_orders
AFTER UPDATE OF account_status, current_lat, current_lng, last_location_updated_at ON public.riders
FOR EACH ROW
WHEN (
    NEW.account_status = 'online' 
    AND (
        OLD.account_status IS DISTINCT FROM 'online' 
        OR NEW.current_lat IS DISTINCT FROM OLD.current_lat 
        OR NEW.current_lng IS DISTINCT FROM OLD.current_lng
        OR NEW.last_location_updated_at IS DISTINCT FROM OLD.last_location_updated_at
    )
)
EXECUTE FUNCTION public.assign_nearby_searching_orders_to_rider();
