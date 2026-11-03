// Synthetic loopback PostgreSQL only. No configurable remote endpoint or production data.
import {spawn} from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
const root=process.cwd();
const exe=path.join(root,'.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe');
function sql(text) { return new Promise((resolve,reject)=>{
  const child=spawn(exe,['-X','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d','waydrop_perf_test','-Atq','-v','ON_ERROR_STOP=1'],
    {windowsHide:true,env:{...process.env,PGCONNECT_TIMEOUT:'3',PGOPTIONS:'-c statement_timeout=5000 -c lock_timeout=3000'}});
  let out='',err='';child.stdout.on('data',b=>out+=b);child.stderr.on('data',b=>err+=b);
  child.on('error',reject);child.on('close',code=>code?reject(Error(err)):resolve(out.trim()));child.stdin.end(text);
}); }
const schema='loading_spike_chat_test';
const results=[];
try {
  await sql(`CREATE SCHEMA ${schema};
    CREATE TABLE ${schema}.messages(id uuid PRIMARY KEY, body text);
    CREATE TABLE ${schema}.notification_effects(message_id uuid);
    CREATE FUNCTION ${schema}.notify() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
      INSERT INTO ${schema}.notification_effects VALUES(NEW.id); RETURN NEW; END $$;
    CREATE TRIGGER notify AFTER INSERT ON ${schema}.messages FOR EACH ROW EXECUTE FUNCTION ${schema}.notify();`);
  const insert=`INSERT INTO ${schema}.messages VALUES('00000000-0000-4000-8000-000000000001','synthetic');`;
  const attempts=await Promise.allSettled(Array.from({length:16},()=>sql(insert)));
  assert.equal(attempts.filter(x=>x.status==='fulfilled').length,1);
  assert.equal(attempts.filter(x=>x.status==='rejected'&&/duplicate key/.test(x.reason.message)).length,15);
  assert.equal(await sql(`SELECT count(*) FROM ${schema}.messages;`),'1');
  assert.equal(await sql(`SELECT count(*) FROM ${schema}.notification_effects;`),'1');
  results.push({name:'16 concurrent retries share UUID: one commit and one AFTER INSERT effect',status:'PASS',successful_inserts:1,duplicate_rejections:15});
  await assert.rejects(sql(insert),/duplicate key/);
  assert.equal(await sql(`SELECT count(*) FROM ${schema}.notification_effects;`),'1');
  results.push({name:'replay after committed response loss produces no additional notification effect',status:'PASS'});
  await sql(`BEGIN; INSERT INTO ${schema}.messages VALUES('00000000-0000-4000-8000-000000000002','rollback'); ROLLBACK;`);
  assert.equal(await sql(`SELECT count(*) FROM ${schema}.notification_effects;`),'1');
  results.push({name:'rolled-back INSERT also rolls back notification side effect',status:'PASS'});
} finally {
  // Fixed synthetic schema only; preserve the existing acceptance fixtures.
  await sql(`DROP SCHEMA IF EXISTS ${schema} CASCADE;`);
  await fs.writeFile(path.join(root,'docs/performance/loading-spike-20261101/PG17_RESULTS.json'),JSON.stringify({
    environment:'local PostgreSQL 17 loopback; PK/AFTER trigger semantics only, not managed RLS/pg_net integration',results},null,2));
}
assert.equal(results.length,3);console.log(JSON.stringify(results));
