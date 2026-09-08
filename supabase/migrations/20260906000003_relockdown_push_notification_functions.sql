-- Migration: re-lock the 4 push-notification functions left PUBLIC-executable.
-- Date: 2026-09-06
-- Audit finding H2 (WayDrop Production Release Readiness & Security Audit, 2026-09-06).
--
-- ============================================================================================
-- ROOT CAUSE
-- ============================================================================================
-- All four functions below are SECURITY DEFINER, OWNER `postgres`, and carry NO caller-identity
-- check of their own. Their ACL on production is still NULL (PostgreSQL's default
-- `EXECUTE TO PUBLIC`), so `anon` and `authenticated` retain EXECUTE and PostgREST exposes each
-- as a callable `POST /rest/v1/rpc/<name>` endpoint. Verified live 2026-09-06:
--   proacl = NULL for all four; has_function_privilege('anon' | 'authenticated', oid, 'execute')
--   = true for all four.
--
-- Migration `20260715000002_revoke_public_notification_rpcs.sql` was written to fix exactly this
-- (prior finding "C8"): it REVOKEs all four FROM PUBLIC and GRANTs them to service_role/postgres.
-- It is recorded in `supabase_migrations.schema_migrations` but its DDL NEVER TOOK EFFECT on
-- production (the live ACL is still the untouched default, confirmed against both the 2026-09-01
-- and 2026-08-24 production schema dumps). This matches the documented "migration recorded but
-- not applied" drift pattern already noted in
-- `20260718000004_reapply_search_path_hardening_batch.sql` and re-hit by Phase 1
-- (`20260716000005` / `20260724000000` role-guard trigger). This migration RE-APPLIES the
-- lockdown forward-only; it does not edit the earlier file.
--
--   * send_push_notification_fnc(uuid, text, text, jsonb)  -- HIGH
--       INSERTs a row into `public.notifications` for a CALLER-SUPPLIED `p_user_id` with
--       CALLER-SUPPLIED `p_title` / `p_body` / `p_data`. Directly callable => any signed-in user
--       sends an arbitrary push (phishing / spam) to ANY other user; the insert also fires
--       `on_notification_insert` -> FCM delivery.
--
--   * send_admin_push_notification(text, text, text, text, jsonb)  -- HIGH
--       Fans the above out to every rider / every non-rider user / ALL users (optionally
--       city-filtered). Directly callable => any signed-in user broadcasts to the entire user
--       base. Retained as a callable RPC for the admin panel (see LEGITIMATE CALLERS) but gated
--       in-body to admin / service-role sessions only.
--
--   * deliver_push_notification_http_fnc(uuid, text, text, jsonb)  -- HIGH
--       Reads the `supabase_service_role_key` from Vault and `net.http_post`s it (as a Bearer
--       token) to `/functions/v1/send-push-notification` with a caller-supplied body. Directly
--       callable => forged FCM sends AND the service-role key is used on behalf of an
--       unauthenticated caller.
--
--   * check_dormant_riders()  -- MEDIUM/HIGH
--       Scans riders and emits dormancy / expiry push notifications. Directly callable => a user
--       triggers the entire dormant-rider notification sweep on demand (spam amplification).
--
-- ============================================================================================
-- LEGITIMATE CALLERS  (traced exhaustively 2026-09-06: live `pg_get_functiondef` over every
-- public function, `cron.job`, and grep over lib/*.dart + supabase/functions/*.ts)
-- ============================================================================================
--   send_push_notification_fnc:
--     - NO Flutter `.rpc(...)` call.  NO edge-function `.rpc(...)` call (name appears only in
--       source comments in send-push-notification/index.ts and notification_detail_screen.dart).
--     - ONLY `PERFORM public.send_push_notification_fnc(...)` from inside these functions, ALL
--       SECURITY DEFINER + OWNER postgres (verified live):
--         expire_stale_intercity_requests, generate_intercity_delivery_otp_after_proof,
--         on_intercity_request_change, on_new_chat_message, on_rider_assignment_change,
--         on_rider_location_near_destination, on_rider_review_insert,
--         on_rider_wallet_balance_update, regenerate_intercity_delivery_otp,
--         send_order_status_notifications_core (both overloads), send_admin_push_notification.
--
--   deliver_push_notification_http_fnc:
--     - NO Flutter call.  NO edge-function call.
--     - ONLY `PERFORM public.deliver_push_notification_http_fnc(...)` from
--       `on_notification_insert()` (AFTER INSERT trigger on public.notifications; SECURITY
--       DEFINER, OWNER postgres).
--
--   check_dormant_riders:
--     - NO Flutter call.  NO edge-function call.  NO PL/pgSQL caller.
--     - ONLY the pg_cron job `rider-dormant-and-expiry-checks` (`0 * * * *`,
--       `SELECT public.check_dormant_riders();`) -- runs as `postgres`.
--
--   send_admin_push_notification:
--     - NO Flutter call.  NO edge-function call.  NO PL/pgSQL caller in this repo.
--     - Invoked by the external WayDrop admin panel (docs/10_Admin.md S2.2: "System-Wide Alerts
--       ... using the `send_admin_push_notification` database function"). Per docs/10_Admin.md
--       S1 the admin panel authenticates through Supabase Auth as a user whose email is in
--       `public.admins`, i.e. it calls this RPC with an authenticated admin JWT.
--       `DEPLOYMENT_CHECKLIST.md` codifies the intended posture: an authenticated NON-admin must
--       be rejected; `has_function_privilege('anon', 'send_admin_push_notification(...)',
--       'execute')` must be false.
--
-- ============================================================================================
-- WHY THIS DOES NOT BREAK ANY LEGITIMATE CALLER
-- ============================================================================================
--   1. Every internal `PERFORM` caller of send_push_notification_fnc /
--      deliver_push_notification_http_fnc is a SECURITY DEFINER function OWNED BY `postgres`;
--      the owner always retains EXECUTE regardless of any REVOKE, and the inner call runs with
--      `current_user = postgres`. The pg_cron caller of check_dormant_riders runs as `postgres`.
--      => the three pure-internal functions keep working after `REVOKE ... FROM PUBLIC`.
--   2. send_admin_push_notification stays GRANTable to `authenticated` so the admin-panel JWT
--      can still reach it; a prepended guard rejects any authenticated session that is not an
--      admin (`public.is_admin()` = EXISTS row in public.admins for `auth.email()` and
--      is_active). A service-role / pg_cron / dashboard session has `auth.uid()` NULL and is
--      allowed (mirrors the Phase 1 `prevent_role_self_escalation` session model and the
--      existing in-body `is_admin()` gating on `admin_search_*`). Its PERFORM of
--      send_push_notification_fnc runs as `postgres` (owner) -> unaffected by that REVOKE.
--   3. This is the identical posture already applied to complete_order_and_settle,
--      initiate_withdrawal, credit_rider_for_completed_order (Phase 1), etc.
--
-- NOTHING ELSE changes: no FCM / token-storage / template / notification-content logic, no RLS
-- policy, no trigger, no schema. send_admin_push_notification's fan-out body is reproduced
-- byte-for-byte from the live definition (pg_get_functiondef, 2026-09-06) with ONLY the guard
-- prepended.
-- ============================================================================================

-- -------------------------------------------------------------------------------------------
-- 1. Pure-internal functions: PUBLIC loses EXECUTE; service_role keeps it (owner postgres
--    retains it implicitly and covers every SECURITY DEFINER / pg_cron path).
-- -------------------------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.send_push_notification_fnc(uuid, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.deliver_push_notification_http_fnc(uuid, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.check_dormant_riders() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.send_push_notification_fnc(uuid, text, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.deliver_push_notification_http_fnc(uuid, text, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.check_dormant_riders() TO service_role;

-- -------------------------------------------------------------------------------------------
-- 2. send_admin_push_notification: body reproduced verbatim from the live definition with a
--    prepended admin / service-role guard. PUBLIC (incl. anon) loses EXECUTE; `authenticated`
--    keeps it so the admin-panel JWT can call in, but a non-admin authenticated session is
--    rejected by the guard.
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.send_admin_push_notification(
    p_recipient_type text,
    p_city text,
    p_title text,
    p_body text,
    p_data jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id uuid;
BEGIN
    -- H2 guard: block a real end-user session that is not an admin. A service-role key,
    -- pg_cron, and the dashboard SQL console all carry no `sub` claim => auth.uid() IS NULL
    -- => allowed. An admin-panel JWT (email in public.admins, is_active) => is_admin() true
    -- => allowed. Any other authenticated user => rejected.
    IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
        RAISE EXCEPTION
            'send_admin_push_notification may only be called by an admin session or a backend service role.'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF p_recipient_type = 'riders' THEN
        FOR v_user_id IN
            SELECT DISTINCT r.user_id
            FROM public.riders r
            WHERE p_city IS NULL OR EXISTS (
                SELECT 1 FROM public.orders o
                WHERE o.rider_id = r.id AND (o.pickup_city = p_city OR o.destination_city = p_city)
                LIMIT 1
            )
        LOOP
            PERFORM public.send_push_notification_fnc(v_user_id, p_title, p_body, p_data);
        END LOOP;

    ELSIF p_recipient_type = 'users' THEN
        FOR v_user_id IN
            SELECT DISTINCT u.id
            FROM public.users u
            WHERE (p_city IS NULL OR EXISTS (
                SELECT 1 FROM public.orders o
                WHERE o.user_id = u.id AND (o.pickup_city = p_city OR o.destination_city = p_city)
                LIMIT 1
            ))
            AND NOT EXISTS (SELECT 1 FROM public.riders r WHERE r.user_id = u.id)
        LOOP
            PERFORM public.send_push_notification_fnc(v_user_id, p_title, p_body, p_data);
        END LOOP;

    ELSE
        FOR v_user_id IN
            SELECT id FROM public.users u
            WHERE p_city IS NULL OR EXISTS (
                SELECT 1 FROM public.orders o
                WHERE o.user_id = u.id AND (o.pickup_city = p_city OR o.destination_city = p_city)
                LIMIT 1
            )
        LOOP
            PERFORM public.send_push_notification_fnc(v_user_id, p_title, p_body, p_data);
        END LOOP;
    END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.send_admin_push_notification(text, text, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_admin_push_notification(text, text, text, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_admin_push_notification(text, text, text, text, jsonb) TO service_role;
