// ONLY connects to a disposable loopback cluster on port 54329. No remote URL input.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
const here=path.dirname(fileURLToPath(import.meta.url));
const root=path.resolve(here,'../../..');
const runtime=path.join(root,'.dart_tool/waydrop-local-runtime');
const bin=path.join(runtime,'postgresql-17.11-core/pgsql/bin');
const backup=path.join(root,'.dart_tool/production_performance_preflight_20261101');
const fixture=JSON.parse(await fs.readFile(path.join(here,'fixture-source.json'),'utf8'));
const q=s=>"'"+String(s).replaceAll("'","''")+"'";
const qi=s=>'"'+s.replaceAll('"','""')+'"';
const uid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const results=[];
async function sql(input,{database='waydrop_perf_test'}={}){
  assert.ok(['waydrop_perf_test','waydrop_perf_restore'].includes(database));
  return await new Promise((resolve,reject)=>{
    const child=spawn(path.join(bin,'psql.exe'),['-X','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d',database,'-A','-t','-v','ON_ERROR_STOP=1','-q'],{windowsHide:true,env:{...process.env,PGCONNECT_TIMEOUT:'3',PGOPTIONS:'-c statement_timeout=15000 -c lock_timeout=3000'}});
    let out='',err='';child.stdout.on('data',b=>out+=b);child.stderr.on('data',b=>err+=b);child.on('error',reject);child.on('close',code=>code?reject(Error(err)):resolve(out.trim()));child.stdin.end(input);
  });
}
async function json(query){return JSON.parse(await sql(`SELECT coalesce(jsonb_agg(t),'[]'::jsonb) FROM (${query})t;`));}
const check=async(name,fn)=>{const start=performance.now();try{const detail=await fn();results.push({name,status:'PASS',duration_ms:Math.round(performance.now()-start),detail});console.log('PASS '+name);}catch(e){results.push({name,status:'FAIL',error:String(e)});console.error('FAIL '+name+': '+e.message);}};
function synthetic(c,n){
  if(c.type==='uuid')return uid(100000+n);
  if(c.type==='date')return '1990-01-01';
  if(c.type==='timestamptz')return '2026-01-01T00:00:00Z';
  if(c.type==='bool')return true;
  if(['numeric','int4','float8'].includes(c.type))return 1;
  if(c.type==='aadhaar')return '000000000000';
  const en=fixture.enums.find(e=>e.typname===c.type);if(en)return en.labels[0];
  return 'SYNTHETIC-'+n;
}
async function insert(table,n,overrides){
  const values=Object.fromEntries(fixture.columns.filter(c=>c.table===table&&c.nullable==='NO'&&!c.default).map(c=>[c.name,synthetic(c,n)]));
  Object.assign(values,overrides);
  await sql(`INSERT INTO ${qi(table)}(${Object.keys(values).map(qi)}) VALUES (${Object.values(values).map(v=>v===null?'NULL':q(v))});`);
}
async function order(n,extra={}){await insert('orders',n,{id:uid(n),user_id:uid(9000),order_code:'TEST-'+n,order_type:'ride',vehicle_type:'bike',distance_meters:1000,distance_km:1,pickup_lat:17,pickup_lng:79,destination_lat:17.01,destination_lng:79,actual_fare:100,current_fare:100,rider_earning:80,payment_mode:'cash',order_status:'searching',...extra});}
async function install(name,proposed){const file=path.join(root,'docs/production-performance/waves',name);const body=await fs.readFile(file,'utf8');if(proposed)await sql(body.replace(/ROLLBACK;\s*$/,'COMMIT;'));else await sql(await fs.readFile(path.join(backup,name.startsWith('01_')?'find_nearby_riders.before.sql':'assign_nearby_searching_orders_core.before.sql'),'utf8'));}
await check('Native PostgreSQL 17 loopback identity',async()=>{const v=await sql('SHOW server_version;');assert.match(v,/^17\./);return v;});
if(results.at(-1).status==='FAIL')throw Error('Cannot proceed without native PostgreSQL 17');
await check('Recreate sanitized types, seven tables, constraints, RLS and relevant real triggers',async()=>{
  // Re-run-safe only inside this fixed synthetic database. No database URL accepted.
  let ddl="DO $$ BEGIN IF current_database() IS DISTINCT FROM 'waydrop_perf_test' OR inet_server_addr() IS DISTINCT FROM inet '127.0.0.1' OR inet_server_port() IS DISTINCT FROM 54329 THEN RAISE EXCEPTION 'Synthetic loopback database required'; END IF; END $$; DROP SCHEMA public CASCADE; CREATE SCHEMA public; DROP SCHEMA IF EXISTS auth CASCADE; CREATE SCHEMA auth;";
  ddl+="DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF; END $$;";
  ddl+="CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$; CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.role',true),'') $$; CREATE FUNCTION auth.email() RETURNS text LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.email',true),'') $$; GRANT USAGE ON SCHEMA auth,public TO anon,authenticated,service_role; GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO anon,authenticated,service_role;";
  for(const en of fixture.enums)ddl+=`CREATE TYPE ${qi(en.typname)} AS ENUM (${en.labels.map(q)});`;
  ddl+='CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS "uuid-ossp";';
  // Unrelated FK targets are key-only placeholders, explicitly excluded from parity claims.
  ddl+='CREATE TABLE users(id uuid PRIMARY KEY); CREATE TABLE admins(id uuid PRIMARY KEY,email text,is_active boolean); CREATE TABLE payments(id uuid PRIMARY KEY); CREATE TABLE user_devices(id uuid PRIMARY KEY); CREATE TABLE pricing_config(id uuid PRIMARY KEY); CREATE TABLE intercity_requests(parcel_id uuid,traveller_id uuid,status text); CREATE TABLE government_tax_config(threshold_amount numeric,is_active boolean,updated_at timestamptz);';
  for(const table of [...new Set(fixture.columns.map(c=>c.table))]){
    ddl+=`CREATE TABLE ${qi(table)} (`+fixture.columns.filter(c=>c.table===table).map(c=>{
      const type=fixture.column_types.find(t=>t.table===table&&t.column===c.name).format;
      return `${qi(c.name)} ${type}${c.default?' DEFAULT '+c.default:''}${c.nullable==='NO'?' NOT NULL':''}`;
    }).join(',')+');';
  }
  for(const c of fixture.constraints.filter(c=>c.type!=='f'))ddl+=`ALTER TABLE ${qi(c.table)} ADD CONSTRAINT ${qi(c.name)} ${c.ddl};`;
  for(const c of fixture.constraints.filter(c=>c.type==='f'))ddl+=`ALTER TABLE ${qi(c.table)} ADD CONSTRAINT ${qi(c.name)} ${c.ddl};`;
  ddl+='CREATE TABLE local_push_capture(id bigserial PRIMARY KEY,user_id uuid,title text,body text,data jsonb); CREATE FUNCTION send_push_notification_fnc(uuid,text,text,jsonb) RETURNS void LANGUAGE sql AS $$ INSERT INTO local_push_capture(user_id,title,body,data) VALUES($1,$2,$3,$4) $$;';
  for(const f of fixture.functions)ddl+=f.definition+';';
  for(const f of fixture.additional_functions)ddl+=f+';';
  ddl+=await fs.readFile(path.join(backup,'find_nearby_riders.before.sql'),'utf8');
  ddl+=await fs.readFile(path.join(backup,'assign_nearby_searching_orders_core.before.sql'),'utf8');
  ddl+='REVOKE ALL ON FUNCTION assign_nearby_searching_orders_core(uuid,uuid,float8,float8,partner_service_mode_enum) FROM PUBLIC; GRANT EXECUTE ON FUNCTION assign_nearby_searching_orders_core(uuid,uuid,float8,float8,partner_service_mode_enum) TO service_role;';
  const triggerNames=['trg_riders_gps_bridge_to_rider_locations','trg_rider_locations_near_destination_check','trigger_enforce_rider_assignment_service_mode','trigger_prevent_local_ride_assignment_to_busy_rider','trigger_rider_assignment_change','trigger_assign_nearby_orders','trigger_prevent_service_mode_switch_during_active_order','protect_rider_financial_columns_trigger'];
  for(const t of fixture.triggers.filter(t=>triggerNames.some(n=>t.ddl.includes(' '+n+' '))))ddl+=t.ddl+';';
  for(const table of ['riders','rider_assignments','rider_locations','orders'])ddl+=`ALTER TABLE ${table} ENABLE ROW LEVEL SECURITY;`;
  for(const p of fixture.policies)ddl+=`CREATE POLICY ${qi(p.policyname)} ON ${qi(p.tablename)} AS ${p.permissive} FOR ${p.cmd} TO ${p.roles.map(r=>r==='public'?'PUBLIC':qi(r)).join(',')}${p.qual?' USING ('+p.qual+')':''}${p.with_check?' WITH CHECK ('+p.with_check+')':''};`;
  ddl+='GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO authenticated,service_role; GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon; CREATE INDEX idx_riders_user_id ON riders(user_id); CREATE INDEX idx_riders_kyc_id ON riders(kyc_id);';
  await fs.writeFile(path.join(here,'generated-fixture.sql'),ddl);await sql(ddl);
  return {tables:7,policies:fixture.policies.length,triggers:triggerNames.length,externalEffects:'captured locally; no pg_net/vault/realtime',unrelatedTables:'key-only FK placeholders'};
});
if(results.at(-1).status==='FAIL')throw Error('Fixture setup failed');
if(process.argv.includes('--with-atomic-acceptance')) {
  for(const f of JSON.parse(await fs.readFile(path.join(here,'fare-source.json'),'utf8'))) await sql(f.definition+';');
  const atomic=await fs.readFile(path.join(here,'../acceptance/01_atomic_acceptance.sql'),'utf8');
  await sql(atomic.replace(/ROLLBACK;\s*$/,'COMMIT;'));
}
await sql(`INSERT INTO users SELECT ('00000000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid FROM generate_series(9000,9100)g; INSERT INTO government_tax_config VALUES(100,true,now()); INSERT INTO dispatch_config(config_code,round_2_radius_km,rider_location_stale_sec) VALUES('TEST',5,60);`);
for(let i=1;i<=60;i++){
  await insert('rider_kyc',i,{id:uid(100+i),user_id:uid(9000+i),full_name:'Synthetic '+i,aadhaar_number:String(i).padStart(12,'0'),pan_number:'ABCDE'+String(i).padStart(4,'0')+'F',date_of_birth:'1990-01-01',vehicle_number:'TEST-'+i,vehicle_type:i%3===0?'cab':i%3===1?'bike':'auto',kyc_status:i%13===0?'rejected':'approved',activation_status:i%17===0?'inactive':'active'});
  await insert('riders',i,{id:uid(200+i),kyc_id:uid(100+i),user_id:uid(9000+i),account_status:i%11===0?'offline':'online',service_mode:i%2===0?'intercity':'local',current_lat:17+(i-30)*0.001,current_lng:79+i*0.00013,last_location_updated_at:new Date().toISOString(),government_tax_due_balance:i%19===0?100:0,cod_pending_amount:i%23===0?500:0,cod_limit:500});
}
for(let i=0;i<8;i++)await order(1000+i,{order_type:fixture.enums.find(e=>e.typname==='order_type_enum').labels[i],actual_weight_kg:i%2?12:5});
await check('Original/proposed matching equivalence across eligibility, radii, exclusions and limits',async()=>{
  const cases=[];for(let i=0;i<8;i++)for(const radius of [0,0.1,2,5,30000,'NaN'])for(const limit of [1,3,100])cases.push(`SELECT * FROM find_nearby_riders(${q(uid(1000+i))},17,79,${q(radius)}::float8,${limit},ARRAY[${q(uid(201))}::uuid])`);
  const capture=async()=>{const v=[];for(const c of cases)v.push(await json(c));return v;};
  const before=await capture();await install('01_find_nearby_riders.sql',true);assert.deepEqual(await capture(),before);return {comparisons:cases.length};
});
await check('Owner/nonowner authorization, RLS GPS update and privileged core denial',async()=>{
  const own=`SET ROLE authenticated; SET request.jwt.claim.sub=${q(uid(9000))};`;
  assert.equal(JSON.parse(await sql(own+`SELECT count(*) FROM find_nearby_riders(${q(uid(1000))},17,79,5,100);`))>0,true);
  assert.equal(await sql(`SET ROLE authenticated; SET request.jwt.claim.sub=${q(uid(9050))}; SELECT count(*) FROM find_nearby_riders(${q(uid(1000))},17,79,5,100);`),'0');
  await assert.rejects(sql(`SET ROLE authenticated; SELECT assign_nearby_searching_orders_core(${q(uid(201))},${q(uid(9001))},17,79,'local');`),/permission denied/);
  assert.equal(await sql(`SET ROLE authenticated; SET request.jwt.claim.sub=${q(uid(9001))}; WITH t AS (UPDATE riders SET current_lat=current_lat WHERE id=${q(uid(202))} RETURNING id) SELECT count(*) FROM t;`),'0');
});
await check('Concurrent real assignment offers and reoffers preserve unique pairs, logs and earnings',async()=>{
  const run=async()=>{
    await sql('TRUNCATE rider_assignments,order_assignment_logs,local_push_capture;');
    const calls=Array.from({length:12},(_,i)=>{const rider=i%2?203:201;return sql(`SELECT assign_nearby_searching_orders_core(${q(uid(rider))},${q(uid(9000+rider-200))},17,79,'local');`);});
    await Promise.all(calls);
    return await json('SELECT order_id,rider_id,assignment_status,distance_km,estimated_earnings FROM rider_assignments ORDER BY order_id,rider_id');
  };
  await install('02_assign_nearby_searching_orders_core.sql',false);const before=await run();assert.ok(before.length>0);
  await install('02_assign_nearby_searching_orders_core.sql',true);assert.deepEqual(await run(),before);
  assert.equal(await sql('SELECT count(*) FROM (SELECT order_id,rider_id,count(*) FROM rider_assignments GROUP BY 1,2 HAVING count(*)>1)t;'),'0');
  await sql("UPDATE rider_assignments SET assignment_status='expired',last_seen_fare=80; UPDATE orders SET rider_earning=95 WHERE order_status='searching';");
  await Promise.all(Array.from({length:6},()=>sql(`SELECT assign_nearby_searching_orders_core(${q(uid(201))},${q(uid(9001))},17,79,'local');`)));
  assert.equal(await sql(`SELECT count(*) FROM rider_assignments WHERE rider_id=${q(uid(201))} AND (assignment_status<>'sent' OR last_seen_fare<>95 OR estimated_earnings<>80);`),'0');
  return {sessions:12,offerPairs:before.length,scope:'Real core DML/unique-key races; final order acceptance RPC is not exercised'};
});
await check('GPS bridge, stationary heartbeat, late ongoing order, notification idempotency and heading-only updates',async()=>{
  await sql('TRUNCATE local_push_capture;');await order(2000,{order_type:'intercity_ride',rider_id:uid(202),order_status:'searching',destination_lat:17,destination_lng:79});
  const heartbeat=`UPDATE riders SET current_lat=17,current_lng=79,last_location_updated_at=clock_timestamp() WHERE id=${q(uid(202))};`;
  await sql(heartbeat);await sql(`UPDATE orders SET order_status='ongoing' WHERE id=${q(uid(2000))};`);await sql(heartbeat);
  assert.equal(await sql(`SELECT near_destination_notified FROM orders WHERE id=${q(uid(2000))};`),'t');
  assert.equal(await sql("SELECT count(*) FROM local_push_capture WHERE data->>'type'='trip_near_destination';"),'1');
  await sql(heartbeat+heartbeat);
  assert.equal(await sql("SELECT count(*) FROM local_push_capture WHERE data->>'type'='trip_near_destination';"),'1');
  const oldHeading=await sql(`SELECT current_heading FROM rider_locations WHERE rider_id=${q(uid(202))};`);
  await sql(`UPDATE riders SET current_heading=123 WHERE id=${q(uid(202))};`);
  assert.equal(await sql(`SELECT current_heading FROM rider_locations WHERE rider_id=${q(uid(202))};`),oldHeading);
  // Production bridge fires UPDATE OF coordinates: heading-only updates intentionally do not bridge.
  await sql(`UPDATE riders SET current_lat=17,current_lng=79,current_heading=124,last_location_updated_at=clock_timestamp() WHERE id=${q(uid(202))};`);
  assert.equal(await sql(`SELECT current_heading FROM rider_locations WHERE rider_id=${q(uid(202))};`),'124');
  return {stationaryArrivalNotifications:1,headingOnlyBridge:'Does not fire by existing UPDATE OF definition; coordinate-targeted heartbeat carries heading'};
});
await check('Index guards, lock timeout, exact recreation and retained UNIQUE constraints',async()=>{
  for(const [n,key]of [[3,'user_id'],[4,'kyc_id']]){
    const drop=await fs.readFile(path.join(here,`../waves/0${n}_drop_idx_riders_${key}.sql`),'utf8');
    await sql(drop);assert.equal(await sql(`SELECT to_regclass('idx_riders_${key}') IS NOT NULL;`),'t');
    const blocker=sql('BEGIN; LOCK TABLE riders IN ACCESS SHARE MODE; SELECT pg_sleep(2); COMMIT;');
    await new Promise(r=>setTimeout(r,300));await assert.rejects(sql(drop.replace(/ROLLBACK;\s*$/,'COMMIT;')),/lock timeout/);await blocker;
    await sql(drop.replace(/ROLLBACK;\s*$/,'COMMIT;'));
    assert.equal(await sql(`SELECT indisunique AND indisvalid FROM pg_index WHERE indexrelid='riders_${key}_key'::regclass;`),'t');
    const restore=await fs.readFile(path.join(here,`../waves/0${n}_restore_idx_riders_${key}.rollback.sql`),'utf8');await sql(restore.replace(/ROLLBACK;\s*$/,'COMMIT;'));
    assert.equal(await sql(`SELECT to_regclass('idx_riders_${key}') IS NOT NULL;`),'t');
  }
});
await check('Matching rollback restores definition hashes, owners and ACL',async()=>{
  for(const [name,n]of [['find_nearby_riders',1],['assign_nearby_searching_orders_core',2]]){
    const meta=JSON.parse(await sql(`SELECT json_build_object('md5',md5(pg_get_functiondef(oid)),'owner',proowner,'acl',proacl) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname=${q(name)};`));
    const rollback=await fs.readFile(path.join(here,`../waves/0${n}_${name}.rollback.sql`),'utf8');
    await sql(rollback.replace('REPLACE_WITH_VERIFIED_POST_DEPLOYMENT_MD5',meta.md5).replace(/ROLLBACK;\s*$/,'COMMIT;'));
    const restored=JSON.parse(await sql(`SELECT json_build_object('md5',md5(pg_get_functiondef(oid)),'owner',proowner,'acl',proacl) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname=${q(name)};`));
    assert.equal(restored.owner,meta.owner);assert.deepEqual(restored.acl,meta.acl);
    const captured=JSON.parse(await fs.readFile(path.join(backup,'catalog.json'),'utf8')).function_backups.find(f=>f.signature.startsWith(name+'('));assert.equal(restored.md5,captured.md5);
  }
});
const report={engine:await sql('SELECT version();'),productionConnected:false,atomicAcceptanceInstalled:process.argv.includes('--with-atomic-acceptance'),results,limitations:['Supabase JWT verification/PostgREST/realtime/WAL delivery/pg_net/vault/cron not reproduced by this suite; see separate acceptance REST tests.','auth claim SQL functions emulate gateway-populated settings. Outbound push calls captured, not delivered.','Unrelated FK targets are key-only placeholders; payment provider and complete payment lifecycle not exercised.']};
await fs.writeFile(path.join(here,'PG17_RESULTS.json'),JSON.stringify(report,null,2)+'\n');
if(results.some(r=>r.status==='FAIL'))process.exitCode=1;
