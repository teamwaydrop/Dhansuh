CREATE OR REPLACE FUNCTION public.redispatch_freed_riders()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_rider RECORD;
BEGIN
    IF NOT pg_try_advisory_xact_lock(4735021, 1) THEN
        RAISE NOTICE 'redispatch_freed_riders: previous sweep still running -- skipping this tick.';
        RETURN;
    END IF;

    FOR v_rider IN (
        SELECT r.id, r.user_id, r.current_lat, r.current_lng, r.service_mode
        FROM public.riders r
        WHERE r.account_status = 'online'
          AND r.current_lat IS NOT NULL
          AND r.current_lng IS NOT NULL
          AND EXISTS (
              SELECT 1 FROM public.orders o
              WHERE o.rider_id = r.id
                AND o.updated_at >= NOW() - INTERVAL '5 minutes'
          )
          AND NOT EXISTS (
              SELECT 1 FROM public.orders bo
              WHERE bo.rider_id = r.id
                AND bo.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending')
          )
    ) LOOP
        BEGIN
            PERFORM public.assign_nearby_searching_orders_core(
                v_rider.id,
                v_rider.user_id,
                v_rider.current_lat,
                v_rider.current_lng,
                v_rider.service_mode
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'redispatch_freed_riders: failed to rematch rider %: %', v_rider.id, SQLERRM;
        END;
    END LOOP;
END;
$function$

