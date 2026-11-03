// Synthetic local data only; fixed loopback host/port and database names.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../../..');
const runtime=path.join(root,'.dart_tool/waydrop-local-runtime'),bin=path.join(runtime,'postgresql-17.11-core/pgsql/bin');
const flags=['-h','127.0.0.1','-p','54329','-U','waydrop_local'];
const restoreDb=process.argv.includes('--acceptance')?'waydrop_acceptance_restore':'waydrop_perf_restore_verified';
function run(name,args,input){const r=spawnSync(path.join(bin,name+'.exe'),args,{input,encoding:'utf8',windowsHide:true,maxBuffer:8*1024*1024});if(r.error||r.status)throw Error(r.error??r.stderr);return r.stdout.trim();}
function sql(text,db){assert.ok(['waydrop_perf_test','waydrop_perf_restore_verified','waydrop_acceptance_restore'].includes(db));return run('psql',[...flags,'-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-d',db],text);}
const tables=['users','rider_kyc','riders','orders','rider_assignments','order_assignment_logs','rider_locations','dispatch_config','government_tax_config','local_push_capture'];
const fingerprint=`SELECT jsonb_build_object('rows',jsonb_build_object(${tables.map(t=>`'${t}',(SELECT md5(coalesce(string_agg(to_jsonb(t)::text,E'\n' ORDER BY to_jsonb(t)::text),'')) FROM ${t} t)`).join(',')}),'functions',(SELECT md5(string_agg(pg_get_functiondef(p.oid)||p.proowner::text||coalesce(p.proacl::text,''),E'\n' ORDER BY p.oid::regprocedure::text)) FROM pg_proc p WHERE pronamespace IN ('public'::regnamespace,'auth'::regnamespace)),'policies',(SELECT md5(string_agg(to_jsonb(p)::text,E'\n' ORDER BY tablename,policyname)) FROM pg_policies p WHERE schemaname='public'),'indexes',(SELECT md5(string_agg(indexdef,E'\n' ORDER BY indexname)) FROM pg_indexes WHERE schemaname='public'),'triggers',(SELECT md5(string_agg(pg_get_triggerdef(t.oid),E'\n' ORDER BY tgname)) FROM pg_trigger t WHERE NOT tgisinternal AND tgrelid IN (SELECT oid FROM pg_class WHERE relnamespace='public'::regnamespace)));`;
const before=JSON.parse(sql(fingerprint,'waydrop_perf_test'));
const dump=path.join(runtime,'synthetic-verified-recovery.dump');run('pg_dump',[...flags,'-d','waydrop_perf_test','-Fc','-f',dump]);
run('createdb',[...flags,restoreDb]);
run('pg_restore',[...flags,'-d',restoreDb,'--exit-on-error',dump]);
const after=JSON.parse(sql(fingerprint,restoreDb));assert.deepEqual(after,before);
const report={status:'PASS',engine:'PostgreSQL 17.11 Windows',productionConnected:false,syntheticTablesContentHashesMatched:tables.length,functionDefinitionsOwnersACLMatched:true,policyDefinitionsMatched:true,indexDefinitionsMatched:true,triggerDefinitionsMatched:true,fingerprints:after,productionDataRecoveryVerified:false,limitations:'Same-host synthetic restore. No managed Auth, Storage, vault secrets, pg_net, Edge runtime or off-site restore proof.'};
await fs.writeFile(path.join(here,process.argv.includes('--acceptance')?'../acceptance/RESTORE_RESULTS.json':'RESTORE_RESULTS.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
