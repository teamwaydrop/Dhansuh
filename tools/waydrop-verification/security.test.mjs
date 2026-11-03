import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const root = new URL('../../', import.meta.url);
const read = async p => fs.readFile(new URL(p, root), 'utf8');
const uid = n => `00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const kyc = n => `10000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
function catalog(raw) {
  const result = JSON.parse(raw).content[0].text;
  const wrapped = JSON.parse(result).result;
  return JSON.parse(wrapped.match(/\n<untrusted-data-[^>]+>\n([\s\S]*?)\n<\/untrusted-data-/)[1])[0].audit;
}
const original = catalog(await read('docs/WAYDROP_BACKEND_CATALOG_2026-10-31.json'));
function applyOnlyLocally(sql) {
  // Only the outside transaction terminator is changed, in memory, for this
  // disposable engine. The proposal on disk remains rollback-by-default.
  assert.match(sql, /ROLLBACK;\s*$/);
  return sql.replace(/ROLLBACK;\s*$/, 'COMMIT;');
}

test('SQL authorization proposals against isolated PostgreSQL', async t => {
  const db = new PGlite();
  const results = [];
  async function role(role, userId, fn) {
    assert.ok(['anon','authenticated','service_role'].includes(role));
    return db.transaction(async tx => {
      await tx.exec(`SET LOCAL ROLE ${role}`);
      await tx.query("select set_config('request.jwt.claim.role',$1,true), set_config('request.jwt.claim.sub',$2,true)", [role,userId ?? '']);
      return fn(tx);
    });
  }
  const denied = (fn, code='42501') => assert.rejects(fn, e => e.code===code);
  const run = async (name, fn) => t.test(name, async () => {
    try { await fn(); results.push({name,status:'passed'}); }
    catch(e) { results.push({name,status:'failed',code:e.code,message:e.message}); throw e; }
  });
  try {
    await db.exec(await fs.readFile(new URL('security-fixture.sql',import.meta.url),'utf8'));
    // The genuine existing UPDATE role guard is kept, not replaced by the proposal.
    const oldRole = original.triggers.find(f=>f.tgname==='trigger_prevent_role_self_escalation');
    await db.exec(oldRole.definition);
    await db.exec('CREATE TRIGGER trigger_prevent_role_self_escalation BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.prevent_role_self_escalation()');
    // RPC placeholders test actual EXECUTE ACLs, not business/dispatch bodies.
    // No network extensions or production credentials are present in this engine.
    const aclSignatures = [
      'expire_stale_searching_orders()', 'redispatch_stalled_searching_orders()',
      'expire_stale_active_orders()', 'expire_stale_intercity_requests()',
      'redispatch_freed_riders()', 'assign_new_order_to_nearby_online_riders_core(uuid)',
      'send_order_status_notifications_core(uuid,text,text,text,integer,text,text,uuid,uuid,text,text)',
    ];
    for (const signature of aclSignatures) await db.exec(`CREATE FUNCTION public.${signature} RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$ BEGIN RETURN; END $$`);
    const mutable = [
      ['handle_promo_usage_changes()','trigger','RETURN NEW;'],
      ['fail_withdrawal(uuid,jsonb)','jsonb',"RETURN '{}'::jsonb;"],
      ['complete_withdrawal(uuid,text,text,jsonb)','jsonb',"RETURN '{}'::jsonb;"],
      ['expire_trip_sharing_tokens()','void','RETURN;'],
      ['check_otp_lockout(character varying)','jsonb',"RETURN '{}'::jsonb;"],
      ['log_otp_attempt(character varying,boolean,character varying,character varying,character varying)','void','RETURN;'],
    ];
    for (const [signature,type,body] of mutable) await db.exec(`CREATE FUNCTION public.${signature} RETURNS ${type} LANGUAGE plpgsql SECURITY DEFINER AS $$ BEGIN ${body} END $$`);
    const promo = original.functions.find(f=>f.signature==='validate_and_calculate_promo(character varying,numeric,uuid)');
    await db.exec(promo.definition);

    // Confirm the fixture reproduces the actual permission gaps before fixing it.
    await run('baseline: own profile INSERT could assign admin', async () => {
      await role('authenticated',uid(3),tx=>tx.query("INSERT INTO public.users(id,role) VALUES($1,'admin')",[uid(3)]));
      assert.equal((await db.query('SELECT role FROM users WHERE id=$1',[uid(3)])).rows[0].role,'admin');
      await db.query('DELETE FROM users WHERE id=$1',[uid(3)]);
    });
    await run('baseline: private view was readable by anon', async () => {
      const r=await role('anon',null,tx=>tx.query('SELECT count(*)::int n FROM public.parcel_compliance_view'));
      assert.equal(r.rows[0].n,2);
    });
    await run('baseline: own KYC decisions were mutable', async () => {
      await role('authenticated',uid(1),tx=>tx.query("UPDATE public.rider_kyc SET kyc_status='approved',activation_status='active' WHERE user_id=$1",[uid(1)]));
      await db.query("UPDATE rider_kyc SET kyc_status='pending',activation_status='inactive' WHERE user_id=$1",[uid(1)]);
    });
    await run('baseline: client could insert active payout status',async()=>{
      await role('authenticated',uid(1),tx=>tx.query("INSERT INTO rider_payout_accounts VALUES($1,$2,'active')",[kyc(9),uid(1)]));
      await db.query('DELETE FROM rider_payout_accounts WHERE id=$1',[kyc(9)]);
    });
    await run('baseline: promo caller could query another account audience',async()=>{
      const r=await role('authenticated',uid(1),tx=>tx.query("SELECT validate_and_calculate_promo('ONLYB',100,$1) result",[uid(2)]));
      assert.equal(r.rows[0].result.discount_amount,20);
    });
    await run('proposal remains rollback-by-default',async()=>{
      await db.exec(await read('docs/proposals/waydrop_security_review.sql'));
      const r=await db.query("SELECT count(*)::int n FROM pg_trigger WHERE tgname='guard_client_user_security_fields'");
      assert.equal(r.rows[0].n,0);
      assert.equal((await db.query("SELECT has_table_privilege('anon','parcel_compliance_view','SELECT') allowed")).rows[0].allowed,true);
    });

    await db.exec(applyOnlyLocally(await read('docs/proposals/waydrop_security_review.sql')));
    await db.exec(applyOnlyLocally(await read('docs/proposals/waydrop_promo_ownership_review.sql')));

    for(const [field,value] of [['role',"'admin'"],['role',"'support'"],['is_developer','true'],['is_suspended','true']]) {
      await run(`deny profile INSERT ${field}=${value}`,()=>denied(()=>role('authenticated',uid(3),tx=>tx.query(`INSERT INTO users(id,${field}) VALUES($1,${value})`,[uid(3)]))));
    }
    await run('allow ordinary own profile creation and editing', async () => {
      await role('authenticated',uid(3),tx=>tx.query("INSERT INTO users(id,full_name) VALUES($1,'Ordinary')",[uid(3)]));
      await role('authenticated',uid(3),tx=>tx.query("UPDATE users SET full_name='Changed' WHERE id=$1",[uid(3)]));
      assert.equal((await db.query('SELECT role,is_developer,full_name FROM users WHERE id=$1',[uid(3)])).rows[0].role,'user');
    });
    for(const [field,value] of [['role',"'admin'"],['is_developer','true'],['is_suspended','true']]) {
      await run(`deny profile UPDATE ${field}`,()=>denied(()=>role('authenticated',uid(1),tx=>tx.query(`UPDATE users SET ${field}=${value} WHERE id=$1`,[uid(1)]))));
    }
    await run('deny profile ownership reassignment via inherited UPDATE WITH CHECK',()=>denied(()=>role('authenticated',uid(1),tx=>tx.query('UPDATE users SET id=$1 WHERE id=$2',[uid(9),uid(1)]))));
    await run('cross-account profile read/write affects no rows',async()=>{
      const r=await role('authenticated',uid(1),tx=>tx.query("UPDATE users SET full_name='Intruder' WHERE id=$1 RETURNING id",[uid(2)]));
      assert.equal(r.rows.length,0);
      assert.equal((await role('authenticated',uid(1),tx=>tx.query('SELECT id FROM users WHERE id=$1',[uid(2)]))).rows.length,0);
    });
    for(const change of ["kyc_status='approved'","activation_status='active'","blocked_until=now()","rejection_reason='client decision'"]) {
      await run(`deny owner KYC decision UPDATE ${change}`,()=>denied(()=>role('authenticated',uid(1),tx=>tx.query(`UPDATE rider_kyc SET ${change} WHERE user_id=$1`,[uid(1)]))));
    }
    await run('deny forged approved KYC INSERT',()=>denied(()=>role('authenticated',uid(3),tx=>tx.query("INSERT INTO rider_kyc(id,user_id,kyc_status,activation_status) VALUES($1,$2,'approved','active')",[kyc(3),uid(3)]))));
    await run('allow pending KYC INSERT and ordinary document/profile edits',async()=>{
      await role('authenticated',uid(3),tx=>tx.query('INSERT INTO rider_kyc(id,user_id) VALUES($1,$2)',[kyc(3),uid(3)]));
      await role('authenticated',uid(3),tx=>tx.query("UPDATE rider_kyc SET full_name='Applicant' WHERE user_id=$1",[uid(3)]));
    });
    for(const column of ['kyc_status','activation_status']) {
      await run(`deny explicit null ${column} on KYC INSERT`,()=>denied(()=>role('authenticated',uid(3),tx=>
        tx.query(`INSERT INTO rider_kyc(id,user_id,${column}) VALUES($1,$2,null)`,[kyc(9),uid(3)]))));
    }
    await run('authorized existing staff KYC review remains possible',async()=>{
      await role('service_role',null,tx=>tx.query("INSERT INTO users(id,role) VALUES($1,'admin')",[uid(4)]));
      await role('authenticated',uid(4),tx=>tx.query("UPDATE rider_kyc SET kyc_status='approved',activation_status='active' WHERE user_id=$1",[uid(2)]));
      assert.equal((await db.query('SELECT activation_status FROM rider_kyc WHERE user_id=$1',[uid(2)])).rows[0].activation_status,'active');
    });
    await run('suspended staff cannot use the KYC decision exception',async()=>{
      await role('service_role',null,tx=>tx.query('UPDATE users SET is_suspended=true WHERE id=$1',[uid(4)]));
      await denied(()=>role('authenticated',uid(4),tx=>tx.query("UPDATE rider_kyc SET kyc_status='rejected' WHERE user_id=$1",[uid(2)])));
    });
    await run('cross-account KYC write affects no rows',async()=>{
      assert.equal((await role('authenticated',uid(1),tx=>tx.query("UPDATE rider_kyc SET full_name='Intruder' WHERE user_id=$1 RETURNING id",[uid(2)]))).rows.length,0);
    });
    await run('deny fabricated active payout INSERT',()=>denied(()=>role('authenticated',uid(1),tx=>tx.query("INSERT INTO rider_payout_accounts VALUES($1,$2,'active')",[kyc(9),uid(1)]))));
    await run('allow pending payout setup',()=>role('authenticated',uid(1),tx=>tx.query("INSERT INTO rider_payout_accounts VALUES($1,$2,'pending')",[kyc(9),uid(1)])));
    for(const view of ['parcel_compliance_view','parcel_security_timeline_view']) {
      for(const actor of ['anon','authenticated']) await run(`deny ${actor} SELECT ${view}`,()=>denied(()=>role(actor,actor==='anon'?null:uid(1),tx=>tx.query(`SELECT * FROM ${view}`))));
      await run(`allow service-role SELECT ${view}`,()=>role('service_role',null,tx=>tx.query(`SELECT * FROM ${view}`)));
    }
    for(const signature of aclSignatures) {
      const f=original.functions.find(f=>f.signature===signature);
      assert.ok(f, 'signature must exist in the real catalog: '+signature);
      await run(`ACL: ${signature} is server-only`,async()=>{
        const p=await db.query("SELECT has_function_privilege('anon',$1,'EXECUTE') a, has_function_privilege('authenticated',$1,'EXECUTE') u, has_function_privilege('service_role',$1,'EXECUTE') s",['public.'+signature]);
        assert.deepEqual(p.rows[0],{a:false,u:false,s:true});
      });
    }
    await run('anon invocation of internal RPC is denied before its body runs',()=>denied(()=>role('anon',null,tx=>tx.query('SELECT public.expire_stale_searching_orders()'))));
    await run('server invocation of internal RPC remains allowed (ACL fixture body only)',()=>role('service_role',null,tx=>tx.query('SELECT public.expire_stale_searching_orders()')));
    await run('promo same-user positive calculation preserves 10 percent discount',async()=>{
      const r=await role('authenticated',uid(1),tx=>tx.query("SELECT public.validate_and_calculate_promo('OPEN',100,$1) result",[uid(1)]));
      assert.equal(r.rows[0].result.discount_amount,10);
    });
    await run('promo another-user identity is denied',()=>denied(()=>role('authenticated',uid(1),tx=>tx.query("SELECT public.validate_and_calculate_promo('ONLYB',100,$1)",[uid(2)]))));
    await run('promo missing identity is denied',()=>denied(()=>role('authenticated',null,tx=>tx.query("SELECT public.validate_and_calculate_promo('OPEN',100,$1)",[uid(1)]))));
    await run('promo null target identity is denied',()=>denied(()=>role('authenticated',uid(1),tx=>tx.query("SELECT public.validate_and_calculate_promo('OPEN',100,null)"))));
    await run('promo anon EXECUTE is denied',()=>denied(()=>role('anon',null,tx=>tx.query("SELECT public.validate_and_calculate_promo('OPEN',100,$1)",[uid(1)]))));
    await run('server promo pricing can evaluate the actual order owner',async()=>{
      const r=await role('service_role',null,tx=>tx.query("SELECT public.validate_and_calculate_promo('ONLYB',100,$1) result",[uid(2)]));
      assert.equal(r.rows[0].result.discount_amount,20);
    });
    await run('service role can assign roles, approve KYC and activate provider-confirmed payout',async()=>{
      await role('service_role',null,async tx=>{
        await tx.query("UPDATE users SET role='admin',is_developer=true,is_suspended=true WHERE id=$1",[uid(3)]);
        await tx.query("UPDATE rider_kyc SET kyc_status='approved',activation_status='active' WHERE user_id=$1",[uid(1)]);
        await tx.query("UPDATE rider_payout_accounts SET cashfree_beneficiary_status='active' WHERE user_id=$1",[uid(1)]);
      });
      assert.equal((await db.query('SELECT activation_status FROM rider_kyc WHERE user_id=$1',[uid(1)])).rows[0].activation_status,'active');
    });
    await run('all seven changed definer paths are pinned',async()=>{
      const r=await db.query("SELECT proname,proconfig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND proname=ANY($1)",[['handle_promo_usage_changes','validate_and_calculate_promo','fail_withdrawal','complete_withdrawal','expire_trip_sharing_tokens','check_otp_lockout','log_otp_attempt']]);
      assert.equal(r.rows.length,7);
      for(const f of r.rows) assert.ok(f.proconfig?.some(c=>c==='search_path=public, pg_temp'),f.proname);
    });
  } finally {
    const version=(await db.query('SELECT version()')).rows[0].version;
    await fs.writeFile(new URL('docs/WAYDROP_LOCAL_SECURITY_TEST_RESULTS.json',root),JSON.stringify({engine:version,productionConnected:false,scope:'Synthetic schema; actual proposed trigger/promo SQL and existing role guard. Internal RPC bodies are ACL fixtures, not dispatch/payment execution.',results},null,2));
    await db.close();
  }
});
