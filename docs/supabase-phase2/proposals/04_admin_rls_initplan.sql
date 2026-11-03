-- LOCAL REVIEW PROPOSAL ONLY. NOT EXECUTED. Outside automatic migrations.
-- Requires approved staging differential tests and separate deployment approval.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '15s';
-- Row-independent STABLE admin helper: retain every existing policy audience,
-- ownership predicate and permissive-policy relationship; only cache this check.
DO $policy_guard$
DECLARE t text; p text; old_qual text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid='public.is_admin()'::regprocedure AND provolatile IN ('s','i')) THEN
    RAISE EXCEPTION 'Admin helper is no longer statement-stable';
  END IF;
  FOREACH t IN ARRAY ARRAY['orders','riders','users','rider_kyc'] LOOP
    p := 'admin_can_select_' || t;
    SELECT pg_get_expr(polqual,polrelid) INTO old_qual
    FROM pg_policy WHERE polrelid=to_regclass('public.'||t) AND polname=p;
    IF old_qual IS DISTINCT FROM 'is_admin()' THEN
      RAISE EXCEPTION 'Policy drift on %',p;
    END IF;
    EXECUTE format('ALTER POLICY %I ON public.%I USING ((SELECT public.is_admin()))',p,t);
  END LOOP;
END
$policy_guard$;
ROLLBACK;
