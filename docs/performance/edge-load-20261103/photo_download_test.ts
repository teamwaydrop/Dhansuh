import assert from 'node:assert/strict';
import {downloadPhotoBytes} from '../../../supabase/functions/_shared/photo_download.ts';

async function fixture(work: (fire: () => void, timerCount: () => number) => Promise<void>) {
  const originalFetch = globalThis.fetch, originalSet = globalThis.setTimeout, originalClear = globalThis.clearTimeout;
  const timers = new Map<number, () => void>(); let id = 0;
  globalThis.setTimeout = ((fn: () => void) => {timers.set(++id,fn);return id;}) as unknown as typeof setTimeout;
  globalThis.clearTimeout = ((key: number) => {timers.delete(key);}) as typeof clearTimeout;
  try { await work(() => [...timers.values()].forEach(fn=>fn()),()=>timers.size); }
  finally { globalThis.fetch = originalFetch;globalThis.setTimeout=originalSet;globalThis.clearTimeout=originalClear; }
}
Deno.test('photo body deadline aborts after headers arrive but body is held', () => fixture(async fire => {
  let bodyController!: ReadableStreamDefaultController<Uint8Array>;
  globalThis.fetch = async (_url, init) => {
    const body = new ReadableStream<Uint8Array>({start(controller){bodyController=controller;}});
    init!.signal!.addEventListener('abort',()=>bodyController.error(new DOMException('synthetic','AbortError')),{once:true});
    return new Response(body);
  };
  const work = downloadPhotoBytes('https://synthetic.invalid/image');
  await Promise.resolve(); await Promise.resolve(); fire();
  await assert.rejects(work, error => error instanceof Error && error.name==='AbortError');
}));
Deno.test('photo successful body is unchanged and deadline timer is cleared', () => fixture(async (_fire,count) => {
  globalThis.fetch = async () => new Response(new Uint8Array([255,216,255,1,2,3]));
  assert.deepEqual(new Uint8Array(await downloadPhotoBytes('https://synthetic.invalid/image')),new Uint8Array([255,216,255,1,2,3]));
  assert.equal(count(),0);
}));
Deno.test('photo timeout before headers also aborts and clears timer', () => fixture(async (fire,count) => {
  globalThis.fetch = (_url,init) => new Promise((_resolve,reject)=>init!.signal!.addEventListener('abort',()=>reject(new DOMException('synthetic','AbortError')),{once:true}));
  const work = downloadPhotoBytes('https://synthetic.invalid/image'); fire();
  await assert.rejects(work,error=>error instanceof Error && error.name==='AbortError'); assert.equal(count(),0);
}));
Deno.test('photo non-success response fails without returning provider content', () => fixture(async (_fire,count) => {
  globalThis.fetch = async () => new Response('synthetic-private-provider-body',{status:503});
  await assert.rejects(downloadPhotoBytes('https://synthetic.invalid/image'),{message:'Failed to download image from storage (HTTP 503)'}); assert.equal(count(),0);
}));
