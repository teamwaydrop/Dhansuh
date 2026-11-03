// Verify existing payloads without rebuilding, deploying or touching production.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../../..');
const sha=s=>createHash('sha256').update(s).digest('hex');
const read=p=>fs.readFile(p,'utf8');
const manifest=JSON.parse(await read(path.join(here,'RELEASE_MANIFEST.json')));
for(const f of manifest.files)assert.equal(sha(await read(path.join(root,'supabase',f.file))),f.sha256,'Release file drift: '+f.file);
for(const r of manifest.requests){
 const bytes=await read(path.join(here,r.file));assert.equal(sha(bytes),r.sha256,'Request drift: '+r.file);
 const req=JSON.parse(bytes);assert.equal(req.tool,'mcp__codex_apps__supabase_deploy_edge_function');assert.equal(req.arguments.project_id,'yvwpchffctiagevpqgwy');assert.equal(req.arguments.name,'accept-order');assert.equal(req.arguments.verify_jwt,false);
 const js=await read(path.join(here,r.file.replace('.json','.codex.js')));
 assert.deepEqual(JSON.parse(js.slice(js.indexOf('edge_function(')+'edge_function('.length,js.lastIndexOf(');'))),req.arguments,'Command/payload drift');
 if(r.file==='DEPLOY_REQUEST.json')for(const file of req.arguments.files){const release=manifest.files.find(f=>f.file===file.name);assert.ok(release);assert.equal(sha(file.content),release.sha256);}
}
assert.equal(sha(await read(path.join(here,'deno.lock'))),manifest.dependencyLockSha256,'Dependency lock drift');
console.log('PASS: five release files, three request hashes, exact deployment/recovery commands and completed dependency lock. No production calls.');
