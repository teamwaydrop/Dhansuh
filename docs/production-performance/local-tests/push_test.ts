// Full unmodified handler body, actual WebCrypto signing and fetchWithTimeout.
// Deno denies network. Provider/Auth/DB boundaries are mock transports, not real delivery.
import assert from 'node:assert/strict';
const base=new URL('../../../.dart_tool/waydrop-local-runtime/push-under-test/',import.meta.url);
const originalNow=Date.now;const originalFetch=globalThis.fetch;
let tick=originalNow(),serial=0;
Date.now=()=>tick;
const key=await crypto.subtle.generateKey({name:'RSASSA-PKCS1-v1_5',modulusLength:2048,publicExponent:new Uint8Array([1,0,1]),hash:'SHA-256'},true,['sign','verify']);
const der=new Uint8Array(await crypto.subtle.exportKey('pkcs8',key.privateKey));
const pem='-----BEGIN PRIVATE KEY-----\n'+btoa(String.fromCharCode(...der))+'\n-----END PRIVATE KEY-----';
Deno.env.set('SUPABASE_URL','http://127.0.0.1:54328');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY','synthetic-service-key');
Deno.env.set('FIREBASE_SERVICE_ACCOUNT_KEY',JSON.stringify({client_email:'test@example.invalid',private_key:pem,project_id:'synthetic-test-project'}));
type Scenario={disabled?:boolean,pref?:Record<string,unknown>,noTokens?:boolean,authInvalid?:boolean,prefError?:boolean,tokenError?:boolean,oauthFail?:boolean,fcmStatus?:number,timeout?:boolean};
async function load(variant:string,s:Scenario={}){
  tick+=60000;
  const stats={reads:[] as string[],updates:[] as any[],deletes:0,oauth:0,fcm:0,payloads:[] as any[]};
  (globalThis as any).__pushSupabase={auth:{getUser:async(token:string)=>({data:{user:s.authInvalid||token==='anon-key'?null:{id:'user-a'}},error:s.authInvalid?'invalid':null})},from(table:string){
    let update:any,del=false;
    const resolve=async()=>{
      stats.reads.push(table);
      if(update){stats.updates.push(update);return {data:null,error:null};}
      if(del){stats.deletes++;return {data:null,error:null};}
      await new Promise(r=>setTimeout(r,2));
      if(table==='production_config')return {data:{notifications_enabled:!s.disabled},error:null};
      if(table==='users')return {data:{pref_order_notifications:true,pref_chat_notifications:true,pref_rating_notifications:true,pref_admin_notifications:true,order_notification_mode:'all',...s.pref},error:s.prefError?new Error('synthetic preference failure'):null};
      if(table==='user_device_tokens')return {data:s.noTokens?[]:[{fcm_token:'synthetic-destination'}],error:s.tokenError?new Error('synthetic token failure'):null};
      throw Error('Unexpected table '+table);
    };
    const b:any={select(){return b;},eq(){return b;},single:resolve,maybeSingle:resolve,update(v:any){update=v;return b;},delete(){del=true;return b;},then(ok:any,bad:any){return resolve().then(ok,bad);}};return b;
  }};
  globalThis.fetch=async(input:any,init:any)=>{
    const url=String(input);
    if(url==='https://oauth2.googleapis.com/token'){
      stats.oauth++;await new Promise(r=>setTimeout(r,15));
      const jwt=new URLSearchParams(init.body).get('assertion')!.split('.');
      const decode=(s:string)=>Uint8Array.from(atob(s.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
      const claims=JSON.parse(new TextDecoder().decode(decode(jwt[1])));
      assert.equal(claims.aud,'https://oauth2.googleapis.com/token');
      assert.equal(claims.scope,'https://www.googleapis.com/auth/firebase.messaging');
      assert.equal(await crypto.subtle.verify('RSASSA-PKCS1-v1_5',key.publicKey,decode(jwt[2]),new TextEncoder().encode(jwt[0]+'.'+jwt[1])),true);
      if(s.oauthFail)return Response.json({error:'synthetic_oauth_failure'},{status:400});
      return Response.json({access_token:'synthetic-oauth-token',expires_in:3600});
    }
    if(url.startsWith('https://fcm.googleapis.com/v1/projects/synthetic-test-project/')){
      stats.fcm++;stats.payloads.push(JSON.parse(init.body));
      if(s.timeout)return await new Promise((_resolve,reject)=>{init.signal.addEventListener('abort',()=>reject(new DOMException('synthetic timeout','AbortError')),{once:true});});
      return Response.json(s.fcmStatus===404?{error:'UNREGISTERED'}:{name:'synthetic-message'},{status:s.fcmStatus??200});
    }
    throw Error('Unexpected outbound target blocked: '+url);
  };
  await import(new URL(`functions/${variant}/index.ts?test=${serial++}`,base).href);
  const handler=(globalThis as any).__pushHandler;
  const request=async(body:any={user_id:'user-a',title:'Synthetic title',body:'Synthetic body',data:{type:'order_assignment',notification_id:'test-notification',order_id:'test-order'}},token:string|null='synthetic-service-key',method='POST')=>{
    const response=await handler(new Request('http://localhost/test',{method,headers:token?{Authorization:'Bearer '+token}:undefined,...(method==='OPTIONS'?{}:{body:typeof body==='string'?body:JSON.stringify(body)})}));
    return {status:response.status,body:method==='OPTIONS'?await response.text():await response.json()};
  };
  return {stats,request,s};
}
for(const variant of ['baseline','proposed']){
  Deno.test(`${variant}: missing, invalid, anon and cross-user authorization`,async()=>{
    const t=await load(variant);assert.equal((await t.request(undefined,null)).status,401);assert.equal((await t.request(undefined,'anon-key')).status,401);assert.equal((await t.request({user_id:'other-user',title:'x',body:'y'},'user-session')).status,403);assert.equal(t.stats.fcm,0);assert.equal(t.stats.oauth,0);
    const bad=await load(variant,{authInvalid:true});assert.equal((await bad.request(undefined,'bad-session')).status,401);
  });
  Deno.test(`${variant}: OPTIONS, input validation and malformed JSON`,async()=>{
    const t=await load(variant);assert.equal((await t.request(undefined,null,'OPTIONS')).status,200);assert.equal((await t.request({})).status,400);assert.equal((await t.request('{broken')).status,500);assert.equal(t.stats.oauth,0);
  });
  Deno.test(`${variant}: global flag and all user preference gates prevent delivery`,async()=>{
    const disabled=await load(variant,{disabled:true});assert.equal((await disabled.request()).body.reason,'notifications_disabled');assert.equal(disabled.stats.reads.includes('user_device_tokens'),false);
    for(const [type,pref]of [['chat_message','pref_chat_notifications'],['new_rating','pref_rating_notifications'],['order_assignment','pref_order_notifications'],['admin_broadcast','pref_admin_notifications']]){
      const t=await load(variant,{pref:{[pref]:false}});assert.equal((await t.request({user_id:'user-a',title:'x',body:'y',data:{type,notification_id:'n'}})).status,200);assert.equal(t.stats.oauth,0);assert.equal(t.stats.fcm,0);assert.ok(t.stats.updates.some(x=>x.delivery_status==='skipped'));
    }
    for(const mode of ['tracking_silent','important_only']){const t=await load(variant,{pref:{order_notification_mode:mode}});await t.request({user_id:'user-a',title:'x',body:'y',data:{type:'order_status',status:'searching'}});assert.equal(t.stats.fcm,0);}
  });
  Deno.test(`${variant}: owner and server request payload, status and cached OAuth`,async()=>{
    const t=await load(variant);assert.equal((await t.request(undefined,'user-session')).status,200);await t.request();assert.equal(t.stats.oauth,1);assert.equal(t.stats.fcm,2);assert.ok(t.stats.updates.some(x=>x.delivery_status==='sent'&&x.push_sent));assert.equal(t.stats.payloads[0].message.android.notification.channel_id,'order_alerts_v2');assert.equal(t.stats.payloads[0].message.data.order_id,'test-order');
    tick+=56*60000;await t.request();assert.equal(t.stats.oauth,2);
  });
  Deno.test(`${variant}: concurrent cold requests and OAuth failure followed by retry`,async()=>{
    const t=await load(variant);const responses=await Promise.all(Array.from({length:10},()=>t.request()));assert.ok(responses.every(x=>x.status===200));assert.equal(t.stats.oauth,variant==='proposed'?1:10);assert.equal(t.stats.fcm,10);
    const bad=await load(variant,{oauthFail:true});assert.equal((await bad.request()).status,500);bad.s.oauthFail=false;assert.equal((await bad.request()).status,200);assert.equal(bad.stats.oauth,2);
  });
  Deno.test(`${variant}: no tokens and database failures`,async()=>{
    const empty=await load(variant,{noTokens:true});assert.equal((await empty.request()).status,200);assert.equal(empty.stats.oauth,0);
    for(const scenario of [{prefError:true},{tokenError:true}]){const t=await load(variant,scenario);assert.equal((await t.request()).status,500);assert.equal(t.stats.fcm,0);assert.ok(t.stats.updates.some(x=>x.delivery_status==='failed'));}
  });
  Deno.test(`${variant}: provider errors, invalid-token cleanup and request retry semantics`,async()=>{
    for(const status of [401,404,429,500]){const t=await load(variant,{fcmStatus:status});const r=await t.request();assert.equal(r.status,200);assert.equal(t.stats.fcm,1);assert.ok(t.stats.updates.some(x=>x.delivery_status==='failed'));assert.equal(t.stats.deletes,status===404?1:0);t.s.fcmStatus=200;await t.request();assert.equal(t.stats.fcm,2);assert.ok(t.stats.updates.some(x=>x.delivery_status==='sent'));}
  });
  Deno.test(`${variant}: real fetchWithTimeout abort preserves failure status`,async()=>{
    const t=await load(variant,{timeout:true});assert.equal((await t.request()).status,500);assert.ok(t.stats.updates.some(x=>x.delivery_status==='failed'));
  });
}
Deno.test('restore globals',()=>{Date.now=originalNow;globalThis.fetch=originalFetch;});
