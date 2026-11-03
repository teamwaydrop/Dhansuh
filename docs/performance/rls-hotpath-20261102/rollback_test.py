"""Exercise only the fixed loopback RLS fixture's reviewed rollback file."""
import json
from local_fixture import ART, sql, scalar

assert scalar('SELECT value FROM rls_fixture_marker')=='waydrop_rls_hotpath_synthetic_v1'
assert scalar("SELECT inet_server_addr()=inet '127.0.0.1' AND inet_server_port()=54329")=='t'
candidate=(ART/'RLS_INITPLAN_CANDIDATE.sql').read_text()
rollback=(ART/'RLS_INITPLAN_ROLLBACK.sql').read_text()
def state():
    return scalar("SELECT jsonb_object_agg(polname,pg_get_expr(polqual,polrelid)) FROM pg_policy WHERE polname IN('admin_can_select_orders','admin_can_select_riders','admin_can_select_users','admin_can_select_rider_kyc')")
original=state()
sql(candidate.rsplit('ROLLBACK;',1)[0]+'COMMIT;')
wrapped=state()
sql(rollback)
assert state()==wrapped
sql(rollback.rsplit('ROLLBACK;',1)[0]+'COMMIT;')
assert state()==original
r=sql(rollback,check=False)
assert r.returncode and 'Rollback policy drift' in r.stderr
result={'dry_run_keeps_candidate':True,'committed_local_rollback_restores_original':True,'second_rollback_blocks_on_drift':True,'production_applied':False}
(ART/'ROLLBACK_RESULTS.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS three guarded rollback checks')
