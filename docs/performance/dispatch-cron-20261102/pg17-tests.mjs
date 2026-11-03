// Synthetic PostgreSQL 17 only: fixed loopback/port/database; no remote URL input.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../../..');
const exe=path.join(root,'.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe');
const db='waydrop_part3_test',results=[];
const uid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const q=s=>"'"+String(s).replaceAll("'","''")+"'";
async function sql(input,database=db){
 assert.ok([db,'postgres'].includes(database));
 return await new Promise((resolve,reject)=>{
  const child=spawn(exe,['-X','-q','-A','-t','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d',database,'-v','ON_ERROR_STOP=1'],{windowsHide:true,env:{...process.env,PGCONNECT_TIMEOUT:'3',PGOPTIONS:'-c statement_timeout=20000 -c lock_timeout=3000'}});
  let out='',err='';child.stdout.on('data',b=>out+=b);child.stderr.on('data',b=>err+=b);child.on('error',reject);child.on('close',n=>n?reject(Error(err)):resolve(out.trim()));child.stdin.end(input);
 });
}
async function test(name,fn){try{const detail=await fn();results.push({name,status:'PASS',detail});console.log('PASS '+name);}catch(e){results.push({name,status:'FAIL',error:String(e)});console.error('FAIL '+name+': '+e.message);}}
if(await sql(`SELECT 1 FROM pg_database WHERE datname=${q(db)}`,'postgres')!=='1')await sql(`CREATE DATABASE ${db}`,'postgres');
await sql(`DO $$ BEGIN IF current_database()<>'${db}' OR inet_server_addr()<>inet '127.0.0.1' OR inet_server_port()<>54329 THEN RAISE EXCEPTION 'Synthetic loopback required'; END IF; END $$;`);
const fixture=JSON.parse(await fs.readFile(path.join(root,'docs/production-performance/local-tests/fixture-source.json'),'utf8'));
let ddl=await fs.readFile(path.join(root,'docs/production-performance/local-tests/generated-fixture.sql'),'utf8');
assert.ok(ddl.includes("current_database() IS DISTINCT FROM 'waydrop_perf_test'"));
ddl=ddl.replaceAll('waydrop_perf_test',db);
await sql(ddl);
await sql(`DROP SCHEMA IF EXISTS vault CASCADE; DROP SCHEMA IF EXISTS net CASCADE;
CREATE SCHEMA vault; CREATE TABLE vault.decrypted_secrets(name text,decrypted_secret text); INSERT INTO vault.decrypted_secrets VALUES('supabase_service_role_key','synthetic-only');
CREATE TABLE local_http_enqueue(id bigserial PRIMARY KEY,body jsonb);
CREATE SCHEMA IF NOT EXISTS net;
CREATE FUNCTION net.http_post(url text,headers jsonb,body jsonb,timeout_milliseconds int) RETURNS bigint LANGUAGE sql AS $$ INSERT INTO public.local_http_enqueue(body) VALUES(body) RETURNING id $$;
CREATE TABLE local_observation(key text PRIMARY KEY,n int DEFAULT 0); INSERT INTO local_observation VALUES('audit_exceptions',0),('core_calls',0);
INSERT INTO users VALUES(${q(uid(9000))}),(${q(uid(9001))}); INSERT INTO government_tax_config VALUES(100,true,now());
INSERT INTO dispatch_config(config_code,round_2_radius_km,rider_location_stale_sec,max_search_duration_sec,rider_response_timeout_sec) VALUES('PART3',5,60,420,120);`);
function synthetic(c,n){if(c.type==='uuid')return uid(100000+n);if(c.type==='date')return '1990-01-01';if(c.type==='timestamptz')return new Date().toISOString();if(c.type==='bool')return true;if(['numeric','int4','float8'].includes(c.type))return 1;if(c.type==='aadhaar')return '000000000001';const en=fixture.enums.find(e=>e.typname===c.type);return en?en.labels[0]:'SYNTHETIC-'+n;}
async function insert(table,n,extra){const values=Object.fromEntries(fixture.columns.filter(c=>c.table===table&&c.nullable==='NO'&&!c.default).map(c=>[c.name,synthetic(c,n)]));Object.assign(values,extra);await sql(`INSERT INTO ${table}(${Object.keys(values).map(k=>'"'+k+'"')}) VALUES(${Object.values(values).map(v=>v===null?'NULL':q(v))})`);}
await insert('rider_kyc',101,{id:uid(101),user_id:uid(9001),full_name:'Synthetic Rider',aadhaar_number:'000000000001',pan_number:'ABCDE0001F',date_of_birth:'1990-01-01',vehicle_number:'TEST-PART3',vehicle_type:'bike',kyc_status:'approved',activation_status:'active'});
await insert('riders',201,{id:uid(201),user_id:uid(9001),kyc_id:uid(101),account_status:'online',service_mode:'local',current_lat:17,current_lng:79,last_location_updated_at:new Date().toISOString(),government_tax_due_balance:0,cod_pending_amount:0,cod_limit:500});
async function order(id,extra={}){await insert('orders',id,{id:uid(id),user_id:uid(9000),order_code:'PART3-'+id,order_type:'ride',order_status:'searching',vehicle_type:'bike',distance_meters:1000,distance_km:1,pickup_lat:17,pickup_lng:79,destination_lat:17.01,destination_lng:79,actual_fare:100,current_fare:100,rider_earning:80,...extra});}
const coreCall=`SELECT public.assign_nearby_searching_orders_core(${q(uid(201))},${q(uid(9001))},17,79,'local');`;
async function install(name,version,instrument=false){let body=await fs.readFile(path.join(here,`${name}.${version}.sql`),'utf8');if(instrument)body=body.replace(/EXCEPTION WHEN OTHERS THEN\s+NULL;/g,"EXCEPTION WHEN OTHERS THEN UPDATE public.local_observation SET n=n+1 WHERE key='audit_exceptions';");await sql(body);}
await test('orphan recovery selector, fresh-lease exclusion and boundaries',async()=>{
 await order(7001,{dispatch_worker_running:true,dispatch_worker_started_at:new Date(Date.now()-180000).toISOString()});
 await order(7002,{dispatch_worker_running:true,dispatch_worker_started_at:new Date().toISOString()});
 await order(7003,{dispatch_worker_running:true,dispatch_worker_started_at:null});
 await order(7004,{dispatch_worker_running:false,dispatch_worker_started_at:null});
 await order(7005,{order_status:'cancelled',dispatch_worker_running:true,dispatch_worker_started_at:new Date(Date.now()-180000).toISOString()});
 await order(7006,{created_at:new Date(Date.now()-600000).toISOString(),dispatch_worker_running:true,dispatch_worker_started_at:null});
 await install('redispatch_stalled_searching_orders','before');await sql('SELECT redispatch_stalled_searching_orders();');
 const before=JSON.parse(await sql("SELECT coalesce(jsonb_agg(body->>'order_id'),'[]') FROM local_http_enqueue"));
 assert.deepEqual(before,[uid(7004)]);
 await sql('TRUNCATE local_http_enqueue;');await install('redispatch_stalled_searching_orders','candidate');await sql('SELECT redispatch_stalled_searching_orders();');
 const after=JSON.parse(await sql("SELECT coalesce(jsonb_agg(body->>'order_id'),'[]') FROM local_http_enqueue"));
 assert.deepEqual(after.sort(),[uid(7001),uid(7003),uid(7004)]);
 await sql("UPDATE orders SET order_status='cancelled';");return {before,after,freshLeaseEnqueued:false,terminalEnqueued:false,outOfLifetimeEnqueued:false};
});
await test('real worker CAS: 12 contenders, null lease recovery, stale release fencing',async()=>{
 await order(7010,{dispatch_worker_running:true,dispatch_worker_started_at:null});
 const claim=stamp=>`UPDATE orders SET dispatch_worker_running=true,dispatch_worker_started_at=${q(stamp)} WHERE id=${q(uid(7010))} AND order_status='searching' AND dispatch_worker_running=true AND dispatch_worker_started_at IS NULL RETURNING id;`;
 const stamps=Array.from({length:12},(_,i)=>new Date(Date.now()+i).toISOString());
 const claims=await Promise.all(stamps.map(stamp=>sql(claim(stamp))));assert.equal(claims.filter(Boolean).length,1);
 const started=await sql(`SELECT dispatch_worker_started_at::text FROM orders WHERE id=${q(uid(7010))}`);
 assert.equal(await sql(`UPDATE orders SET dispatch_worker_running=false WHERE id=${q(uid(7010))} AND dispatch_worker_started_at='2000-01-01' RETURNING id`),'');
 assert.equal(await sql(`SELECT dispatch_worker_running FROM orders WHERE id=${q(uid(7010))}`),'t');
 await sql(`UPDATE orders SET order_status='accepted' WHERE id=${q(uid(7010))}`);
 assert.equal(await sql(`UPDATE orders SET dispatch_worker_running=true WHERE id=${q(uid(7010))} AND order_status='searching' RETURNING id`),'');
 await sql(`UPDATE orders SET order_status='cancelled' WHERE id=${q(uid(7010))}`);return {contenders:12,winners:1,lease:started,oldReleaseChangedRows:0,terminalClaimChangedRows:0};
});
await test('audit conflicts eliminated; valid boosted expired/rejected re-offers survive',async()=>{
 await order(7020);const observations=[];
 for(const version of ['before','candidate']){
  await install('assign_nearby_searching_orders_core',version,true);
  await sql(`DELETE FROM rider_assignments WHERE order_id=${q(uid(7020))}; DELETE FROM order_assignment_logs WHERE order_id=${q(uid(7020))}; UPDATE local_observation SET n=0;`);
  await sql(coreCall);
  for(let i=0;i<6;i++)await sql(`UPDATE rider_assignments SET assignment_status=${q(i%2?'rejected':'expired')},hidden_until=now()-interval '1 minute' WHERE order_id=${q(uid(7020))}; UPDATE orders SET rider_earning=rider_earning+1 WHERE id=${q(uid(7020))};`+coreCall);
  const exceptions=Number(await sql("SELECT n FROM local_observation WHERE key='audit_exceptions'"));
  assert.equal(await sql(`SELECT assignment_status FROM rider_assignments WHERE order_id=${q(uid(7020))}`),'sent');
  assert.equal(await sql(`SELECT count(*) FROM order_assignment_logs WHERE order_id=${q(uid(7020))}`),'1');
  observations.push({version,reoffers:6,auditExceptions:exceptions});
 }
 assert.deepEqual(observations.map(x=>x.auditExceptions),[6,0]);
 await sql(`UPDATE rider_assignments SET assignment_status='rejected',hidden_until=now()+interval '4 minutes' WHERE order_id=${q(uid(7020))}; UPDATE orders SET rider_earning=rider_earning+1 WHERE id=${q(uid(7020))};`+coreCall);
 assert.equal(await sql(`SELECT assignment_status FROM rider_assignments WHERE order_id=${q(uid(7020))}`),'rejected');
 await sql(`UPDATE rider_assignments SET assignment_status='accepted' WHERE order_id=${q(uid(7020))};`+coreCall);
 assert.equal(await sql(`SELECT assignment_status FROM rider_assignments WHERE order_id=${q(uid(7020))}`),'accepted');
 await sql(`UPDATE orders SET order_status='cancelled' WHERE id=${q(uid(7020))}`);return {observations,cooldownPreserved:true,alreadyAcceptedNotReoffered:true};
});
await test('empty-search freed sweep does zero rematch calls; nonempty fallback retained',async()=>{
 await sql("UPDATE orders SET order_status='cancelled';");
 const original=await fs.readFile(path.join(here,'assign_nearby_searching_orders_core.before.sql'),'utf8');
 await sql(original.replaceAll('assign_nearby_searching_orders_core','part3_core_body'));
 await sql(`CREATE OR REPLACE FUNCTION assign_nearby_searching_orders_core(p_rider_id uuid,p_rider_user_id uuid,p_current_lat float8,p_current_lng float8,p_service_mode partner_service_mode_enum) RETURNS void LANGUAGE plpgsql AS $$ BEGIN UPDATE local_observation SET n=n+1 WHERE key='core_calls'; PERFORM part3_core_body(p_rider_id,p_rider_user_id,p_current_lat,p_current_lng,p_service_mode); END $$;`);
 await sql(`UPDATE orders SET rider_id=${q(uid(201))},updated_at=now() WHERE id=${q(uid(7005))}`);
 const counts=[];
 for(const version of ['before','candidate']){await install('redispatch_freed_riders',version);await sql("UPDATE local_observation SET n=0 WHERE key='core_calls'; SELECT redispatch_freed_riders(); SELECT redispatch_freed_riders(); SELECT redispatch_freed_riders();");counts.push(Number(await sql("SELECT n FROM local_observation WHERE key='core_calls'")));}
 assert.deepEqual(counts,[3,0]);await order(7030);await sql('SELECT redispatch_freed_riders();');assert.equal(await sql("SELECT n FROM local_observation WHERE key='core_calls'"),'1');
 await install('assign_nearby_searching_orders_core','candidate');return {threeEmptySweepsCoreCallsBefore:counts[0],after:counts[1],nonemptyCoreCalls:1};
});
await test('12 overlapping rematch calls retain one offer and one notification effect',async()=>{
 await sql("UPDATE orders SET order_status='cancelled';");await order(7040);
 await Promise.all(Array.from({length:12},()=>sql(coreCall)));
 assert.equal(await sql(`SELECT count(*) FROM rider_assignments WHERE order_id=${q(uid(7040))}`),'1');
 assert.equal(await sql(`SELECT count(*) FROM order_assignment_logs WHERE order_id=${q(uid(7040))}`),'1');
 assert.equal(await sql(`SELECT count(*) FROM local_push_capture WHERE data->>'order_id'=${q(uid(7040))}`),'1');
 return {contenders:12,assignmentRows:1,auditRows:1,notificationEffects:1};
});
await fs.writeFile(path.join(here,'PG17_RESULTS.json'),JSON.stringify({database:db,host:'127.0.0.1',port:54329,synthetic:true,productionChanged:false,limits:'Real captured functions and synthetic schema; pg_net is a local queue capture, no managed Auth/Realtime/FCM parity claimed.',results},null,2)+'\n');
if(results.some(r=>r.status==='FAIL'))process.exitCode=1;
