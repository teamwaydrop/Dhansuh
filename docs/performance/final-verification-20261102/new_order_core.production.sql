CREATE OR REPLACE FUNCTION public.assign_new_order_to_nearby_online_riders_core(p_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_order RECORD;
    v_radius_km double precision;
    v_rider RECORD;
BEGIN
    SELECT id, user_id, order_status, pickup_lat, pickup_lng
    INTO v_order
    FROM public.orders
    WHERE id = p_order_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF v_order.order_status != 'searching' THEN
        RETURN;
    END IF;

    IF v_order.pickup_lat IS NULL OR v_order.pickup_lng IS NULL THEN
        RETURN;
    END IF;

    SELECT COALESCE(round_2_radius_km, 5.0) INTO v_radius_km
    FROM public.dispatch_config
    WHERE is_active = true
    LIMIT 1;
    v_radius_km := COALESCE(v_radius_km, 5.0);

    -- Byte-for-byte identical to the loop this replaces inside
    -- assign_new_order_to_nearby_online_riders() (20260808000005) -- only NEW.* references became
    -- v_order.* after the fresh SELECT above.
    FOR v_rider IN (
        SELECT r.id, r.user_id, r.current_lat, r.current_lng, r.service_mode
        FROM public.riders r
        WHERE r.account_status = 'online'
          AND r.current_lat IS NOT NULL
          AND r.current_lng IS NOT NULL
          AND r.user_id != v_order.user_id
          AND (
              6371 * acos(
                  LEAST(GREATEST(
                      cos(radians(v_order.pickup_lat)) * cos(radians(r.current_lat))
                          * cos(radians(r.current_lng) - radians(v_order.pickup_lng))
                      + sin(radians(v_order.pickup_lat)) * sin(radians(r.current_lat))
                  , -1.0), 1.0)
              )
          ) <= v_radius_km
    ) LOOP
        PERFORM public.assign_nearby_searching_orders_core(
            v_rider.id,
            v_rider.user_id,
            v_rider.current_lat,
            v_rider.current_lng,
            v_rider.service_mode
        );
    END LOOP;
END;
$function$

