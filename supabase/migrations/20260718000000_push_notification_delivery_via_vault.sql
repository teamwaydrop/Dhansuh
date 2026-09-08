-- Fixes push notification delivery: deliver_push_notification_http_fnc previously read its
-- service-role key from `current_setting('app.settings.supabase_service_role_key', true)`,
-- set via `ALTER DATABASE postgres SET ...` (20260716000011). That statement requires
-- superuser privileges that the `postgres` role does not have on this hosted project
-- (`permission denied to set parameter "app.settings.supabase_url"`, verified directly), so
-- it was never actually run — meaning no push notification has ever been delivered for any
-- event in this app (the row still lands in public.notifications; only the outbound HTTP
-- call to send-push-notification was silently skipped every time, via this function's
-- existing fail-open RAISE WARNING + RETURN).
--
-- Fix: read the service-role key from Supabase Vault (`supabase_vault` extension, already
-- installed) instead of a database-level GUC. Vault doesn't require superuser to populate —
-- only `vault.create_secret(...)`, run once via the Dashboard SQL Editor (deliberately NOT
-- included in this migration file, since it would otherwise commit the live secret to git).
-- The URL is not sensitive (already present in multiple other migrations/edge functions in
-- this repo) so it stays a literal rather than also being vaulted.
--
-- This function still fails open (RAISE WARNING + RETURN) if the vault secret hasn't been
-- created yet, matching the previous behavior for the same reason: a missing notification
-- config must never break the caller's transaction (e.g. accepting a booking).

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
    v_supabase_url text := 'https://yvwpchffctiagevpqgwy.supabase.co';
    v_service_role_key text;
BEGIN
    SELECT decrypted_secret INTO v_service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_service_role_key'
    LIMIT 1;

    IF v_service_role_key IS NULL THEN
        RAISE WARNING 'Push notification delivery skipped: vault secret "supabase_service_role_key" is not configured. Run vault.create_secret(...) once via the Supabase Dashboard SQL Editor.';
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
