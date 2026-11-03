-- Captured production definition; NOT a deployment script.
CREATE OR REPLACE FUNCTION public.deliver_push_notification_http_fnc(p_user_id uuid, p_title text, p_body text, p_data jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_supabase_url text := 'https://yvwpchffctiagevpqgwy.supabase.co';
    v_service_role_key text;
    v_notification_id uuid;
BEGIN
    -- Phase 6: best-effort extraction for failure-tracking context only -- never affects delivery,
    -- and a bad/missing value here can never abort the function (guarded sub-block).
    BEGIN
        v_notification_id := NULLIF(p_data->>'notification_id', '')::uuid;
    EXCEPTION WHEN OTHERS THEN
        v_notification_id := NULL;
    END;

    SELECT decrypted_secret INTO v_service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_service_role_key'
    LIMIT 1;

    IF v_service_role_key IS NULL THEN
        RAISE WARNING 'Push notification delivery skipped: vault secret "supabase_service_role_key" is not configured. Run vault.create_secret(...) once via the Supabase Dashboard SQL Editor.';
        BEGIN
            INSERT INTO public.notification_failures (
                failure_stage, source_function, notification_type, reference_id, user_id,
                notification_id, error_message
            ) VALUES (
                'enqueue', 'deliver_push_notification_http_fnc', p_data->>'type',
                NULLIF(p_data->>'reference_id', '')::uuid, p_user_id, v_notification_id,
                'vault secret "supabase_service_role_key" is not configured'
            );
        EXCEPTION WHEN OTHERS THEN
            -- Failure-tracking must never itself introduce a new failure mode.
            NULL;
        END;
        RETURN;
    END IF;

    PERFORM net.http_post(
        url := v_supabase_url || '/functions/v1/send-push-notification',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_service_role_key
        ),
        body := jsonb_build_object(
            'user_id', p_user_id,
            'title', p_title,
            'body', p_body,
            'data', p_data
        ),
        timeout_milliseconds := 5000
    );
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed to send push notification HTTP call: %', SQLERRM;
    BEGIN
        INSERT INTO public.notification_failures (
            failure_stage, source_function, notification_type, reference_id, user_id,
            notification_id, error_code, error_message
        ) VALUES (
            'push_delivery', 'deliver_push_notification_http_fnc', p_data->>'type',
            NULLIF(p_data->>'reference_id', '')::uuid, p_user_id, v_notification_id,
            SQLSTATE, left(SQLERRM, 2000)
        );
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
END;
$function$

