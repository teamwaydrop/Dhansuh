// LOCAL DIAGNOSTIC PROPOSAL. NOT EXECUTED against production during this audit.
// A later approved operator may run <=3 public-config reads. Never logs row values/keys.
import {randomUUID} from 'node:crypto';
if(process.env.PERF_READONLY_APPROVED!=='1')throw new Error('Explicit approval required before making diagnostic requests');
const base=new URL(process.env.SUPABASE_URL??'');
if(base.protocol!=='https:')throw new Error('HTTPS endpoint required');
const key=process.env.SUPABASE_ANON_KEY;
if(!key)throw new Error('Supply a publishable/anon key securely; no server key');
if(key.startsWith('sb_secret_'))throw new Error('Server keys are prohibited');
if(key.split('.').length===3){const claims=JSON.parse(Buffer.from(key.split('.')[1],'base64url'));if(claims.role!=='anon')throw new Error('Only anon JWT keys are allowed');}
else if(!key.startsWith('sb_publishable_'))throw new Error('Expected an anon/publishable key');
const url=new URL('/rest/v1/production_config',base);
url.searchParams.set('select','minimum_android_version,force_update,maintenance_mode,is_active');
url.searchParams.set('is_active','eq.true');
for(let i=0;i<3;i++){
 const started=performance.now();
 const response=await fetch(url,{headers:{apikey:key,'x-client-info':'waydrop-perf-readonly-probe','x-request-id':randomUUID()},signal:AbortSignal.timeout(5000)});
 const body=await response.arrayBuffer();
 console.log(JSON.stringify({sample:i+1,status:response.status,elapsed_ms:performance.now()-started,bytes:body.byteLength,server_timing:(response.headers.get('server-timing')??'').match(/[a-zA-Z_]+;dur=[0-9.]+/g)??[]}));
 if(response.status!==200)break;
 if(i<2)await new Promise(r=>setTimeout(r,2000));
}
