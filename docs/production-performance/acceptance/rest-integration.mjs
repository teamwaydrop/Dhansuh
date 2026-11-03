// Real local PostgREST + signed JWTs + PG17. Not the managed Supabase gateway.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {createHmac,randomBytes} from 'node:crypto';
import assert from 'node:assert/strict';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../../..');
const runtime=path.join(root,'.dart_tool/waydrop-local-runtime');
const exe=path.join(runtime,'postgresql-17.11-core/pgsql/bin/psql.exe');
const uid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
async function sql(input){return new Promise((ok,bad)=>{const c=spawn(exe,['-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d','waydrop_perf_test'],{windowsHide:true});let out='',err='';c.stdout.on('data',b=>out+=b);c.stderr.on('data',b=>err+=b);c.on('error',bad);c.on('close',n=>n?bad(Error(err)):ok(out.trim()));c.stdin.end(input);});}
const definitions=JSON.parse(await fs.readFile(path.join(here,'auth-helpers.json'),'utf8'));
for(const f of definitions)await sql(f.definition+';');
await sql("DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='waydrop_rest') THEN CREATE ROLE waydrop_rest LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE; END IF; END $$; GRANT anon,authenticated,service_role TO waydrop_rest;");
const secret=randomBytes(48).toString('hex');
const token=(role,extra={})=>{const h=Buffer.from(JSON.stringify({alg:'HS256',typ:'JWT'})).toString('base64url'),p=Buffer.from(JSON.stringify({role,exp:Math.floor(Date.now()/1000)+300,...extra})).toString('base64url');return h+'.'+p+'.'+createHmac('sha256',secret).update(h+'.'+p).digest('base64url');};
const service=token('service_role'),authenticated=token('authenticated',{sub:uid(9001)});
const cfg=path.join(runtime,'postgrest-local.conf');
await fs.writeFile(cfg,`db-uri = "postgresql://waydrop_rest@127.0.0.1:54329/waydrop_perf_test"\ndb-schemas = "public"\ndb-anon-role = "anon"\ndb-pool = 8\ndb-config = false\nserver-host = "127.0.0.1"\nserver-port = 54327\njwt-secret = "${secret}"\n`);
const childEnv=Object.fromEntries(Object.entries(process.env).filter(([k])=>k.toLowerCase()!=='path'));
childEnv.Path=path.dirname(exe)+path.delimiter+(process.env.Path??process.env.PATH??'');
const proc=spawn(path.join(runtime,'postgrest-16.5/postgrest.exe'),[cfg],{windowsHide:true,env:childEnv});const closed=new Promise(r=>proc.once('close',r));let stderr='';proc.stderr.on('data',b=>stderr+=b);proc.stdout.on('data',()=>{});
const results=[];
async function test(name,fn){try{await fn();results.push({name,status:'PASS'});console.log('PASS '+name);}catch(e){results.push({name,status:'FAIL',error:String(e)});console.error('FAIL '+name+': '+e.message);}}
async function request(jwt,body){return await fetch('http://127.0.0.1:54327/rpc/claim_order_assignment_atomic',{method:'POST',headers:{'Content-Type':'application/json',...(jwt?{Authorization:'Bearer '+jwt}:{})},body:JSON.stringify(body)});}
const body=(rider=201)=>({p_order_id:uid(5000),p_rider_id:uid(rider),p_actor_user_id:uid(9000+rider-200)});
try{
  let ready=false;for(let i=0;i<70;i++){try{const r=await fetch('http://127.0.0.1:54327/');if(r.ok){ready=true;break;}}catch{}await new Promise(r=>setTimeout(r,100));}
  if(!ready)throw Error('Local REST startup failed: '+stderr.slice(-1000));
  await sql(`DELETE FROM orders WHERE order_code LIKE 'ATOMIC-%' OR order_code='SYNTHETIC-RACE' OR order_code='REST-ACCEPT'; INSERT INTO orders SELECT (jsonb_populate_record(NULL::orders,to_jsonb(o)||jsonb_build_object('id','${uid(5000)}','order_code','REST-ACCEPT','rider_id',NULL,'order_status','searching','current_fare',100,'final_fare',90,'commission_percentage',10,'gst_percentage',5))).* FROM orders o WHERE id='${uid(1000)}'; INSERT INTO rider_assignments(order_id,rider_id,expires_at) VALUES('${uid(5000)}','${uid(201)}',now()+interval '5 minutes'),('${uid(5000)}','${uid(207)}',now()+interval '5 minutes');`);
  await test('Actual REST JWT verification rejects forged and expired service credentials',async()=>{assert.equal((await request(service+'forged',body())).status,401);assert.equal((await request(token('service_role',{exp:Math.floor(Date.now()/1000)-120}),body())).status,401);});
  await test('Actual REST schema/ACL denies anon and authenticated direct RPC callers',async()=>{const a=await request(null,body());const b=await request(authenticated,body());assert.ok([401,403,404].includes(a.status));assert.ok([401,403,404].includes(b.status));});
  await test('Actual REST service RPC serializes concurrent riders and preserves JSON result',async()=>{const responses=await Promise.all([request(service,body(201)),request(service,body(207))]);const data=await Promise.all(responses.map(r=>r.json()));assert.ok(responses.every(r=>r.status===200));assert.deepEqual(data.map(r=>r.http_status).sort(),[200,409]);const winner=data.find(r=>r.http_status===200);assert.equal(winner.order.final_fare,90);assert.equal(winner.order.commission_amount,9.52);assert.equal(await sql(`SELECT count(*) FROM rider_assignments WHERE order_id='${uid(5000)}' AND assignment_status='accepted';`),'1');});
  await test('Actual REST idempotent retry and wrong actor enforce ownership',async()=>{const rider=await sql(`SELECT rider_id FROM orders WHERE id='${uid(5000)}';`);const n=Number(rider.slice(-12));const r=await request(service,body(n));assert.equal((await r.json()).idempotent,true);const wrong=await request(service,{...body(n),p_actor_user_id:uid(9050)});assert.equal((await wrong.json()).http_status,403);});
  await test('Actual REST retains financial/state column guards for authenticated users',async()=>{const r=await fetch(`http://127.0.0.1:54327/orders?id=eq.${uid(5000)}`,{method:'PATCH',headers:{Authorization:'Bearer '+token('authenticated',{sub:uid(9000)}),'Content-Type':'application/json'},body:JSON.stringify({order_status:'searching',final_fare:1})});assert.ok(r.status>=400);assert.equal(Number(await sql(`SELECT final_fare FROM orders WHERE id='${uid(5000)}';`)),90);});
  // Run the real Supabase SDK against this REST endpoint. A local URL-prefix
  // adapter replaces only the managed /rest/v1 proxy, not JWT/DB/RPC behavior.
  const sdk=path.join(runtime,'sdk-rest-test.ts');
  await fs.writeFile(sdk,`import {createClient} from 'https://esm.sh/@supabase/supabase-js@2';\nconst jwt=Deno.env.get('WAYDROP_LOCAL_JWT')!;\nconst client=createClient('http://127.0.0.1:54327',jwt,{auth:{persistSession:false,autoRefreshToken:false},global:{fetch:(input,init)=>{const u=new URL(typeof input==='string'?input:input instanceof URL?input:input.url);if(u.hostname!=='127.0.0.1'||u.port!=='54327')throw Error('Unexpected target');u.pathname=u.pathname.replace(/^\\/rest\\/v1/,'');return fetch(u,init);}}});\nconst rider=${JSON.stringify(await sql(`SELECT rider_id FROM orders WHERE id='${uid(5000)}';`))};\nconst actor='00000000-0000-4000-8000-'+String(9000+Number(rider.slice(-12))-200).padStart(12,'0');\nconst {data,error}=await client.rpc('claim_order_assignment_atomic',{p_order_id:'${uid(5000)}',p_rider_id:rider,p_actor_user_id:actor});\nif(error||!data?.idempotent)throw Error('SDK RPC integration failed: '+JSON.stringify(error));console.log('SDK RPC PASS');\n`);
  await test('Real locked Supabase SDK RPC succeeds through local signed-JWT REST',async()=>{
    await new Promise((ok,bad)=>{const c=spawn(path.join(runtime,'deno-2.9.8-core/deno.exe'),['run','--config',path.join(here,'../local-tests/deno-runtime.json'),'--cached-only','--frozen-lockfile','--lock='+path.join(here,'../local-tests/deno.lock'),'--allow-net=127.0.0.1:54327','--allow-env=WAYDROP_LOCAL_JWT',sdk],{windowsHide:true,env:{...process.env,DENO_DIR:path.join(runtime,'deno-cache'),DENO_NO_PACKAGE_JSON:'1',WAYDROP_LOCAL_JWT:service}});let err='';c.stdout.on('data',()=>{});c.stderr.on('data',b=>err+=b);c.on('close',n=>n?bad(Error(err)):ok());c.on('error',bad);});
  });
}finally{proc.kill();await closed;await fs.writeFile(path.join(runtime,'postgrest-local.log'),stderr);await fs.rm(cfg,{force:true});}
const report={engine:'PostgREST 16.5 + PostgreSQL 17.11 Windows',productionConnected:false,results,limitations:['Local transport, schema cache, SQL auth helpers, signed-JWT and real SDK verified; managed platform/runtime versions differ.','Managed GoTrue user sessions, Supabase gateway, pg_net/vault, Realtime and production rollback remain unverified.']};
await fs.writeFile(path.join(here,'REST_INTEGRATION_RESULTS.json'),JSON.stringify(report,null,2)+'\n');if(results.some(r=>r.status==='FAIL'))process.exitCode=1;
