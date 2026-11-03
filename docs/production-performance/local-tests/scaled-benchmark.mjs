import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../../..');
const exe=path.join(root,'.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe');
const uid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
function sql(input){const r=spawnSync(exe,['-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d','waydrop_perf_test'],{input,encoding:'utf8',windowsHide:true});if(r.status)throw Error(r.stderr);return r.stdout.trim();}
const median=a=>[...a].sort((a,b)=>a-b)[Math.floor(a.length/2)];
function measure(statement){
  const explain=('EXPLAIN(ANALYZE,FORMAT JSON) '+statement).replaceAll("'","''");
  return JSON.parse(sql(`CREATE TEMP TABLE bench_plans(i integer,p jsonb); DO $$ DECLARE i integer; p jsonb; BEGIN FOR i IN 1..15 LOOP EXECUTE '${explain}' INTO p; INSERT INTO bench_plans VALUES(i,p); END LOOP; END $$; SELECT jsonb_agg((p->0->>'Execution Time')::numeric ORDER BY i) FROM bench_plans WHERE i>3;`));
}
const result={scope:'Synthetic scale/mechanism check only; one backend per scenario with three warmups and twelve measured calls. No production latency forecast.',riders:{},orders:{}};
try{
  sql(`INSERT INTO users SELECT md5('SCALE-USER-'||g)::uuid FROM generate_series(1,500)g; INSERT INTO rider_kyc SELECT (jsonb_populate_record(NULL::rider_kyc,to_jsonb(k)||jsonb_build_object('id',md5('SCALE-KYC-'||g)::uuid,'user_id',md5('SCALE-USER-'||g)::uuid))).* FROM rider_kyc k CROSS JOIN generate_series(1,500)g WHERE k.id='${uid(101)}'; INSERT INTO riders SELECT (jsonb_populate_record(NULL::riders,to_jsonb(r)||jsonb_build_object('id',md5('SCALE-RIDER-'||g)::uuid,'kyc_id',md5('SCALE-KYC-'||g)::uuid,'user_id',md5('SCALE-USER-'||g)::uuid,'current_lat',45,'current_lng',40,'last_location_updated_at',clock_timestamp()))).* FROM riders r CROSS JOIN generate_series(1,500)g WHERE r.id='${uid(201)}'; UPDATE riders SET last_location_updated_at=clock_timestamp(); ANALYZE;`);
  for(const mode of ['original','proposed']){
    const source=await fs.readFile(path.join(root,mode==='original'?'.dart_tool/production_performance_preflight_20261101/find_nearby_riders.before.sql':'docs/production-performance/waves/01_find_nearby_riders.sql'),'utf8');sql(source.replace(/ROLLBACK;\s*$/,'COMMIT;'));
    const samples=measure(`SELECT * FROM find_nearby_riders('${uid(1000)}',17,79,5,10);`);result.riders[mode]={rows:560,farRows:500,samples:samples.length,median_ms:median(samples)};
  }
  sql(`INSERT INTO orders SELECT (jsonb_populate_record(NULL::orders,to_jsonb(o)||jsonb_build_object('id',md5('SCALE-ORDER-'||g)::uuid,'order_code','SCALE-ORDER-'||g,'pickup_lat',45,'pickup_lng',40,'created_at',clock_timestamp()))).* FROM orders o CROSS JOIN generate_series(1,1000)g WHERE o.id='${uid(1000)}'; ANALYZE;`);
  for(const mode of ['original','proposed']){
    const source=await fs.readFile(path.join(root,mode==='original'?'.dart_tool/production_performance_preflight_20261101/assign_nearby_searching_orders_core.before.sql':'docs/production-performance/waves/02_assign_nearby_searching_orders_core.sql'),'utf8');sql(source.replace(/ROLLBACK;\s*$/,'COMMIT;'));
    const samples=measure(`SELECT assign_nearby_searching_orders_core('${uid(201)}','${uid(9001)}',17,79,'local');`);result.orders[mode]={farSearchingOrders:1000,samples:samples.length,median_ms:median(samples)};
  }
}finally{
  sql("DELETE FROM orders WHERE order_code LIKE 'SCALE-ORDER-%'; DELETE FROM users WHERE id IN (SELECT md5('SCALE-USER-'||g)::uuid FROM generate_series(1,500)g);");
  for(const name of ['find_nearby_riders','assign_nearby_searching_orders_core'])sql(await fs.readFile(path.join(root,'.dart_tool/production_performance_preflight_20261101/'+name+'.before.sql'),'utf8'));
}
await fs.writeFile(path.join(here,'SCALED_PERFORMANCE.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result,null,2));
