// Generates Edge-bundled anonymous transaction logic from the verified RPC body.
// No network/production execution; no CREATE FUNCTION, indexes or schema DDL.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../../..');
const source=await fs.readFile(path.join(here,'../acceptance/01_atomic_acceptance.sql'),'utf8');
const marker='AS $function$';
let body=source.slice(source.indexOf(marker)+marker.length,source.lastIndexOf('$function$;')).trim();
body=body.replace('DECLARE',`DECLARE
  p_order_id uuid:=nullif(current_setting('app.accept_order_id',true),'')::uuid;
  p_rider_id uuid:=nullif(current_setting('app.accept_rider_id',true),'')::uuid;
  p_actor_user_id uuid:=nullif(current_setting('app.accept_actor_id',true),'')::uuid;`);
let returns=0;
body=body.replace(/RETURN (jsonb_build_object\([\s\S]*?\));/g,(_,value)=>{returns++;return `PERFORM set_config('app.acceptance_result',(${value})::text,true); RETURN;`;});
if(returns!==15)throw Error('Unexpected return count: '+returns);
// Without a new global unique index, refuse pre-existing inconsistent accepted
// assignments and assert exactly one matching assignment before committing.
body=body.replace('  -- Re-read and validate eligibility under the locks.',`  IF EXISTS (SELECT 1 FROM public.rider_assignments WHERE order_id=p_order_id AND assignment_status='accepted') THEN
    PERFORM set_config('app.acceptance_result',jsonb_build_object('http_status',409,'success',false,'code','ACCEPTANCE_STATE_INCONSISTENT','message','Order acceptance state requires review')::text,true); RETURN;
  END IF;
  -- Re-read and validate eligibility under the locks.`);
body=body.replace("  IF NOT EXISTS (SELECT 1 FROM public.rider_assignments", "  IF (SELECT count(*) FROM public.rider_assignments WHERE order_id=p_order_id AND assignment_status='accepted')<>1 OR NOT EXISTS (SELECT 1 FROM public.rider_assignments");
body=body.replace("WHERE order_id=p_order_id AND rider_id=p_rider_id AND assignment_status='accepted';\n    IF NOT FOUND THEN","WHERE order_id=p_order_id AND rider_id=p_rider_id AND assignment_status='accepted';\n    IF NOT FOUND OR (SELECT count(*) FROM public.rider_assignments WHERE order_id=p_order_id AND assignment_status='accepted')<>1 THEN");
const block='DO $acceptance$\n'+body+'\n$acceptance$;';
if(/\b(CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE)\s/i.test(block))throw Error('Unexpected schema operation in Edge transaction');
const target=path.join(here,'candidate/functions/accept-order');await fs.mkdir(target,{recursive:true});
await fs.writeFile(path.join(target,'acceptance_sql.ts'),'// Anonymous PL/pgSQL block. Executed only inside one direct DB transaction.\nexport const ACCEPTANCE_SQL = '+JSON.stringify(block)+';\n');
// Original RPC candidate archived before Edge-only promotion.
console.log('Generated Edge transaction SQL, '+returns+' original return paths; no schema DDL.');
