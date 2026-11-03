// Full handler; synthetic Auth/DB/FCM transports. Deno network permission is denied.
import assert from 'node:assert/strict';
const originalFetch = globalThis.fetch, originalNow = Date.now;
let tick = originalNow(), serial = 0;
Date.now = () => tick;
const key = await crypto.subtle.generateKey({name:'RSASSA-PKCS1-v1_5',modulusLength:2048,publicExponent:new Uint8Array([1,0,1]),hash:'SHA-256'},true,['sign','verify']);
const pem = '-----BEGIN PRIVATE KEY-----\n'+btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.exportKey('pkcs8',key.privateKey))))+'\n-----END PRIVATE KEY-----';
Deno.env.set('SUPABASE_URL','http://127.0.0.1:54328');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY','synthetic-service-key');
Deno.env.set('FIREBASE_SERVICE_ACCOUNT_KEY',JSON.stringify({client_email:'test@example.invalid',private_key:pem,project_id:'synthetic-project'}));
type Scenario = {errorCode?:string,httpStatus?:number,mixed?:boolean,authThrow?:boolean,foreign?:boolean,noTokens?:boolean,disabled?:boolean,prefDisabled?:boolean,cleanupError?:boolean,statusError?:boolean,networkOnly?:boolean};
async function load(s:Scenario={}) {
  tick+=60000;
  const stats={fcm:0,oauth:0,deletes:[] as any[],updates:[] as any[],reads:[] as string[],sent:false, payloads:[] as any[]};
  (globalThis as any).__pushSupabase={auth:{getUser:async(token:string)=>{
    if(s.authThrow)throw Error('synthetic-private-marker');
    return {data:{user:token==='invalid'?null:{id:'user-a'}},error:null};
  }},from(table:string){
    let update:any,del=false;const filters:Record<string,unknown>={};
    const resolve=async()=>{
      if(update){stats.updates.push({patch:update,filters:{...filters}});if(!s.statusError&&update.push_sent)stats.sent=true;return {error:s.statusError?{message:'synthetic-private-marker'}:null};}
      if(del){stats.deletes.push({...filters});return {error:s.cleanupError?{}:null};}
      stats.reads.push(table);
      if(table==='notifications')return {data:s.foreign?null:{id:'n',push_sent:stats.sent},error:null};
      if(table==='production_config')return {data:{notifications_enabled:!s.disabled},error:null};
      if(table==='users')return {data:{pref_chat_notifications:!s.prefDisabled,pref_order_notifications:true,pref_rating_notifications:true,pref_admin_notifications:true,order_notification_mode:'all'},error:null};
      if(table==='user_device_tokens')return {data:s.noTokens?[]:[{fcm_token:'synthetic-token-a',updated_at:'2026-11-01T00:00:00Z'},...(s.mixed?[{fcm_token:'synthetic-token-b',updated_at:'2026-11-01T00:00:00Z'}]:[])],error:null};
      throw Error('Unexpected table '+table);
    };
    const b:any={select(){return b;},eq(k:string,v:unknown){filters[k]=v;return b;},single:resolve,maybeSingle:resolve,update(v:unknown){update=v;return b;},delete(){del=true;return b;},then(ok:any,bad:any){return resolve().then(ok,bad);}};return b;
  }};
  globalThis.fetch=async(input:any,init:any)=>{
    const url=String(input);
    if(url==='https://oauth2.googleapis.com/token') { stats.oauth++;return Response.json({access_token:'synthetic-access',expires_in:3600}); }
    assert.ok(url.startsWith('https://fcm.googleapis.com/v1/projects/synthetic-project/'));
    stats.fcm++;
    const payload=JSON.parse(init.body);stats.payloads.push(payload);
    if(s.networkOnly||(s.mixed&&payload.message.token==='synthetic-token-b'))throw Error('synthetic-private-marker');
    return Response.json(s.errorCode?{error:{details:[{'@type':'type.googleapis.com/google.firebase.fcm.v1.FcmError',errorCode:s.errorCode}],message:'synthetic-private-marker'}}:{name:'synthetic-ok'}, {status:s.httpStatus??200});
  };
  const path=Deno.env.get('PART4_BASELINE')==='1'
    ? new URL('../../../.dart_tool/waydrop-local-runtime/part4-push-baseline/send-push-notification/index.ts',import.meta.url)
    : new URL('../../../supabase/functions/send-push-notification/index.ts',import.meta.url);
  await import(path.href+'?case='+serial++);
  const handler=(globalThis as any).__pushHandler;
  const request=async(token='synthetic-service-key',body:any={user_id:'user-a',title:'Synthetic title',body:'Synthetic body',data:{type:'chat_message',notification_id:'n'}})=>{
    const response=await handler(new Request('http://localhost/test',{method:'POST',headers:{Authorization:'Bearer '+token},body:JSON.stringify(body)}));
    return {status:response.status,body:await response.json()};
  };
  return {stats,request,s};
}
Deno.test('token cleanup: arbitrary 404 must retain token',async()=>{
  const t=await load({httpStatus:404});await t.request();assert.equal(t.stats.deletes.length,0);
});
Deno.test('sibling: one network failure preserves successful delivery',async()=>{
  const t=await load({mixed:true});const r=await t.request();assert.equal(r.status,200);assert.equal(r.body.success,true);assert.ok(t.stats.updates.some(x=>x.patch.push_sent===true));
});
Deno.test('scope: authorization transport failure must not update any notification',async()=>{
  const t=await load({authThrow:true});await t.request('user-session');assert.equal(t.stats.updates.length,0);
});
Deno.test('typed UNREGISTERED cleanup is recipient and registration-version scoped',async()=>{
  const t=await load({httpStatus:404,errorCode:'UNREGISTERED'});const r=await t.request();
  assert.equal(r.body.success,false);assert.deepEqual(t.stats.deletes,[{fcm_token:'synthetic-token-a',user_id:'user-a',updated_at:'2026-11-01T00:00:00Z'}]);
  assert.ok(t.stats.updates.every(x=>x.filters.user_id==='user-a'));
});
Deno.test('INVALID_ARGUMENT, transient and untyped errors never prune tokens',async()=>{
  for(const [code,status]of [['INVALID_ARGUMENT',400],['UNAVAILABLE',503],['QUOTA_EXCEEDED',429],['INTERNAL',500],['UNREGISTERED',410]]) {
    const t=await load({httpStatus:status as number,errorCode:code as string});await t.request();
    assert.equal(t.stats.deletes.length,code==='UNREGISTERED'?1:0);
  }
  const t=await load({httpStatus:410});await t.request();assert.equal(t.stats.deletes.length,0);
});
Deno.test('sequential recorded-success replay sends once; warm OAuth remains cached',async()=>{
  const t=await load();await t.request();const r=await t.request();
  assert.equal(r.body.already_sent,true);assert.equal(t.stats.fcm,1);assert.equal(t.stats.oauth,1);
  t.stats.sent=false;await t.request();assert.equal(t.stats.oauth,1);assert.equal(t.stats.fcm,2);
});
Deno.test('foreign notification id returns 404 before provider or status writes',async()=>{
  const t=await load({foreign:true});assert.equal((await t.request('user-session')).status,404);
  assert.equal(t.stats.fcm,0);assert.equal(t.stats.updates.length,0);
});
Deno.test('empty tokens recorded skipped; inbox not deleted',async()=>{
  const t=await load({noTokens:true});await t.request();assert.equal(t.stats.oauth,0);
  assert.ok(t.stats.updates.some(x=>x.patch.delivery_status==='skipped'&&x.patch.delivery_error==='NO_REGISTERED_TOKENS'));
  assert.equal(t.stats.deletes.length,0);
});
Deno.test('preference and global flag remain enforced',async()=>{
  for(const s of [{prefDisabled:true},{disabled:true}]){const t=await load(s);await t.request();assert.equal(t.stats.fcm,0);assert.equal(t.stats.oauth,0);}
});
Deno.test('invalid session and cross-user target cannot send or update',async()=>{
  const t=await load();assert.equal((await t.request('invalid')).status,401);
  assert.equal((await t.request('user-session',{user_id:'other',title:'x',body:'y',data:{notification_id:'n'}})).status,403);
  assert.equal(t.stats.fcm,0);assert.equal(t.stats.updates.length,0);
});
Deno.test('network-only failures give explicit failure without token or provider text disclosure',async()=>{
  const t=await load({networkOnly:true});const r=await t.request();assert.equal(r.body.success,false);
  const text=JSON.stringify(r.body);assert.ok(!text.includes('synthetic-token'));assert.ok(!text.includes('synthetic-private-marker'));
  assert.ok(t.stats.updates.some(x=>x.patch.delivery_status==='failed'));
});
Deno.test('cleanup error remains a failed delivery without throwing the handler',async()=>{
  const t=await load({httpStatus:404,errorCode:'UNREGISTERED',cleanupError:true});await t.request();
  assert.ok(t.stats.updates.some(x=>x.patch.delivery_status==='failed'));
});
Deno.test('simultaneous replays are not exactly-once: two requests can both send',async()=>{
  const t=await load();await Promise.all([t.request(),t.request()]);
  assert.equal(t.stats.fcm,2); // Remaining cross-request claim/fencing gap.
});
Deno.test('provider accepts but DB status error remains ambiguous and replayable',async()=>{
  const t=await load({statusError:true});await t.request();await t.request();
  assert.equal(t.stats.fcm,2); // Deliberately document the remaining exactly-once gap.
});
Deno.test('chat payload preserves title/body/type and platform sound/icon',async()=>{
  const t=await load();await t.request();const m=t.stats.payloads[0].message;
  assert.equal(m.notification.body,'Synthetic body');assert.equal(m.data.type,'chat_message');
  assert.equal(m.android.notification.icon,'ic_stat_notify');assert.equal(m.android.notification.channel_id,'high_importance_channel');
});
Deno.test('restore globals',()=>{Date.now=originalNow;globalThis.fetch=originalFetch;});
