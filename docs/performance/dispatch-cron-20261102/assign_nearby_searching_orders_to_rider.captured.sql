CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_to_rider()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    PERFORM public.assign_nearby_searching_orders_core(
        NEW.id,
        NEW.user_id,
        NEW.current_lat,
        NEW.current_lng,
        NEW.service_mode
    );

    RETURN NEW;
END;
$function$
;
