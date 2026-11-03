CREATE OR REPLACE FUNCTION public.prevent_local_ride_assignment_to_busy_rider()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_new_order_type text;
    v_new_distance integer;
BEGIN
    IF NEW.assignment_status IS DISTINCT FROM 'sent' THEN
        RETURN NEW;
    END IF;

    SELECT o.order_type::text, o.distance_meters
    INTO v_new_order_type, v_new_distance
    FROM public.orders o
    WHERE o.id = NEW.order_id;

    -- Only local rides are in scope for this guard.
    IF v_new_order_type IS DISTINCT FROM 'ride' OR COALESCE(v_new_distance, 0) > 20000 THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.orders bo
        WHERE bo.rider_id = NEW.rider_id
          AND bo.id != NEW.order_id
          AND bo.order_type = 'ride'
          AND COALESCE(bo.distance_meters, 0) <= 20000
          AND bo.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing', 'payment_pending')
    ) THEN
        RETURN NULL;
    END IF;

    RETURN NEW;
END;
$function$
;
