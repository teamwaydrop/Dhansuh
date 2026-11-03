// Native PostgreSQL 17, synthetic loopback DB only. No remote connection input.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../../..');
const exe=path.join(root,'.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe');
const uid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const q=v=>"'"+String(v).replaceAll("'","''")+"'";
async function sql(input){return new Promise((resolve,reject)=>{
  const c=spawn(exe,['-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d','waydrop_perf_test'],{windowsHide:true,env:{...process.env,PGCONNECT_TIMEOUT:'3',PGOPTIONS:'-c statement_timeout=15000 -c lock_timeout=3000'}});let out='',err='';c.stdout.on('data',b=>out+=b);c.stderr.on('data',b=>err+=b);c.on('error',reject);c.on('close',n=>n?reject(Error(err)):resolve(out.trim()));c.stdin.end(input);
});}
const results=[];
async function test(name,fn){try{const detail=await fn();results.push({name,status:'PASS',detail});console.log('PASS '+name);}catch(e){results.push({name,status:'FAIL',error:String(e)});console.error('FAIL '+name+': '+e.message);}}
function request(id,rider=201,actor=9001){return `SELECT public.claim_order_assignment_atomic(${q(uid(id))},${q(uid(rider))},${q(uid(actor))});`;}
const service=body=>"BEGIN; SET LOCAL ROLE service_role; SET LOCAL request.jwt.claim.role='service_role'; "+body+' COMMIT;';
const call=async(id,rider=201,actor=9001)=>JSON.parse(await sql(service(request(id,rider,actor))));
const snapshot=async id=>JSON.parse(await sql(`SELECT jsonb_build_object('order',(SELECT to_jsonb(o) FROM orders o WHERE id=${q(uid(id))}),'assignments',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM rider_assignments a WHERE order_id=${q(uid(id))}),'logs',(SELECT jsonb_agg(to_jsonb(l) ORDER BY id) FROM order_assignment_logs l WHERE order_id=${q(uid(id))}),'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM local_push_capture e WHERE data->>'order_id'=${q(uid(id))}));`));
async function seed(id,riders=[201,207]){
  await sql(`DELETE FROM orders WHERE id=${q(uid(id))}; INSERT INTO orders SELECT (jsonb_populate_record(NULL::orders,to_jsonb(o)||jsonb_build_object('id',${q(uid(id))},'order_code','ATOMIC-${id}','rider_id',NULL,'order_status','searching','current_fare',100,'final_fare',90,'rider_earning',80,'commission_percentage',10,'gst_percentage',5))).* FROM orders o WHERE id=${q(uid(1000))};`);
  for(const r of riders)await sql(`INSERT INTO rider_assignments(order_id,rider_id,expires_at,estimated_earnings) VALUES(${q(uid(id))},${q(uid(r))},now()+interval '5 minutes',80); INSERT INTO order_assignment_logs(order_id,rider_id,assignment_round,assignment_status) VALUES(${q(uid(id))},${q(uid(r))},1,'sent');`);
}
async function clear(){await sql(`DELETE FROM local_push_capture WHERE data->>'order_id' BETWEEN ${q(uid(4000))} AND ${q(uid(4999))} OR data->>'order_id' IN (${q(uid(3000))},${q(uid(5000))}); DELETE FROM orders WHERE order_code LIKE 'ATOMIC-%' OR order_code IN ('SYNTHETIC-RACE','REST-ACCEPT');`);}
await sql("DO $$ BEGIN IF current_database()<>'waydrop_perf_test' OR inet_server_addr()<>inet '127.0.0.1' OR inet_server_port()<>54329 THEN RAISE EXCEPTION 'Loopback test DB required'; END IF; END $$;");
const guards=JSON.parse(await fs.readFile(path.join(here,'production-guards.json'),'utf8'));
for(const g of guards)await sql(g.definition+';');
await sql(`DROP TRIGGER IF EXISTS local_order_state_guard ON orders; DROP TRIGGER IF EXISTS local_order_financial_guard ON orders; DROP TRIGGER IF EXISTS local_order_mode_guard ON orders;
CREATE TRIGGER local_order_state_guard BEFORE UPDATE OF order_status,rider_id,pickup_otp,delivery_otp ON orders FOR EACH ROW EXECUTE FUNCTION protect_order_state_columns();
CREATE TRIGGER local_order_financial_guard BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION protect_order_financial_columns();
CREATE TRIGGER local_order_mode_guard BEFORE UPDATE OF rider_id ON orders FOR EACH ROW EXECUTE FUNCTION enforce_order_rider_service_mode();
CREATE OR REPLACE FUNCTION local_accept_event() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.order_status='accepted' AND OLD.order_status IS DISTINCT FROM NEW.order_status THEN INSERT INTO local_push_capture(user_id,title,body,data) VALUES(NEW.user_id,'accept','synthetic',jsonb_build_object('type','local_accept','order_id',NEW.id)); END IF; RETURN NEW; END $$;
DROP TRIGGER IF EXISTS local_accept_event_trigger ON orders; CREATE TRIGGER local_accept_event_trigger AFTER UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION local_accept_event();
CREATE OR REPLACE FUNCTION local_accept_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.assignment_status='accepted' AND current_setting('app.local_accept_fault',true)='true' THEN RAISE EXCEPTION 'Injected assignment failure'; END IF; RETURN NEW; END $$;
DROP TRIGGER IF EXISTS local_accept_fault_trigger ON rider_assignments; CREATE TRIGGER local_accept_fault_trigger BEFORE INSERT OR UPDATE ON rider_assignments FOR EACH ROW EXECUTE FUNCTION local_accept_fault();
CREATE OR REPLACE FUNCTION local_commit_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.order_status='accepted' AND current_setting('app.local_commit_fault',true)='true' THEN RAISE EXCEPTION 'Injected commit failure'; END IF; RETURN NEW; END $$;
DROP TRIGGER IF EXISTS local_commit_fault_trigger ON orders; CREATE CONSTRAINT TRIGGER local_commit_fault_trigger AFTER UPDATE ON orders DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION local_commit_fault();`);
await test('7 riders racing one order: one success, six 409s, one accepted assignment',async()=>{
  await clear();const riders=[201,207,225,231,237,243,249];await seed(4000,riders);
  const out=await Promise.all(riders.map(r=>call(4000,r,9000+r-200)));assert.equal(out.filter(v=>v.http_status===200).length,1);assert.equal(out.filter(v=>v.http_status===409).length,6);
  const s=await snapshot(4000);assert.equal(s.assignments.filter(a=>a.assignment_status==='accepted').length,1);assert.ok(s.assignments.filter(a=>a.rider_id!==s.order.rider_id).every(a=>a.assignment_status==='expired'));assert.equal(s.order.final_fare,90);return {responses:out.map(v=>v.http_status)};
});
await test('Losing request changes no order, assignment, log or captured event',async()=>{
  const before=await snapshot(4000);const loser=before.order.rider_id===uid(201)?207:201;assert.equal((await call(4000,loser,9000+loser-200)).http_status,409);assert.deepEqual(await snapshot(4000),before);
});
await test('12 duplicate requests: idempotent responses, one event, stable timestamps/fares',async()=>{
  await clear();await seed(4001);const out=await Promise.all(Array.from({length:12},()=>call(4001)));assert.ok(out.every(v=>v.http_status===200));assert.equal(out.filter(v=>v.idempotent).length,11);const before=await snapshot(4001);await call(4001);assert.deepEqual(await snapshot(4001),before);assert.equal(before.events.filter(e=>e.data.type==='local_accept').length,1);
});
await test('One rider racing two orders is serialized: only one order accepted',async()=>{
  await clear();await seed(4002);await seed(4003);const out=await Promise.all([call(4002),call(4003)]);assert.deepEqual(out.map(v=>v.http_status).sort(),[200,400]);const states=await Promise.all([snapshot(4002),snapshot(4003)]);assert.equal(states.filter(s=>s.order.order_status==='accepted').length,1);assert.equal(states.filter(s=>s.order.order_status==='searching').length,1);
});
await test('Wrong owner, missing actor and client roles cannot accept or spoof service access',async()=>{
  await clear();await seed(4004);const before=await snapshot(4004);assert.equal((await call(4004,201,9007)).http_status,403);
  for(const role of ['anon','authenticated'])await assert.rejects(sql(`BEGIN; SET LOCAL ROLE ${role}; SET LOCAL request.jwt.claim.role='service_role'; ${request(4004)} COMMIT;`),/permission denied/);
  await assert.rejects(sql(request(4004)),/Service-role caller required/);assert.deepEqual(await snapshot(4004),before);
  assert.equal(JSON.parse(await sql(service(`SELECT public.claim_order_assignment_atomic(${q(uid(4004))},${q(uid(201))},NULL);`))).http_status,400);
});
await test('Pinned transaction snapshots fail closed instead of allowing cross-order write skew',async()=>{
  for(const isolation of ['REPEATABLE READ','SERIALIZABLE'])await assert.rejects(sql(`BEGIN ISOLATION LEVEL ${isolation}; SET LOCAL ROLE service_role; SET LOCAL request.jwt.claim.role='service_role'; ${request(4004)} COMMIT;`),/READ COMMITTED/);
});
await test('Locked eligibility: service mode, offline, tax and COD exclusions preserved',async()=>{
  for(const [id,rider,actor,status,code]of [[4005,202,9002,403,'WRONG_SERVICE_MODE'],[4006,211,9011,400,null],[4007,219,9019,403,'TAX_DUE_THRESHOLD_BLOCKED'],[4008,223,9023,403,'COD_LIMIT_EXCEEDED']]){
    await clear();await seed(id,[]);const before=await snapshot(id);const out=await call(id,rider,actor);assert.equal(out.http_status,status);if(code)assert.equal(out.code,code);assert.deepEqual(await snapshot(id),before);
  }
});
await test('No prior offer creates a valid accepted assignment and expiry atomically',async()=>{
  await clear();await seed(4009,[]);const out=await call(4009);assert.equal(out.http_status,200);assert.equal(out.assignment.assignment_status,'accepted');assert.ok(new Date(out.assignment.expires_at)>new Date(out.assignment.sent_at));assert.equal(out.assignment.estimated_earnings,80);
});
await test('Expired/rejected/user-approved offers and subscription promo fare preserved',async()=>{
  for(const status of ['expired','rejected','accepted_by_user']){await clear();await seed(4010);await sql(`UPDATE rider_assignments SET assignment_status=${q(status)} WHERE order_id=${q(uid(4010))} AND rider_id=${q(uid(201))};`);const out=await call(4010);assert.equal(out.http_status,200);assert.equal(out.order.current_fare,100);assert.equal(out.order.final_fare,90);assert.equal(out.order.commission_amount,9.52);assert.equal(out.order.rider_earning,90.48);}
  await clear();await seed(4011);await sql(`UPDATE riders SET subscription_active=true,subscription_expires_at='2099-01-01' WHERE id=${q(uid(201))};`);
  try{const out=await call(4011);assert.equal(out.order.commission_amount,0);assert.equal(out.order.final_fare,90);assert.equal(out.order.rider_earning,100);}finally{await sql(`UPDATE riders SET subscription_active=false,subscription_expires_at=NULL WHERE id=${q(uid(201))};`);}
});
await test('Assignment-trigger failure rolls back claimed order, expired offers, logs and notifications',async()=>{
  await clear();await seed(4012);const before=await snapshot(4012);await assert.rejects(sql(service("SET LOCAL app.local_accept_fault='true'; "+request(4012))),/Injected assignment failure/);assert.deepEqual(await snapshot(4012),before);assert.equal((await call(4012)).http_status,200);
});
await test('Deferred commit failure and lost-response retry leave no partial commit',async()=>{
  await clear();await seed(4013);const before=await snapshot(4013);await assert.rejects(sql(service("SET LOCAL app.local_commit_fault='true'; "+request(4013))),/Injected commit failure/);assert.deepEqual(await snapshot(4013),before);assert.equal((await call(4013)).http_status,200);const committed=await snapshot(4013);assert.equal((await call(4013)).idempotent,true);assert.deepEqual(await snapshot(4013),committed);
});
await test('Unique accepted constraint rejects independent/legacy writer',async()=>{
  await assert.rejects(sql(`UPDATE rider_assignments SET assignment_status='accepted' WHERE order_id=${q(uid(4013))} AND rider_id=${q(uid(207))};`),/rider_assignments_one_accepted_per_order/);assert.equal((await snapshot(4013)).assignments.filter(a=>a.assignment_status==='accepted').length,1);
});
await test('Caller rollback and lock timeout leave acceptance state untouched',async()=>{
  await clear();await seed(4014);const before=await snapshot(4014);await sql(service(request(4014)).replace(/COMMIT;$/,'ROLLBACK;'));assert.deepEqual(await snapshot(4014),before);
  const blocked=sql(`BEGIN; SELECT id FROM riders WHERE id=${q(uid(201))} FOR NO KEY UPDATE; SELECT pg_sleep(0.5); COMMIT;`);await new Promise(r=>setTimeout(r,150));await assert.rejects(sql(service("SET LOCAL lock_timeout='50ms'; "+request(4014))),/lock timeout/);await blocked;assert.deepEqual(await snapshot(4014),before);
});
await test('Concurrent dispatch INSERT of the winning pair is reconciled by the atomic upsert',async()=>{
  await clear();await seed(4015,[]);
  await sql(`CREATE OR REPLACE FUNCTION local_accept_pause() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF current_setting('app.local_accept_pause',true)='true' AND NEW.order_status='accepted' THEN PERFORM pg_sleep(0.5); END IF; RETURN NEW; END $$; CREATE TRIGGER local_accept_pause_trigger AFTER UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION local_accept_pause();`);
  try{const pending=sql(service("SET LOCAL app.local_accept_pause='true'; "+request(4015)));await new Promise(r=>setTimeout(r,180));await sql(`INSERT INTO rider_assignments(order_id,rider_id,expires_at,estimated_earnings) VALUES(${q(uid(4015))},${q(uid(201))},now()+interval '5 minutes',80);`);assert.equal(JSON.parse(await pending).http_status,200);assert.equal((await snapshot(4015)).assignments.filter(a=>a.assignment_status==='accepted').length,1);}finally{await sql('DROP TRIGGER local_accept_pause_trigger ON orders; DROP FUNCTION local_accept_pause();');}
});
await test('Self orders are rejected and eligible intercity modes preserve fare/promo behavior',async()=>{
  await clear();await seed(4016,[]);await sql(`UPDATE orders SET user_id=${q(uid(9001))} WHERE id=${q(uid(4016))};`);const before=await snapshot(4016);assert.equal((await call(4016)).http_status,400);assert.deepEqual(await snapshot(4016),before);
  for(const type of ['intercity_ride','intercity_parcel']){await clear();await seed(4017,[]);await sql(`UPDATE orders SET order_type=${q(type)},vehicle_type='cab',actual_weight_kg=12 WHERE id=${q(uid(4017))};`);const out=await call(4017,206,9006);assert.equal(out.http_status,200);assert.equal(out.order.final_fare,90);assert.equal(out.order.commission_amount,9.52);assert.equal(out.assignment.assignment_status,'accepted');}
});
const report={status:results.every(r=>r.status==='PASS')?'PASS':'FAIL',engine:await sql('SELECT version();'),productionConnected:false,results,limits:['Auth/PostgREST transport and pg_net/Realtime delivery still require managed integration.','Fault triggers and notification capture are local test instrumentation, not production DDL.']};
await fs.writeFile(path.join(here,'ATOMIC_RESULTS.json'),JSON.stringify(report,null,2)+'\n');if(report.status==='FAIL')process.exitCode=1;
