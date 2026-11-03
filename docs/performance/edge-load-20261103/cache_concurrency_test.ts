import assert from 'node:assert/strict';

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}
let serial = 0;
async function helper(file: string) {
  return await import(new URL(`../../../supabase/functions/_shared/${file}?fixture=${serial++}`, import.meta.url).href);
}
async function flush() { for (let i = 0; i < 12; i++) await Promise.resolve(); }
function fakeTime() {
  const originalNow = Date.now, originalSet = globalThis.setTimeout, originalClear = globalThis.clearTimeout;
  let now = 100000, id = 0;
  const timers = new Map<number, () => void>();
  Date.now = () => now;
  globalThis.setTimeout = ((fn: () => void) => { timers.set(++id, fn); return id; }) as unknown as typeof setTimeout;
  globalThis.clearTimeout = ((key: number) => { timers.delete(key); }) as typeof clearTimeout;
  return { timers, advance(ms: number) { now += ms; }, fire() { const work = [...timers.values()]; timers.clear(); work.forEach(fn => fn()); }, restore() { Date.now = originalNow; globalThis.setTimeout = originalSet; globalThis.clearTimeout = originalClear; } };
}
function storage(fetcher: (path: string) => unknown) {
  return {storage: {from(bucket: string) { assert.equal(bucket, 'rider_kyc'); return {createSignedUrl(path: string, expiry: number) { assert.equal(expiry, 21600); return fetcher(path); }}; }}};
}

Deno.test('signed URL: concurrent same-path misses issue one Storage operation', async () => {
  const {getSignedRiderImageUrl: get} = await helper('signed_url_cache.ts');
  const gate = deferred<unknown>(); let calls = 0;
  const client = storage(() => { calls++; return gate.promise; });
  const pending = [get(client, 'a'), get(client, 'a'), get(client, 'a')];
  await flush(); const observed = calls;
  gate.resolve({data: {signedUrl: 'synthetic-a'}});
  assert.deepEqual(await Promise.all(pending), ['synthetic-a', 'synthetic-a', 'synthetic-a']);
  assert.equal(observed, 1);
});
Deno.test('signed URL: unrelated paths remain independent and completed URL is reused', async () => {
  const {getSignedRiderImageUrl: get} = await helper('signed_url_cache.ts'); let calls = 0;
  const client = storage(async path => { calls++; return {data: {signedUrl: path}}; });
  assert.deepEqual(await Promise.all([get(client, 'a'), get(client, 'b')]), ['a', 'b']);
  assert.equal(await get(client, 'a'), 'a'); assert.equal(calls, 2);
});
Deno.test('signed URL: null failure releases claim and does not cache failure', async () => {
  const {getSignedRiderImageUrl: get} = await helper('signed_url_cache.ts'); let calls = 0;
  const client = storage(async () => { calls++; return calls === 1 ? {data: null, error: {code: 'synthetic'}} : {data: {signedUrl: 'retry'}}; });
  assert.equal(await get(client, 'a'), null); assert.equal(await get(client, 'a'), 'retry'); assert.equal(calls, 2);
});
Deno.test('signed URL: thrown failure releases claim for retry', async () => {
  const {getSignedRiderImageUrl: get} = await helper('signed_url_cache.ts'); let calls = 0;
  const client = storage(() => { if (++calls === 1) throw Error('synthetic'); return Promise.resolve({data: {signedUrl: 'retry'}}); });
  await assert.rejects(get(client, 'a'), /synthetic/); assert.equal(await get(client, 'a'), 'retry');
});
Deno.test('signed URL: existing 5.5 hour refresh boundary preserved', async () => {
  const clock = fakeTime();
  try {
    const {getSignedRiderImageUrl: get} = await helper('signed_url_cache.ts'); let calls = 0;
    const client = storage(async () => ({data: {signedUrl: `value-${++calls}`}}));
    assert.equal(await get(client, 'a'), 'value-1'); clock.advance(5.5*3600000-1);
    assert.equal(await get(client, 'a'), 'value-1'); clock.advance(1);
    assert.equal(await get(client, 'a'), 'value-2');
  } finally { clock.restore(); }
});
Deno.test('ETA: overlapping same-order requests share one provider operation', async () => {
  const clock = fakeTime();
  try {
    const {getEtaWithBudget: get} = await helper('eta_cache.ts'); const gate = deferred<unknown>(); let calls = 0;
    const fetcher = () => { calls++; return gate.promise; };
    const work = [get('a', fetcher), get('a', fetcher), get('a', fetcher)];
    await flush(); const observed = calls;
    gate.resolve({distanceKm: 2, estimatedArrivalMinutes: 3});
    assert.deepEqual(await Promise.all(work), Array(3).fill({distanceKm: 2, estimatedArrivalMinutes: 3}));
    assert.equal(observed, 1);
  } finally { clock.restore(); }
});
Deno.test('ETA: visible deadline retains ownership until raw provider settles', async () => {
  const clock = fakeTime();
  try {
    const {getEtaWithBudget: get} = await helper('eta_cache.ts'); const gate = deferred<unknown>(); let calls = 0;
    const fetcher = () => { calls++; return gate.promise; };
    const first = get('a', fetcher); await flush(); clock.fire();
    assert.equal((await first).degraded, true);
    const retry = get('a', fetcher); await flush(); const observed = calls;
    gate.resolve({distanceKm: 2, estimatedArrivalMinutes: 3}); await retry;
    assert.equal(observed, 1); assert.equal((await get('a', fetcher)).degraded, undefined);
  } finally { clock.restore(); }
});
Deno.test('ETA: failures release ownership; retry can succeed', async () => {
  const clock = fakeTime();
  try {
    const {getEtaWithBudget: get} = await helper('eta_cache.ts'); let calls = 0;
    const fetcher = async () => { if (++calls === 1) throw Error('synthetic'); return {distanceKm: 2, estimatedArrivalMinutes: 3}; };
    assert.equal((await get('a', fetcher)).degraded, true);
    assert.equal((await get('a', fetcher)).distanceKm, 2); assert.equal(calls, 2);
  } finally { clock.restore(); }
});
Deno.test('ETA: different orders remain independent', async () => {
  const clock = fakeTime();
  try {
    const {getEtaWithBudget: get} = await helper('eta_cache.ts'); let calls = 0;
    const fetcher = async () => ({distanceKm: ++calls, estimatedArrivalMinutes: 3});
    const values = await Promise.all([get('a', fetcher), get('b', fetcher)]);
    assert.equal(calls, 2); assert.notEqual(values[0].distanceKm, values[1].distanceKm);
  } finally { clock.restore(); }
});
Deno.test('ETA: successful operation clears unused deadline timer', async () => {
  const clock = fakeTime();
  try {
    const {getEtaWithBudget: get} = await helper('eta_cache.ts');
    await get('a', async () => ({distanceKm: 2, estimatedArrivalMinutes: 3}));
    assert.equal(clock.timers.size, 0);
  } finally { clock.restore(); }
});
Deno.test('ETA: 20 second TTL and degraded last-good fallback preserved', async () => {
  const clock = fakeTime();
  try {
    const {getEtaWithBudget: get} = await helper('eta_cache.ts'); let calls = 0;
    const fetcher = async () => { if (++calls > 1) throw Error('synthetic'); return {distanceKm: 2, estimatedArrivalMinutes: 3}; };
    await get('a', fetcher); clock.advance(19999); await get('a', fetcher); assert.equal(calls, 1);
    clock.advance(1); assert.deepEqual(await get('a', fetcher), {distanceKm: 2, estimatedArrivalMinutes: 3, degraded: true}); assert.equal(calls, 2);
  } finally { clock.restore(); }
});
Deno.test('ETA: synchronous provider failure also returns degraded response', async () => {
  const clock = fakeTime();
  try {
    const {getEtaWithBudget: get} = await helper('eta_cache.ts');
    assert.equal((await get('a', () => { throw Error('synthetic'); })).degraded, true);
  } finally { clock.restore(); }
});
