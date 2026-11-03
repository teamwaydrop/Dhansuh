CREATE OR REPLACE FUNCTION public.find_nearby_riders(p_order_id uuid, p_pickup_lat double precision, p_pickup_lng double precision, p_radius_km double precision, p_limit integer, p_excluded_rider_ids uuid[] DEFAULT '{}'::uuid[])
 RETURNS TABLE(rider_id uuid, user_id uuid, full_name text, vehicle_type text, vehicle_number text, current_lat double precision, current_lng double precision, distance_km numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_order_type text;
    v_vehicle_type text;
    v_stale_sec integer;
    v_creator_user_id uuid;
    v_weight_kg double precision;
    v_distance_meters integer;
    v_required_mode public.partner_service_mode_enum;
    v_tax_due_threshold numeric;
BEGIN
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

    IF auth.uid() IS NOT NULL AND (v_creator_user_id IS NULL OR auth.uid() != v_creator_user_id) THEN
        RETURN;
    END IF;

    v_required_mode := public.get_required_service_mode(v_order_type, v_distance_meters);

    SELECT COALESCE(rider_location_stale_sec, 60)
    INTO v_stale_sec
    FROM dispatch_config
    WHERE is_active = true
    LIMIT 1;

    SELECT public.get_active_tax_due_threshold()
    INTO v_tax_due_threshold;

    RETURN QUERY
    WITH candidates AS (
        SELECT
            r.id AS rider_id,
            r.user_id,
            rk.full_name,
            rk.vehicle_type::text AS vehicle_type,
            rk.vehicle_number,
            r.current_lat,
            r.current_lng,
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
            ) AS raw_distance_km
        FROM riders r
        INNER JOIN rider_kyc rk
            ON rk.user_id = r.user_id
        WHERE
            r.account_status = 'online'
            AND r.service_mode = v_required_mode
            AND r.current_lat IS NOT NULL
            AND r.current_lng IS NOT NULL
            AND r.user_id != v_creator_user_id
            AND NOT (r.id = ANY(p_excluded_rider_ids))
            AND r.government_tax_due_balance < v_tax_due_threshold
            AND COALESCE(r.cod_pending_amount, 0) < COALESCE(r.cod_limit, 500)
            AND (rk.kyc_status::text IN ('approved', 'pending', 'under_review', 'resubmitted') OR rk.kyc_status IS NULL)
            AND (rk.activation_status::text IN ('active', 'pending', 'inactive') OR rk.activation_status IS NULL)
            AND (
                r.last_location_updated_at >= (NOW() - (v_stale_sec || ' seconds')::interval)
                OR
                r.last_location_updated_at >= (NOW() - INTERVAL '24 hours')
                OR
                r.last_location_updated_at IS NULL
            )
            AND (
                ((v_order_type = 'ride' OR v_order_type = 'intercity_ride' OR v_order_type = 'intercity') AND
                 rk.vehicle_type::text = v_vehicle_type)
                OR
                (v_order_type = 'ride_sharing' AND rk.vehicle_type::text IN ('auto', 'cab'))
                OR
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
                (v_order_type NOT IN ('ride', 'intercity_ride', 'intercity', 'ride_sharing', 'local_parcel', 'intercity_parcel') AND v_order_type NOT LIKE '%parcel%' AND v_order_type NOT LIKE '%delivery%')
            )
            AND NOT public.rider_is_on_active_trip(r.id)
    )
    SELECT
        candidates.rider_id,
        candidates.user_id,
        candidates.full_name,
        candidates.vehicle_type,
        candidates.vehicle_number,
        candidates.current_lat,
        candidates.current_lng,
        ROUND(candidates.raw_distance_km::numeric, 2) AS distance_km
    FROM candidates
    WHERE candidates.raw_distance_km <= p_radius_km
    ORDER BY distance_km ASC
    LIMIT p_limit;
END;
$function$
;
