import assert from 'node:assert/strict';
Deno.env.set('SUPABASE_URL', 'https://synthetic.invalid');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'synthetic-not-a-key');
await import('./functions/process-verification-photo/index.ts');
type Scenario = {missing?: boolean; foreign?: boolean; unassigned?: boolean; invalidType?: boolean; authFail?: boolean; riderForeign?: boolean; orderError?: boolean; emptyPostgrest?: boolean; dropoff?: boolean};
async function request(s: Scenario = {}) {
  const stats = {downloads: 0, writes: [] as string[], reads: [] as string[]};
  (globalThis as any).__photoClient = {auth: {getUser: async () => ({data: {user: s.authFail ? null : {id: 'own-user'}}, error: null})}, from(table: string) {
    let write = false;
    async function finish() {
      if (write) { stats.writes.push(table); return {data: {id: 'synthetic-photo'}, error: null}; }
      stats.reads.push(table);
      if (table === 'riders') return {data: {user_id: s.riderForeign ? 'foreign-user' : 'own-user'}, error: null};
      if (table === 'orders') return {data: s.missing || s.orderError || s.emptyPostgrest ? null : {user_id: 'sender', rider_id: s.unassigned ? null : s.foreign ? 'other-rider' : 'own-rider'}, error: s.orderError ? {code: '57014'} : s.emptyPostgrest ? {code: 'PGRST116'} : null};
      throw Error('Unexpected read '+table);
    }
    const q: any = {select() {return q;}, eq() {return q;}, insert() {write = true; return q;}, update() {write = true; return q;}, single: finish, then(yes: any, no: any) {return finish().then(yes, no);}}; return q;
  }};
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => { stats.downloads++; return new Response(new Uint8Array([1,2,3])); };
  try {
    const response = await (globalThis as any).__photoHandler(new Request('https://synthetic.invalid/functions/v1/process-verification-photo', {method: 'POST', headers: {Authorization: 'Bearer synthetic', 'Content-Type': 'application/json'}, body: JSON.stringify({order_id: 'order-a', rider_id: 'own-rider', photo_type: s.invalidType ? 'arbitrary' : s.dropoff ? 'dropoff' : 'pickup', photo_url: 'https://synthetic.invalid/storage/v1/object/public/parcel_images/synthetic.jpg'})}));
    return {status: response.status, stats};
  } finally { globalThis.fetch = originalFetch; }
}
for (const [name, scenario, expected] of [
  ['different assigned rider', {foreign: true}, 403],
  ['unassigned order', {unassigned: true}, 403],
  ['missing order', {missing: true}, 404],
  ['PostgREST empty single', {emptyPostgrest: true}, 404],
  ['order database error', {orderError: true}, 503],
  ['invalid proof type', {invalidType: true}, 400],
  ['invalid Auth', {authFail: true}, 401],
  ['foreign rider account', {riderForeign: true}, 403],
] as const) {
  Deno.test(`photo: ${name} stops before download and writes`, async () => {
    const result = await request(scenario);
    assert.equal(result.status, expected); assert.equal(result.stats.downloads, 0); assert.deepEqual(result.stats.writes, []);
  });
}
Deno.test('photo: assigned rider retains valid pickup proof writes', async () => {
  const result = await request(); assert.equal(result.status, 200); assert.equal(result.stats.downloads, 1);
  assert.deepEqual(result.stats.writes, ['order_parcel_photos', 'orders', 'order_verifications', 'parcel_security_logs']);
  assert.deepEqual(result.stats.reads, ['riders', 'orders']);
});
Deno.test('photo: assigned rider dropoff retains proof writes without pickup flag update', async () => {
  const result = await request({dropoff: true}); assert.equal(result.status, 200); assert.equal(result.stats.downloads, 1);
  assert.deepEqual(result.stats.writes, ['order_parcel_photos', 'order_verifications', 'parcel_security_logs']);
});
