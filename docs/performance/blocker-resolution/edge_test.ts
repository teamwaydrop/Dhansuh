// Actual handlers + actual PostgreSQL RPC transactions. Only Auth, preference
// transport and FCM are synthetic. Deno has no outbound network permission.
import assert from 'node:assert/strict';
import {runDurableDispatch} from '../../../supabase/functions/start-dispatch/durable_dispatch.ts';
import {deliveryOutcome,retryAfter,notificationAllowed} from '../../../supabase/functions/send-push-notification/delivery_result.ts';
import {fetchBufferedWithTimeout} from '../../../supabase/functions/_shared/http.ts';
const root=new URL('../../../',import.meta.url);
const psql=new URL('.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe',root).pathname.replace(/^\//,'');
const quote=(v:unknown)=>v===null?'NULL':typeof v==='number'?String(v):"'"+String(v).replaceAll("'","''")+"'";
async function sql(text:string):Promise<string>{
 const child=new Deno.Command(psql,{args:['-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d','waydrop_blocker_test'],stdin:'piped',stdout:'piped',stderr:'piped'}).spawn();
 const writer=child.stdin.getWriter();await writer.write(new TextEncoder().encode("SET request.jwt.claim.role='service_role'; "+text));await writer.close();
 const out=await child.output();if(!out.success)throw Error(new TextDecoder().decode(out.stderr));return new TextDecoder().decode(out.stdout).trim();
}
const uid=(n:number)=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
let fault='',fcm=0,status=200,mixed=false,prefOff=false,enqueueNid='';
const seen:any[]=[];const providerBodies:any[]=[];
const client:any={auth:{getUser:async(token:string)=>({data:{user:token==='invalid'?null:{id:uid(9001)}},error:null})},
 async rpc(name:string,args:Record<string,unknown>){
  assert.match(name,/^(request_order_dispatch|claim_order_dispatch|step_order_dispatch|release_order_dispatch|claim_notification_delivery|begin_notification_device|finish_notification_device)$/);
  if(fault==='before_begin'&&name==='begin_notification_device'){fault='';throw Error('synthetic crash');}
  if(fault==='before_finish'&&name==='finish_notification_device'){fault='';throw Error('synthetic crash');}
  const value=await sql(`SELECT public.${name}(${Object.entries(args).map(([k,v])=>k+'=>'+quote(v)).join(',')})::text;`);
  let data;try{data=JSON.parse(value);}catch(_){data=value==='t'?true:value==='f'?false:value;}
  seen.push({name,args,data});
  if((fault==='after_begin'&&name==='begin_notification_device')||(fault==='after_finish'&&name==='finish_notification_device')||(fault==='after_step'&&name==='step_order_dispatch')){fault='';throw Error('synthetic lost RPC response');}
  return {data,error:null};
 },from(table:string){
  assert.equal(table,'users');const b:any={select(){return b;},eq(){return b;},maybeSingle:async()=>({data:{pref_chat_notifications:!prefOff,pref_order_notifications:true,order_notification_mode:'all'},error:null}),then(ok:any,bad:any){return Promise.resolve({data:{notifications_enabled:true},error:null}).then(ok,bad);}};
  // production_config has a separate call shape; handled below by wrapper.
  return b;
 }};
const originalFrom=client.from;
client.from=(table:string)=> table==='production_config' ? {select(){return this;},limit(){return this;},maybeSingle:async()=>({data:{notifications_enabled:true},error:null})}:originalFrom(table);
(globalThis as any).__pushSupabase=client;
Deno.env.set('SUPABASE_URL','http://127.0.0.1:54328');Deno.env.set('SUPABASE_SERVICE_ROLE_KEY','synthetic-service');
const key=await crypto.subtle.generateKey({name:'RSASSA-PKCS1-v1_5',modulusLength:2048,publicExponent:new Uint8Array([1,0,1]),hash:'SHA-256'},true,['sign','verify']);
const bytes=new Uint8Array(await crypto.subtle.exportKey('pkcs8',key.privateKey));
Deno.env.set('FIREBASE_SERVICE_ACCOUNT_KEY',JSON.stringify({client_email:'synthetic@example.invalid',project_id:'synthetic-project',private_key:'-----BEGIN PRIVATE KEY-----\n'+btoa(String.fromCharCode(...bytes))+'\n-----END PRIVATE KEY-----'}));
const originalFetch=globalThis.fetch;
globalThis.fetch=async(input:any,init:any)=>{
 const url=String(input);
 if(url==='https://oauth2.googleapis.com/token')return Response.json({access_token:'synthetic-oauth',expires_in:3600});
 assert.ok(url.startsWith('https://fcm.googleapis.com/v1/projects/synthetic-project/'));
 fcm++;providerBodies.push(JSON.parse(init.body));
 if(mixed&&fcm%2===0)throw Error('synthetic unknown provider receipt');
 return Response.json(status===200?{name:'synthetic-accepted'}:{error:{details:[{'@type':'type.googleapis.com/google.firebase.fcm.v1.FcmError',errorCode:status===404?'UNREGISTERED':'UNAVAILABLE'}]}},{status});
};
await import('../../../supabase/functions/send-push-notification/index.ts');
const push=(globalThis as any).__pushHandler;
async function seed(devices=1){
 fcm=0;status=200;mixed=false;prefOff=false;fault='';seen.length=0;providerBodies.length=0;
 const nid=crypto.randomUUID();enqueueNid=nid;
 await sql(`DELETE FROM user_device_tokens WHERE user_id='${uid(9001)}';`);
 for(let i=0;i<devices;i++)await sql(`INSERT INTO user_device_tokens(id,user_id,fcm_token,updated_at) VALUES('${crypto.randomUUID()}','${uid(9001)}','synthetic-device-${i}',clock_timestamp());`);
 await sql(`INSERT INTO notifications(id,user_id,title,body,notification_type,payload) VALUES('${nid}','${uid(9001)}','canonical title','canonical body','chat_message','{}');`);
 return nid;
}
function request(nid:string,token='synthetic-service',extra:any={}){return push(new Request('http://localhost/push',{method:'POST',headers:{Authorization:'Bearer '+token},body:JSON.stringify({user_id:uid(9001),title:'forged title',body:'forged body',data:{notification_id:nid},...extra})}));}
async function expire(nid:string){await sql(`UPDATE waydrop_internal.notification_devices SET lease_until=clock_timestamp()-interval '1 second' WHERE notification_id='${nid}';`);}

Deno.test('eight simultaneous full handlers make one provider attempt per device',async()=>{
 const nid=await seed(2);await Promise.all(Array.from({length:8},()=>request(nid)));
 assert.equal(fcm,2);assert.equal(await sql(`SELECT push_sent FROM notifications WHERE id='${nid}'`),'t');
 assert.ok(providerBodies.every(x=>x.message.notification.body==='canonical body'));
 await request(nid);assert.equal(fcm,2);
});
for(const boundary of ['before_begin','after_begin','before_finish','after_finish']){
 Deno.test(`handler interruption at ${boundary} has no duplicate downstream send`,async()=>{
  const nid=await seed();fault=boundary;await request(nid);const sent=fcm;
  await expire(nid);await request(nid);
  if(boundary==='before_begin'){assert.equal(sent,0);assert.equal(fcm,1);}
  else if(boundary==='after_begin'){assert.equal(sent,0);assert.equal(fcm,0);assert.equal(await sql(`SELECT state FROM waydrop_internal.notification_jobs WHERE notification_id='${nid}'`),'uncertain');}
  else {assert.equal(sent,1);assert.equal(fcm,1);}
 });
}
Deno.test('partial device success survives a sibling unknown receipt; no auto-resend',async()=>{
 const nid=await seed(2);mixed=true;await request(nid);
 assert.equal(await sql(`SELECT push_sent FROM notifications WHERE id='${nid}'`),'t');
 assert.equal(await sql(`SELECT state FROM waydrop_internal.notification_jobs WHERE notification_id='${nid}'`),'uncertain');
 await request(nid);assert.equal(fcm,2);
});
Deno.test('transient rejection retries only after persisted backoff',async()=>{
 const nid=await seed();status=503;await request(nid);assert.equal(fcm,1);
 await request(nid);assert.equal(fcm,1);
 await sql(`UPDATE waydrop_internal.notification_devices SET next_at=clock_timestamp()-interval '1 second' WHERE notification_id='${nid}';`);
 status=200;await request(nid);assert.equal(fcm,2);
});
Deno.test('auth denial and actor scoping cannot mutate another notification',async()=>{
 const nid=await seed();assert.equal((await request(nid,'invalid')).status,401);
 assert.equal((await request(nid,'session',{user_id:uid(9002)})).status,403);
 assert.equal(fcm,0);assert.equal(await sql(`SELECT COALESCE(sum(attempts),0) FROM waydrop_internal.notification_devices WHERE notification_id='${nid}'`),'0');
});
Deno.test('preferences skip durably without an FCM call or inbox deletion',async()=>{
 const nid=await seed();prefOff=true;await request(nid);assert.equal(fcm,0);
 assert.equal(await sql(`SELECT delivery_status FROM notifications WHERE id='${nid}'`),'skipped');
});
Deno.test('typed invalid registration is cleaned by SQL recipient/version CAS',async()=>{
 const nid=await seed();status=404;await request(nid);
 assert.equal(await sql(`SELECT count(*) FROM user_device_tokens WHERE user_id='${uid(9001)}'`),'0');
});
Deno.test('provider classification and Retry-After do not treat generic 404 as invalid token',()=>{
 assert.equal(deliveryOutcome(404,'{}'),'PERMANENT');assert.equal(deliveryOutcome(0,''),'UNCERTAIN');
 assert.equal(deliveryOutcome(429,'{}'),'QUOTA');assert.equal(retryAfter('120'),120);
 assert.equal(notificationAllowed('chat_message',{}, {pref_chat_notifications:false}),false);
});
Deno.test('dispatch runner cannot fall back to unsafe writes after missing RPC',async()=>{
 let calls=0;await assert.rejects(runDurableDispatch({rpc:async()=>{calls++;return {data:null,error:'missing'}}},'o',{budgetMs:1}),/STORAGE_UNAVAILABLE/);
 assert.equal(calls,1);
});
Deno.test('buffered deadline aborts a response whose headers arrived but body stalled',async()=>{
 const mock=globalThis.fetch;
 globalThis.fetch=async(_input:any,init:any)=>new Response(new ReadableStream({start(controller){init.signal.addEventListener('abort',()=>controller.error(new DOMException('timeout','AbortError')),{once:true});}}));
 try{await assert.rejects(fetchBufferedWithTimeout('https://synthetic.invalid',{},10),/timeout/);}finally{globalThis.fetch=mock;}
});
Deno.test('actual dispatch runner commits one step and a lost response cannot duplicate offers',async()=>{
 const oid=crypto.randomUUID();
 await sql(`UPDATE riders SET last_location_updated_at=clock_timestamp(); INSERT INTO orders SELECT (jsonb_populate_record(NULL::orders,to_jsonb(o)||jsonb_build_object('id','${oid}','order_code','BLOCKER-EDGE','order_status','searching','rider_id',NULL,'created_at',clock_timestamp(),'dispatch_state','{}'::jsonb,'dispatch_worker_running',false,'dispatch_worker_started_at',NULL))).* FROM orders o WHERE id='${uid(1000)}';`);
 fault='after_step';
 await assert.rejects(runDurableDispatch(client,oid,{budgetMs:1000}),/lost RPC response/);
 const before=Number(await sql(`SELECT count(*) FROM rider_assignments WHERE order_id='${oid}';`));
 assert.ok(before>0);
 await sql(`UPDATE waydrop_internal.dispatch_jobs SET next_at=clock_timestamp()-interval '1 second' WHERE order_id='${oid}';`);
 const result=await runDurableDispatch(client,oid,{budgetMs:1000});
 assert.equal(result.steps,1);assert.equal(result.offers,0);
 assert.equal(Number(await sql(`SELECT count(*) FROM rider_assignments WHERE order_id='${oid}';`)),before);
});
Deno.test('restore mocked provider transport',()=>{globalThis.fetch=originalFetch;});
