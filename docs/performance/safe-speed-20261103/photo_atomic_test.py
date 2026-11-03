"""Fixed loopback synthetic DB only; actual PostgreSQL transactions/concurrency."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import subprocess,json,time
ROOT=Path(__file__).resolve().parents[3]
ART=Path(__file__).parent
DB='waydrop_photo_atomic_test'
ARGS=[str(ROOT/'.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe'),'-X','-q','-A','-t','-h','127.0.0.1','-p','54329','-U','waydrop_local','-v','ON_ERROR_STOP=1']
def sql(q,ok=True,db=DB):
 p=subprocess.run([*ARGS,'-d',db],input=q,text=True,capture_output=True,encoding='utf-8',timeout=20)
 assert (p.returncode==0)==ok,p.stderr
 return p.stdout.strip()
assert sql("SELECT inet_server_addr()=inet '127.0.0.1' AND inet_server_port()=54329;",db='postgres')=='t'
if sql("SELECT count(*) FROM pg_database WHERE datname='waydrop_photo_atomic_test';",db='postgres')=='0': sql('CREATE DATABASE waydrop_photo_atomic_test;',db='postgres')
else: assert sql('SELECT label FROM public.fixture_marker;')=='waydrop_photo_atomic_synthetic_v1'
sql("""
DROP SCHEMA public CASCADE; CREATE SCHEMA public;
CREATE TABLE public.fixture_marker(label text);INSERT INTO public.fixture_marker VALUES('waydrop_photo_atomic_synthetic_v1');
CREATE TABLE public.riders(id uuid PRIMARY KEY,user_id uuid NOT NULL);
CREATE TABLE public.orders(id uuid PRIMARY KEY,rider_id uuid REFERENCES public.riders(id),user_id uuid NOT NULL,pickup_verification_completed bool DEFAULT false,pickup_verification_completed_at timestamptz);
CREATE TABLE public.order_parcel_photos(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_id uuid NOT NULL REFERENCES public.orders(id),rider_id uuid NOT NULL REFERENCES public.riders(id),photo_url text NOT NULL,photo_type text NOT NULL,latitude numeric,longitude numeric,file_sha256 text,captured_at timestamptz DEFAULT now());
CREATE TABLE public.order_verifications(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_id uuid NOT NULL REFERENCES public.orders(id),verification_type text NOT NULL,verification_status text NOT NULL,photo_url text,latitude numeric,longitude numeric,metadata jsonb,created_by uuid,created_at timestamptz DEFAULT now());
CREATE TABLE public.parcel_security_logs(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_id uuid NOT NULL REFERENCES public.orders(id),sender_user_id uuid NOT NULL,rider_id uuid,event_type text NOT NULL,latitude double precision,longitude double precision,event_latitude numeric,event_longitude numeric,ip_address inet,device_id text,metadata jsonb,created_at timestamptz DEFAULT now());
CREATE TABLE public.fault(stage text);INSERT INTO public.fault VALUES('');
CREATE FUNCTION public.inject_fault() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN IF (SELECT stage FROM public.fault)=TG_TABLE_NAME THEN RAISE EXCEPTION 'synthetic transition failure';END IF;RETURN NEW;END;$$;
CREATE TRIGGER fault BEFORE INSERT ON public.order_parcel_photos FOR EACH ROW EXECUTE FUNCTION public.inject_fault();
CREATE TRIGGER fault BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.inject_fault();
CREATE TRIGGER fault BEFORE INSERT ON public.order_verifications FOR EACH ROW EXECUTE FUNCTION public.inject_fault();
CREATE TRIGGER fault BEFORE INSERT ON public.parcel_security_logs FOR EACH ROW EXECUTE FUNCTION public.inject_fault();
""")
sql((ART/'PHOTO_ATOMIC_RPC.review.sql').read_text(encoding='utf-8'))
def uid(n): return f'00000000-0000-4000-8000-{n:012d}'
order,rider,actor,other=map(uid,[1,2,3,4])
def reset():
 sql(f"UPDATE public.fault SET stage='';TRUNCATE public.order_verifications,public.order_parcel_photos,public.parcel_security_logs,public.orders,public.riders;INSERT INTO public.riders VALUES('{rider}','{actor}'),('{other}','{other}');INSERT INTO public.orders(id,rider_id,user_id)VALUES('{order}','{rider}','{actor}');")
def call(who=actor,kind='pickup'):
 return f"SELECT public.record_order_photo_proof_v1('{order}','{who}','{rider}','{kind}','https://synthetic.invalid/photo','{'a'*64}',0,0,'synthetic-device',NULL)::text;"
def state(): return json.loads(sql("SELECT json_build_object('photos',(SELECT count(*) FROM public.order_parcel_photos),'verified',(SELECT count(*) FROM public.order_verifications),'logs',(SELECT count(*) FROM public.parcel_security_logs),'flag',(SELECT pickup_verification_completed FROM public.orders),'zero',(SELECT bool_and(latitude=0 AND longitude=0) FROM public.order_parcel_photos));"))
results=[]
reset();a=json.loads(sql(call()));b=json.loads(sql(call()));assert a['photo_log_id']==b['photo_log_id'] and not a['replayed'] and b['replayed'];assert state()==dict(photos=1,verified=1,logs=1,flag=True,zero=True)
results.append('atomic success, exact replay and zero coordinates')
reset()
with ThreadPoolExecutor(max_workers=8) as pool: replies=list(pool.map(lambda _:json.loads(sql(call())),range(8)))
assert sum(not r['replayed'] for r in replies)==1 and state()['photos']==state()['logs']==state()['verified']==1
results.append('eight simultaneous callers produce one set of effects')
reset();sql(call(other),ok=False);assert state()['photos']==0
results.append('foreign actor denied with zero effects')
for stage in ['order_parcel_photos','orders','order_verifications','parcel_security_logs']:
 reset();sql(f"UPDATE public.fault SET stage='{stage}';");sql(call(),ok=False);s=state();assert s['photos']==s['verified']==s['logs']==0 and not s['flag'];sql("UPDATE public.fault SET stage='';")
results.append('failure at each of four durable transitions rolls back everything')
reset();sql(f"INSERT INTO public.order_parcel_photos(order_id,rider_id,photo_url,photo_type,file_sha256)VALUES('{order}','{rider}','https://synthetic.invalid/photo','pickup','{'a'*64}');");sql(call(),ok=False);assert state()['photos']==1 and state()['verified']==state()['logs']==0
results.append('legacy partial result fails closed without automatic repair')
def wait_state(app,wait):
 for _ in range(100):
  rows=sql(f"SELECT count(*) FROM pg_stat_activity WHERE application_name='{app}' AND wait_event='{wait}';")
  if rows=='1': return
  time.sleep(.02)
 raise AssertionError('Expected controlled database wait not observed')
reset()
holder=subprocess.Popen([*ARGS,'-d',DB,'-c',f"SET application_name='proof_holder';BEGIN;UPDATE public.orders SET rider_id='{other}' WHERE id='{order}';SELECT pg_sleep(2);COMMIT;"],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
wait_state('proof_holder','PgSleep')
caller=subprocess.Popen([*ARGS,'-d',DB,'-c',"SET application_name='proof_caller';"+call()],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
for _ in range(100):
 if sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='proof_caller' AND wait_event_type='Lock';")=='1':break
 time.sleep(.01)
else: raise AssertionError('Proof did not wait behind assignment writer')
holder.communicate(timeout=10);_,err=caller.communicate(timeout=10);assert holder.returncode==0 and caller.returncode!=0 and 'PROOF_FORBIDDEN' in err;assert state()['photos']==0
results.append('assignment replacement locks out waiting old-rider proof')
reset()
crasher=subprocess.Popen([*ARGS,'-d',DB,'-c',"SET application_name='proof_crash';BEGIN;"+call()+"SELECT pg_sleep(30);COMMIT;"],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
wait_state('proof_crash','PgSleep');assert sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='proof_crash' AND pid<>pg_backend_pid();")=='t';crasher.communicate(timeout=10);assert crasher.returncode!=0
s=state();assert s['photos']==s['verified']==s['logs']==0 and not s['flag'];sql(call());assert state()['photos']==1
results.append('crash after effects before commit rolls back; retry recovers once')
assert sql("SELECT NOT has_function_privilege('anon','public.record_order_photo_proof_v1(uuid,uuid,uuid,text,text,text,numeric,numeric,text,inet)','EXECUTE') AND NOT has_function_privilege('authenticated','public.record_order_photo_proof_v1(uuid,uuid,uuid,text,text,text,numeric,numeric,text,inet)','EXECUTE') AND has_function_privilege('service_role','public.record_order_photo_proof_v1(uuid,uuid,uuid,text,text,text,numeric,numeric,text,inet)','EXECUTE');")=='t'
results.append('service-only ACL')
reset();sql(call(kind='dropoff'));assert not state()['flag'] and state()['photos']==state()['verified']==state()['logs']==1
results.append('dropoff proof does not set pickup completion flag')
out={'passed_groups':len(results),'failed':0,'groups':results,'fixture':DB,'managed_auth_and_triggers':False,'production':False}
(ART/'PHOTO_ATOMIC_RESULTS.json').write_text(json.dumps(out,indent=2)+'\n',encoding='utf-8');print(json.dumps(out))
