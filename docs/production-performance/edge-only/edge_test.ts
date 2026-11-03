import assert from 'node:assert/strict';
const root=new URL('../../../',import.meta.url);
const user='00000000-0000-4000-8000-000000009001';
Deno.env.set('SUPABASE_URL','http://127.0.0.1:54328');Deno.env.set('SUPABASE_SERVICE_ROLE_KEY','synthetic-service');
const originalNow=Date.now;let tick=originalNow(),count=0;Date.now=()=>tick;
async function setup(opts:any={}){
  tick+=60000;const calls:any[]=[];
  (globalThis as any).__pushSupabase={auth:{getUser:async()=>({data:{user:opts.invalid?null:{id:user}},error:opts.invalid?'invalid':null})},from(table:string){
    const c:any={select(){return c},eq(){return c},single:async()=>({data:table==='orders'?{id:'order',order_type:opts.type??'ride',order_status:opts.accepted?'accepted':'searching',rider_id:opts.accepted?'rider':null}:opts.flags??{},error:null})};return c;
  },rpc:async()=>{throw Error('No RPC allowed');}};
  (globalThis as any).__atomicAccept=async(orderId:string,riderId:string,actorId:string)=>{calls.push({orderId,riderId,actorId});if(opts.error)throw opts.error;return opts.result??{http_status:200,success:true};};
  await import(new URL(`supabase/functions/accept-order/index.ts?edgecase=${count++}`,root).href);
  const handler=(globalThis as any).__pushHandler;
  const request=async(token:string|null='session',body:any={order_id:'order',rider_id:'rider',p_actor_user_id:'forged'})=>handler(new Request('http://localhost/test',{method:'POST',headers:token?{Authorization:'Bearer '+token}:undefined,body:typeof body==='string'?body:JSON.stringify(body)}));
  return {request,calls};
}
Deno.test('handler denies missing/invalid auth and malformed input before acceptance transaction',async()=>{
  const a=await setup();assert.equal((await a.request(null)).status,401);assert.equal((await a.request('session','{bad')).status,400);assert.equal((await a.request('session',{})).status,400);assert.equal(a.calls.length,0);const b=await setup({invalid:true});assert.equal((await b.request()).status,401);assert.equal(b.calls.length,0);
});
Deno.test('handler binds actor to verified session and uses only one atomic transaction',async()=>{
  const a=await setup();assert.equal((await a.request()).status,200);assert.deepEqual(a.calls,[{orderId:'order',riderId:'rider',actorId:user}]);
});
Deno.test('all existing feature gates block NEW acceptances before transaction',async()=>{
  for(const [type,flag]of [['ride','local_rides_enabled'],['ride','ride_booking_enabled'],['local_parcel','parcel_enabled'],['intercity_ride','intercity_enabled'],['intercity_parcel','intercity_enabled']]){const a=await setup({type,flags:{[flag]:false}});assert.equal((await a.request()).status,503);assert.equal(a.calls.length,0);}
});
Deno.test('idempotent retry still reaches ownership-checked RPC when flags are disabled',async()=>{
  const a=await setup({accepted:true,flags:{ride_booking_enabled:false},result:{http_status:200,success:true,idempotent:true}});const r=await a.request();assert.equal(r.status,200);assert.equal((await r.json()).idempotent,true);assert.equal(a.calls.length,1);
  const denied=await setup({accepted:true,result:{http_status:403,success:false}});assert.equal((await denied.request()).status,403);
});
Deno.test('loser and unexpected uniqueness failure fails closed',async()=>{
  const a=await setup({result:{http_status:409,success:false}});assert.equal((await a.request()).status,409);
  const b=await setup({error:{code:'23505',message:'duplicate key violates rider_assignments_one_accepted_per_order'}});assert.equal((await b.request()).status,500);
});
Deno.test('deadlock, lock timeout, cancellation and serialization errors are retryable 503',async()=>{
  for(const code of ['40001','40P01','55P03','57014','ECONNRESET']){const a=await setup({error:{code}});const r=await a.request();assert.equal(r.status,503);assert.equal((await r.json()).retryable,true);assert.equal(a.calls.length,1);}
});
Deno.test('missing connection or other DB failure fails closed without split-write fallback',async()=>{
  for(const code of ['PGRST202','XX000']){const a=await setup({error:{code}});assert.equal((await a.request()).status,500);assert.equal(a.calls.length,1);}
});
Deno.test('restore clock',()=>{Date.now=originalNow;});
