-- =====================================================================
-- P2 FIX: prevent_role_self_escalation() lost its SET search_path hardening.
-- =====================================================================
-- ROOT CAUSE: the function was correctly hardened with `SET search_path = public` in
-- 20260716000007_harden_security_definer_search_path.sql, but
-- 20260724000000_add_developer_test_mode_flag.sql later re-created the function (to add
-- the is_developer column check) by CREATE OR REPLACE-ing the ORIGINAL pre-hardening body,
-- silently dropping the SET clause again. This is a process regression, not an actively
-- exploitable bug today (the function only touches NEW/OLD row fields and the
-- schema-qualified auth.role(), so there's no unqualified call for a hijacked search_path
-- to intercept in this specific function) -- fixed here for defense-in-depth consistency
-- with every other SECURITY DEFINER function in this schema.
--
-- Logic is identical to the current (20260724000000) definition -- only SET search_path is
-- added back.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.prevent_role_self_escalation()
RETURNS TRIGGER AS $$
BEGIN
    IF (NEW.role IS DISTINCT FROM OLD.role OR NEW.is_developer IS DISTINCT FROM OLD.is_developer) THEN
        IF auth.role() != 'service_role' THEN
            RAISE EXCEPTION 'Changing the role or is_developer column is not permitted for this session.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
