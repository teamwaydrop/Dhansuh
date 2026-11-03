CREATE OR REPLACE FUNCTION public.on_rider_assignment_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_rider_user_id uuid := NULL;
    v_order_type text := NULL;
    v_notification_type text := 'order_assignment';
BEGIN
    -- Notify when status is set or updated to 'sent'
    IF NEW.assignment_status = 'sent' AND (TG_OP = 'INSERT' OR OLD.assignment_status IS DISTINCT FROM 'sent') THEN
        SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

        IF v_rider_user_id IS NOT NULL THEN
            SELECT order_type::text INTO v_order_type FROM public.orders WHERE id = NEW.order_id;

            IF v_order_type IN ('intercity_ride', 'intercity_parcel') THEN
                v_notification_type := 'intercity_order_assignment';
            END IF;

            PERFORM public.send_push_notification_fnc(
                v_rider_user_id,
                'New Order Request',
                'You have a new order request nearby!',
                jsonb_build_object(
                    'type', v_notification_type,
                    'order_id', NEW.order_id,
                    'assignment_id', NEW.id
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$function$
;
