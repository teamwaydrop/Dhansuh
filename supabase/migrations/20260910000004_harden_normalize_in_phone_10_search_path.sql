-- =============================================================================
-- HARDENING FOLLOW-UP to 20260910000003_lawful_disclosure_workflow.sql
--
-- Advisor: function_search_path_mutable -- pin search_path on the phone-
-- normalisation helper so it matches the codebase hardening standard
-- (cf. 20260716000007_harden_security_definer_search_path.sql).
--
-- _normalize_in_phone_10 is LANGUAGE sql IMMUTABLE, SECURITY INVOKER, and calls
-- only pg_catalog builtins (regexp_replace, length, right, coalesce). This
-- changes ONLY the function's search_path config attribute -- the body,
-- signature, volatility, security mode, and behaviour are unchanged.
--
-- Applied to production 2026-09-10 (recorded version 20260909121113).
--
-- ROLLBACK:
--   ALTER FUNCTION public._normalize_in_phone_10(text) RESET search_path;
-- =============================================================================

ALTER FUNCTION public._normalize_in_phone_10(text) SET search_path = 'public';
