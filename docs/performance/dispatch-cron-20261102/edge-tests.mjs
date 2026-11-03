// Execute the actual worker-acquisition block with an in-memory PostgREST model.
// Native PostgreSQL concurrency tests independently verify the SQL CAS semantics.
import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
import {test} from 'node:test';
const source=await fs.readFile(process.env.PART3_BASELINE==='1'
 ? new URL('production-start-dispatch.ts',import.meta.url)
 : new URL('../../../supabase/functions/start-dispatch/index.ts',import.meta.url),'utf8');
const begin=source.indexOf('    const nowStr = new Date().toISOString();');
const end=source.indexOf('    let chainedTriggered = false;',begin);
assert.ok(begin>0&&end>begin);
const block=source.slice(begin,end).replace('let staleStartedAt: string | null = null;','let staleStartedAt = null;');
const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
const acquire=new AsyncFunction('supabase','order_id','const corsHeaders={};'+block+'return {won:true};');
function database(row){
 const db={row:{...row},writes:[],from(table){assert.equal(table,'orders');const filters=[];let patch=null;return {
 select(){return this;},update(data){patch=data;return this;},eq(k,v){filters.push(r=>r[k]===v);return this;},is(k,v){filters.push(r=>(r[k]??null)===v);return this;},or(){filters.push(r=>r.dispatch_worker_running===false||r.dispatch_worker_running==null);return this;},
 async single(){return {data:{...db.row},error:null};},
 async maybeSingle(){if(!filters.every(f=>f(db.row)))return {data:null,error:null};Object.assign(db.row,patch);db.writes.push({...patch});return {data:{id:db.row.id},error:null};}
 };}};return db;
}
const row=extra=>({id:'synthetic-order',order_status:'searching',dispatch_worker_running:false,dispatch_worker_started_at:null,...extra});
test('two workers recovering a timestamp-less orphan have exactly one winner',async()=>{
 const db=database(row({dispatch_worker_running:true}));
 const result=await Promise.all([acquire(db,db.row.id),acquire(db,db.row.id)]);
 assert.equal(result.filter(r=>r.won).length,1);assert.equal(db.writes.length,1);
});
test('fresh live lease is not stolen',async()=>{
 const db=database(row({dispatch_worker_running:true,dispatch_worker_started_at:new Date().toISOString()}));
 const result=await acquire(db,db.row.id);assert.equal(result instanceof Response,true);assert.equal(db.writes.length,0);
});
test('stale timestamp lease is replaced by one timestamp CAS',async()=>{
 const db=database(row({dispatch_worker_running:true,dispatch_worker_started_at:new Date(Date.now()-180000).toISOString()}));
 const result=await Promise.all([acquire(db,db.row.id),acquire(db,db.row.id)]);assert.equal(result.filter(r=>r.won).length,1);assert.equal(db.writes.length,1);
});
test('terminal order never acquires a worker flag',async()=>{
 const db=database(row({order_status:'accepted'}));await acquire(db,db.row.id);assert.equal(db.writes.length,0);
});
test('Edge audit write uses duplicate-ignore conflict key without overwriting audit state',async()=>{
 const match=source.match(/await supabase\.from\("order_assignment_logs"\)\.upsert\(logRows, \{[\s\S]*?\}\);/);
 assert.ok(match,'audit write must use duplicate-ignore');
 let observed;
 await new AsyncFunction('supabase','logRows',match[0])({from(table){assert.equal(table,'order_assignment_logs');return {async upsert(rows,options){observed={rows,options};}};}},[{order_id:'o',rider_id:'r',assignment_round:1}]);
 assert.deepEqual(observed.options,{onConflict:'order_id,rider_id,assignment_round',ignoreDuplicates:true});
});
