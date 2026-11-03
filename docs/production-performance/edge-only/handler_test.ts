// Execute the repository's atomic handler against native local PG17 through a
// minimal Supabase client transport adapter. No PostgREST/Auth-server parity claim.
import assert from 'node:assert/strict';
const root=new URL('../../../',import.meta.url);
const psql=new URL('.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe',root).pathname.replace(/^\//,'');
const uid=(n:number)=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const quote=(v:unknown)=>v===null?'NULL':"'"+String(v).replaceAll("'","''")+"'";
const ident=(s:string)=>'"'+s.replaceAll('"','""')+'"';
async function sql(text:string){
  const child=new Deno.Command(psql,{args:['-X','-A','-t','-q','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d','waydrop_perf_test','-v','ON_ERROR_STOP=1'],stdin:'piped',stdout:'piped',stderr:'piped'}).spawn();
  const w=child.stdin.getWriter();await w.write(new TextEncoder().encode(text));await w.close();const out=await child.output();if(!out.success)throw Error(new TextDecoder().decode(out.stderr));return new TextDecoder().decode(out.stdout).trim();
}
const fare=JSON.parse(await Deno.readTextFile(new URL('../local-tests/fare-source.json',import.meta.url)));
for(const f of fare)await sql(f.definition+';');
Deno.env.set('SUPABASE_DB_URL','postgresql://waydrop_local@127.0.0.1:54329/waydrop_perf_test');Deno.env.set('SUPABASE_URL','http://127.0.0.1:54328');Deno.env.set('SUPABASE_SERVICE_ROLE_KEY','synthetic-service-key');
let orderReads=0;let release:()=>void;let readBarrier=new Promise<void>(r=>release=r);
(globalThis as any).__pushSupabase={auth:{getUser:async(token:string)=>({data:{user:{id:token}},error:null})},async rpc(){throw Error('RPC forbidden in Edge-only wave');},from(table:string){
  if(table==='production_config'){const c:any={select(){return c},eq(){return c},single:async()=>({data:{},error:null})};return c;}
  if(!['riders','orders','rider_assignments','order_assignment_logs'].includes(table))throw Error('Unexpected table '+table);
  let operation='select',values:Record<string,unknown>={},where:string[]=[],limit='',order='',single=false;
  const execute=async()=>{
    try{
      let statement='';const filter=where.length?' WHERE '+where.join(' AND '):'';
      if(operation==='select')statement=`SELECT * FROM ${ident(table)}${filter}${order}${limit}`;
      if(operation==='update')statement=`UPDATE ${ident(table)} SET ${Object.entries(values).map(([k,v])=>ident(k)+'='+quote(v)).join(',')}${filter} RETURNING *`;
      if(operation==='insert')statement=`INSERT INTO ${ident(table)}(${Object.keys(values).map(ident)}) VALUES(${Object.values(values).map(quote)}) RETURNING *`;
      if(table==='orders'&&operation==='select'&&where.some(s=>s.includes(uid(3000)))&&orderReads<2){orderReads++;const data=JSON.parse(await sql(`SELECT coalesce(jsonb_agg(t),'[]') FROM (${statement})t;`));if(orderReads===2)release();await readBarrier;return {data:single?data[0]??null:data,error:null};}
      const wrapped=operation==='select'?`SELECT coalesce(jsonb_agg(t),'[]') FROM (${statement})t;`:`WITH t AS (${statement}) SELECT coalesce(jsonb_agg(t),'[]') FROM t;`;
      const data=JSON.parse(await sql(wrapped));return {data:single?data[0]??null:data,error:null};
    }catch(e){return {data:null,error:{message:String(e)}};}
  };
  const b:any={select(){return b},eq(k:string,v:unknown){where.push(ident(k)+'='+quote(v));return b},neq(k:string,v:unknown){where.push(ident(k)+'<>'+quote(v));return b},order(k:string,options:any){order=' ORDER BY '+ident(k)+(options?.ascending===false?' DESC':' ASC');return b},limit(n:number){limit=' LIMIT '+n;return b},update(v:any){operation='update';values=v;return b},insert(v:any){operation='insert';values=v;return b},single(){single=true;return execute()},maybeSingle(){single=true;return execute()},then(ok:any,bad:any){return execute().then(ok,bad)}};return b;
}};
await import(new URL('supabase/functions/accept-order/index.ts',root).href);
const handler=(globalThis as any).__pushHandler;
const {closeAcceptanceExecutor}=await import('../../../supabase/functions/accept-order/atomic_acceptance.ts');
Deno.test('actual acceptance handler: two riders race for one order; payable fare preserved',async()=>{
  await sql("DELETE FROM orders WHERE order_code LIKE 'EDGE-%' OR order_code LIKE 'ATOMIC-%' OR order_code='REST-ACCEPT';");
  const outcomes:any[]=[];
  try {
  for(const mode of ['original','proposed']){
    await sql(`DELETE FROM orders WHERE id='${uid(3000)}'; INSERT INTO orders SELECT (jsonb_populate_record(NULL::orders,to_jsonb(o)||jsonb_build_object('id','${uid(3000)}','order_code','SYNTHETIC-RACE','rider_id',NULL,'order_status','searching','current_fare',100,'final_fare',90,'rider_earning',80,'commission_percentage',10,'gst_percentage',5))).* FROM orders o WHERE id='${uid(1000)}'; INSERT INTO rider_assignments(order_id,rider_id,expires_at,estimated_earnings) VALUES('${uid(3000)}','${uid(201)}',now()+interval '5 minutes',80),('${uid(3000)}','${uid(207)}',now()+interval '5 minutes',80);`);
    if(mode==='proposed')for(const n of ['01_find_nearby_riders.sql','02_assign_nearby_searching_orders_core.sql'])await sql((await Deno.readTextFile(new URL('../waves/'+n,import.meta.url))).replace(/ROLLBACK;\s*$/,'COMMIT;'));
    orderReads=0;readBarrier=new Promise(r=>release=r);
    const requests=[201,207].map(n=>handler(new Request('http://localhost/test',{method:'POST',headers:{Authorization:'Bearer '+uid(9000+n-200)},body:JSON.stringify({order_id:uid(3000),rider_id:uid(n)})})));
    const responses=await Promise.all(requests);assert.deepEqual(responses.map(r=>r.status).sort(),[200,409]);
    const state=JSON.parse(await sql(`SELECT json_build_object('order_status',order_status,'current_fare',current_fare,'final_fare',final_fare,'commission_amount',commission_amount,'gst_amount',gst_amount,'rider_earning',rider_earning) FROM orders WHERE id='${uid(3000)}';`));
    assert.equal(state.order_status,'accepted');assert.equal(state.current_fare,100);assert.equal(state.final_fare,90);assert.equal(state.commission_amount,9.52);assert.equal(state.rider_earning,90.48);outcomes.push(state);
    // Record loser assignment state as well: optimistic order locking alone
    // does not imply every earlier assignment write was transactional.
    outcomes.push(JSON.parse(await sql(`SELECT jsonb_agg(assignment_status ORDER BY assignment_status) FROM rider_assignments WHERE order_id='${uid(3000)}';`)));
  }
  assert.deepEqual(outcomes[0],outcomes[2]);assert.deepEqual(outcomes[1],outcomes[3]);
  const result={status:'PASS',responses:[200,409],fare:outcomes[0],assignmentStatuses:outcomes[1],scope:'Atomic repository handler and fare SQL, native PG17; Auth and PostgREST transport emulated. Supabase asynchronous integrations outside the fixture are not exercised.'};
  await Deno.writeTextFile(new URL('HANDLER_RESULTS.json',import.meta.url),JSON.stringify(result,null,2)+'\n');
  for(const name of ['find_nearby_riders','assign_nearby_searching_orders_core'])await sql(await Deno.readTextFile(new URL('.dart_tool/production_performance_preflight_20261101/'+name+'.before.sql',root)));
  } finally {await closeAcceptanceExecutor();}
});
Deno.test('close pooled executor',async()=>await closeAcceptanceExecutor());
Deno.test('acceptance invariant: only the winning rider has an accepted assignment',async()=>{
  const accepted=Number(await sql(`SELECT count(*) FROM rider_assignments WHERE order_id='${uid(3000)}' AND assignment_status='accepted';`));
  const output=new URL('HANDLER_RESULTS.json',import.meta.url);
  const report=JSON.parse(await Deno.readTextFile(output));
  report.singleAcceptedAssignmentInvariant={status:accepted===1?'PASS':'FAIL',expected:1,actual:accepted,reproducedWith:'Atomic handler with original and proposed matching functions.',productionImpact:'Not deployed; managed asynchronous integrations remain a deployment gate.'};
  await Deno.writeTextFile(output,JSON.stringify(report,null,2)+'\n');
  assert.equal(accepted,1,'Existing handler race: loser returned 409 but its assignment remained accepted');
});

Deno.test('emergency Edge recovery blocks writes and verified handler can resume',async()=>{
 const originalServe=Deno.serve, originalHandler=(globalThis as any).__pushHandler; let closed:any;
 const state=()=>sql("SELECT md5(string_agg(t,'|' ORDER BY t)) FROM (SELECT to_jsonb(o)::text t FROM orders o UNION ALL SELECT to_jsonb(a)::text FROM rider_assignments a UNION ALL SELECT to_jsonb(l)::text FROM order_assignment_logs l UNION ALL SELECT to_jsonb(e)::text FROM local_push_capture e)x;");
 const before=await state();
 try {
  (Deno as any).serve=(handler:any)=>{closed=handler;return {};};
  await import('./recovery-fail-closed/functions/accept-order/index.ts');
  const result=await closed(new Request('http://localhost/test',{method:'POST',body:'{}'}));
  assert.equal(result.status,503);assert.equal(result.headers.get('Retry-After'),'30');
  assert.equal((await closed(new Request('http://localhost/test',{method:'OPTIONS'}))).status,200);
  assert.equal(await state(),before);
 } finally {(Deno as any).serve=originalServe;(globalThis as any).__pushHandler=originalHandler;}
 orderReads=2;const winner=await sql("SELECT rider_id FROM orders WHERE id='"+uid(3000)+"';");const winnerNumber=Number(winner.slice(-12));const retry=await originalHandler(new Request('http://localhost/test',{method:'POST',headers:{Authorization:'Bearer '+uid(9000+winnerNumber-200)},body:JSON.stringify({order_id:uid(3000),rider_id:winner})}));
 assert.equal(retry.status,200);assert.equal((await retry.json()).idempotent,true);await closeAcceptanceExecutor();
});
