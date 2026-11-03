-- Captured production definition; NOT a deployment script.
CREATE OR REPLACE FUNCTION public.on_notification_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    -- Call delivery helper to trigger FCM send-push-notification edge function
    PERFORM public.deliver_push_notification_http_fnc(
        NEW.user_id,
        NEW.title,
        NEW.body,
        NEW.payload || jsonb_build_object(
            'notification_id', NEW.id,
            'type', NEW.notification_type,
            'reference_id', NEW.reference_id,
            'reference_type', NEW.reference_type
        )
    );
    RETURN NEW;
END;
$function$

