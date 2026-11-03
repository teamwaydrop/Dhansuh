-- READ ONLY. Run only after the staging project identity is verified.
-- Save the complete result privately before applying any DDL. Function bodies
-- may contain server-only implementation details; do not publish this snapshot.
WITH wanted_functions(signature) AS (VALUES
 ('public.expire_stale_searching_orders()'),
 ('public.redispatch_stalled_searching_orders()'),
 ('public.expire_stale_active_orders()'),
 ('public.expire_stale_intercity_requests()'),
 ('public.redispatch_freed_riders()'),
 ('public.assign_new_order_to_nearby_online_riders_core(uuid)'),
 ('public.send_order_status_notifications_core(uuid,text,text,text,integer,text,text,uuid,uuid,text,text)'),
 ('public.handle_promo_usage_changes()'),
 ('public.validate_and_calculate_promo(character varying,numeric,uuid)'),
 ('public.fail_withdrawal(uuid,jsonb)'),
 ('public.complete_withdrawal(uuid,text,text,jsonb)'),
 ('public.expire_trip_sharing_tokens()'),
 ('public.check_otp_lockout(character varying)'),
 ('public.log_otp_attempt(character varying,boolean,character varying,character varying,character varying)')
), function_snapshot AS (
 SELECT w.signature, p.oid IS NOT NULL AS object_exists,
   pg_get_userbyid(p.proowner) AS owner,
   pg_get_functiondef(p.oid) AS definition, p.proconfig AS settings,
   p.prosecdef AS security_definer,
   (SELECT coalesce(jsonb_agg(jsonb_build_object(
     'grantor', pg_get_userbyid(a.grantor),
     'grantee', CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
     'privilege', a.privilege_type, 'grantable', a.is_grantable)), '[]'::jsonb)
    FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a) AS grants
 FROM wanted_functions w LEFT JOIN pg_proc p ON p.oid=to_regprocedure(w.signature)
), view_snapshot AS (
 SELECT c.relname AS name, pg_get_userbyid(c.relowner) AS owner,
   pg_get_viewdef(c.oid,true) AS definition, c.reloptions AS options,
   (SELECT coalesce(jsonb_agg(jsonb_build_object(
     'grantor', pg_get_userbyid(a.grantor),
     'grantee', CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
     'privilege', a.privilege_type, 'grantable', a.is_grantable)), '[]'::jsonb)
    FROM aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a) AS grants
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relkind='v'
   AND c.relname IN ('parcel_compliance_view','parcel_security_timeline_view')
), table_snapshot AS (
 SELECT c.relname AS name,c.relrowsecurity AS rls_enabled,c.relforcerowsecurity AS rls_forced,
   (SELECT jsonb_agg(jsonb_build_object('column',a.attname,'type',format_type(a.atttypid,a.atttypmod),
     'not_null',a.attnotnull,'default',pg_get_expr(d.adbin,d.adrelid)) ORDER BY a.attnum)
    FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
    WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped) AS columns
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relkind IN ('r','p')
   AND c.relname IN ('users','rider_kyc','rider_payout_accounts')
), trigger_snapshot AS (
 SELECT c.relname AS table_name,t.tgname AS name,t.tgenabled AS enabled,
   pg_get_triggerdef(t.oid,true) AS definition,
   pg_get_functiondef(t.tgfoid) AS function_definition
 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
 JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND NOT t.tgisinternal
   AND c.relname IN ('users','rider_kyc','rider_payout_accounts')
)
SELECT jsonb_build_object(
 'captured_at',now(),'database',current_database(),'server_version',current_setting('server_version'),
 'functions',(SELECT jsonb_agg(to_jsonb(f) ORDER BY f.signature) FROM function_snapshot f),
 'views',(SELECT jsonb_agg(to_jsonb(v) ORDER BY v.name) FROM view_snapshot v),
 'tables',(SELECT jsonb_agg(to_jsonb(t) ORDER BY t.name) FROM table_snapshot t),
 'triggers',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.table_name,t.name),'[]'::jsonb) FROM trigger_snapshot t),
 'policies',(SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.tablename,p.policyname),'[]'::jsonb)
   FROM pg_policies p WHERE p.schemaname='public' AND p.tablename IN ('users','rider_kyc','rider_payout_accounts')),
 'public_schema_create',jsonb_build_object(
   'anon',has_schema_privilege('anon','public','CREATE'),
   'authenticated',has_schema_privilege('authenticated','public','CREATE'))
) AS staging_security_snapshot;
