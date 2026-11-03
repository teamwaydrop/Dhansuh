import assert from 'node:assert/strict';
let id = 0;
async function load(file: string) { return await import(new URL(`../../../supabase/functions/_shared/${file}?pricing_fixture=${id++}`, import.meta.url).href); }
function fixture() {
  let release!: (v: unknown) => void;
  let result = new Promise(resolve => { release = resolve; });
  const reads: string[] = [];
  const client = {from(table: string) { reads.push(table); const q = {select() {return q;}, eq() {return q;}, then(yes: (v: unknown) => unknown, no: (e: unknown) => unknown) { return result.then(yes, no); }}; return q; }};
  return {client, reads, release(v: unknown) { release(v); }, next(v: unknown) { result = Promise.resolve(v); }};
}
Deno.test('pricing zones: three concurrent quotes share one table read', async () => {
  const {getActivePricingZones: get} = await load('pricing_zones_cache.ts'); const f = fixture();
  const requests = [get(f.client), get(f.client), get(f.client)];
  f.release({data: [{id: 'synthetic-zone'}], error: null});
  assert.deepEqual(await Promise.all(requests), Array(3).fill([{id: 'synthetic-zone'}]));
  assert.deepEqual(f.reads, ['pricing_zones']);
  await get(f.client); assert.equal(f.reads.length, 1);
});
Deno.test('pricing zones: database error is not cached as a valid empty set', async () => {
  const {getActivePricingZones: get} = await load('pricing_zones_cache.ts'); const f = fixture();
  f.release({data: null, error: {code: 'synthetic'}}); assert.equal(await get(f.client), null);
  f.next({data: [{id: 'retry'}], error: null}); assert.deepEqual(await get(f.client), [{id: 'retry'}]); assert.equal(f.reads.length, 2);
});
Deno.test('pricing zones: approved existing 30 second TTL preserved', async () => {
  const original = Date.now; let now = 100000; Date.now = () => now;
  try {
    const {getActivePricingZones: get} = await load('pricing_zones_cache.ts'); const f = fixture();
    f.release({data: [{id: 'old'}], error: null}); await get(f.client); now += 29999;
    await get(f.client); assert.equal(f.reads.length, 1); now++;
    f.next({data: [{id: 'new'}], error: null}); assert.deepEqual(await get(f.client), [{id: 'new'}]); assert.equal(f.reads.length, 2);
  } finally { Date.now = original; }
});
Deno.test('pricing config: concurrent active-approved reads remain coalesced', async () => {
  const {getActivePricingConfigs: get} = await load('pricing_config_cache.ts'); const f = fixture();
  const work = [get(f.client), get(f.client), get(f.client)]; f.release({data: [{id: 'config'}], error: null});
  assert.deepEqual(await Promise.all(work), Array(3).fill([{id: 'config'}])); assert.deepEqual(f.reads, ['pricing_config']);
});
