-- =====================================================================
-- Migration: Revoke public EXECUTE on push-notification RPCs (C8)
-- Date: 2026-07-15
-- Description: send_push_notification_fnc, deliver_push_notification_http_fnc,
--              check_dormant_riders, and send_admin_push_notification are all
--              SECURITY DEFINER but were never REVOKEd FROM PUBLIC, unlike
--              other sensitive functions in this codebase (check_otp_lockout,
--              log_otp_attempt, initiate_withdrawal). That left them callable
--              by any authenticated (arguably anonymous) client via
--              rpc/<function_name> — e.g. rpc('send_admin_push_notification', ...)
--              could blast arbitrary push notifications to every user or rider
--              on the platform, or rpc('send_push_notification_fnc', ...) could
--              spoof a targeted notification to any specific user_id.
--
--              Fix: REVOKE EXECUTE FROM PUBLIC and GRANT only to service_role
--              and postgres, matching the pattern already used correctly for
--              check_otp_lockout/log_otp_attempt. These functions are only
--              ever invoked from within other SECURITY DEFINER trigger
--              functions (owned by postgres) or a scheduled pg_cron job
--              (also runs as postgres), so this does not change any existing
--              notification behavior — it only removes public callability.
-- =====================================================================

REVOKE EXECUTE ON FUNCTION public.send_push_notification_fnc(uuid, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_push_notification_fnc(uuid, text, text, jsonb) TO service_role, postgres;

REVOKE EXECUTE ON FUNCTION public.deliver_push_notification_http_fnc(uuid, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.deliver_push_notification_http_fnc(uuid, text, text, jsonb) TO service_role, postgres;

REVOKE EXECUTE ON FUNCTION public.check_dormant_riders() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_dormant_riders() TO service_role, postgres;

REVOKE EXECUTE ON FUNCTION public.send_admin_push_notification(text, text, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_admin_push_notification(text, text, text, text, jsonb) TO service_role, postgres;
