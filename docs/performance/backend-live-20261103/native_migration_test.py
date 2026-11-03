"""Replay guarded migration/rollback in fixed loopback synthetic fixture only."""
from pathlib import Path
import subprocess
import json

ART = Path(__file__).resolve().parent
ROOT = ART.parents[2]
ARGS = [str(ROOT / '.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe'), '-X', '-q', '-A', '-t', '-h', '127.0.0.1', '-p', '54329', '-U', 'waydrop_local', '-d', 'waydrop_idle_dispatch_test', '-v', 'ON_ERROR_STOP=1']

def sql(q, ok=True):
    p = subprocess.run(ARGS, input=q, text=True, capture_output=True, timeout=20)
    assert (p.returncode == 0) == ok, p.stderr
    return p.stdout.strip()

assert sql("SELECT inet_server_addr()=inet '127.0.0.1' AND inet_server_port()=54329 AND (SELECT label='waydrop_idle_dispatch_synthetic_v1' FROM public.fixture_marker);") == 't'
before = 'b486cd2e7650778ba2a41fe3eac5ea0a'
after = 'd70d703c15e3ee72834dc627af1fee80'
def digest():
    return sql("SELECT md5(pg_get_functiondef('public.redispatch_stalled_searching_orders()'::regprocedure));")

# Sole replay substitution: production owner postgres -> synthetic owner waydrop_local.
apply = (ART/'APPLY.sql').read_text(encoding='utf-8').replace("pg_get_userbyid(p.proowner)='postgres'", "pg_get_userbyid(p.proowner)='waydrop_local'")
rollback = (ART/'ROLLBACK.review.sql').read_text(encoding='utf-8').replace("pg_get_userbyid(p.proowner)='postgres'", "pg_get_userbyid(p.proowner)='waydrop_local'")
sql((ART/'redispatch_stalled.before.sql').read_text(encoding='utf-8'))
assert digest() == before
sql(apply)
assert digest() == after
sql(apply, ok=False)
assert digest() == after
sql(rollback)
assert digest() == after
assert rollback.rstrip().endswith('ROLLBACK;')
sql(rollback.rstrip()[:-len('ROLLBACK;')]+'COMMIT;')
assert digest() == before
sql(rollback, ok=False)
assert digest() == before
assert sql("SELECT NOT has_function_privilege('anon','public.redispatch_stalled_searching_orders()','EXECUTE') AND NOT has_function_privilege('authenticated','public.redispatch_stalled_searching_orders()','EXECUTE') AND has_function_privilege('service_role','public.redispatch_stalled_searching_orders()','EXECUTE');") == 't'
result = {'passed': 6, 'failed': 0, 'checks': ['apply hash', 'repeat apply fails closed', 'default rollback is dry-run', 'explicit rollback restores original', 'repeat rollback fails closed', 'ACL preserved'], 'fixture_only_substitution': 'owner postgres -> waydrop_local', 'final_definition_md5': digest()}
(ART/'NATIVE_MIGRATION_RESULTS.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
print(json.dumps(result))
