// Prepares reviewed request files only. Never calls Supabase or deploys.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../../..');
const sha=s=>createHash('sha256').update(s).digest('hex');
const project_id='yvwpchffctiagevpqgwy';
const read=p=>fs.readFile(path.join(root,p),'utf8');
const files=[];for(const name of ['index.ts','atomic_acceptance.ts','acceptance_sql.ts','deno.json'])files.push({name:'functions/accept-order/'+name,content:await read('supabase/functions/accept-order/'+name)});
files.push({name:'functions/_shared/production_config_cache.ts',content:await read('supabase/functions/_shared/production_config_cache.ts')});
const wiring=JSON.parse(await read('docs/production-performance/acceptance/MANAGED_WIRING_READ_ONLY.json'));
if(sha(files.at(-1).content)!==wiring.sharedDependency.sha256)throw Error('Shared helper drift');
const sql=JSON.parse(files.find(f=>f.name.endsWith('acceptance_sql.ts')).content.match(/export const ACCEPTANCE_SQL = ([\s\S]*);\s*$/)[1]);
if(/\b(CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE)\s/i.test(sql))throw Error('DDL forbidden');
if(files[0].content.includes('claim_order_assignment_atomic')||files[0].content.includes('supabase.rpc('))throw Error('RPC candidate is not Edge-only');
const request=(files)=>({tool:'mcp__codex_apps__supabase_deploy_edge_function',arguments:{project_id,name:'accept-order',entrypoint_path:'functions/accept-order/index.ts',verify_jwt:false,files}});
const payloads={DEPLOY_REQUEST:request(files),RECOVER_FAIL_CLOSED_REQUEST:request([{name:'functions/accept-order/index.ts',content:await read('docs/production-performance/edge-only/recovery-fail-closed/functions/accept-order/index.ts')}]),RECOVER_LEGACY_PAUSED_ONLY_REQUEST:request([{name:'functions/accept-order/index.ts',content:await read('docs/production-performance/edge-only/recovery-compatible/functions/accept-order/index.ts')},files.at(-1),files.find(f=>f.name.endsWith('deno.json'))])};
const manifest={status:'LOCAL_PASS_MANAGED_VALIDATION_PENDING_NO_GO',notExecuted:true,project:project_id,scope:'accept-order Edge only; no migrations, schema, RLS, repair data or other functions',files:files.map(f=>({file:f.name,sha256:sha(f.content)})),requests:[],dependencyLockSha256:sha(await read('docs/production-performance/edge-only/deno.lock'))};
for(const [name,payload]of Object.entries(payloads)){const bytes=JSON.stringify(payload,null,2)+'\n';await fs.writeFile(path.join(here,name+'.json'),bytes);manifest.requests.push({file:name+'.json',sha256:sha(bytes)});await fs.writeFile(path.join(here,name+'.codex.js'),'// PREPARED ONLY. Requires explicit production authority and release gates.\nawait tools.mcp__codex_apps__supabase_deploy_edge_function('+JSON.stringify(payload.arguments,null,2)+');\n');}
await fs.writeFile(path.join(here,'RELEASE_MANIFEST.json'),JSON.stringify(manifest,null,2)+'\n');
console.log('Prepared three Edge-only requests with hashes. No production calls.');
