-- Captured production definition; NOT a deployment script.
CREATE OR REPLACE FUNCTION public.send_push_notification_fnc(p_user_id uuid, p_title text, p_body text, p_data jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_notification_type text := COALESCE(p_data->>'type', 'general');
    v_reference_id uuid := NULL;
    v_reference_type text := NULL;
BEGIN
    -- Extract reference info if present
    IF p_data ? 'order_id' THEN
        BEGIN
            v_reference_id := (p_data->>'order_id')::uuid;
            v_reference_type := 'order';
        EXCEPTION WHEN OTHERS THEN
            -- Ignore formatting errors
        END;
    ELSIF p_data ? 'payment_id' THEN
        BEGIN
            v_reference_id := (p_data->>'payment_id')::uuid;
            v_reference_type := 'payment';
        EXCEPTION WHEN OTHERS THEN
            -- Ignore formatting errors
        END;
    END IF;

    -- Insert into notifications log table (which triggers async HTTP delivery)
    INSERT INTO public.notifications (
        user_id,
        title,
        body,
        notification_type,
        reference_id,
        reference_type,
        payload
    ) VALUES (
        p_user_id,
        p_title,
        p_body,
        v_notification_type,
        v_reference_id,
        v_reference_type,
        p_data
    );
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'send_push_notification_fnc: failed to insert notification for user %: %', p_user_id, SQLERRM;
    BEGIN
        INSERT INTO public.notification_failures (
            failure_stage, source_function, notification_type, reference_id, user_id,
            error_code, error_message
        ) VALUES (
            'insert', 'send_push_notification_fnc', v_notification_type, v_reference_id, p_user_id,
            SQLSTATE, left(SQLERRM, 2000)
        );
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
END;
$function$

