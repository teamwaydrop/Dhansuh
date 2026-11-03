import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../../..');
const exe=path.join(root,'.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe');
function sql(input){const r=spawnSync(exe,['-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d','waydrop_perf_test'],{input,encoding:'utf8',windowsHide:true});if(r.status)throw Error(r.stderr);return r.stdout.trim();}
const definitionHash=sql("SELECT md5(pg_get_functiondef('public.claim_order_assignment_atomic(uuid,uuid,uuid)'::regprocedure));");
const indexDefinition=sql("SELECT pg_get_indexdef('public.rider_assignments_one_accepted_per_order'::regclass);");
const guard=`DO $guard$ BEGIN
  IF current_setting('app.acceptance_rollback_traffic_drained',true) IS DISTINCT FROM 'approved' THEN
    RAISE EXCEPTION 'Pause and drain acceptance traffic before object rollback';
  END IF;
  IF md5(pg_get_functiondef('public.claim_order_assignment_atomic(uuid,uuid,uuid)'::regprocedure)) IS DISTINCT FROM '${definitionHash}' THEN
    RAISE EXCEPTION 'Acceptance function definition drift';
  END IF;
  IF pg_get_indexdef('public.rider_assignments_one_accepted_per_order'::regclass) IS DISTINCT FROM '${indexDefinition.replaceAll("'","''")}' THEN
    RAISE EXCEPTION 'Accepted-assignment index drift';
  END IF;
END $guard$;`;
await fs.writeFile(path.join(here,'02_rollback_atomic_acceptance.sql'),`-- REVIEW ONLY. No business rows are restored or deleted. Requires traffic drain.
-- Restore a reviewed Edge bundle only while acceptance remains paused. v60 has the known race.
BEGIN;
SET LOCAL lock_timeout='1s';
SET LOCAL statement_timeout='15s';
${guard}
DROP FUNCTION public.claim_order_assignment_atomic(uuid,uuid,uuid) RESTRICT;
DROP INDEX public.rider_assignments_one_accepted_per_order;
ROLLBACK;
`);
await fs.writeFile(path.join(here,'03_disable_atomic_rpc.sql'),`-- Emergency fail-closed option for the NEW handler. Keep the uniqueness index.
-- Review/approval required; this file defaults to ROLLBACK.
BEGIN;
SET LOCAL lock_timeout='1s';
DO $$ BEGIN IF md5(pg_get_functiondef('public.claim_order_assignment_atomic(uuid,uuid,uuid)'::regprocedure)) IS DISTINCT FROM '${definitionHash}' THEN RAISE EXCEPTION 'Acceptance function drift'; END IF; END $$;
REVOKE EXECUTE ON FUNCTION public.claim_order_assignment_atomic(uuid,uuid,uuid) FROM service_role;
ROLLBACK;
`);
const source=await fs.readFile(path.join(here,'01_atomic_acceptance.sql'),'utf8');
await fs.writeFile(path.join(here,'01_atomic_acceptance.deploy.sql'),source.replace(/ROLLBACK;\s*$/,'COMMIT;\n'));
const files=['01_atomic_acceptance.sql','01_atomic_acceptance.deploy.sql','02_rollback_atomic_acceptance.sql','03_disable_atomic_rpc.sql'];
const artifacts=[];for(const file of files){const body=await fs.readFile(path.join(here,file));artifacts.push({file:'docs/production-performance/acceptance/'+file,sha256:createHash('sha256').update(body).digest('hex')});}
const edge=await fs.readFile(path.join(root,'supabase/functions/accept-order/index.ts'));artifacts.push({file:'supabase/functions/accept-order/index.ts',sha256:createHash('sha256').update(edge).digest('hex')});
await fs.writeFile(path.join(here,'RELEASE_MANIFEST.json'),JSON.stringify({status:'LOCAL_VERIFIED_PRODUCTION_NOT_APPROVED',localPgGetFunctionDefMd5:definitionHash,indexDefinition,files:artifacts},null,2)+'\n');
console.log('Prepared guarded SQL rollback, fail-closed switch and exact release hashes.');
