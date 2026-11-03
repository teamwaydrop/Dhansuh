"""Actual local PG17 RLS parity, statement caching and EXPLAIN ANALYZE tests."""
import hashlib
import json
from pathlib import Path
import statistics
import time
from local_fixture import ART, ROOT, DB, sql, scalar, uid, lit, seed

assert scalar("SELECT current_database()= 'waydrop_rls_hotpath_test' AND inet_server_addr()=inet '127.0.0.1' AND inet_server_port()=54329")=='t'
assert scalar('SELECT value FROM rls_fixture_marker')=='waydrop_rls_hotpath_synthetic_v1'
RESULTS=[]
TABLES=['admins','riders','rider_kyc','users','orders','intercity_requests','rider_assignments']

def obj(query):return json.loads(scalar(query))
def claims(n,forged=False):
    v={'sub':uid(n),'email':f'user{n}@example.invalid','role':'authenticated'}
    if forged:v['user_metadata']={'role':'admin','is_admin':True}
    return json.dumps(v)
def settings(n,role='authenticated',forged=False):
    return "SET LOCAL request.jwt.claim.sub=''; SET LOCAL request.jwt.claim.email=''; SET LOCAL request.jwt.claim.role=''; SET LOCAL request.jwt.claims="+lit(claims(n,forged))+"; SET LOCAL ROLE "+role+';'
def snapshot(n,role='authenticated',forged=False):
    fields=[]
    for t in TABLES:
        if role=='anon' and t!='users':continue
        fields += [lit(t),'(SELECT coalesce(jsonb_agg(id ORDER BY id),\'[]\'::jsonb) FROM '+t+')']
    query='SELECT jsonb_build_object('+','.join(fields)+');'
    return obj('BEGIN;'+settings(n,role,forged)+query+'ROLLBACK;')
def policy_state():
    return obj("SELECT jsonb_object_agg(relname||'.'||polname,jsonb_build_object('expr',pg_get_expr(polqual,polrelid),'check',pg_get_expr(polwithcheck,polrelid),'cmd',polcmd,'permissive',polpermissive,'roles',polroles)) FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid")
def reset_baseline():
    for t in ['orders','riders','users','rider_kyc']:
        sql(f'ALTER POLICY admin_can_select_{t} ON {t} USING (public.is_admin());')
def apply():
    candidate=(ART/'RLS_INITPLAN_CANDIDATE.sql').read_text()
    assert candidate.rstrip().endswith('ROLLBACK;')
    sql(candidate.rsplit('ROLLBACK;',1)[0]+'COMMIT;')
def check(name,fn):
    result=fn();RESULTS.append({'name':name,'status':'PASS','details':result});print('PASS',name,flush=True)

def parity():
    reset_baseline();seed(25)
    actors={'active_admin':(1,'authenticated',False),'inactive_admin':(2,'authenticated',False),'support':(3,'authenticated',False),'owner_offline_rider':(5,'authenticated',False),'assignment_rider':(6,'authenticated',False),'unrelated':(999,'authenticated',False),'forged_user_metadata':(999,'authenticated',True),'service_role':(999,'service_role',False),'anon':(999,'anon',False)}
    baseline={k:snapshot(*v) for k,v in actors.items()}
    before=policy_state()
    apply()
    after=policy_state()
    changed=[k for k in before if before[k]!=after[k]]
    assert sorted(changed)==sorted(t+'.admin_can_select_'+t for t in ['orders','riders','users','rider_kyc']),changed
    for k in changed:
        assert {a:b for a,b in before[k].items() if a!='expr'}=={a:b for a,b in after[k].items() if a!='expr'}
    for k,v in actors.items():assert snapshot(*v)==baseline[k],k
    assert len(baseline['active_admin']['riders'])==25
    assert len(baseline['active_admin']['rider_kyc'])==25
    assert len(baseline['active_admin']['users'])==128
    assert len(baseline['support']['rider_kyc'])==25
    assert uid(20002) in baseline['owner_offline_rider']['riders']
    assert uid(10002) in baseline['owner_offline_rider']['rider_kyc']
    assert len(baseline['unrelated']['rider_kyc'])==0
    # Existing KYC support policy also trusts users.role='admin', independently
    # of admins.is_active. Preserve and report this baseline distinction.
    assert len(baseline['inactive_admin']['rider_kyc'])==25
    assert len(baseline['inactive_admin']['riders'])==13
    assert baseline['forged_user_metadata']==baseline['unrelated']
    assert baseline['anon']['users']==[]
    assert len(baseline['service_role']['orders'])==60
    return {'actors':len(actors),'rowset_comparisons':len(actors)*len(TABLES)-6,'changed_policies':changed,'explicit_positive_negative_assertions':11}

def denials():
    results={}
    for phase in ['before','after']:
        reset_baseline()
        if phase=='after':apply()
        outcomes=[]
        for t in ['riders','rider_kyc','orders','admins']:
            r=sql('BEGIN;SET LOCAL ROLE anon; SELECT id FROM '+t+';ROLLBACK;',check=False)
            assert r.returncode and 'permission denied' in r.stderr,(phase,t,r.stderr)
            outcomes.append(t)
        results[phase]=outcomes
    return results

def update_parity():
    out={}
    for phase in ['before','after']:
        reset_baseline()
        if phase=='after':apply()
        rows={}
        for actor in [1,2,3,5,6,999]:
            values=[]
            for table,col in [('riders','current_heading'),('users','full_name'),('orders','current_fare')]:
                text='BEGIN;'+settings(actor)+f'WITH changed AS (UPDATE {table} SET {col}={col} RETURNING id) SELECT coalesce(jsonb_agg(id ORDER BY id),\'[]\'::jsonb) FROM changed;ROLLBACK;'
                values.append(json.loads(scalar(text)))
            rows[str(actor)]=values
        out[phase]=rows
    assert out['before']==out['after']
    assert len(out['after']['5'][0])==1
    assert len(out['after']['999'][0])==0
    return {'actor_table_update_comparisons':18,'transactions_rolled_back':36}

def cache_scope():
    apply_needed='is_admin()'==scalar("SELECT pg_get_expr(polqual,polrelid) FROM pg_policy WHERE polname='admin_can_select_riders'")
    if apply_needed:apply()
    text='BEGIN;'+settings(1)+"PREPARE k AS SELECT count(*) FROM rider_kyc;EXECUTE k;SET LOCAL request.jwt.claims="+lit(claims(5))+";EXECUTE k;SET LOCAL request.jwt.claims="+lit(claims(3))+";EXECUTE k;DEALLOCATE k;ROLLBACK;"
    actual=sql(text).stdout.strip().splitlines()
    assert actual==['25','1','25'],actual
    sql("UPDATE admins SET is_active=false WHERE email='user1@example.invalid';")
    revoked=snapshot(1)
    assert len(revoked['riders'])==13
    sql("UPDATE admins SET is_active=true WHERE email='user1@example.invalid';")
    assert len(snapshot(1)['riders'])==25
    return {'prepared_statement_actor_counts':actual,'admin_revocation_next_statement':True}

def drift_and_rollback():
    reset_baseline();original=policy_state()
    candidate=(ART/'RLS_INITPLAN_CANDIDATE.sql').read_text()
    sql(candidate)
    assert policy_state()==original,'Default ROLLBACK changed policy'
    sql('ALTER POLICY admin_can_select_users ON users USING (false);')
    r=sql(candidate,check=False)
    assert r.returncode and 'Policy drift' in r.stderr
    assert scalar("SELECT pg_get_expr(polqual,polrelid) FROM pg_policy WHERE polname='admin_can_select_riders'")=='is_admin()','Partial apply escaped rollback'
    reset_baseline()
    sql('ALTER FUNCTION public.is_admin() VOLATILE;')
    r=sql(candidate,check=False);assert r.returncode and 'function drift' in r.stderr
    sql('ALTER FUNCTION public.is_admin() STABLE;')
    reset_baseline();apply();reset_baseline()
    assert policy_state()==original
    return {'default_rollback':True,'policy_drift_blocks':True,'function_drift_blocks':True,'no_partial_apply':True,'restore_original':True}

QUERY="""SELECT r.id,r.current_lat,r.current_lng,r.current_heading,
(SELECT json_build_object('vehicle_type',k.vehicle_type) FROM rider_kyc k WHERE k.id=r.kyc_id LIMIT 1) AS rider_kyc
FROM riders r WHERE r.account_status='online' AND r.current_lat IS NOT NULL
AND r.current_lat BETWEEN 16.45 AND 16.55 AND r.current_lng IS NOT NULL AND r.current_lng BETWEEN 80.55 AND 80.65 LIMIT 50"""

def documents(text):
    decoder=json.JSONDecoder();result=[];text=text.strip()
    while text:
        value,end=decoder.raw_decode(text);result.append(value);text=text[end:].lstrip()
    return result

def benchmark():
    results=[]
    for size in [25,250]:
        seed(size)
        for phase in ['before','after']:
            reset_baseline()
            if phase=='after':apply()
            for actor in [1,5,999]:
                sql("SELECT pg_stat_reset_single_function_counters('public.is_admin()'::regprocedure);")
                statement='BEGIN;SET LOCAL track_functions=\'all\';'+settings(actor)
                statement+=('EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) '+QUERY+';')*9
                statement+='COMMIT;'
                plans=[x[0] for x in documents(sql(statement).stdout)]
                assert len(plans)==9
                count=int(scalar("SELECT coalesce(calls,0) FROM pg_stat_user_functions WHERE funcid='public.is_admin()'::regprocedure"))
                timing=[x['Execution Time'] for x in plans[2:]]
                nodes=[]
                def walk(n):
                    nodes.append(n)
                    for x in n.get('Plans',[]):walk(x)
                walk(plans[-1]['Plan'])
                results.append({'riders':size,'phase':phase,'actor':actor,'execution_ms_median':statistics.median(timing),'execution_ms_min':min(timing),'execution_ms_max':max(timing),'planning_ms_median':statistics.median(x['Planning Time'] for x in plans[2:]),'is_admin_calls_total_9_queries':count,'plan_nodes':len(nodes),'actual_output_rows':plans[-1]['Plan']['Actual Rows']})
                (ART/f'PLAN_{size}_{phase}_actor{actor}.json').write_text(json.dumps(plans[-1],indent=2)+'\n')
    for row in results:
        if row['phase']=='after':
            before=next(x for x in results if x['riders']==row['riders'] and x['actor']==row['actor'] and x['phase']=='before')
            assert row['actual_output_rows']==before['actual_output_rows']
            assert row['is_admin_calls_total_9_queries']<=before['is_admin_calls_total_9_queries'],(before,row)
    (ART/'BENCHMARK.json').write_text(json.dumps(results,indent=2)+'\n')
    seed(25);reset_baseline()
    return results

try:
    check('captured 40-policy baseline and candidate preserve nine actor rowsets',parity)
    check('anon table grant denials unchanged',denials)
    check('UPDATE target rowsets unchanged',update_parity)
    check('prepared statement identity changes and admin revocation',cache_scope)
    check('drift guards, dry-run rollback and restoration',drift_and_rollback)
    check('local actual RLS plans/timings/helper calls at 25 and 250 riders',benchmark)
finally:
    (ART/'NATIVE_RESULTS.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
    reset_baseline()
