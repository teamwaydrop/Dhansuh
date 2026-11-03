// Fixed disposable loopback target only. Does not read production credentials.
import fs from 'node:fs/promises';
import {spawn} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {randomBytes} from 'node:crypto';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../../..');
const runtime=path.join(root,'.dart_tool/waydrop-local-runtime');
const psql=path.join(runtime,'postgresql-17.11-core/pgsql/bin/psql.exe');
async function sql(input){return await new Promise((ok,bad)=>{const p=spawn(psql,['-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d','waydrop_perf_test'],{windowsHide:true});let out='',err='';p.stdout.on('data',b=>out+=b);p.stderr.on('data',b=>err+=b);p.on('error',bad);p.on('close',n=>n?bad(Error(err)):ok(out.trim()));p.stdin.end(input);});}
await sql("DO $$ BEGIN IF current_database()<>'waydrop_perf_test' OR inet_server_addr()<>inet '127.0.0.1' OR inet_server_port()<>54329 THEN RAISE EXCEPTION 'Disposable loopback target required'; END IF; END $$;");
for(const f of JSON.parse(await fs.readFile(path.join(here,'../acceptance/auth-helpers.json'),'utf8')))await sql(f.definition+';');
await sql("DO $$ BEGIN IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='waydrop_rest') THEN CREATE ROLE waydrop_rest LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE; END IF; IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='waydrop_edge') THEN CREATE ROLE waydrop_edge LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE; END IF; IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='waydrop_edge_denied') THEN CREATE ROLE waydrop_edge_denied LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE; END IF; END $$; GRANT anon,authenticated,service_role TO waydrop_rest; GRANT service_role TO waydrop_edge;");
const secret=randomBytes(48).toString('hex'),cfg=path.join(runtime,'edge-network-postgrest.conf');
await fs.writeFile(cfg,`db-uri = "postgresql://waydrop_rest@127.0.0.1:54329/waydrop_perf_test"\ndb-schemas = "public"\ndb-anon-role = "anon"\ndb-pool = 4\ndb-config = false\nserver-host = "127.0.0.1"\nserver-port = 54327\njwt-secret = "${secret}"\n`);
const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>k.toLowerCase()!=='path'));env.Path=path.dirname(psql)+path.delimiter+(process.env.Path??process.env.PATH??'');
const rest=spawn(path.join(runtime,'postgrest-16.5/postgrest.exe'),[cfg],{windowsHide:true,env});let errors='';rest.stderr.on('data',b=>errors+=b);rest.stdout.on('data',()=>{});const closed=new Promise(r=>rest.on('close',r));
try{
 let ready=false;for(let n=0;n<60;n++){try{const r=await fetch('http://127.0.0.1:54327/');await r.text();if(r.ok){ready=true;break;}}catch{}await new Promise(r=>setTimeout(r,100));}if(!ready)throw Error('PostgREST startup failed: '+errors.slice(-600));
 await new Promise((ok,bad)=>{const p=spawn(path.join(runtime,'deno-2.9.8-core/deno.exe'),['run','--config',path.join(here,'deno-network.json'),'--cached-only','--frozen','--lock='+path.join(here,'deno.lock'),'--allow-net=127.0.0.1:54327,127.0.0.1:54328,127.0.0.1:54329','--allow-env','--allow-read='+root,'--allow-write='+path.join(here,'NETWORK_RESULTS.json'),path.join(here,'network_integration.ts')],{windowsHide:true,env:{...process.env,DENO_DIR:path.join(runtime,'deno-cache'),DENO_NO_PACKAGE_JSON:'1',PGPASSWORD:'',WAYDROP_SYNTHETIC_JWT_SECRET:secret}});p.stdout.pipe(process.stdout);p.stderr.pipe(process.stderr);p.on('error',bad);p.on('close',n=>n?bad(Error('Network integration tests failed (see results/log)')):ok());});
}finally{rest.kill();await closed;await fs.rm(cfg,{force:true});}
