import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../../..');
const runtime=path.join(root,'.dart_tool/waydrop-local-runtime'),bin=path.join(runtime,'postgresql-17.11-core/pgsql/bin');
const flags=['-h','127.0.0.1','-p','54329','-U','waydrop_local'];
function run(exe,args,input){const r=spawnSync(path.join(bin,exe+'.exe'),args,{input,encoding:'utf8',windowsHide:true,maxBuffer:8*1024*1024,env:{...process.env,PGCONNECT_TIMEOUT:'3'}});if(r.error||r.status)throw Error(r.error??r.stderr);return r.stdout.trim();}
const sql=(s,db='waydrop_perf_test')=>run('psql',[...flags,'-X','-A','-t','-q','-v','ON_ERROR_STOP=1','-d',db],s);
const uid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const sample=statement=>JSON.parse(sql('EXPLAIN(ANALYZE,BUFFERS,WAL,FORMAT JSON) '+statement))[0];
const median=a=>[...a].sort((a,b)=>a-b)[Math.floor(a.length/2)];
const summary=plans=>({samples:plans.length,median_execution_ms:median(plans.map(p=>p['Execution Time'])),min_execution_ms:Math.min(...plans.map(p=>p['Execution Time'])),max_execution_ms:Math.max(...plans.map(p=>p['Execution Time'])),median_wal_bytes:median(plans.map(p=>p.Plan['WAL Bytes']??0))});
sql('UPDATE riders SET last_location_updated_at=clock_timestamp(); ANALYZE;');
const nearby=`SELECT * FROM find_nearby_riders('${uid(1000)}',17,79,5,10);`;
const matching={};
for(const mode of ['original','proposed']){
  const source=await fs.readFile(path.join(root,mode==='original'?'.dart_tool/production_performance_preflight_20261101/find_nearby_riders.before.sql':'docs/production-performance/waves/01_find_nearby_riders.sql'),'utf8');
  sql(mode==='original'?source:source.replace(/ROLLBACK;\s*$/,'COMMIT;'));
  for(let i=0;i<3;i++)sample(nearby);
  matching[mode]=summary(Array.from({length:12},()=>sample(nearby)));
}
sql(await fs.readFile(path.join(root,'.dart_tool/production_performance_preflight_20261101/find_nearby_riders.before.sql'),'utf8'));
const gps={};
const heartbeat=`UPDATE riders SET current_lat=current_lat,current_lng=current_lng,last_location_updated_at=clock_timestamp() WHERE id='${uid(202)}';`;
for(const mode of ['with_duplicate_indexes','without_duplicate_indexes']){
  if(mode.startsWith('without'))for(const [n,key]of [[3,'user_id'],[4,'kyc_id']])sql((await fs.readFile(path.join(here,`../waves/0${n}_drop_idx_riders_${key}.sql`),'utf8')).replace(/ROLLBACK;\s*$/,'COMMIT;'));
  for(let i=0;i<3;i++)sample(heartbeat);
  gps[mode]=summary(Array.from({length:12},()=>sample(heartbeat)));
}
for(const [n,key]of [[3,'user_id'],[4,'kyc_id']])sql((await fs.readFile(path.join(here,`../waves/0${n}_restore_idx_riders_${key}.rollback.sql`),'utf8')).replace(/ROLLBACK;\s*$/,'COMMIT;'));
// Back up and restore SYNTHETIC local data only; never use production connection strings.
const dump=path.join(runtime,'synthetic-recovery.dump');
run('pg_dump',[...flags,'-d','waydrop_perf_test','-Fc','-f',dump]);
run('createdb',[...flags,'waydrop_perf_restore']);
run('pg_restore',[...flags,'-d','waydrop_perf_restore','--exit-on-error',dump]);
const fingerprint="SELECT json_build_object('riders',(SELECT count(*) FROM riders),'orders',(SELECT count(*) FROM orders),'assignments',(SELECT count(*) FROM rider_assignments),'push_capture',(SELECT count(*) FROM local_push_capture),'functions',(SELECT jsonb_agg(md5(pg_get_functiondef(oid)) ORDER BY proname) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('find_nearby_riders','assign_nearby_searching_orders_core')),'policies',(SELECT count(*) FROM pg_policies WHERE schemaname='public'),'indexes',(SELECT count(*) FROM pg_indexes WHERE schemaname='public'));";
const before=JSON.parse(sql(fingerprint));assert.deepEqual(JSON.parse(sql(fingerprint,'waydrop_perf_restore')),before);
const report={scope:'Local Windows PostgreSQL 17.11 only; 60 synthetic riders. Each measured call uses a fresh backend after shared-buffer warmup and includes PL/pgSQL preparation; not a steady-state production benchmark or capacity test.',matching,gps,recovery:{status:'PASS',method:'pg_dump custom archive -> independent local database -> row counts, function hashes, policy/index counts equal',fingerprint:before,productionRecoveryProven:false},limitations:['Microbenchmarks include noise and different cache/WAL states; do not extrapolate percentages to production.','Whole production backups, storage, managed Auth, Edge deployment versions and secrets were not restored.']};
await fs.writeFile(path.join(here,'LOCAL_PERFORMANCE_RECOVERY.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
