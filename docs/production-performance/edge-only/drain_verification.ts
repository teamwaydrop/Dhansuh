// Rehearse the exact read-only drain query against a synthetic held writer.
import postgres from 'npm:postgres@3.4.5';
import assert from 'node:assert/strict';
const root=new URL('../../../',import.meta.url);
const psql=new URL('.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe',root).pathname.replace(/^\//,'');
const db=postgres('postgresql://waydrop_local@127.0.0.1:54329/waydrop_perf_test',{max:1,prepare:false,ssl:false});
async function counters(cutoff:string){const r=await new Deno.Command(psql,{args:['-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d','waydrop_perf_test','-v','pause_cutoff_utc='+cutoff,'-f',new URL('drain-check.read-only.sql',import.meta.url).pathname.replace(/^\//,'')],stdout:'piped',stderr:'piped'}).output();assert.equal(r.code,0,new TextDecoder().decode(r.stderr));return new TextDecoder().decode(r.stdout).trim().split('|').slice(1).map(Number);}
let release!:()=>void,ready!:(s:string)=>void;const hold=new Promise<void>(r=>release=r),locked=new Promise<string>(r=>ready=r);
const transaction=db.begin(async tx=>{await tx`LOCK TABLE rider_assignments IN ROW EXCLUSIVE MODE`;const [r]=await tx`SELECT clock_timestamp()+interval '1 second' cutoff`;ready(r.cutoff.toISOString());await hold;});
const results=[];
try{const cutoff=await locked,before=await counters(cutoff);assert.ok(before[0]>=1);assert.ok(before[2]>=1);results.push({name:'Drain query detects a pre-cutoff transaction and held assignment write lock',status:'PASS'});release();await transaction;const after=await counters(cutoff);assert.deepEqual(after,[0,0,0]);results.push({name:'Drain query clears only after transaction and write lock end',status:'PASS'});}
finally{release();await transaction;await db.end({timeout:2});}
await Deno.writeTextFile(new URL('DRAIN_RESULTS.json',import.meta.url),JSON.stringify({productionConnected:false,tests:results,limitations:['Verifies SQL counters locally; does not establish a managed routing cutoff or prove old v60 workers drained.']},null,2)+'\n');
console.log('PASS: two read-only drain-counter assertions; no data modification.');
