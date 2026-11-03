// Three bounded GETs only. No sign-in, refresh, user creation or user data read.
import fs from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
const key=process.env.WAYDROP_PUBLIC_API_KEY;
if(!key?.startsWith('sb_publishable_'))throw Error('Explicit public publishable key required; server/secret keys forbidden');
const origin='https://yvwpchffctiagevpqgwy.supabase.co';
const tests=[['auth_health','/auth/v1/health',{}],['public_jwks','/auth/v1/.well-known/jwks.json',{}],['invalid_session_rejected','/auth/v1/user',{Authorization:'Bearer waydrop-readonly-invalid-session'}]];
const selected=process.argv.includes('--negative-only')?tests.filter(t=>t[0]==='invalid_session_rejected'):tests;
let results=await Promise.all(selected.map(async([name,route,extra])=>{
  try{const r=await fetch(origin+route,{method:'GET',headers:{apikey:key,...extra},signal:AbortSignal.timeout(8000)});const data=await r.json().catch(()=>null);const invalidJwt=data?.code==='bad_jwt'||data?.error_code==='bad_jwt'||/invalid.*jwt|invalid.*token|malformed.*jwt|jwt.*malformed/i.test(String(data?.msg??data?.message??data?.error??''));return {name,status:r.status,passed:name==='invalid_session_rejected'?[401,403].includes(r.status)&&invalidJwt:r.status===200,...(name==='invalid_session_rejected'?{auth_error_code:data?.code??data?.error_code??null,invalid_jwt_reason:invalidJwt}:{}),...(name==='public_jwks'?{public_key_count:data?.keys?.length??0,algorithms:[...new Set((data?.keys??[]).map(k=>k.alg))]}:{})};}catch(e){return {name,passed:false,error:e.name};}
}));
if(process.argv.includes('--negative-only')){const prior=JSON.parse(await fs.readFile(fileURLToPath(new URL('MANAGED_AUTH_READ_ONLY.json',import.meta.url)),'utf8'));results=[...prior.results.filter(r=>r.name!=='invalid_session_rejected'),...results];}
const report={date:'2026-11-01',productionReadOnly:true,method:'Three endpoint GET checks using public publishable key; negative check repeated once to verify the 403 Auth error reason. No valid user session or secrets used',results,limits:['Health, public key availability and invalid-session rejection do not prove valid sign-in, refresh, logout or user-scoped RLS behavior.','No production write, subscription, order or notification was created.']};
await fs.writeFile(fileURLToPath(new URL('MANAGED_AUTH_READ_ONLY.json',import.meta.url)),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
