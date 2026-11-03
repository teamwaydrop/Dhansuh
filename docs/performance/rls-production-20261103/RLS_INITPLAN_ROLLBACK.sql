-- LOCAL REVIEW ROLLBACK. Defaults to ROLLBACK; explicit approval required.
BEGIN;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '15s';
DO $restore$
DECLARE t text; p record;
BEGIN
  FOREACH t IN ARRAY ARRAY['orders','riders','users','rider_kyc'] LOOP
    SELECT polcmd,polpermissive,polroles,pg_get_expr(polqual,polrelid) AS expression
    INTO p FROM pg_policy WHERE polrelid=to_regclass('public.'||t) AND polname='admin_can_select_'||t;
    IF NOT FOUND OR p.polcmd<>'r' OR NOT p.polpermissive
      OR p.polroles IS DISTINCT FROM ARRAY['authenticated'::regrole::oid]
      OR p.expression IS DISTINCT FROM '( SELECT is_admin() AS is_admin)'
    THEN RAISE EXCEPTION 'Rollback policy drift on %',t; END IF;
    EXECUTE format('ALTER POLICY %I ON public.%I USING (public.is_admin())','admin_can_select_'||t,t);
  END LOOP;
END
$restore$;
ROLLBACK;
