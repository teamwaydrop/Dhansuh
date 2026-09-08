-- Migration: restore the users.role / users.is_developer self-escalation guard.
-- Date: 2026-09-06
-- Audit finding H4 (WayDrop Production Release Readiness & Security Audit, 2026-09-06).
--
-- ============================================================================================
-- ROOT CAUSE
-- ============================================================================================
--   1. `public.users` carries `GRANT SELECT,INSERT,...,UPDATE ON TABLE public.users TO
--      authenticated` (table-wide, verified in the 2026-09-01 production dump) and its RLS UPDATE
--      policy "Users can update own profile" is `FOR UPDATE TO authenticated USING (auth.uid() =
--      id)` with NO `WITH CHECK` and NO column restriction. PostgreSQL RLS cannot restrict
--      columns, so a normal authenticated user can
--      `PATCH /rest/v1/users?id=eq.<self>` with `{"role":"admin"}` or `{"is_developer":true}`.
--   2. The `trigger_prevent_role_self_escalation` BEFORE UPDATE trigger that migration
--      `20260716000005_prevent_role_self_escalation.sql` was meant to add is ABSENT from
--      production: the only trigger on `public.users` in the 2026-09-01 schema dump is
--      `trg_populate_user_code` (BEFORE INSERT). The `prevent_role_self_escalation()` FUNCTION is
--      present (extended for `is_developer` by `20260724000000`) but wired to nothing. Migration
--      `20260724000000` did a bare `CREATE OR REPLACE FUNCTION` and (by its own comment) relied on
--      "the existing trigger", which never existed on live.
--
-- IMPACT: a normal user self-grants `is_developer = true` -> the `calculate-order-pricing`
-- "Developer Test Mode" pricing-zone bypass (`calculate-order-pricing/index.ts`:
-- `isDev = is_developer === true || role === "admin"`); or `role = 'admin'` -> chat-visibility
-- exemptions and any future `users.role`-gated path.
--
-- ============================================================================================
-- LEGITIMATE CALLERS
-- ============================================================================================
-- A whole-repo search (lib/*.dart, supabase/functions/*.ts, supabase/migrations/*.sql) found
-- NO code path that writes `users.role` or `users.is_developer`. Role/dev assignment is done
-- out-of-band via the Supabase dashboard / SQL console (session role `postgres`, no JWT) --
-- exactly as documented in `20260716000005`'s own header.
--   * `update-order-status/index.ts` reads `users` (`.select("phone")`) only -- never writes it.
--   * The client writes to `users` are: `upsert({id, phone})` (post-OTP), `update({full_name,
--     email, profile_completed})` (profile setup), `update({onboarding_completed})`,
--     `update({preferred_mode})`, `update({profile_photo_url})`, and the notification-preference
--     / gender single-column updates in profile_tab. NONE touch `role` or `is_developer`.
--   * The SECURITY INVOKER trigger `update_user_average_rating` (AFTER I/U/D on rider_reviews)
--     does `UPDATE users SET rating = ..., rating_sum = ..., total_ratings = ...` while running as
--     the `authenticated` inserting user. Those three columns are deliberately NOT revoked below,
--     so this trigger is unaffected.
--
-- `is_suspended` is intentionally NOT referenced anywhere in this migration: that column
-- DOES NOT EXIST on `public.users` (verified live -- a PostgREST `select=is_suspended` returns
-- HTTP 400 / `42703 column ... does not exist`). The Flutter suspension check reads a
-- non-existent key (`profile['is_suspended'] ?? false`) and always evaluates false; that is a
-- separate, out-of-Phase-1 product bug (the suspension feature is a no-op), not a
-- privilege-escalation vector. Referencing a non-existent column here would raise an error.
--
-- ============================================================================================
-- FIX -- two independent, minimal layers; neither touches business logic or unrelated columns
-- ============================================================================================
--   A. Column-level `REVOKE UPDATE (role, is_developer) ON public.users FROM authenticated, anon`.
--      `authenticated` keeps table UPDATE on every OTHER column and loses it on exactly these
--      two. PostgreSQL checks UPDATE privilege only on the columns actually written, so all
--      legitimate profile / preference / rating writes continue to work; a write that includes
--      `role` or `is_developer` gets `42501 permission denied for column ...`. `service_role` is
--      unaffected (a column REVOKE from `authenticated`/`anon` does not touch it).
--   B. (Re)attach `trigger_prevent_role_self_escalation`. The guard fires only for a real
--      end-user PostgREST session: a user access token carries a `sub` claim (=> `auth.uid()`
--      IS NOT NULL); the `service_role` key has no `sub` (=> NULL); the dashboard SQL console and
--      pg_cron carry no JWT at all (=> NULL). So out-of-band assignment is never blocked.
-- ============================================================================================

-- -------------------------------------------------------------------------------------------
-- Layer A -- column-level UPDATE privilege
-- -------------------------------------------------------------------------------------------
REVOKE UPDATE (role, is_developer) ON TABLE public.users FROM authenticated;
REVOKE UPDATE (role, is_developer) ON TABLE public.users FROM anon;

-- -------------------------------------------------------------------------------------------
-- Layer B -- trigger guard (function body re-asserted from 20260724000000 with a hardened
-- session check; trigger (re)created)
-- -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prevent_role_self_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF (NEW.role IS DISTINCT FROM OLD.role
        OR NEW.is_developer IS DISTINCT FROM OLD.is_developer) THEN
        -- Block only a real end-user session. `auth.uid()` is non-NULL only when the request
        -- carries a user access token (has a `sub` claim). The service_role key (`{"role":
        -- "service_role"}`, no `sub`) and the dashboard SQL console / pg_cron (no JWT) both yield
        -- NULL here, so legitimate out-of-band role/is_developer assignment is never blocked.
        IF auth.uid() IS NOT NULL
           AND coalesce(auth.role(), 'authenticated') <> 'service_role' THEN
            RAISE EXCEPTION
                'Changing the role or is_developer column is not permitted for this session.'
                USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_prevent_role_self_escalation ON public.users;
CREATE TRIGGER trigger_prevent_role_self_escalation
BEFORE UPDATE ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.prevent_role_self_escalation();
