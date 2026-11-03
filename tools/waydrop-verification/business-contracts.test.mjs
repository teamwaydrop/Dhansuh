import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { calculateFare, buildPricingResponse, roundToWholeRupee } from '../../supabase/functions/calculate-order-pricing/pricing-calculations.ts';
import { normalizeIndianPhone, resolveCashfreeCustomerPhone } from '../../supabase/functions/_shared/customer_phone.ts';
import { isFeatureEnabled } from '../../supabase/functions/_shared/production_config_cache.ts';

test('actual pricing helper recognizes every existing per-km alias in precedence order',()=>{
  assert.equal(calculateFare({per_km_rate:2.5},10).baseFare,25);
  assert.equal(calculateFare({per_km:3,per_km_rate:2.5},10).baseFare,30);
  assert.equal(calculateFare({per_km_charge:4,per_km:3,per_km_rate:2.5},10).baseFare,40);
  assert.equal(calculateFare({after_base_per_km:5,per_km_charge:4,per_km:3,per_km_rate:2.5},10).baseFare,50);
  assert.equal(calculateFare({base_price:20,base_km:2,per_km_rate:2.5},10).baseFare,40);
});
test('actual fare engine preserves minimum, slab and weight charges',()=>{
  assert.equal(calculateFare({minimum_fare:30,per_km_rate:2},1).baseFare,32);
  assert.equal(calculateFare({pricing_type:'slab',slabs:[{from_km:5,per_km:2},{from_km:0,per_km:4}]},10).baseFare,30);
  assert.equal(calculateFare({per_km_rate:2.5,weight_charges:[{max_kg:5,extra_charge:5},{max_kg:10,extra_charge:10}]},10,8).baseFare,35);
});
test('actual response builder preserves rounded payable total and unrounded commission calculation',()=>{
  const {pricing:p}=buildPricingResponse(100.25,10,15,5,10,'bike','ride',{}, {zone_type:'tier_1'},'Synthetic',10,{});
  const fare=(100.25+10)*0.9;
  assert.equal(Number(p.final_fare),roundToWholeRupee(fare*1.05));
  assert.equal(Number(p.commission_amount),Number((fare*0.15).toFixed(2)));
  assert.equal(Number(p.rider_earning),Number((fare*0.85).toFixed(2)));
});
test('actual phone helper normalizes country prefix and never invents a real customer number',async()=>{
  assert.equal(normalizeIndianPhone('+91 98765 43210'),'9876543210');
  assert.equal(normalizeIndianPhone('invalid'),null);
  const admin={auth:{admin:{getUserById:async()=>({data:{user:{phone:'919876543210',is_anonymous:false}}})}}};
  assert.deepEqual(await resolveCashfreeCustomerPhone(admin,'owner'),{phone:'9876543210',isReviewer:false});
  const missing={auth:{admin:{getUserById:async()=>({data:{user:{is_anonymous:false}}})}},
    from:()=>({select:()=>({eq:()=>({maybeSingle:async()=>({data:null})})})})};
  assert.deepEqual(await resolveCashfreeCustomerPhone(missing,'owner'),{phone:null,isReviewer:false});
});

test('execute the shipped create-order flag gate for all service types without any order writes',async()=>{
  const source=await fs.readFile(new URL('../../supabase/functions/create-order/index.ts',import.meta.url),'utf8');
  const start=source.indexOf('    const productionConfig = await getProductionConfig(supabase);');
  const end=source.indexOf('    // =====================================================\n    // NORMALIZE PARCEL TYPE',start);
  assert.ok(start>source.indexOf('await supabase.auth.getUser(authToken)'));
  assert.ok(end>start);
  const actualGate=source.slice(start,end);
  class HttpError extends Error { constructor(status,message,code){super(message);this.status=status;this.code=code;} }
  const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
  const gate=new AsyncFunction('order_type','getProductionConfig','isFeatureEnabled','HttpError','supabase',actualGate);
  for(const type of ['ride','local_parcel','intercity_ride','intercity_parcel','batch_delivery','food_delivery','grocery_delivery']) {
    await gate(type,async()=>null,isFeatureEnabled,HttpError,{});
  }
  for(const [type,flag] of [['ride','local_rides_enabled'],['ride','ride_booking_enabled'],['local_parcel','parcel_enabled'],['intercity_ride','intercity_enabled'],['intercity_parcel','intercity_enabled']]) {
    await assert.rejects(()=>gate(type,async()=>({[flag]:false}),isFeatureEnabled,HttpError,{}),e=>e.status===503&&e.code==='FEATURE_DISABLED');
  }
  await gate('local_parcel',async()=>({intercity_enabled:false}),isFeatureEnabled,HttpError,{});
  await gate('intercity_parcel',async()=>({parcel_enabled:false}),isFeatureEnabled,HttpError,{});
});
