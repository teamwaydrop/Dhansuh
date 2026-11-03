// Offline source reconstruction only. Does not deploy or contact production.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../../..');
const hash=b=>createHash('sha256').update(b).digest('hex');
const previous=JSON.parse(await fs.readFile(path.join(here,'FINAL_READ_ONLY_CHECK.json'),'utf8')).currentAcceptanceEdge;
const wiring=JSON.parse(await fs.readFile(path.join(here,'MANAGED_WIRING_READ_ONLY.json'),'utf8'));
const entry=await fs.readFile(path.join(root,'.dart_tool/production_performance_preflight_20261101/accept-order.v60.ts'));
const helper=await fs.readFile(path.join(root,'supabase/functions/_shared/production_config_cache.ts'));
if(previous.version!==60||!previous.sourceMatchesCapturedV60||hash(entry)!==previous.sourceSha256)throw Error('Captured v60 source hash mismatch');
if(!wiring.sharedDependency.matchesCapturedProduction||hash(helper)!==wiring.sharedDependency.sha256)throw Error('Shared dependency mismatch');
const dest=path.join(here,'recovery-v60');
const files=[['functions/accept-order/index.ts',entry],['functions/_shared/production_config_cache.ts',helper],['deno.lock',await fs.readFile(path.join(here,'../local-tests/deno.lock'))],['deno.json',await fs.readFile(path.join(here,'../local-tests/deno-runtime.json'))]];
const records=[];
for(const [name,bytes]of files){const target=path.join(dest,name);await fs.mkdir(path.dirname(target),{recursive:true});await fs.writeFile(target,bytes);if(hash(await fs.readFile(target))!==hash(bytes))throw Error('Recovery read-back failed');records.push({file:name,sha256:hash(bytes)});}
const result={status:'SOURCE_RECONSTRUCTION_VERIFIED_HOSTED_ROLLBACK_PENDING',version:60,verify_jwt:previous.verify_jwt,originalBundleIdentifier:previous.bundleIdentifier,files:records,productionContacted:false,productionModified:false,limits:['Original source bytes and unchanged relative helper reconstructed and reread successfully.','Lockfile is the current locally verified dependency snapshot, not evidence of the original v60 production dependency graph.','Deno 2.9.8 is the local runtime; hosted runtime/bundle reproduction is not proven.','v60 contains the known acceptance race. Restoring it must not reopen acceptance traffic.','No historical hosted bundle retrieval or managed redeployment/rollback has been performed.']};
await fs.writeFile(path.join(dest,'RECOVERY_MANIFEST.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({status:result.status,version:60,filesVerified:records.length},null,2));
