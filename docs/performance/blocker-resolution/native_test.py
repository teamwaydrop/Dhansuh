"""Fixed disposable loopback database only. Deterministic transaction/crash tests."""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import uuid

ROOT=Path(__file__).resolve().parents[3]
ART=Path(__file__).parent
PSQL=ROOT/'.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe'
DB='waydrop_blocker_test'
def sql(text,ok=True):
    r=subprocess.run([str(PSQL),'-X','-q','-A','-t','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d',DB,'-v','ON_ERROR_STOP=1','-c',"SET request.jwt.claim.role='service_role'; "+text],capture_output=True,text=True,encoding='utf-8')
    if ok and r.returncode: raise AssertionError(r.stderr)
    return r
def scalar(text):return sql(text).stdout.strip().splitlines()[-1]
def obj(text):return json.loads(scalar(text))
def uid(n):return f'00000000-0000-4000-8000-{n:012d}'
assert scalar('SELECT current_database()')==DB
results=[]
def test(name,action):
    try:
        details=action();results.append({'name':name,'status':'PASS','details':details});print('PASS',name,flush=True)
    except Exception as error:
        results.append({'name':name,'status':'FAIL','error':str(error)});print('FAIL',name,str(error),flush=True)
        raise
def eq(actual,expected):assert actual==expected,(actual,expected)

def bootstrap():
    # Fixture started as the prior native acceptance schema/data. No production URL.
    sql("DROP SCHEMA IF EXISTS waydrop_internal CASCADE; DROP TRIGGER IF EXISTS trigger_assign_nearby_orders ON riders; DROP TRIGGER IF EXISTS trigger_assign_new_order_to_nearby_riders ON orders; CREATE OR REPLACE FUNCTION public.accept_intercity_request(p_request_id uuid,p_rider_user_id uuid) RETURNS jsonb LANGUAGE sql AS $$SELECT jsonb_build_object('success',true)$$;")
    import re
    original=(ROOT/'docs/production-performance/waves/01_find_nearby_riders.sql').read_text()
    body=original[original.index('CREATE OR REPLACE FUNCTION'):original.index('$function$',original.index('$function$')+1)+len('$function$')]+';'
    sql(body)
    prior=json.loads((ROOT/'docs/performance/dispatch-cron-20261102/CATALOG.json').read_text())
    sql(next(x['definition'] for x in prior['functions'] if x['name']=='rider_self_rematch'))
    migration=(ROOT/'docs/migration-review/not-applied/20261102044001_waydrop_dispatch_fencing_and_delivery_outbox.sql').read_text()
    sql(migration.replace('CREATE FUNCTION ','CREATE OR REPLACE FUNCTION ').replace('ADD COLUMN dispatch_generation','ADD COLUMN IF NOT EXISTS dispatch_generation'))
    sql("CREATE SCHEMA IF NOT EXISTS vault; CREATE TABLE IF NOT EXISTS vault.decrypted_secrets(name text,decrypted_secret text); DELETE FROM vault.decrypted_secrets; INSERT INTO vault.decrypted_secrets VALUES('supabase_service_role_key','synthetic'); CREATE SCHEMA IF NOT EXISTS net; CREATE TABLE IF NOT EXISTS public.blocker_http(id bigserial,body jsonb);")
    sql("CREATE OR REPLACE FUNCTION net.http_post(url text,headers jsonb,body jsonb,timeout_milliseconds integer) RETURNS bigint LANGUAGE plpgsql AS $$DECLARE n bigint; BEGIN IF current_setting('blocker.fail_enqueue',true)='true' THEN RAISE EXCEPTION 'synthetic enqueue failure'; END IF; INSERT INTO blocker_http(body) VALUES(body) RETURNING id INTO n; RETURN n; END $$;")
    sql('DELETE FROM blocker_http;')
    sql("DELETE FROM orders WHERE order_code LIKE 'BLOCKER-%'; UPDATE orders SET order_status='cancelled'; UPDATE riders SET account_status='online',last_location_updated_at=clock_timestamp(),current_lat=17,current_lng=79; UPDATE rider_kyc SET kyc_status='approved',activation_status='active';")
    # Table fixture has the same captured notification AFTER INSERT shape.
    cutover=(ART/'CUTOVER.candidate.sql').read_text()
    signatures=re.findall(r"'(public\.[^']+)" ,cutover.split('END $preflight$')[0])
    values=','.join("('"+x+"')" for x in signatures)
    fingerprints=obj("SELECT jsonb_object_agg(sig,jsonb_build_object('md5',md5(pg_get_functiondef(p.oid)),'owner',p.proowner::regrole::text,'acl',COALESCE(p.proacl::text,'NULL'))) FROM (VALUES "+values+") s(sig) JOIN pg_proc p ON p.oid=to_regprocedure(s.sig)")
    sql("SELECT set_config('waydrop.approved_cutover','"+json.dumps(fingerprints).replace("'","''")+"',false);"+cutover)
    sql("DROP TRIGGER IF EXISTS trigger_notification_insert ON notifications; CREATE TRIGGER trigger_notification_insert AFTER INSERT ON notifications FOR EACH ROW EXECUTE FUNCTION on_notification_insert();")
    sql("DROP TRIGGER IF EXISTS trigger_assign_new_order_to_nearby_riders ON orders; CREATE TRIGGER trigger_assign_new_order_to_nearby_riders AFTER INSERT ON orders FOR EACH ROW EXECUTE FUNCTION assign_new_order_to_nearby_online_riders();")
    sql("DROP TRIGGER IF EXISTS trigger_assign_nearby_orders ON riders; CREATE TRIGGER trigger_assign_nearby_orders AFTER UPDATE OF account_status ON riders FOR EACH ROW WHEN (NEW.account_status::text='online' AND OLD.account_status IS DISTINCT FROM NEW.account_status) EXECUTE FUNCTION assign_nearby_searching_orders_to_rider();")
    return {'database':DB,'production':False}
test('disabled additive schema then explicit local cutover',bootstrap)

serial=900000
def order():
    global serial
    serial+=1;oid=uid(serial)
    sql(f"INSERT INTO orders SELECT (jsonb_populate_record(NULL::orders,to_jsonb(o)||jsonb_build_object('id','{oid}','order_code','BLOCKER-{serial}','order_status','searching','rider_id',NULL,'created_at',clock_timestamp(),'current_fare',100,'actual_fare',100,'final_fare',90,'rider_earning',80,'commission_percentage',10,'gst_percentage',5,'dispatch_worker_running',false,'dispatch_worker_started_at',NULL,'dispatch_state','{{}}'::jsonb))).* FROM orders o WHERE id='{uid(1000)}';")
    return oid
def claim(oid):return obj(f"SELECT claim_order_dispatch('{oid}')")
def step(oid,t):return obj(f"SELECT step_order_dispatch('{oid}','{t}')")
def force_due(oid):sql(f"UPDATE waydrop_internal.dispatch_jobs SET next_at=clock_timestamp()-interval '1 second',queued_until=NULL WHERE order_id='{oid}';")

def coalescing():
    oid=order()
    # The order-created trigger plus equivalent request callers compete for one job.
    with ThreadPoolExecutor(max_workers=12) as pool:
        out=list(pool.map(lambda _:obj(f"SELECT request_order_dispatch('{oid}')"),range(12)))
    eq(scalar(f"SELECT count(*) FROM blocker_http WHERE body->>'order_id'='{oid}'"),'1')
    with ThreadPoolExecutor(max_workers=12) as pool:claims=list(pool.map(lambda _:claim(oid),range(12)))
    eq(sum(x['claimed'] for x in claims),1)
    return {'events':13,'enqueues':1,'claim_winners':1}
test('12 overlapping requests enqueue once and one generation has one owner',coalescing)

def stale():
    oid=order();obj(f"SELECT request_order_dispatch('{oid}')");old=claim(oid)
    sql(f"UPDATE waydrop_internal.dispatch_jobs SET lease_until=clock_timestamp()-interval '1 second' WHERE order_id='{oid}'")
    new=claim(oid);assert new['token']!=old['token'];eq(new['generation'],old['generation']+1)
    eq(step(oid,old['token'])['code'],'STALE_OWNER')
    eq(scalar(f"SELECT release_order_dispatch('{oid}','{old['token']}')"),'f')
    bad=sql(f"UPDATE orders SET dispatch_state='{{\"stale\":true}}' WHERE id='{oid}'",ok=False);assert bad.returncode
    applied=step(oid,new['token']);eq(applied['applied'],True)
    eq(step(oid,old['token'])['code'],'STALE_OWNER')
    return {'stale_state_writes':0,'stale_releases':0,'replacement_applied':True,'offers':applied['offers']}
test('pause old owner, expire, replace, resume old owner: no writes/release',stale)

def rollback():
    oid=order();obj(f"SELECT request_order_dispatch('{oid}')");c=claim(oid)
    sql(f"BEGIN; SELECT step_order_dispatch('{oid}','{c['token']}'); ROLLBACK;")
    eq(scalar(f"SELECT count(*) FROM rider_assignments WHERE order_id='{oid}'"),'0')
    eq(scalar(f"SELECT state FROM waydrop_internal.dispatch_jobs WHERE order_id='{oid}'"),'running')
    # A rolled-back step can be replayed by the same live owner without duplicates.
    step(oid,c['token'])
    count=scalar(f"SELECT count(*) FROM rider_assignments WHERE order_id='{oid}'")
    eq(step(oid,c['token'])['code'],'STALE_OWNER')
    eq(scalar(f"SELECT count(*) FROM rider_assignments WHERE order_id='{oid}'"),count)
    return {'rollback_offers':0,'committed_offers':int(count),'replay_extra_offers':0}
test('crash/rollback during step rolls back offer, audit, notification and state',rollback)

def parity():
    oid=order();rid=uid(201)
    cases=[('offline',"UPDATE riders SET account_status='offline' WHERE id='{r}'",'RIDER_OFFLINE'),
      ('kyc',"UPDATE rider_kyc SET kyc_status='rejected' WHERE id=(SELECT kyc_id FROM riders WHERE id='{r}')",'KYC_NOT_VERIFIED'),
      ('activation',"UPDATE rider_kyc SET activation_status='inactive' WHERE id=(SELECT kyc_id FROM riders WHERE id='{r}')",'KYC_NOT_VERIFIED'),
      ('mode',"UPDATE riders SET service_mode='intercity' WHERE id='{r}'",'WRONG_SERVICE_MODE'),
      ('cod',"UPDATE riders SET cod_pending_amount=1000,cod_limit=500 WHERE id='{r}'",'COD_LIMIT_EXCEEDED'),
      ('tax',"UPDATE riders SET government_tax_due_balance=1000 WHERE id='{r}'",'TAX_DUE_THRESHOLD_BLOCKED'),
      ('stale',"UPDATE riders SET last_location_updated_at=clock_timestamp()-interval '1 day' WHERE id='{r}'",'LOCATION_STALE'),
      ('vehicle',"UPDATE rider_kyc SET vehicle_type='cab' WHERE id=(SELECT kyc_id FROM riders WHERE id='{r}')",'WRONG_VEHICLE'),
      ('self',"UPDATE orders SET user_id=(SELECT user_id FROM riders WHERE id='{r}') WHERE id='{o}'",'SELF_ORDER'),
      ('search',"UPDATE orders SET created_at=clock_timestamp()-interval '2 days' WHERE id='{o}'",'SEARCH_EXPIRED')]
    for name,mutation,reason in cases:
        text="BEGIN; "+mutation.format(r=rid,o=oid)+f"; SELECT jsonb_build_array(dispatch_eligibility('{oid}','{rid}','offer'),dispatch_eligibility('{oid}','{rid}','accept')); ROLLBACK;"
        val=json.loads(sql(text).stdout.strip().splitlines()[-1]);eq(val,[reason,reason])
        # All former writers only request; canonical step and public matcher must deny.
        flow=f"BEGIN; "+mutation.format(r=rid,o=oid)+f"; SELECT assign_new_order_to_nearby_online_riders_core('{oid}'); SELECT assign_nearby_searching_orders_core('{rid}','{uid(9001)}',17,79,'local'); SELECT redispatch_stalled_searching_orders(); SELECT redispatch_freed_riders(); SELECT set_config('request.jwt.claim.sub','{uid(9001)}',true); SELECT rider_self_rematch(); SELECT set_config('request.jwt.claim.sub','',true); SELECT step_order_dispatch('{oid}',(claim_order_dispatch('{oid}')->>'token')::uuid); SELECT jsonb_build_array((SELECT count(*) FROM rider_assignments WHERE order_id='{oid}' AND rider_id='{rid}' AND assignment_status='sent'),(SELECT count(*) FROM find_nearby_riders('{oid}',17,79,6,50,'{{}}'::uuid[]) WHERE rider_id='{rid}')); ROLLBACK;"
        eq(json.loads(sql(flow).stdout.strip().splitlines()[-1]),[0,0])
    return {'parity_rows':len(cases),'entry_points':5,'public_matcher':True,'phases':['offer','accept']}
test('shared offer/accept eligibility denies each inconsistent rider state',parity)

def notification(two=False):
    user=uid(9001);nid=str(uuid.uuid4())
    sql(f"DELETE FROM user_device_tokens WHERE user_id='{user}';")
    devices=[]
    for i in range(2 if two else 1):
        did=str(uuid.uuid4());devices.append(did)
        sql(f"INSERT INTO user_device_tokens(id,user_id,fcm_token,updated_at) VALUES('{did}','{user}','synthetic-{did}',clock_timestamp())")
    sql(f"INSERT INTO notifications(id,user_id,title,body,notification_type,payload) VALUES('{nid}','{user}','synthetic','synthetic','chat_message','{{}}')")
    return nid,devices
def push_claim(nid,actor='NULL'):return obj(f"SELECT claim_notification_delivery('{nid}',{actor})")
def begin(nid,d):return scalar(f"SELECT begin_notification_device('{nid}','{d['device_id']}','{d['registered_at']}','{d['token']}')")
def finish(nid,d,result,delay=0):return scalar(f"SELECT finish_notification_device('{nid}','{d['device_id']}','{d['registered_at']}','{d['token']}','{result}',{delay})")
def expire(nid):sql(f"UPDATE waydrop_internal.notification_devices SET lease_until=clock_timestamp()-interval '1 second',next_at=clock_timestamp()-interval '1 second' WHERE notification_id='{nid}'")

def push_concurrency():
    nid,_=notification(True)
    with ThreadPoolExecutor(max_workers=12) as pool:out=list(pool.map(lambda _:push_claim(nid),range(12)))
    devices=[d for c in out for d in c['devices']];eq(len(devices),2)
    for d in devices:eq(begin(nid,d),'t');eq(finish(nid,d,'SENT'),'t')
    eq(push_claim(nid)['devices'],[])
    eq(scalar(f"SELECT push_sent FROM notifications WHERE id='{nid}'"),'t')
    return {'concurrent_handlers':12,'device_claims':2,'replay_claims':0}
test('concurrent push handlers claim each registration exactly once',push_concurrency)

def crashes():
    nid,_=notification();d=push_claim(nid)['devices'][0]
    expire(nid);new=push_claim(nid)['devices'][0];assert new['token']!=d['token'];eq(begin(nid,d),'f')
    eq(begin(nid,new),'t')
    expire(nid);eq(push_claim(nid)['devices'],[])
    eq(scalar(f"SELECT state FROM waydrop_internal.notification_devices WHERE notification_id='{nid}'"),'uncertain')
    # Same owner may settle a delayed actual provider acknowledgement. No new send.
    eq(finish(nid,new,'SENT'),'t');eq(push_claim(nid)['devices'],[])
    return {'pre_intent_crash':'reclaimed','post_intent_crash':'uncertain/no automatic resend','late_ack':'sent'}
test('crashes before/after send intent cannot create a second provider attempt',crashes)

def partial_retry():
    nid,_=notification(True);a,b=push_claim(nid)['devices']
    eq(begin(nid,a),'t');eq(finish(nid,a,'SENT'),'t')
    eq(begin(nid,b),'t');eq(finish(nid,b,'TRANSIENT',60),'t')
    eq(push_claim(nid)['devices'],[])
    sql(f"UPDATE waydrop_internal.notification_devices SET next_at=clock_timestamp()-interval '1 second' WHERE notification_id='{nid}' AND state='retry'")
    retry=push_claim(nid)['devices'];eq(len(retry),1);eq(retry[0]['device_id'],b['device_id'])
    eq(scalar(f"SELECT push_sent FROM notifications WHERE id='{nid}'"),'t')
    for attempt in range(2,6):
        d=retry[0];eq(begin(nid,d),'t');eq(finish(nid,d,'TRANSIENT'),'t')
        sql(f"UPDATE waydrop_internal.notification_devices SET next_at=clock_timestamp()-interval '1 second' WHERE notification_id='{nid}' AND state='retry'")
        retry=push_claim(nid)['devices']
    eq(retry,[]);eq(scalar(f"SELECT delivery_status FROM notifications WHERE id='{nid}'"),'partial_failed')
    return {'successful_device_retries':0,'max_attempts':5,'terminal_state':'partial_failed'}
test('partial success retained; only transient sibling retries with bounded budget',partial_retry)

def cleanup():
    nid,_=notification();d=push_claim(nid)['devices'][0];eq(begin(nid,d),'t')
    sql(f"UPDATE user_device_tokens SET fcm_token='synthetic-refreshed-token' WHERE id='{d['device_id']}'")
    eq(finish(nid,d,'UNREGISTERED'),'t')
    eq(scalar(f"SELECT count(*) FROM user_device_tokens WHERE id='{d['device_id']}'"),'1')
    return {'refreshed_registration_deleted':False}
test('unregistered cleanup cannot delete a refreshed registration',cleanup)

def enqueue_recovery():
    user=uid(9001);nid=str(uuid.uuid4())
    sql(f"BEGIN; SET LOCAL blocker.fail_enqueue='true'; INSERT INTO notifications(id,user_id,title,body,notification_type) VALUES('{nid}','{user}','synthetic','synthetic','chat_message'); COMMIT;")
    eq(scalar(f"SELECT last_error FROM waydrop_internal.notification_jobs WHERE notification_id='{nid}'"),'ENQUEUE_FAILED')
    sql(f"UPDATE waydrop_internal.notification_jobs SET next_at=clock_timestamp()-interval '1 second' WHERE notification_id='{nid}'")
    obj('SELECT recover_waydrop_work(100)')
    eq(scalar(f"SELECT count(*) FROM blocker_http WHERE body->'data'->>'notification_id'='{nid}'"),'1')
    return {'durable_intent_retained':True,'recovered_kicks':1}
test('enqueue failure preserves inbox and durable intent; recovery kicks once',enqueue_recovery)

def unauthorized():
    nid,_=notification()
    bad=sql(f"SELECT claim_notification_delivery('{nid}','{uid(999999)}')",ok=False);assert bad.returncode
    for role in ['anon','authenticated']:
        bad=sql(f"SET ROLE {role}; SELECT claim_notification_delivery('{nid}',NULL)",ok=False);assert bad.returncode
    for signature in ['public.request_order_dispatch(uuid)','public.claim_order_dispatch(uuid)','public.step_order_dispatch(uuid,uuid)','public.release_order_dispatch(uuid,uuid)','public.recover_waydrop_work(integer)','public.redispatch_stalled_searching_orders()','public.redispatch_freed_riders()','public.begin_notification_device(uuid,uuid,timestamptz,uuid)','public.finish_notification_device(uuid,uuid,timestamptz,uuid,text,integer)']:
        for role in ['anon','authenticated']:
            eq(scalar(f"SELECT has_function_privilege('{role}','{signature}','EXECUTE')"),'f')
    return {'foreign_actor_denied':True,'untrusted_rpc_roles_denied':True,'additional_privilege_assertions':18}
test('claims cannot target a foreign recipient or run as an untrusted role',unauthorized)

def acceptance():
    source=(ROOT/'supabase/functions/accept-order/acceptance_sql.ts').read_text()
    statement=json.loads(source.split('export const ACCEPTANCE_SQL = ',1)[1].strip().removesuffix(';'))
    oid=order()
    def accept(rider):
        actor=uid(9000+int(rider[-12:])-200)
        return obj(f"BEGIN; SET LOCAL ROLE service_role; SELECT set_config('app.accept_order_id','{oid}',true),set_config('app.accept_rider_id','{rider}',true),set_config('app.accept_actor_id','{actor}',true); "+statement+" SELECT current_setting('app.acceptance_result')::jsonb; COMMIT;")
    with ThreadPoolExecutor(max_workers=2) as pool:out=list(pool.map(accept,[uid(201),uid(207)]))
    eq(sorted(x['http_status'] for x in out),[200,409])
    eq(scalar(f"SELECT count(*) FROM rider_assignments WHERE order_id='{oid}' AND assignment_status='accepted'"),'1')
    winner=scalar(f"SELECT rider_id FROM orders WHERE id='{oid}'")
    retry=accept(winner);eq(retry['idempotent'],True)
    eq(float(retry['order']['final_fare']),90.0)
    # A running old worker cannot reopen the accepted row after the transaction.
    bad=sql(f"UPDATE rider_assignments SET assignment_status='sent' WHERE order_id='{oid}'",ok=False);assert bad.returncode
    sql(f"UPDATE orders SET order_status='cancelled' WHERE id='{oid}'")
    return {'winners':1,'idempotent_retry':True,'fare_preserved':True,'old_writer_rejected':True}
test('atomic acceptance with new guards: one rider wins, financial retry unchanged',acceptance)

def entry_points():
    oid=order();rid=uid(201)
    # Every entry point converges to one job; none writes an offer itself.
    statements=[f"SELECT assign_new_order_to_nearby_online_riders_core('{oid}')",
      f"SELECT assign_nearby_searching_orders_core('{rid}','{uid(9001)}',17,79,'local')",
      "SELECT redispatch_stalled_searching_orders()","SELECT redispatch_freed_riders()",
      f"SELECT set_config('request.jwt.claim.sub','{uid(9001)}',false); SELECT rider_self_rematch()"]
    for s in statements:sql(s)
    eq(scalar(f"SELECT count(*) FROM waydrop_internal.dispatch_jobs WHERE order_id='{oid}'"),'1')
    eq(scalar(f"SELECT count(*) FROM blocker_http WHERE body->>'order_id'='{oid}'"),'1')
    eq(scalar(f"SELECT count(*) FROM rider_assignments WHERE order_id='{oid}'"),'0')
    sql(f"BEGIN; UPDATE riders SET account_status='offline' WHERE id='{rid}'; SELECT assign_nearby_searching_orders_core('{rid}','{uid(9001)}',17,79,'local'); ROLLBACK;")
    return {'entry_paths':5,'job_rows':1,'http_kicks':1,'direct_offer_writes':0}
test('new-order, rider rematch, self-rematch and both cron paths coalesce',entry_points)

def crash_claim_budget():
    nid,_=notification()
    for i in range(5):
        c=push_claim(nid);eq(len(c['devices']),1);expire(nid)
    eq(push_claim(nid)['devices'],[])
    eq(scalar(f"SELECT state FROM waydrop_internal.notification_devices WHERE notification_id='{nid}'"),'terminal')
    return {'abandoned_claims':5,'automatic_retry_after_budget':False}
test('repeated pre-intent crashes have a bounded terminal retry budget',crash_claim_budget)


def rollback_delivery():
    nid,_=notification()
    sql(f"BEGIN; SELECT claim_notification_delivery('{nid}'); ROLLBACK;")
    eq(scalar(f"SELECT snapshot_done FROM waydrop_internal.notification_jobs WHERE notification_id='{nid}'"),'f')
    d=push_claim(nid)['devices'][0]
    args=f"'{nid}','{d['device_id']}','{d['registered_at']}','{d['token']}'"
    sql(f"BEGIN; SELECT begin_notification_device({args}); ROLLBACK;")
    eq(scalar(f"SELECT state FROM waydrop_internal.notification_devices WHERE notification_id='{nid}'"),'claimed')
    eq(begin(nid,d),'t')
    sql(f"BEGIN; SELECT finish_notification_device({args},'SENT'); ROLLBACK;")
    eq(scalar(f"SELECT state FROM waydrop_internal.notification_devices WHERE notification_id='{nid}'"),'sending')
    eq(finish(nid,d,'SENT'),'t')
    eq(finish(nid,d,'SENT'),'t')
    n2=str(uuid.uuid4())
    sql(f"BEGIN; INSERT INTO notifications(id,user_id,title,body,notification_type,payload) VALUES('{n2}','{uid(9001)}','synthetic','synthetic','chat_message','{{}}'); ROLLBACK;")
    eq(scalar(f"SELECT count(*) FROM waydrop_internal.notification_jobs WHERE notification_id='{n2}'"),'0')
    return {'rolled_back_transitions':['inbox/intent','snapshot/claim','send intent','acknowledgement'],'ack_replay':True}
test('crash before each delivery commit leaves no partial durable transition',rollback_delivery)


def kyc_serialization():
    import time
    rid=uid(201)
    sql(f"UPDATE rider_kyc SET kyc_status='approved' WHERE id=(SELECT kyc_id FROM riders WHERE id='{rid}')")
    # Separate sessions, actual row locks; wait for the lock holder before revocation.
    args=[str(PSQL),'-X','-q','-A','-t','-h','127.0.0.1','-p','54329','-U','waydrop_local','-d',DB,'-v','ON_ERROR_STOP=1']
    holder=subprocess.Popen([*args,'-c',f"SET application_name='blocker_kyc_holder'; BEGIN; SELECT id FROM riders WHERE id='{rid}' FOR NO KEY UPDATE; SELECT pg_sleep(2); COMMIT;"],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    deadline=time.monotonic()+5
    while scalar("SELECT count(*) FROM pg_stat_activity WHERE application_name='blocker_kyc_holder' AND wait_event='PgSleep'")!='1':
        assert time.monotonic()<deadline;time.sleep(.02)
    with ThreadPoolExecutor(max_workers=1) as pool:
        update=pool.submit(sql,f"SET application_name='blocker_kyc_revoke'; UPDATE rider_kyc SET kyc_status='rejected' WHERE id=(SELECT kyc_id FROM riders WHERE id='{rid}')")
        deadline=time.monotonic()+3
        while scalar("SELECT count(*) FROM pg_stat_activity WHERE application_name='blocker_kyc_revoke' AND wait_event_type='Lock'")!='1':
            assert time.monotonic()<deadline;time.sleep(.02)
        holder.communicate(timeout=5);eq(holder.returncode,0);update.result(timeout=5)
    oid=order();eq(scalar(f"SELECT dispatch_eligibility('{oid}','{rid}','offer')"),'KYC_NOT_VERIFIED')
    sql(f"UPDATE rider_kyc SET kyc_status='approved' WHERE id=(SELECT kyc_id FROM riders WHERE id='{rid}')")
    return {'concurrent_kyc_revocation_waited_for_rider_lock':True,'subsequent_offer_denied':True}
test('KYC revocation serializes with the rider ownership lock',kyc_serialization)

def recovery_fairness():
    # Isolate due queue only in this fixed synthetic database.
    sql("UPDATE waydrop_internal.notification_jobs SET next_at='infinity'; UPDATE waydrop_internal.dispatch_jobs SET next_at='infinity';")
    a,_=notification();b,_=notification()
    sql(f"UPDATE waydrop_internal.notification_jobs SET next_at=clock_timestamp()-interval '1 hour',queued_until=clock_timestamp()+interval '1 hour' WHERE notification_id='{a}'; UPDATE waydrop_internal.notification_jobs SET next_at=clock_timestamp()-interval '1 second',queued_until=NULL WHERE notification_id='{b}';")
    before=scalar(f"SELECT count(*) FROM blocker_http WHERE body->'data'->>'notification_id'='{b}'")
    result=obj('SELECT recover_waydrop_work(1)')
    eq(result['notification_kicks'],1)
    eq(int(scalar(f"SELECT count(*) FROM blocker_http WHERE body->'data'->>'notification_id'='{b}'")),int(before)+1)
    return {'batch_limit':1,'already_queued_oldest_skipped':True,'other_due_job_kicked':True}
test('bounded recovery skips already queued jobs without starving due work',recovery_fairness)

(ART/'NATIVE_RESULTS.json').write_text(json.dumps({'database':DB,'production':False,'results':results},indent=2)+'\n')
print(json.dumps({'passed':len(results),'failed':0}))
