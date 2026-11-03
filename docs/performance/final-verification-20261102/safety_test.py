"""Additional native counterexamples. Uses prior synthetic fixtures only, never production."""
import json
from pathlib import Path
import subprocess
from concurrent.futures import ThreadPoolExecutor

ROOT=Path(__file__).resolve().parents[3]
ART=Path(__file__).parent
PSQL=ROOT/'.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe'
def sql(statement,db='waydrop_part3_test',ok=True):
    assert db in ['waydrop_part3_test','waydrop_part4_synthetic']
    r=subprocess.run([str(PSQL),'-X','-q','-A','-t','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d',db,'-v','ON_ERROR_STOP=1','-c',statement],capture_output=True,text=True)
    if ok and r.returncode: raise AssertionError(r.stderr)
    return r
def uid(n): return f'00000000-0000-4000-8000-{n:012d}'
assert sql('SELECT current_database()').stdout.strip()=='waydrop_part3_test'
o,r=uid(7040),uid(201)
results=[]
def record(name,verdict,**detail):
    results.append(dict(name=name,verdict=verdict,**detail))

# Execute the captured SECURITY DEFINER body with the observed caller privileges.
sql((ART/'new_order_core.production.sql').read_text())
sql('GRANT USAGE ON SCHEMA public TO anon,authenticated,service_role; GRANT EXECUTE ON FUNCTION assign_new_order_to_nearby_online_riders_core(uuid) TO PUBLIC;')
sql(f"BEGIN; SET LOCAL ROLE anon; SELECT assign_new_order_to_nearby_online_riders_core('{o}'); ROLLBACK;")
record('anonymous invocation of captured internal matching body is admitted','DEFECT_REPRODUCED')
sql((ART/'INTERNAL_DISPATCH_ACL.candidate.sql').read_text())
for role in ['anon','authenticated']:
    denied=sql(f"BEGIN; SET LOCAL ROLE {role}; SELECT assign_new_order_to_nearby_online_riders_core('{o}'); ROLLBACK;",ok=False)
    assert denied.returncode and 'permission denied for function' in denied.stderr
    record(f'ACL candidate denies direct {role} call','LOCAL_FIX_PASS')
sql(f"BEGIN; SET LOCAL ROLE service_role; SELECT assign_new_order_to_nearby_online_riders_core('{o}'); ROLLBACK;")
record('ACL candidate preserves service-role enqueue consumer','LOCAL_FIX_PASS')

worker=(ROOT/'supabase/functions/start-dispatch/index.ts').read_text()
assert '.upsert(dispatchRows, { onConflict: "order_id,rider_id" })' in worker
assert '.update({ dispatch_state: stateUpdate })\n                .eq("id", order_id)' in worker
# Exact PostgreSQL equivalents of the worker's conflict update / ID-only state
# write. Captured assignment constraints and fixture triggers are installed.
out=sql(f"""BEGIN;
UPDATE orders SET dispatch_worker_running=true,dispatch_worker_started_at='2026-11-02T00:01:00Z',order_status='accepted',rider_id='{r}' WHERE id='{o}';
UPDATE rider_assignments SET assignment_status='accepted',accepted_at=now() WHERE order_id='{o}' AND rider_id='{r}';
INSERT INTO rider_assignments(order_id,rider_id,assignment_status,sent_at,expires_at,accepted_at)
VALUES('{o}','{r}','sent',now(),now()+interval '2 minutes',NULL)
ON CONFLICT(order_id,rider_id) DO UPDATE SET assignment_status=excluded.assignment_status,sent_at=excluded.sent_at,expires_at=excluded.expires_at,accepted_at=excluded.accepted_at;
UPDATE orders SET dispatch_state='{{"owner":"old-worker"}}'::jsonb WHERE id='{o}';
SELECT jsonb_build_object('offer_status',assignment_status,'accepted_at_cleared',a.accepted_at IS NULL,'new_lease_retained',o.dispatch_worker_started_at='2026-11-02T00:01:00Z','state_overwritten',o.dispatch_state->>'owner'='old-worker')
FROM rider_assignments a JOIN orders o ON o.id=a.order_id WHERE a.order_id='{o}' AND a.rider_id='{r}';
ROLLBACK;""").stdout.strip()
state=json.loads(out)
assert state==dict(offer_status='sent',accepted_at_cleared=True,new_lease_retained=True,state_overwritten=True),state
record('resumed old worker can overwrite offer and dispatch state after replacement','UNSAFE_REPRODUCED',scope='Native equivalents of actual unfenced write predicates; not a complete managed Edge process rehearsal',**state)
out=sql(f"""BEGIN;
UPDATE orders SET dispatch_worker_running=true,dispatch_worker_started_at='2026-11-02T00:01:00Z' WHERE id='{o}';
WITH changed AS (UPDATE orders SET dispatch_worker_running=false WHERE id='{o}' AND dispatch_worker_started_at='2026-11-02T00:00:00Z' RETURNING id) SELECT count(*) FROM changed;
ROLLBACK;""").stdout.strip()
assert out=='0',out
record('old worker exact-token release cannot clear replacement lease','PASS',changed_rows=0)

# Real lock-wait race: the reject read saw sent, accept holds that row and then
# commits accepted, and the conditional reject UPDATE must recheck after waiting.
reject=(ROOT/'supabase/functions/reject-order/index.ts').read_text()
assert '.eq("assignment_status", assignment.assignment_status)' in reject
sql(f"UPDATE rider_assignments SET assignment_status='sent',accepted_at=NULL WHERE order_id='{o}' AND rider_id='{r}';")
with ThreadPoolExecutor(max_workers=1) as pool:
    acceptance=pool.submit(sql,f"BEGIN; /* part5_accept_barrier */ UPDATE rider_assignments SET assignment_status='accepted',accepted_at=now() WHERE order_id='{o}' AND rider_id='{r}'; SELECT pg_sleep(2); COMMIT;")
    for _ in range(12):
        waiting=sql("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid<>pg_backend_pid() AND datname=current_database() AND query LIKE '%part5_accept_barrier%' AND wait_event='PgSleep');").stdout.strip()
        if waiting=='t': break
    assert waiting=='t','Acceptance test barrier did not start'
    changed=sql(f"WITH changed AS (UPDATE rider_assignments SET assignment_status='rejected' WHERE order_id='{o}' AND rider_id='{r}' AND assignment_status='sent' RETURNING id) SELECT count(*) FROM changed;").stdout.strip()
    acceptance.result()
assert changed=='0',changed
assert sql(f"SELECT assignment_status FROM rider_assignments WHERE order_id='{o}' AND rider_id='{r}'").stdout.strip()=='accepted'
record('conditional reject rechecks after a concurrent acceptance row lock','LOCAL_FIX_PASS',changed_rows=0,accepted_preserved=True)

# Current captured rider core does not itself recheck online eligibility.
core=f"SELECT assign_nearby_searching_orders_core('{r}','{uid(9001)}',17,79,'local');"
out=sql(f"""BEGIN;
UPDATE orders SET order_status='cancelled' WHERE id<>'{o}';
UPDATE orders SET order_status='searching',rider_id=NULL,created_at=now() WHERE id='{o}';
UPDATE riders SET account_status='offline' WHERE id='{r}';
DELETE FROM rider_assignments WHERE order_id='{o}'; DELETE FROM order_assignment_logs WHERE order_id='{o}';
{core}
SELECT count(*) FROM rider_assignments WHERE order_id='{o}' AND assignment_status='sent';
ROLLBACK;""").stdout.strip().splitlines()[-1]
assert out=='1',out
record('service rider-core call can offer to rider now offline','ELIGIBILITY_PARITY_GAP_REPRODUCED',offers=1,limit='Caller may have selected online before a transition; not evidence of incident occurrence')
out=sql(f"""BEGIN;
UPDATE orders SET order_status='cancelled' WHERE id<>'{o}';
UPDATE orders SET order_status='searching',created_at=now(),dispatch_worker_running=false,dispatch_worker_started_at=NULL WHERE id='{o}';
DELETE FROM local_http_enqueue;
SELECT redispatch_stalled_searching_orders(); SELECT redispatch_stalled_searching_orders();
SELECT count(*) FROM local_http_enqueue WHERE body->>'order_id'='{o}';
ROLLBACK;""").stdout.strip().splitlines()[-1]
assert out=='2',out
record('two completed recovery selections before a worker claims enqueue twice','AMPLIFIER_REPRODUCED',enqueues=2,limit='Transaction advisory locks do not coalesce asynchronous queue lifetime')

# Grant transport-level permission only inside the disposable fixture to test
# that an unauthenticated role still has no admitting RLS policy.
db='waydrop_part4_synthetic'
sql('GRANT USAGE ON SCHEMA public,auth TO anon; GRANT SELECT,INSERT ON order_chat_messages TO anon;',db)
denied=sql(f"BEGIN; SET LOCAL ROLE anon; INSERT INTO order_chat_messages(sender_id,message,is_support,user_id) VALUES('{uid(101)}','synthetic',true,'{uid(101)}'); ROLLBACK;",db,ok=False)
assert denied.returncode and 'row-level security' in denied.stderr
record('unauthenticated chat INSERT denied by RLS despite fixture table grant','PASS')
(ART/'SAFETY_RESULTS.json').write_text(json.dumps({'production_requests':0,'checks':results,'stale_worker_recovery':'BLOCKED_FOR_DEPLOYMENT'},indent=2)+'\n')
print(json.dumps({'checks':len(results),'unexpected_failures':0,'stale_recovery':'BLOCKED_FOR_DEPLOYMENT'}))
