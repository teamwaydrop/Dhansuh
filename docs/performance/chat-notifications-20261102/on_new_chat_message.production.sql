-- Captured production definition; NOT a deployment script.
CREATE OR REPLACE FUNCTION public.on_new_chat_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_recipient_user_id uuid := NULL;
    v_customer_user_id uuid := NULL;
    v_rider_user_id uuid := NULL;
    v_order_rider_id uuid := NULL;
    v_sender_name text := 'Someone';
BEGIN
    -- Get sender name if possible
    SELECT COALESCE(full_name, 'Someone') INTO v_sender_name 
    FROM public.users 
    WHERE id = NEW.sender_id;

    IF NEW.order_id IS NOT NULL THEN
        -- Order chat
        SELECT user_id, rider_id INTO v_customer_user_id, v_order_rider_id 
        FROM public.orders 
        WHERE id = NEW.order_id;
        
        -- Get rider's user_id
        IF NEW.rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;
        ELSIF v_order_rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = v_order_rider_id;
        END IF;

        IF NEW.sender_id = v_customer_user_id THEN
            v_recipient_user_id := v_rider_user_id;
        ELSIF NEW.sender_id = v_rider_user_id THEN
            v_recipient_user_id := v_customer_user_id;
        END IF;
    ELSE
        -- Support chat
        IF NEW.user_id IS NOT NULL AND NEW.sender_id != NEW.user_id THEN
            v_recipient_user_id := NEW.user_id;
        END IF;
    END IF;

    -- Send notification if recipient is determined
    IF v_recipient_user_id IS NOT NULL THEN
        PERFORM public.send_push_notification_fnc(
            v_recipient_user_id,
            v_sender_name,
            NEW.message,
            jsonb_build_object(
                'type', 'chat_message',
                'order_id', NEW.order_id,
                'message_id', NEW.id,
                'sender_type', NEW.sender_type
            )
        );
    END IF;

    RETURN NEW;
END;
$function$

