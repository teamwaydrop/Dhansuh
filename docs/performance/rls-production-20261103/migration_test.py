"""Exact migration on the existing fixed loopback fixture; never remote."""
from pathlib import Path
import json,re,subprocess,time
from local_fixture import ROOT,ART,DB,ARGS,sql,scalar

assert scalar("SELECT current_database()='waydrop_rls_hotpath_test' AND inet_server_addr()=inet '127.0.0.1' AND inet_server_port()=54329")=='t'
assert scalar('SELECT value FROM rls_fixture_marker')=='waydrop_rls_hotpath_synthetic_v1'
path=ROOT/'supabase/migrations/20261103162805_waydrop_cache_admin_rls_checks_per_statement.sql'
source=path.read_text(encoding='utf-8')
queries=re.findall(r'  (SELECT md5\(.*?);',source,re.S)
assert len(queries)==3
local_hashes=[scalar(q.replace(' INTO h\n','\n')+';') for q in queries]
production_hashes=['b0d69176aaedc8cf3200e599c9bab771','89e1543c74e45ca52ef7bec9774e229f','41f89ec20da990fbd2df511ccfaa95c8']
adapted=source
for before,after in zip(production_hashes,local_hashes):adapted=adapted.replace(before,after)
def state():
    return json.loads(scalar("SELECT jsonb_object_agg(c.relname||'.'||p.polname,jsonb_build_object('cmd',polcmd,'roles',polroles,'permissive',polpermissive,'qual',pg_get_expr(polqual,polrelid),'check',pg_get_expr(polwithcheck,polrelid))) FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid"))
def baseline():
    for t in ['orders','rider_kyc','riders','users']:sql(f'ALTER POLICY admin_can_select_{t} ON {t} USING (public.is_admin());')
results=[]
try:
    baseline();before=state()
    r=sql(source,check=False)
    assert r.returncode and 'drift' in r.stderr.lower() and state()==before
    results.append('real production fingerprints refuse a different fixture without changes')

    sql(adapted);after=state()
    changed=sorted(k for k in before if before[k]!=after[k])
    assert changed==sorted(t+'.admin_can_select_'+t for t in ['orders','rider_kyc','riders','users'])
    for k in changed:
        assert {x:v for x,v in before[k].items() if x!='qual'}=={x:v for x,v in after[k].items() if x!='qual'}
        assert after[k]['qual']=='( SELECT is_admin() AS is_admin)'
    results.append('exact migration with fixture-only fingerprints changes precisely four SELECT expressions')

    rollback=(ART/'RLS_INITPLAN_ROLLBACK.sql').read_text(encoding='utf-8')
    sql(rollback.rsplit('ROLLBACK;',1)[0]+'COMMIT;')
    assert state()==before
    results.append('guarded rollback restores the entire original policy state')

    sql('ALTER POLICY admin_can_select_orders ON orders USING (false);')
    drifted=state();r=sql(adapted,check=False)
    assert r.returncode and 'Policy graph drift' in r.stderr and state()==drifted
    results.append('graph drift aborts atomically without changing other policies')
    baseline()

    holder=subprocess.Popen([*ARGS,'-d',DB],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf-8')
    holder.stdin.write("SET application_name='rls_release_lock_holder';BEGIN;LOCK TABLE orders IN ROW EXCLUSIVE MODE;SELECT pg_sleep(2);ROLLBACK;")
    holder.stdin.close();holder.stdin=None
    deadline=time.monotonic()+5
    while scalar("SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid WHERE a.application_name='rls_release_lock_holder' AND l.relation='public.orders'::regclass AND l.granted")=='0':
        assert time.monotonic()<deadline,'Lock holder never acquired expected lock'
        time.sleep(.01)
    r=sql(adapted,check=False)
    assert r.returncode and 'lock timeout' in r.stderr.lower() and state()==before
    holder.communicate(timeout=5)
    results.append('500ms lock timeout aborts behind an observed concurrent writer lock')
finally:baseline()
assert len(results)==5
(ART/'EXACT_MIGRATION_TESTS.json').write_text(json.dumps({'passed':5,'failed':0,'fixture_only_hash_substitution':True,'results':results},indent=2)+'\n',encoding='utf-8')
print('PASS exact migration/guard/rollback/real-lock tests: 5')
