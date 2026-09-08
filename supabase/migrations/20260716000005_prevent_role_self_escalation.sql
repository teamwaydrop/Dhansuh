-- Migration: Block non-service-role writes to users.role.
-- Date: 2026-07-16
--
-- No migration in this set explicitly defines or restricts an UPDATE policy
-- on users.role (added in 20260601000009_generic_chat_and_roles.sql), which
-- grants elevated chat visibility to 'admin'/'support' roles. Whether an
-- ordinary authenticated user can currently write their own role column
-- depends entirely on RLS state defined outside this migration set, which
-- cannot be verified without direct access to the live project (no local
-- Supabase CLI/psql session available in this environment).
--
-- Rather than leave this unverified, this adds a BEFORE UPDATE trigger that
-- unconditionally blocks any change to users.role unless the session is
-- using the service_role key. This is safe regardless of the underlying
-- (unverified) RLS state: if self-role-write was already possible, this
-- closes it; if it was already blocked by RLS, this is a no-op layer of
-- defense-in-depth. Confirmed via full-codebase search that no Flutter
-- screen or edge function currently updates users.role at all (role
-- assignment is presumably done out-of-band, e.g. via the Supabase
-- dashboard/SQL console), so this cannot break any existing flow.

CREATE OR REPLACE FUNCTION public.prevent_role_self_escalation()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.role IS DISTINCT FROM OLD.role THEN
        IF auth.role() != 'service_role' THEN
            RAISE EXCEPTION 'Changing the role column is not permitted for this session.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_prevent_role_self_escalation ON public.users;
CREATE TRIGGER trigger_prevent_role_self_escalation
BEFORE UPDATE ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.prevent_role_self_escalation();
