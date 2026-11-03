// Test-only install/update. The production proposal always refuses object drift.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../../..');
const exe=path.join(root,'.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe');
function sql(input){const r=spawnSync(exe,['-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d','waydrop_perf_test'],{input,encoding:'utf8',windowsHide:true});if(r.status)throw Error(r.stderr);return r.stdout.trim();}
const guard="DO $$ BEGIN IF current_database() IS DISTINCT FROM 'waydrop_perf_test' OR inet_server_addr() IS DISTINCT FROM inet '127.0.0.1' OR inet_server_port() IS DISTINCT FROM 54329 THEN RAISE EXCEPTION 'Synthetic loopback database required'; END IF; END $$;";
const source=await fs.readFile(path.join(here,'01_atomic_acceptance.sql'),'utf8');
if(sql("SELECT to_regprocedure('public.claim_order_assignment_atomic(uuid,uuid,uuid)') IS NOT NULL;")==='t'){
  const body=source.slice(source.indexOf('CREATE FUNCTION public.claim_order_assignment_atomic'),source.lastIndexOf('ROLLBACK;')).replace('CREATE FUNCTION public.claim_order_assignment_atomic','CREATE OR REPLACE FUNCTION public.claim_order_assignment_atomic');
  sql('BEGIN;'+guard+body+'COMMIT;');
}else sql(guard+source.replace(/ROLLBACK;\s*$/,'COMMIT;'));
console.log('Native local acceptance RPC installed/refreshed; production not connected.');
