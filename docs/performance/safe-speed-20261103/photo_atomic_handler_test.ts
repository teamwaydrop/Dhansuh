import {assert as check, assertEquals} from 'https://deno.land/std@0.168.0/testing/asserts.ts';
const assert={equal:assertEquals,deepEqual:assertEquals,ok:(value:unknown,message?:string)=>{check(value,message);},doesNotMatch:(value:string,pattern:RegExp)=>check(!pattern.test(value))};
const root=new URL('../../../',import.meta.url);
const psql=new URL('.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe',root).pathname.replace(/^\//,'');
async function sql(query:string,ok=true){
 const out=await new Deno.Command(psql,{args:['-X','-q','-A','-t','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d','waydrop_photo_atomic_test','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-c',query],stdout:'piped',stderr:'piped'}).output();
 const text=new TextDecoder().decode(out.stdout).trim(),err=new TextDecoder().decode(out.stderr);
 if(ok)assert.ok(out.success,err);return {text,err,success:out.success};
}
assert.equal((await sql("SELECT label FROM public.fixture_marker;")).text,'waydrop_photo_atomic_synthetic_v1');
const uid=(n:number)=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const order=uid(1),rider=uid(2),actor=uid(3),other=uid(4);
const url='https://synthetic.invalid/storage/v1/object/public/parcel_images/proof';
const originalFetch=globalThis.fetch;
Deno.env.set('SUPABASE_URL','https://synthetic.invalid');Deno.env.set('SUPABASE_SERVICE_ROLE_KEY','synthetic-not-a-key');
await import('./photo-atomic-candidate/functions/process-verification-photo/index.ts');
let mode='',rpcs=0;
const quote=(value:unknown)=>value===null?'NULL':typeof value==='number'?String(value):"'"+String(value).replaceAll("'","''")+"'";
(globalThis as any).__photoClient={auth:{getUser:async()=>({data:{user:{id:actor}},error:null})},from(table:string){
 const q:any={select(){return q;},eq(){return q;},single:async()=>({data:table==='riders'?{user_id:actor}:{user_id:actor,rider_id:rider},error:null})};return q;
},async rpc(name:string,args:Record<string,unknown>){
 assert.equal(name,'record_order_photo_proof_v1');assert.equal(args.p_actor_user_id,actor);rpcs++;
 if(mode==='reassign'){await sql(`UPDATE public.orders SET rider_id='${other}' WHERE id='${order}';`);mode='';}
 const result=await sql(`SELECT public.record_order_photo_proof_v1(${Object.entries(args).map(([k,v])=>k+'=>'+quote(v)).join(',')})::text;`,false);
 if(mode==='lost'&&result.success){mode='';throw Error('synthetic-private-lost-response');}
 return result.success?{data:JSON.parse(result.text),error:null}:{data:null,error:{code:result.err.match(/ERROR:\s+([0-9A-Z]{5}):/)?.[1]??'P0001'}};
}};
async function reset(){
 mode='';rpcs=0;await sql("UPDATE public.fault SET stage='';TRUNCATE public.order_parcel_photos,public.order_verifications,public.parcel_security_logs;UPDATE public.orders SET rider_id='"+rider+"',pickup_verification_completed=false,pickup_verification_completed_at=NULL;");
 globalThis.fetch=async()=>new Response(new Uint8Array([255,216,255,1,2,3]));
}
async function send(){return await (globalThis as any).__photoHandler(new Request('https://synthetic.invalid/process-verification-photo',{method:'POST',headers:{Authorization:'Bearer synthetic','Content-Type':'application/json'},body:JSON.stringify({order_id:order,rider_id:rider,photo_type:'pickup',photo_url:url,latitude:0,longitude:0,actor_user_id:other})}));}
async function counts(){return JSON.parse((await sql("SELECT json_build_array((SELECT count(*) FROM public.order_parcel_photos),(SELECT count(*) FROM public.order_verifications),(SELECT count(*) FROM public.parcel_security_logs),(SELECT pickup_verification_completed FROM public.orders));")).text);}
Deno.test('eight full handlers with actual SQL create one proof/verification/audit',async()=>{
 await reset();const responses=await Promise.all(Array.from({length:8},send));assert.ok(responses.every(r=>r.status===200));
 const bodies=await Promise.all(responses.map(r=>r.json()));assert.equal(new Set(bodies.map(b=>b.photo_log_id)).size,1);assert.deepEqual(await counts(),[1,1,1,true]);assert.equal(rpcs,8);
});
Deno.test('snapshot authorization cannot overwrite reassigned order at RPC',async()=>{
 await reset();mode='reassign';assert.equal((await send()).status,403);assert.deepEqual(await counts(),[0,0,0,false]);
});
Deno.test('atomic RPC failure rolls back all proof effects and returns generic 503',async()=>{
 await reset();await sql("UPDATE public.fault SET stage='parcel_security_logs';");const response=await send();assert.equal(response.status,503);assert.deepEqual(await counts(),[0,0,0,false]);assert.doesNotMatch(JSON.stringify(await response.json()),/synthetic transition failure/);await sql("UPDATE public.fault SET stage='';");
});
Deno.test('legacy partial proof is not automatically repaired by retry',async()=>{
 await reset();await sql(`INSERT INTO public.order_parcel_photos(order_id,rider_id,photo_url,photo_type,file_sha256)VALUES('${order}','${rider}','${url}','pickup','${'a'.repeat(64)}');`);
 assert.equal((await send()).status,503);assert.deepEqual(await counts(),[1,0,0,false]);
});
Deno.test('lost response after committed proof replays without duplicate effects',async()=>{
 await reset();mode='lost';const first=await send();assert.equal(first.status,500);assert.doesNotMatch(JSON.stringify(await first.json()),/synthetic-private-lost-response/);
 assert.deepEqual(await counts(),[1,1,1,true]);assert.equal((await send()).status,200);assert.deepEqual(await counts(),[1,1,1,true]);
});
Deno.test('restore synthetic provider transport',()=>{globalThis.fetch=originalFetch;});
