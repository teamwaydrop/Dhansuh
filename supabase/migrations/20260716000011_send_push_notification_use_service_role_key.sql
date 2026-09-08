-- Redefines deliver_push_notification_http_fnc to authenticate to
-- send-push-notification with the service-role key instead of the anon key.
--
-- M2 (follow-up): the edge function's isTrustedServerCaller check accepted
-- SUPABASE_ANON_KEY as a trusted bearer. The anon key ships in every
-- client's .env bundle, so it isn't a secret -- accepting it let anyone who
-- extracted it from an APK send push notifications to an arbitrary user_id,
-- bypassing the per-user auth.getUser() ownership check entirely. The edge
-- function (updated alongside this migration) now only trusts the
-- service-role key; this migration updates the sole internal caller to match.
--
-- REQUIRES A MANUAL, ONE-TIME OPS STEP BEFORE/ALONGSIDE DEPLOYING THIS
-- MIGRATION (not performed here -- this session has no live DB access and
-- must not deploy):
--   ALTER DATABASE postgres SET app.settings.supabase_service_role_key = '<service role key>';
-- The previously-set app.settings.supabase_anon_key value is no longer read
-- by this function. Until the new setting is configured, current_setting
-- returns NULL and this function logs a warning and skips delivery rather
-- than failing the calling trigger (same fail-open behavior as before).

CREATE OR REPLACE FUNCTION public.deliver_push_notification_http_fnc(
    p_user_id uuid,
    p_title text,
    p_body text,
    p_data jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_supabase_url text := current_setting('app.settings.supabase_url', true);
    v_service_role_key text := current_setting('app.settings.supabase_service_role_key', true);
BEGIN
    IF v_supabase_url IS NULL OR v_service_role_key IS NULL THEN
        RAISE WARNING 'Push notification delivery skipped: app.settings.supabase_url / app.settings.supabase_service_role_key are not configured.';
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
END;
$$;
