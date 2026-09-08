-- Fix: public.send_push_notification_fnc on the live database was still running its original
-- 2026-06-02 body (20260602000002_create_notification_triggers.sql) — a direct net.http_post call
-- to send-push-notification using a hardcoded anon-key bearer token, wrapped in
-- `EXCEPTION WHEN OTHERS` that silently swallows all errors.
--
-- Two later migrations (20260617000000_add_order_notification_mode.sql,
-- 20260716000007_harden_security_definer_search_path.sql) both contain
-- `CREATE OR REPLACE FUNCTION public.send_push_notification_fnc(...)` redefining it to insert into
-- public.notifications instead (the version everything since 20260617000000 was designed around:
-- public.notifications row -> on_notification_insert trigger -> deliver_push_notification_http_fnc
-- -> Vault-sourced service-role key -> actual push). `supabase migration list` reports both as
-- applied (local == remote), but the live function body never actually changed — confirmed directly
-- via pg_get_functiondef against the linked project, and reproduced live: a direct INSERT into
-- intercity_requests committed successfully but produced zero rows in public.notifications,
-- while other notification types (e.g. travel_partners_available, which already calls the
-- newer path some other way) were delivering fine with delivery_status = 'sent'.
--
-- Net effect: every trigger that calls send_push_notification_fnc — on_intercity_request_change
-- (this is why a Travel Together request never notified or visibly alerted the traveller),
-- on_order_status_update, on_new_chat_message, on_rider_assignment_change, on_rider_review_insert,
-- on_rider_wallet_balance_update, check_dormant_riders, expire_stale_intercity_requests,
-- send_admin_push_notification — has been silently no-op'ing: the stale anon key is also now
-- rejected outright by send-push-notification's isTrustedServerCaller check (hardened in
-- 20260716000011 to only trust the service-role key), and the EXCEPTION handler swallows that
-- rejection so nothing ever surfaces, rolls back, or gets logged to public.notifications.
--
-- This migration simply re-applies the already-intended definition verbatim so it actually takes
-- effect this time.

CREATE OR REPLACE FUNCTION public.send_push_notification_fnc(
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
END;
$$;
