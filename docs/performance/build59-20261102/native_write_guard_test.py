"""Fixed loopback PostgreSQL guard semantics, synthetic rows only. No production URL."""
import json
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
PSQL = ROOT / '.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe'
ARGS = [str(PSQL), '-X', '-q', '-A', '-t', '-h', '127.0.0.1', '-p', '54329',
        '-U', 'waydrop_local', '-d', 'waydrop_rls_hotpath_test', '-v', 'ON_ERROR_STOP=1']


def run(query):
    r = subprocess.run(ARGS, input=query, capture_output=True, text=True, timeout=15)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


assert run("SELECT current_database()='waydrop_rls_hotpath_test' AND inet_server_addr()=inet '127.0.0.1' AND inet_server_port()=54329;") == 't'
schema = 'waydrop_guard_probe_' + uuid.uuid4().hex[:10]
results = {}
created = False
try:
    run(f"""CREATE SCHEMA {schema};
    CREATE TABLE {schema}.notifications(id int PRIMARY KEY,user_id int,is_read boolean,read_at text);
    CREATE TABLE {schema}.users(id int PRIMARY KEY,preferred_mode text,last_active_mode text);
    CREATE TABLE {schema}.audit(table_name text);
    CREATE FUNCTION {schema}.count_effect() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN INSERT INTO {schema}.audit VALUES(TG_TABLE_NAME); RETURN NEW; END; $$;
    CREATE TRIGGER count_effect AFTER UPDATE ON {schema}.notifications FOR EACH ROW EXECUTE FUNCTION {schema}.count_effect();
    CREATE TRIGGER count_effect AFTER UPDATE ON {schema}.users FOR EACH ROW EXECUTE FUNCTION {schema}.count_effect();
    INSERT INTO {schema}.notifications VALUES(1,1,true,'original'),(2,1,false,NULL),(3,1,NULL,NULL),(4,2,false,NULL),(5,1,false,NULL);
    INSERT INTO {schema}.users VALUES(1,'user','user'),(2,'user',NULL),(3,'rider','user');""")
    created = True

    def notification(n):
        return f"WITH u AS (UPDATE {schema}.notifications SET is_read=true,read_at='new' WHERE id={n} AND user_id=1 AND (is_read IS NULL OR is_read=false) RETURNING id) SELECT count(*) FROM u;"

    def mode(n, value):
        return f"WITH u AS (UPDATE {schema}.users SET preferred_mode='{value}',last_active_mode='{value}' WHERE id={n} AND (preferred_mode IS NULL OR preferred_mode<>'{value}' OR last_active_mode IS NULL OR last_active_mode<>'{value}') RETURNING id) SELECT count(*) FROM u;"

    assert run(notification(1)) == '0'
    assert run(f"SELECT read_at FROM {schema}.notifications WHERE id=1;") == 'original'
    assert run(f"SELECT count(*) FROM {schema}.audit;") == '0'
    results['already_read_no_trigger_or_timestamp_write'] = 'pass'
    assert run(notification(2)) == '1' and run(notification(2)) == '0'
    results['unread_effect_once'] = 'pass'
    assert run(notification(3)) == '1' and run(notification(3)) == '0'
    results['legacy_null_effect_once'] = 'pass'
    assert run(notification(4)) == '0'
    assert run(f"SELECT is_read=false FROM {schema}.notifications WHERE id=4;") == 't'
    results['other_owner_untouched'] = 'pass'
    assert run(mode(1, 'user')) == '0'
    assert run(mode(2, 'user')) == '1' and run(mode(2, 'user')) == '0'
    assert run(mode(3, 'rider')) == '1' and run(mode(3, 'rider')) == '0'
    results['mode_correct_null_and_partial_repair'] = 'pass'

    # Observe the first transaction holding the row before starting its competitor.
    owner = subprocess.Popen([*ARGS, '-c', "SET application_name='waydrop_guard_owner'; BEGIN; " + notification(5) + ' SELECT pg_sleep(5); COMMIT;'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    deadline = time.monotonic() + 3
    while run("SELECT count(*) FROM pg_stat_activity WHERE application_name='waydrop_guard_owner' AND wait_event='PgSleep';") != '1':
        assert time.monotonic() < deadline, 'Owner barrier not observed'
        time.sleep(.02)
    waiter = subprocess.Popen([*ARGS, '-c', "SET application_name='waydrop_guard_waiter'; SET statement_timeout='8s'; " + notification(5)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    deadline = time.monotonic() + 2
    while run("SELECT count(*) FROM pg_stat_activity WHERE application_name='waydrop_guard_waiter' AND wait_event_type='Lock';") != '1':
        assert time.monotonic() < deadline, 'Actual lock overlap not observed'
        time.sleep(.02)
    out1, err1 = owner.communicate(timeout=10)
    out2, err2 = waiter.communicate(timeout=10)
    assert owner.returncode == waiter.returncode == 0, (err1, err2)
    assert out1.strip() == '1' and out2.strip() == '0', (out1, out2)
    assert run(f"SELECT count(*) FROM {schema}.audit WHERE table_name='notifications';") == '3'
    results['actual_lock_overlap_rechecks_predicate_one_winner'] = 'pass'
finally:
    if created:
        run(f'DROP SCHEMA {schema} CASCADE;')

result = {'engine': run('SELECT version();'), 'host': '127.0.0.1', 'port': 54329,
          'synthetic_only': True, 'groups': results, 'passed': len(results),
          'failed': 0, 'actual_concurrent_lock_overlap_observed': True,
          'fixture_schema_removed': True, 'managed_supabase_integration': False,
          'production_latency_or_wal_measurement': False}
(Path(__file__).parent / 'NATIVE_WRITE_GUARDS.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps({'native_groups_passed': len(results), 'lock_overlap_observed': True}))
