CREATE OR REPLACE FUNCTION public.on_order_status_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_supabase_url text := 'https://yvwpchffctiagevpqgwy.supabase.co';
    v_service_role_key text;
BEGIN
    IF OLD.order_status IS DISTINCT FROM NEW.order_status THEN
        BEGIN
            SELECT decrypted_secret INTO v_service_role_key
            FROM vault.decrypted_secrets
            WHERE name = 'supabase_service_role_key'
            LIMIT 1;

            IF v_service_role_key IS NOT NULL THEN
                PERFORM net.http_post(
                    url := v_supabase_url || '/rest/v1/rpc/send_order_status_notifications_core',
                    headers := jsonb_build_object(
                        'Content-Type', 'application/json',
                        'Authorization', 'Bearer ' || v_service_role_key,
                        'apikey', v_service_role_key
                    ),
                    body := jsonb_build_object(
                        'p_order_id', NEW.id,
                        'p_old_status', OLD.order_status,
                        'p_new_status', NEW.order_status,
                        'p_order_type', NEW.order_type,
                        'p_estimated_duration_min', NEW.estimated_duration_min,
                        'p_pickup_otp', NEW.pickup_otp,
                        'p_delivery_otp', NEW.delivery_otp,
                        'p_user_id', NEW.user_id,
                        'p_rider_id', NEW.rider_id,
                        'p_cancelled_by', NEW.cancelled_by,
                        'p_cancel_reason', NEW.cancel_reason
                    ),
                    timeout_milliseconds := 5000
                );
            ELSE
                RAISE WARNING 'on_order_status_update: vault secret "supabase_service_role_key" is not configured -- skipping async notification enqueue for order %', NEW.id;
                BEGIN
                    INSERT INTO public.notification_failures (
                        failure_stage, source_function, notification_type, reference_id, user_id,
                        error_message
                    ) VALUES (
                        'enqueue', 'on_order_status_update', 'order_status', NEW.id, NEW.user_id,
                        'vault secret "supabase_service_role_key" is not configured'
                    );
                EXCEPTION WHEN OTHERS THEN
                    NULL;
                END;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'on_order_status_update: failed to enqueue async notification for order %: %', NEW.id, SQLERRM;
            BEGIN
                INSERT INTO public.notification_failures (
                    failure_stage, source_function, notification_type, reference_id, user_id,
                    error_code, error_message
                ) VALUES (
                    'enqueue', 'on_order_status_update', 'order_status', NEW.id, NEW.user_id,
                    SQLSTATE, left(SQLERRM, 2000)
                );
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
        END;
    END IF;

    RETURN NEW;
END;
$function$
;
