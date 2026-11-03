-- Independently authorized Waydrop read-path optimization. No row/data changes.
-- Preserve four existing SELECT predicates; cache the existing STABLE admin check per statement.
BEGIN;
SET LOCAL lock_timeout='500ms';
SET LOCAL statement_timeout='5s';
LOCK TABLE public.orders, public.rider_kyc, public.riders, public.users IN SHARE ROW EXCLUSIVE MODE;
DO $guard$
DECLARE h text; t text; policy_row record;
BEGIN
  SELECT md5(string_agg(concat_ws('|',schemaname,tablename,policyname,permissive,roles::text,cmd,coalesce(qual,'<null>'),coalesce(with_check,'<null>')),E'\n' ORDER BY tablename,policyname)) INTO h
  FROM pg_policies WHERE schemaname='public' AND tablename IN ('admins','intercity_requests','orders','rider_assignments','rider_kyc','riders','users');
  IF h IS DISTINCT FROM 'b0d69176aaedc8cf3200e599c9bab771' THEN RAISE EXCEPTION 'Policy graph drift; stop'; END IF;

  SELECT md5(string_agg(concat_ws('|',n.nspname,p.proname,pg_get_functiondef(p.oid),coalesce(p.proacl::text,'<null>'),p.proowner::text),E'\n' ORDER BY n.nspname,p.proname)) INTO h
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE (n.nspname='auth' AND p.proname IN ('uid','role','email')) OR (n.nspname='public' AND p.proname IN ('check_is_order_candidate_rider','is_admin'));
  IF h IS DISTINCT FROM '89e1543c74e45ca52ef7bec9774e229f' THEN RAISE EXCEPTION 'Helper/ACL/owner drift; stop'; END IF;

  SELECT md5(string_agg(concat_ws('|',c.relname,c.relrowsecurity::text,c.relforcerowsecurity::text,coalesce(c.relacl::text,'<null>')),E'\n' ORDER BY c.relname)) INTO h
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relname IN ('admins','intercity_requests','orders','rider_assignments','rider_kyc','riders','users');
  IF h IS DISTINCT FROM '41f89ec20da990fbd2df511ccfaa95c8' THEN RAISE EXCEPTION 'Table grants/RLS drift; stop'; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid='public.is_admin()'::regprocedure AND provolatile='s' AND NOT prosecdef
    AND md5(pg_get_functiondef(oid))='193670e935444b315e7919e09dcfc97a')
  THEN RAISE EXCEPTION 'is_admin semantics drift; stop'; END IF;

  FOREACH t IN ARRAY ARRAY['orders','rider_kyc','riders','users'] LOOP
    SELECT polcmd,polpermissive,polroles,pg_get_expr(polqual,polrelid) AS expr,polwithcheck INTO policy_row
      FROM pg_policy WHERE polrelid=to_regclass('public.'||t) AND polname='admin_can_select_'||t;
    IF NOT FOUND OR policy_row.polcmd<>'r' OR NOT policy_row.polpermissive
      OR policy_row.polroles IS DISTINCT FROM ARRAY['authenticated'::regrole::oid] OR policy_row.expr IS DISTINCT FROM 'is_admin()' OR policy_row.polwithcheck IS NOT NULL
    THEN RAISE EXCEPTION 'Target policy drift: %',t; END IF;
    EXECUTE format('ALTER POLICY %I ON public.%I USING ((SELECT public.is_admin()))','admin_can_select_'||t,t);
  END LOOP;
END
$guard$;
DO $verify$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['orders','rider_kyc','riders','users'] LOOP
    IF (SELECT pg_get_expr(polqual,polrelid) FROM pg_policy WHERE polrelid=to_regclass('public.'||t) AND polname='admin_can_select_'||t)
       IS DISTINCT FROM '( SELECT is_admin() AS is_admin)'
    THEN RAISE EXCEPTION 'Unexpected policy rewrite: %',t; END IF;
  END LOOP;
END
$verify$;
COMMIT;
