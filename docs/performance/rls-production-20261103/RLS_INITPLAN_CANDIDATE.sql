-- LOCAL REVIEW CANDIDATE. Not applied to production. Defaults to ROLLBACK.
-- Only four existing authenticated SELECT policies change; helper/grants and
-- all write predicates, ownership rules and other policies stay untouched.
BEGIN;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '15s';
DO $guard$
DECLARE table_name text; policy_name text; p record;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE oid='public.is_admin()'::regprocedure
      AND provolatile='s' AND NOT prosecdef
      AND md5(pg_get_functiondef(oid))='193670e935444b315e7919e09dcfc97a'
  ) THEN RAISE EXCEPTION 'is_admin function drift: stop for review'; END IF;
  FOREACH table_name IN ARRAY ARRAY['orders','riders','users','rider_kyc'] LOOP
    policy_name := 'admin_can_select_' || table_name;
    SELECT polcmd,polpermissive,polroles,pg_get_expr(polqual,polrelid) AS expression
      INTO p FROM pg_policy
      WHERE polrelid=to_regclass('public.'||table_name) AND polname=policy_name;
    IF NOT FOUND OR p.polcmd<>'r' OR NOT p.polpermissive
      OR p.polroles IS DISTINCT FROM ARRAY['authenticated'::regrole::oid]
      OR p.expression IS DISTINCT FROM 'is_admin()'
    THEN RAISE EXCEPTION 'Policy drift on %',policy_name; END IF;
    EXECUTE format('ALTER POLICY %I ON public.%I USING ((SELECT public.is_admin()))',policy_name,table_name);
  END LOOP;
END
$guard$;
ROLLBACK;
