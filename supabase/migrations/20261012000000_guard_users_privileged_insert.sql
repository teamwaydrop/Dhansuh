-- Close the first-profile INSERT privilege gap without replacing the UPDATE guard.
-- Ordinary callers must start with role='user' and is_developer=false. Omitted
-- fields receive those existing column defaults before BEFORE INSERT runs.
-- Reject non-default values (including explicit NULL), rather than silently
-- rewriting supplied values. Unrelated profile fields are not changed.
--
-- Trusted provisioning matches the previously documented mechanisms:
--   * a verified service_role JWT;
--   * the postgres SQL/dashboard session without an end-user subject.
-- SECURITY INVOKER keeps CURRENT_USER meaningful; a caller's auth subject is
-- still checked if a SECURITY DEFINER routine performs the INSERT as postgres.
-- Do not interpret a missing JWT alone as a trusted provisioning identity.
--
-- INSERT ... ON CONFLICT DO UPDATE runs BEFORE INSERT as well as the existing
-- BEFORE UPDATE guard. Explicit privileged input is therefore rejected even
-- when its target profile already exists. Omitted protected fields remain
-- compatible with the current id/phone and tester-profile upsert payloads.
-- Column-level REVOKE alone cannot defeat the existing table-level grants.
-- This migration does not change grants, RLS, defaults, admins, or existing rows.

BEGIN;

CREATE OR REPLACE FUNCTION public.prevent_privileged_users_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
    IF auth.role() = 'service_role'
       OR (CURRENT_USER = 'postgres' AND auth.uid() IS NULL) THEN
        RETURN NEW;
    END IF;

    IF NEW.role IS DISTINCT FROM 'user'
       OR NEW.is_developer IS DISTINCT FROM false THEN
        RAISE EXCEPTION
            'Privileged initial profile values are not permitted for this session.'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_prevent_privileged_users_insert ON public.users;
CREATE TRIGGER trigger_prevent_privileged_users_insert
BEFORE INSERT ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.prevent_privileged_users_insert();

COMMIT;

-- Reviewed rollback, only if separately approved: remove this new INSERT
-- trigger, then this new function. Leave trigger_prevent_role_self_escalation
-- and prevent_role_self_escalation unchanged. Rollback reopens the INSERT gap.
