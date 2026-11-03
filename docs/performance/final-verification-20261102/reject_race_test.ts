// Actual handler; stale SELECT snapshot followed by a competing accept/re-offer.
import assert from 'node:assert/strict';
let status='sent',nextStatus:string|undefined,owner='actor',writes=0,audits=0;
(globalThis as any).__pushSupabase={auth:{getUser:async()=>({data:{user:{id:'actor'}},error:null})},from(table:string){
 let op='select',patch:any;const filters:Record<string,unknown>={};
 const execute=async()=>{
  if(table==='riders')return {data:{user_id:owner},error:null};
  if(table==='orders')return {data:{order_status:'searching'},error:null};
  if(table==='rider_assignments'&&op==='select'){
   const snapshot={id:'assignment',assignment_status:status,assignment_round:1};
   if(nextStatus)status=nextStatus;
   return {data:snapshot,error:null};
  }
  if(table==='rider_assignments'&&op==='update'){
   if(filters.assignment_status!==undefined&&filters.assignment_status!==status)return {data:null,error:null};
   writes++;status=patch.assignment_status??status;return {data:{id:'assignment'},error:null};
  }
  if(table==='order_assignment_logs'){audits++;return {data:null,error:null};}
  throw Error('Unexpected test transport '+table+op);
 };
 const b:any={select(){return b;},eq(k:string,v:unknown){filters[k]=v;return b;},order(){return b;},limit(){return b;},update(v:any){patch=v;op='update';return b;},insert(){op='insert';return b;},single:execute,maybeSingle:execute,then(ok:any,bad:any){return execute().then(ok,bad);}};return b;
}};
const target=Deno.env.get('PART5_REJECT_BASELINE')==='1'
 ? new URL('../../../.dart_tool/waydrop-local-runtime/part5-baseline/supabase/functions/reject-order/index.ts',import.meta.url)
 : new URL('../../../supabase/functions/reject-order/index.ts',import.meta.url);
await import(target.href);
const handler=(globalThis as any).__pushHandler;
const request=()=>handler(new Request('http://localhost/test',{method:'POST',headers:{Authorization:'Bearer synthetic'},body:JSON.stringify({order_id:'order',rider_id:'rider'})}));
for(const initial of ['sent','expired','rejected']){
 Deno.test(`competing acceptance after ${initial} snapshot cannot be overwritten or audited`,async()=>{
  status=initial;nextStatus='accepted';owner='actor';writes=0;audits=0;
  assert.equal((await request()).status,409);assert.equal(status,'accepted');assert.equal(writes,0);assert.equal(audits,0);
 });
}
Deno.test('re-offer after rejected snapshot does not receive the old rejection cooldown',async()=>{
 status='rejected';nextStatus='sent';owner='actor';writes=0;audits=0;
 assert.equal((await request()).status,409);assert.equal(status,'sent');assert.equal(writes,0);assert.equal(audits,0);
});
Deno.test('sent, expired and rejected success paths keep rejection/cooldown ownership',async()=>{
 for(const initial of ['sent','expired','rejected']){
  status=initial;nextStatus=undefined;owner='actor';writes=0;audits=0;
  assert.equal((await request()).status,200);assert.equal(status,'rejected');assert.equal(writes,1);assert.equal(audits,1);
 }
});
