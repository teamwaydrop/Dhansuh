-- Migration: Replace hardcoded anon key / functions URL with config reads,
-- and harden deliver_push_notification_http_fnc with SET search_path.
-- Date: 2026-07-16
--
-- M11: A Supabase anon JWT and the functions base URL were inlined directly
-- in 20260602000002_create_notification_triggers.sql:23 (the now-superseded
-- v1 of send_push_notification_fnc) and 20260617000000_add_order_
-- notification_mode.sql:61 (deliver_push_notification_http_fnc, the
-- function that actually performs this HTTP call today). The credential
-- pair is permanently in git history and can't be rotated without editing
-- and re-deploying SQL.
--
-- This redefines deliver_push_notification_http_fnc — the only function
-- where this hardcoded pair is still live/reachable — to read both values
-- from Postgres config (current_setting) instead. The v1 send_push_
-- notification_fnc in 20260602000002 is dead code already fully superseded
-- by the version in 20260617000000_add_order_notification_mode.sql (which
-- just inserts into public.notifications and no longer calls net.http_post
-- directly), so its hardcoded literal is inert and cannot be "fixed" by a
-- new migration without editing that old file directly, which is out of
-- scope here — flagged as a residual risk in the implementation summary.
--
-- REQUIRES A MANUAL, ONE-TIME OPS STEP BEFORE/ALONGSIDE DEPLOYING THIS
-- MIGRATION (not performed here — this session has no live DB access and
-- must not deploy):
--   ALTER DATABASE postgres SET app.settings.supabase_url = 'https://<project-ref>.supabase.co';
--   ALTER DATABASE postgres SET app.settings.supabase_anon_key = '<anon key>';
-- Until those are set, current_setting(..., true) returns NULL and this
-- function logs a warning and skips delivery rather than failing the
-- calling trigger (the same fail-open behavior as the original
-- EXCEPTION WHEN OTHERS handler).
--
-- M12: also adds SET search_path = public, done here rather than in the
-- general hardening migration to avoid two competing redefinitions of the
-- same function in this batch.

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
    v_anon_key text := current_setting('app.settings.supabase_anon_key', true);
BEGIN
    IF v_supabase_url IS NULL OR v_anon_key IS NULL THEN
        RAISE WARNING 'Push notification delivery skipped: app.settings.supabase_url / app.settings.supabase_anon_key are not configured.';
        RETURN;
    END IF;

    PERFORM net.http_post(
        url := v_supabase_url || '/functions/v1/send-push-notification',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_anon_key
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
