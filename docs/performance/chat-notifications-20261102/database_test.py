"""PG17-only synthetic chat/notification chain. Never accepts a production URL."""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
PSQL = ROOT / '.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe'
DB = 'waydrop_part4_synthetic'
BASE = [str(PSQL), '-X', '-q', '-A', '-t', '-h', '127.0.0.1', '-p', '54329', '-U', 'waydrop_local', '-v', 'ON_ERROR_STOP=1']
def sql(text, db=DB, ok=True):
    result = subprocess.run(BASE + ['-d', db, '-c', text], capture_output=True, text=True, encoding='utf-8')
    if ok and result.returncode:
        raise AssertionError(result.stderr)
    return result

if sql("SELECT 1 FROM pg_database WHERE datname='waydrop_part4_synthetic'", 'postgres').stdout.strip() != '1':
    sql('CREATE DATABASE waydrop_part4_synthetic', 'postgres')
assert sql('SELECT current_database()').stdout.strip() == DB
catalog = json.loads((Path(__file__).parent / 'CATALOG.json').read_text())
# Destructive reset is restricted to this fixed, loopback-only synthetic database.
sql('DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; DROP SCHEMA IF EXISTS auth CASCADE; CREATE SCHEMA auth; DROP SCHEMA IF EXISTS net CASCADE; CREATE SCHEMA net; DROP SCHEMA IF EXISTS vault CASCADE; CREATE SCHEMA vault;')
sql("""
DO $$ BEGIN
IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $$;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.uid',true),'')::uuid $$;
CREATE TYPE intercity_assignment_status_enum AS ENUM ('sent','accepted','rejected');
CREATE TABLE users(id uuid PRIMARY KEY,role text,full_name text);
CREATE TABLE orders(id uuid PRIMARY KEY,user_id uuid,rider_id uuid);
CREATE TABLE riders(id uuid PRIMARY KEY,user_id uuid);
CREATE TABLE rider_assignments(order_id uuid,rider_id uuid,assignment_status intercity_assignment_status_enum);
CREATE TABLE intercity_requests(parcel_id uuid,status text);
CREATE TABLE notification_failures(failure_stage text,source_function text,notification_type text,reference_id uuid,user_id uuid,notification_id uuid,error_code text,error_message text);
CREATE TABLE vault.decrypted_secrets(name text,decrypted_secret text);
INSERT INTO vault.decrypted_secrets VALUES('supabase_service_role_key','synthetic-local-only');
CREATE TABLE net.enqueue_capture(id bigserial PRIMARY KEY, payload jsonb);
CREATE FUNCTION net.http_post(url text,headers jsonb,body jsonb,timeout_milliseconds integer) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE result bigint; BEGIN
IF current_setting('app.fault',true)='timeout' THEN PERFORM pg_sleep(0.1); END IF;
IF current_setting('app.fault',true)='enqueue' THEN RAISE EXCEPTION 'synthetic enqueue failure'; END IF;
INSERT INTO net.enqueue_capture(payload) VALUES(body) RETURNING id INTO result;
RETURN result; END $$;
"""
)
for table in ['order_chat_messages', 'notifications']:
    columns = []
    for col in catalog['columns']:
        if col['table'] != table:
            continue
        columns.append('"%s" %s%s%s' % (col['column'], col['type'],
            ' DEFAULT ' + col['default'] if col['default'] else '',
            ' PRIMARY KEY' if col['column'] == 'id' else ''))
    sql('CREATE TABLE public.' + table + '(' + ','.join(columns) + ')')
for definition in catalog['definitions']:
    sql(definition['definition'])
for trigger in catalog['triggers']:
    sql(trigger['definition'])
sql('ALTER TABLE order_chat_messages ENABLE ROW LEVEL SECURITY; GRANT USAGE ON SCHEMA public,auth TO authenticated,service_role; GRANT SELECT ON users,orders,riders,rider_assignments TO authenticated; GRANT SELECT,INSERT ON order_chat_messages TO authenticated,service_role; GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated,service_role;')
for p in catalog['policies']:
    if p['tablename'] == 'order_chat_messages' and p['cmd'] in ['INSERT','SELECT'] and p['policyname'] != 'admin_can_select_order_chat_messages':
        sql('CREATE POLICY "' + p['policyname'] + '" ON order_chat_messages FOR ' + p['cmd'] + ' TO authenticated ' +
            ('WITH CHECK (' + p['with_check'] + ')' if p['cmd']=='INSERT' else 'USING (' + p['qual'] + ')'))
passenger, rideruser, rider, order, other, admin = [str(uuid.UUID(int=x)) for x in range(101,107)]
sql(f"INSERT INTO users VALUES('{passenger}','user','Synthetic passenger'),('{rideruser}','rider','Synthetic rider'),('{other}','user','Synthetic other'),('{admin}','support','Synthetic agent'); INSERT INTO riders VALUES('{rider}','{rideruser}'); INSERT INTO orders VALUES('{order}','{passenger}','{rider}');")
results = []
def context(actor=passenger, role='authenticated'):
    return f"BEGIN; SET LOCAL ROLE {role}; SET LOCAL app.uid='{actor}'; "
def insert(mid, sender=passenger, oid=order, support=False, extra='', thread_user=passenger):
    return f"INSERT INTO order_chat_messages(id,order_id,rider_id,sender_id,sender_type,message,user_id,is_support) VALUES('{mid}',{repr(oid) if oid else 'NULL'},'{rider}','{sender}','user','synthetic message','{thread_user}',{str(support).lower()}); {extra}"
def record(name, **values):
    results.append({'test':name,'passed':True,**values})

baseline = sql(context()+insert(str(uuid.uuid4()),other)+'ROLLBACK;')
record('captured INSERT policy allows participant to forge sender (rolled back)', before_forged_inserts_allowed=1)
sql(context()+insert(str(uuid.uuid4()),oid=None,support=True,thread_user=other)+'ROLLBACK;')
record('captured INSERT policy allows unsolicited other-user support message (rolled back)')
sql((Path(__file__).parent/'CHAT_SENDER_POLICY.candidate.sql').read_text())
result=sql(context()+insert(str(uuid.uuid4()),oid=None,support=True,thread_user=other)+'COMMIT;',ok=False)
assert result.returncode and 'row-level security' in result.stderr,result.stderr
record('candidate denies unsolicited other-user support message')
sql(context()+insert(str(uuid.uuid4()),oid=None,support=True)+'ROLLBACK;')
record('candidate preserves own support thread')
for label, actor, sender, oid in [('forged sender',passenger,other,order),('foreign order',other,other,order)]:
    result=sql(context(actor)+insert(str(uuid.uuid4()),sender,oid)+'COMMIT;',ok=False)
    assert result.returncode and 'row-level security' in result.stderr, result.stderr
    record('candidate denies '+label)
for label, actor, role, support in [('passenger',passenger,'authenticated',False),('rider',rideruser,'authenticated',False),('support own identity',admin,'authenticated',True),('trusted server',other,'service_role',True)]:
    sql(context(actor,role)+insert(str(uuid.uuid4()),actor,None if support else order,support)+'ROLLBACK;')
    record('candidate preserves '+label)
mid = str(uuid.uuid4())
started=time.perf_counter()
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    attempts=list(pool.map(lambda _: sql(context()+insert(mid)+'COMMIT;',ok=False),range(12)))
assert sum(x.returncode==0 for x in attempts)==1
assert all(x.returncode==0 or 'duplicate key' in x.stderr for x in attempts)
counts=sql('SELECT (SELECT count(*) FROM order_chat_messages),(SELECT count(*) FROM notifications),(SELECT count(*) FROM net.enqueue_capture)').stdout.strip()
assert counts=='1|1|1',counts
record('12 competing identical UUID INSERTs commit one message/notification/enqueue', attempts=12, max_parallel_clients=8, committed=1, rows=[1,1,1], elapsed_ms=round((time.perf_counter()-started)*1000,3))
timeout_id=str(uuid.uuid4())
result=sql(context()+"SET LOCAL app.fault='timeout'; SET LOCAL statement_timeout='10ms'; "+insert(timeout_id)+'COMMIT;',ok=False)
assert result.returncode and 'statement timeout' in result.stderr,result.stderr
assert sql(f"SELECT count(*) FROM order_chat_messages WHERE id='{timeout_id}'").stdout.strip()=='0'
assert sql('SELECT count(*) FROM notifications').stdout.strip()=='1'
record('real statement timeout cancels full chat/notification/enqueue transaction', sqlstate='57014', new_committed_rows=0)
enqueue_id=str(uuid.uuid4())
sql(context()+"SET LOCAL app.fault='enqueue'; "+insert(enqueue_id)+'COMMIT;')
counts=sql('SELECT (SELECT count(*) FROM order_chat_messages),(SELECT count(*) FROM notifications),(SELECT count(*) FROM net.enqueue_capture),(SELECT count(*) FROM notification_failures)').stdout.strip()
assert counts=='2|2|1|1',counts
record('ordinary enqueue exception preserves chat/inbox and records failure, not a chat 500', rows=[2,2,1,1])
sql(f"INSERT INTO intercity_requests VALUES('{order}','request_sent')")
result=sql(context()+insert(str(uuid.uuid4()))+'COMMIT;',ok=False)
assert result.returncode and 'after the request is accepted' in result.stderr,result.stderr
record('actual pre-acceptance trigger still blocks passenger chat')
sql('DELETE FROM intercity_requests')
# Measure the complete captured trigger chain locally, using only a fake pg_net queue.
timings=[]
for _ in range(10):
    start=time.perf_counter()
    sql(context()+insert(str(uuid.uuid4()))+'ROLLBACK;')
    timings.append(round((time.perf_counter()-start)*1000,3))
out={'database':DB,'host':'127.0.0.1:54329','managed_auth':False,'provider_network':False,'tests':results,
     'chain_round_trip_ms_including_psql_startup':timings,
     'measurement_limit':'Synthetic mechanism checks only. No before/after trigger optimization or production latency measurement.'}
(Path(__file__).parent/'DATABASE_RESULTS.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps({'passed':len(results),'failed':0,'concurrent_rows':[1,1,1],'production_requests':0}))
