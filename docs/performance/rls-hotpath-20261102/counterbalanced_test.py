"""Repeat small-table timings in alternating A/B order after mixed first run."""
import ast
from concurrent.futures import ThreadPoolExecutor
import json
import statistics
from local_fixture import ART, sql, scalar, lit, uid, seed

assert scalar('SELECT value FROM rls_fixture_marker')=='waydrop_rls_hotpath_synthetic_v1'
tree=ast.parse((ART/'native_test.py').read_text())
query=next(ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='QUERY' for t in n.targets))
candidate=(ART/'RLS_INITPLAN_CANDIDATE.sql').read_text()
baseline=''.join(f'ALTER POLICY admin_can_select_{t} ON {t} USING (public.is_admin());' for t in ['orders','riders','users','rider_kyc'])
def reset():sql(baseline)
def apply():sql(candidate.rsplit('ROLLBACK;',1)[0]+'COMMIT;')
def settings(n):
    claims=json.dumps({'sub':uid(n),'email':f'user{n}@example.invalid','role':'authenticated'})
    return "SET LOCAL request.jwt.claim.sub='';SET LOCAL request.jwt.claim.email='';SET LOCAL request.jwt.claim.role='';SET LOCAL request.jwt.claims="+lit(claims)+';SET LOCAL ROLE authenticated;'
def docs(text):
    values=[];text=text.strip();decoder=json.JSONDecoder()
    while text:
        value,end=decoder.raw_decode(text);values.append(value);text=text[end:].lstrip()
    return values

seed(25)
rows=[]
try:
    for batch in range(6):
        for phase in (['before','after'] if batch%2==0 else ['after','before']):
            reset()
            if phase=='after':apply()
            commands=''
            for actor in [1,5,999]:
                commands+='BEGIN;'+settings(actor)+('EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) '+query+';')*5+'COMMIT;'
            plans=docs(sql(commands).stdout)
            assert len(plans)==15
            for i,actor in enumerate([1,5,999]):
                group=[p[0] for p in plans[i*5:(i+1)*5]]
                rows.append({'batch':batch,'phase':phase,'actor':actor,'execution_ms':[p['Execution Time'] for p in group[1:]],'planning_ms':[p['Planning Time'] for p in group[1:]],'output_rows':group[-1]['Plan']['Actual Rows']})
    summary=[]
    for actor in [1,5,999]:
        phases={}
        for phase in ['before','after']:
            values=[v for r in rows if r['actor']==actor and r['phase']==phase for v in r['execution_ms']]
            phases[phase]={'median_ms':statistics.median(values),'min_ms':min(values),'max_ms':max(values),'samples':len(values)}
        summary.append({'actor':actor,**phases})
    # Simultaneous identities must not share an admin result across sessions.
    apply()
    def read_actor(n):
        return n,int(sql('BEGIN;'+settings(n)+'SELECT count(*) FROM rider_kyc;ROLLBACK;').stdout.strip())
    actors=[1,5,999,3]*4
    with ThreadPoolExecutor(max_workers=4) as pool:
        concurrent=list(pool.map(read_actor,actors))
    assert all(count=={1:25,5:1,999:0,3:25}[n] for n,count in concurrent)
    result={'fixture_riders':25,'order':'AB,BA alternated over six batches','warmup_excluded_per_actor_phase_batch':1,'summary':summary,'raw':rows,'concurrent_actor_reads':concurrent,'concurrency_pass':True}
    (ART/'COUNTERBALANCED.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'summary':summary,'concurrent_identity_reads_passed':len(concurrent)}))
finally:reset()
