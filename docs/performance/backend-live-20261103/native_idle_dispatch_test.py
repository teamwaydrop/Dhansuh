"""Synthetic loopback-only parity/cost probes for one idle cron guard."""
from pathlib import Path
import json
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
ART = Path(__file__).parent
PSQL = ROOT / '.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe'
DB = 'waydrop_idle_dispatch_test'
ARGS = [str(PSQL), '-X', '-q', '-A', '-t', '-h', '127.0.0.1', '-p', '54329', '-U', 'waydrop_local', '-v', 'ON_ERROR_STOP=1']


def sql(q, database=DB, check=True):
    r = subprocess.run([*ARGS, '-d', database], input=q, capture_output=True, text=True, timeout=20)
    if check:
        assert r.returncode == 0, r.stderr
    return r


assert sql("SELECT inet_server_addr()=inet '127.0.0.1' AND inet_server_port()=54329;", 'postgres').stdout.strip() == 't'
exists = sql(f"SELECT count(*) FROM pg_database WHERE datname='{DB}';", 'postgres').stdout.strip()
if exists == '0':
    sql(f'CREATE DATABASE {DB};', 'postgres')
else:
    assert sql("SELECT label FROM public.fixture_marker;").stdout.strip() == 'waydrop_idle_dispatch_synthetic_v1'
sql("DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; DROP SCHEMA IF EXISTS vault CASCADE; DROP SCHEMA IF EXISTS net CASCADE;")
sql("""
CREATE TABLE public.fixture_marker(label text); INSERT INTO public.fixture_marker VALUES('waydrop_idle_dispatch_synthetic_v1');
CREATE TABLE public.metrics(k text PRIMARY KEY,n int); INSERT INTO public.metrics VALUES('vault',0),('config',0);
CREATE TABLE public.flags(secret_present bool); INSERT INTO public.flags VALUES(true);
CREATE TABLE public.orders(id uuid PRIMARY KEY, order_status text,order_type text,created_at timestamptz,dispatch_worker_running bool,dispatch_worker_started_at timestamptz);
CREATE TABLE public.enqueues(order_id text);
CREATE FUNCTION public.vault_probe() RETURNS text LANGUAGE plpgsql AS $$BEGIN UPDATE public.metrics SET n=n+1 WHERE k='vault'; IF (SELECT secret_present FROM public.flags) THEN RETURN 'synthetic-key'; END IF; RETURN NULL; END;$$;
CREATE FUNCTION public.config_probe() RETURNS int LANGUAGE plpgsql AS $$BEGIN UPDATE public.metrics SET n=n+1 WHERE k='config'; RETURN 900; END;$$;
CREATE SCHEMA vault; CREATE VIEW vault.decrypted_secrets AS SELECT public.vault_probe() AS decrypted_secret,'supabase_service_role_key'::text AS name;
CREATE VIEW public.dispatch_config AS SELECT public.config_probe() AS max_search_duration_sec,true AS is_active;
CREATE SCHEMA net;
CREATE FUNCTION net.http_post(url text, headers jsonb, body jsonb, timeout_milliseconds int) RETURNS bigint LANGUAGE plpgsql AS $$BEGIN
 IF headers->>'Authorization'<>'Bearer synthetic-key' OR headers->>'apikey'<>'synthetic-key' OR timeout_milliseconds<>5000 THEN RAISE EXCEPTION 'Transport contract changed'; END IF;
 INSERT INTO public.enqueues VALUES(body->>'order_id'); RETURN 1; END;$$;
""")
before = (ART/'redispatch_stalled.before.sql').read_text(encoding='utf-8')
after = (ART/'redispatch_stalled.candidate.sql').read_text(encoding='utf-8')


def reset(rows='', secret=True):
    sql("TRUNCATE public.orders,public.enqueues; UPDATE public.metrics SET n=0; UPDATE public.flags SET secret_present="+('true' if secret else 'false')+';'+rows)


def row(kind='ride', status='searching', age=1, running='false', started='NULL'):
    return f"INSERT INTO public.orders VALUES('00000000-0000-4000-8000-000000000611','{status}','{kind}',now()-interval'{age} seconds',{running},{started});"


def tick():
    return json.loads(sql("""SELECT public.redispatch_stalled_searching_orders();
    SELECT json_build_object('vault',(SELECT n FROM public.metrics WHERE k='vault'),'config',(SELECT n FROM public.metrics WHERE k='config'),
      'enqueues',(SELECT count(*) FROM public.enqueues),'rows',(SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]') FROM public.orders o));""").stdout.strip().splitlines()[-1])


cases = [
    ('empty', '', True, 0, False),
    ('intercity_only', row('intercity_ride', age=800000), True, 0, False),
    ('local_ready', row(), True, 1, False),
    ('local_throttled', row(started="now()-interval'10 seconds'"), True, 0, False),
    ('local_retry_ready', row(started="now()-interval'21 seconds'"), True, 1, False),
    ('local_outside_config_window', row(age=1000), True, 0, False),
    ('terminal_cleanup', row(status='completed', running='true', started="now()-interval'121 seconds'"), True, 0, True),
    ('stale_active_search_worker_not_recovered', row(running='true', started="now()-interval'600 seconds'"), True, 0, False),
    ('missing_secret_ready', row(), False, 0, False),
    ('missing_secret_cleanup_preserved', row(status='completed', running='true', started="now()-interval'121 seconds'"), False, 0, False),
]
results = {}
hashes = {}
for phase, definition in [('before', before), ('after', after)]:
    sql(definition)
    if phase == 'before':
        sql('REVOKE ALL ON FUNCTION public.redispatch_stalled_searching_orders() FROM PUBLIC,anon,authenticated; GRANT EXECUTE ON FUNCTION public.redispatch_stalled_searching_orders() TO service_role;')
    hashes[phase] = sql("SELECT md5(pg_get_functiondef('public.redispatch_stalled_searching_orders()'::regprocedure));").stdout.strip()
    assert sql("SELECT NOT has_function_privilege('anon','public.redispatch_stalled_searching_orders()','EXECUTE') AND NOT has_function_privilege('authenticated','public.redispatch_stalled_searching_orders()','EXECUTE') AND has_function_privilege('service_role','public.redispatch_stalled_searching_orders()','EXECUTE');").stdout.strip() == 't'
    for name, rows, secret, enqueues, cleaned in cases:
        reset(rows, secret)
        data = tick()
        assert data['enqueues'] == enqueues, (phase, name, data)
        if cleaned:
            assert data['rows'][0]['dispatch_worker_running'] is False
        if name in ('stale_active_search_worker_not_recovered', 'missing_secret_cleanup_preserved'):
            assert data['rows'][0]['dispatch_worker_running'] is True
        if phase == 'before':
            results[name] = {'before': data}
        else:
            old = results[name]['before']
            # Row timestamps differ because each synthetic scenario is freshly seeded;
            # compare the complete state except those relative setup timestamps.
            clean = lambda values: [{k:v for k,v in x.items() if k not in ('created_at','dispatch_worker_started_at')} for x in values]
            assert clean(data['rows']) == clean(old['rows']), (name, old, data)
            assert data['enqueues'] == old['enqueues']
            results[name]['after'] = data
            results[name]['passed'] = True
    reset()
    tick()
    sql(row())
    arrival = tick()
    assert arrival['enqueues'] == 1
    results.setdefault('arrival_after_idle_tick', {})[phase] = arrival
    # A competing transaction must still be rejected by the existing lock,
    # before either the guard or protected secret/config reads.
    reset(row())
    holder = subprocess.Popen([*ARGS, '-d', DB, '-c', "SET application_name='idle_guard_lock_holder'; BEGIN; SELECT pg_advisory_xact_lock(4735021,2); SELECT pg_sleep(2); COMMIT;"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    limit = time.monotonic()+1.5
    while sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='idle_guard_lock_holder' AND wait_event='PgSleep';").stdout.strip() != '1':
        assert time.monotonic()<limit, 'lock barrier missing'
        time.sleep(.02)
    locked = tick()
    assert locked['enqueues'] == locked['vault'] == locked['config'] == 0
    holder.communicate(timeout=5)
    assert holder.returncode == 0
    results.setdefault('actual_advisory_lock_contention', {})[phase] = locked

assert hashes['before'] == 'b486cd2e7650778ba2a41fe3eac5ea0a', hashes
assert results['empty']['after']['vault'] == results['empty']['after']['config'] == 0
assert results['intercity_only']['after']['vault'] == results['intercity_only']['after']['config'] == 0
result = {'passed_groups':len(results),'failed':0,'hashes':hashes,'cases':results,
          'actual_postgres':True,'synthetic_loopback_only':True,'managed_http_vault_integration':False,
          'fixture':'127.0.0.1:54329/'+DB,'engine':sql('SELECT version();').stdout.strip()}
(ART/'NATIVE_IDLE_GUARD_RESULTS.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'passed_groups':len(results),'failed':0,'hashes':hashes}))
