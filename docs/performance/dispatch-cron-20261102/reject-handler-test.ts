import assert from 'node:assert/strict';
let status='sent',owner='actor',orderStatus='searching';
const requests:{table:string,operation:string}[]=[];
(globalThis as any).__pushSupabase={auth:{getUser:async()=>({data:{user:{id:'actor'}},error:null})},from(table:string){
 let operation='select',patch:any;
 const execute=async()=>{
  requests.push({table,operation});
  if(table==='riders')return {data:{user_id:owner},error:null};
  if(table==='orders')return {data:{order_status:orderStatus},error:null};
  if(table==='rider_assignments'&&operation==='select')return {data:{id:'assignment',assignment_status:status,assignment_round:1},error:null};
  if(table==='rider_assignments'&&operation==='update'){status=patch.assignment_status??status;return {data:{id:'assignment'},error:null};}
  if(table==='order_assignment_logs')return {data:null,error:null};
  throw Error('Unexpected operation '+table+operation);
 };
 const b:any={select(){return b},eq(){return b},order(){return b},limit(){return b},update(v:any){operation='update';patch=v;return b},insert(){operation='insert';return b},single:execute,maybeSingle:execute,then(ok:any,bad:any){return execute().then(ok,bad)}};return b;
}};
if(Deno.env.get('PART3_BASELINE')==='1')await import('./production-reject-order.ts');
else await import('../../../supabase/functions/reject-order/index.ts');
const handler=(globalThis as any).__pushHandler;
const request=()=>new Request('http://localhost/reject',{method:'POST',headers:{Authorization:'Bearer synthetic'},body:JSON.stringify({order_id:'order',rider_id:'rider'})});
function reset(){status='sent';owner='actor';orderStatus='searching';requests.length=0;}
Deno.test('ordinary rejection removes dead remaining-offers query; response retains recovery ownership',async()=>{
 reset();const response=await handler(request());assert.equal(response.status,200);assert.equal(status,'rejected');
 assert.equal(requests.filter(r=>r.table==='rider_assignments'&&r.operation==='select').length,1);
 assert.equal((await response.json()).redispatched,false);
});
Deno.test('reject still requires rider ownership and performs no unauthorized write',async()=>{
 reset();owner='other';assert.equal((await handler(request())).status,403);assert.equal(requests.some(r=>r.operation!=='select'),false);
});
Deno.test('terminal order and already accepted assignment cannot be rejected by these branches',async()=>{
 reset();orderStatus='accepted';assert.equal((await handler(request())).status,400);assert.equal(requests.some(r=>r.operation!=='select'),false);
 reset();status='accepted';assert.equal((await handler(request())).status,400);assert.equal(requests.some(r=>r.operation!=='select'),false);
});
