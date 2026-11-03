import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const here=path.dirname(fileURLToPath(import.meta.url));
const root=path.resolve(here,'../../..');
const backup=path.join(root,'.dart_tool/production_performance_preflight_20261101');
const target=path.join(root,'.dart_tool/waydrop-local-runtime/push-under-test');
await fs.mkdir(path.join(target,'functions/_shared'),{recursive:true});
for(const name of ['http.ts','production_config_cache.ts'])await fs.copyFile(name==='http.ts'?path.join(here,'../waves/shared/http.ts'):path.join(backup,'functions/_shared',name),path.join(target,'functions/_shared',name));
for(const [name,source]of [['baseline',path.join(backup,'functions/send-push-notification/index.ts')],['compat',path.join(here,'../waves/05_compat.index.ts')],['timing',path.join(here,'../waves/05_push_timing.index.ts')],['oauth',path.join(here,'../waves/06_push_oauth.index.ts')],['proposed',path.join(here,'../waves/07_push_prefetch.index.ts')]]){
  await fs.mkdir(path.join(target,'functions',name),{recursive:true});await fs.copyFile(source,path.join(target,'functions',name,'index.ts'));
}
const mocks=path.join(here,'push-mocks');await fs.mkdir(mocks,{recursive:true});
await fs.writeFile(path.join(here,'deno-test.json'),JSON.stringify({imports:{'https://deno.land/std@0.224.0/http/server.ts':'./push-mocks/server.ts','https://esm.sh/@supabase/supabase-js@2':'./push-mocks/supabase.ts'}},null,2));
console.log('Copied complete baseline/proposed handlers, exact config helper and type-compatible timeout helper; test import map redirects only transport/client boundaries.');
