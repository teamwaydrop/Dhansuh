CREATE OR REPLACE FUNCTION public.rider_self_rematch()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_rider RECORD;
BEGIN
    SELECT id, user_id, current_lat, current_lng, service_mode
    INTO v_rider
    FROM public.riders
    WHERE user_id = auth.uid();

    IF NOT FOUND THEN
        RETURN;
    END IF;

    PERFORM public.assign_nearby_searching_orders_core(
        v_rider.id,
        v_rider.user_id,
        v_rider.current_lat,
        v_rider.current_lng,
        v_rider.service_mode
    );
END;
$function$
;
