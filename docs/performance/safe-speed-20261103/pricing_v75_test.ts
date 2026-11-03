import assert from 'node:assert/strict';
Deno.env.set('SUPABASE_URL','https://synthetic.invalid');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY','synthetic-not-a-key');
const originalNow = Date.now; let tick = originalNow(); Date.now = () => tick;
let serial = 0;
async function run(candidate: boolean, fallback=false, invalid=false) {
  tick += 60000;
  const reads: {table:string;limit?:number}[] = [];
  let release!:()=>void;
  const zoneGate = new Promise<void>(r=>{release=r;});
  const zone = {id:'zone-a',zone_code:'SYNTHETIC',zone_name:'Synthetic',zone_type:'city',cities:['Synthetic'],center_lat:0,center_lng:0,radius_km:1};
  const config = {id:'config-a',pricing_zone_id:'zone-a',service_type:'ride',vehicle_type:'bike',pricing_rules:{base_fare:20,per_km_rate:5},discount_percentage:0,gst_percentage:0,commission_percentage:10};
  (globalThis as any).__pricingClient = {auth:{getUser:async()=>({data:{user:null},error:null})},from(table:string){
    let limit:number|undefined;
    const q:any={select(){return q;},eq(){return q;},limit(value:number){limit=value;return q;},then(yes:any,no:any){
      reads.push({table,limit});
      return (async()=>{if(table==='pricing_zones'){await zoneGate;return {data:[zone],error:null};}if(table==='pricing_config')return {data:[config],error:null};throw Error('Unexpected table '+table);})().then(yes,no);
    }};return q;
  }};
  const folder=candidate?'pricing-v75-zone-candidate':'pricing-v75-baseline';
  await import(new URL(`./${folder}/functions/calculate-order-pricing/index.ts?fixture=${serial++}`,import.meta.url).href);
  const handler=(globalThis as any).__pricingHandler;
  const work=Array.from({length:3},()=>handler(new Request('https://synthetic.invalid/pricing',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(invalid?{}:{order_type:'ride',vehicle_type:'bike',pickup_lat:fallback?1:0,pickup_lng:0,pickup_address:'',distance_km:fallback?50:5,max_boost_amount:0})})));
  for(let n=0;n<30;n++)await Promise.resolve();
  const configBeforeZone=reads.some(r=>r.table==='pricing_config');release();
  const responses=await Promise.all(work);
  return {values:await Promise.all(responses.map(async(r:Response)=>({status:r.status,body:await r.json()}))),reads,configBeforeZone};
}
Deno.test('v75 differential normal quote responses unchanged; three zone reads become one',async()=>{
  const before=await run(false),after=await run(true);
  assert.equal(before.values[0].status,200);assert.deepEqual(after.values,before.values);
  assert.equal(before.reads.filter(r=>r.table==='pricing_zones').length,3);
  assert.equal(after.reads.filter(r=>r.table==='pricing_zones').length,1);
  assert.ok(before.configBeforeZone&&after.configBeforeZone);
});
Deno.test('v75 fresh LIMIT-1 fallback and fare response remain unchanged',async()=>{
  const before=await run(false,true),after=await run(true,true);
  assert.equal(before.values[0].status,200);assert.deepEqual(after.values,before.values);
  assert.equal(before.reads.filter(r=>r.table==='pricing_zones'&&r.limit===1).length,3);
  assert.equal(after.reads.filter(r=>r.table==='pricing_zones'&&r.limit===1).length,3);
});
Deno.test('v75 missing-field rejection remains 400 without table reads',async()=>{
  const before=await run(false,false,true),after=await run(true,false,true);
  assert.equal(before.values[0].status,400);assert.deepEqual(after.values,before.values);assert.equal(after.reads.length,0);
});
Deno.test('restore synthetic clock',()=>{Date.now=originalNow;});
