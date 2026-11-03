"""RLS-only synthetic fixture. Fixed loopback DB; no production data or URL."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[3]
ART = Path(__file__).parent
PSQL = ROOT / '.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe'
DB = 'waydrop_rls_hotpath_test'
ARGS = [str(PSQL), '-X', '-q', '-A', '-t', '-h', '127.0.0.1', '-p', '54329', '-U', 'waydrop_local', '-v', 'ON_ERROR_STOP=1']

def sql(text, database=DB, check=True):
    r = subprocess.run([*ARGS, '-d', database], input=text, capture_output=True, text=True, encoding='utf-8')
    if check and r.returncode:
        raise AssertionError(r.stderr)
    return r

def scalar(text):
    return sql(text).stdout.strip().splitlines()[-1]

def qi(value):
    return '"' + value.replace('"', '""') + '"'

def lit(value):
    return "'" + str(value).replace("'", "''") + "'"

def uid(n):
    return f'71000000-0000-4000-8000-{n:012d}'

def metadata():
    return (json.loads((ART/'LIVE_METADATA.json').read_text())['evidence'],
            json.loads((ART/'LIVE_COLUMN_METADATA.json').read_text())['evidence'])

def create():
    host = sql("SELECT inet_server_addr()=inet '127.0.0.1' AND inet_server_port()=54329", 'postgres').stdout.strip()
    assert host == 't'
    exists = sql(f"SELECT count(*) FROM pg_database WHERE datname={lit(DB)}", 'postgres').stdout.strip()
    if exists != '0':
        raise SystemExit('Fixed local fixture already exists; refusing to overwrite. Use native_test.py only if its fixture marker matches.')
    sql('CREATE DATABASE '+DB, 'postgres')
    m, c = metadata()
    statements = ["DO $$BEGIN IF current_database()<>'waydrop_rls_hotpath_test' OR inet_server_addr()<>inet '127.0.0.1' OR inet_server_port()<>54329 THEN RAISE EXCEPTION 'Wrong fixture'; END IF; END$$;", 'CREATE SCHEMA auth;']
    for enum in c['enums']:
        statements.append('CREATE TYPE public.'+qi(enum['name'])+' AS ENUM ('+','.join(map(lit,enum['labels']))+');')
    tables = sorted({col['table'] for col in c['columns']})
    for table in tables:
        cols = [qi(x['column'])+' '+x['type']+(' NOT NULL' if x['not_null'] else '') for x in c['columns'] if x['table']==table]
        statements.append('CREATE TABLE public.'+qi(table)+' ('+','.join(cols)+');')
    for idx in m['indexes']:
        statements.append(idx['definition']+';')
    for fn in m['functions']:
        statements.append(fn['definition']+';')
    for fn in c['helpers']:
        statements.append(fn['definition']+';')
    statements.append('GRANT USAGE ON SCHEMA auth,public TO anon,authenticated,service_role;')
    for table in m['table_security']:
        t=qi(table['table'])
        statements.append('ALTER TABLE public.'+t+(' ENABLE' if table['rls'] else ' DISABLE')+' ROW LEVEL SECURITY;')
        if table['force_rls']:
            statements.append('ALTER TABLE public.'+t+' FORCE ROW LEVEL SECURITY;')
        # Match data-operation grants. DDL/maintenance privileges are irrelevant
        # to this RLS-only fixture and intentionally are not used as test roles.
        acl=table['acl'] or ''
        for role in ['anon','authenticated','service_role']:
            import re
            match=re.search(r'(?:\{|,)'+role+r'=([^/]*)/',acl)
            rights=match.group(1) if match else ''
            permissions=[v for k,v in [('r','SELECT'),('a','INSERT'),('w','UPDATE'),('d','DELETE')] if k in rights]
            if permissions:
                statements.append('GRANT '+','.join(permissions)+' ON public.'+t+' TO '+role+';')
    for p in m['policies']:
        roles=','.join('PUBLIC' if r=='public' else qi(r) for r in p['roles'])
        text='CREATE POLICY '+qi(p['name'])+' ON public.'+qi(p['table'])+' AS '+p['permissive']+' FOR '+p['command']+' TO '+roles
        if p['qual'] is not None:text+=' USING ('+p['qual']+')'
        if p['check'] is not None:text+=' WITH CHECK ('+p['check']+')'
        statements.append(text+';')
    statements.append("CREATE TABLE public.rls_fixture_marker(value text); INSERT INTO public.rls_fixture_marker VALUES('waydrop_rls_hotpath_synthetic_v1');")
    generated='\n'.join(statements)+'\n'
    (ART/'SYNTHETIC_SCHEMA.sql').write_text(generated,encoding='utf-8')
    sql(generated)
    seed(25)
    print('Created fixed local RLS-only fixture with 40 captured policies and synthetic data.')

def seed(rider_count):
    assert scalar('SELECT value FROM rls_fixture_marker')=='waydrop_rls_hotpath_synthetic_v1'
    _,c=metadata()
    enums={x['name']:x['labels'] for x in c['enums']}
    statements=['TRUNCATE admins,users,rider_kyc,riders,orders,intercity_requests,rider_assignments;']
    def insert(table,n,values):
        data={}
        for col in c['columns']:
            if col['table']!=table or not col['not_null']:continue
            name,typ=col['column'],col['type']
            if typ=='uuid':v=uid(900000+n)
            elif typ in enums:v=enums[typ][0]
            elif typ=='boolean':v=False
            elif typ=='date':v='2000-01-01'
            elif typ=='timestamp with time zone':v='2026-11-02T00:00:00Z'
            elif typ=='jsonb':v='{}'
            elif typ in ['integer','numeric','double precision']:v=0
            else:v='SYNTHETIC-'+name+'-'+str(n)
            data[name]=v
        data.update(values)
        def value(v):
            if v is None:return 'NULL'
            if isinstance(v,bool):return str(v).lower()
            if isinstance(v,(int,float)):return str(v)
            return lit(v)
        statements.append('INSERT INTO '+qi(table)+' ('+','.join(map(qi,data))+') VALUES ('+','.join(value(v) for v in data.values())+');')
    user_count=max(128,rider_count+10)
    for n in range(1,user_count+1):
        role='support' if n==3 else 'admin' if n in [1,2] else 'passenger'
        insert('users',n,{'id':uid(n),'role':role,'full_name':'Synthetic '+str(n),'email':f'user{n}@example.invalid'})
    insert('admins',1,{'id':uid(80001),'email':'user1@example.invalid','is_active':True})
    insert('admins',2,{'id':uid(80002),'email':'user2@example.invalid','is_active':False})
    for n in range(1,rider_count+1):
        owner=n+3
        insert('rider_kyc',n,{'id':uid(10000+n),'user_id':uid(owner),'full_name':'Synthetic Rider '+str(n),'vehicle_type':enums['vehicle_type_enum'][n%len(enums['vehicle_type_enum'])],'kyc_status':'approved','activation_status':'active'})
        insert('riders',n,{'id':uid(20000+n),'user_id':uid(owner),'kyc_id':uid(10000+n),'account_status':'online' if n%2 else 'offline','service_mode':'intercity' if n%3==0 else 'local','current_lat':16.5+n/100000,'current_lng':80.6+n/100000,'current_heading':0})
    for n in range(1,61):
        insert('orders',n,{'id':uid(30000+n),'order_code':'SYNTHETIC-'+str(n),'user_id':uid(4+n%6),'rider_id':uid(20001+n%rider_count),'order_type':'intercity_parcel' if n%3==0 else 'local_parcel','order_status':['searching','accepted','completed'][n%3]})
        if n%3==0:
            insert('intercity_requests',n,{'id':uid(40000+n),'parcel_id':uid(30000+n),'sender_id':uid(4+n%6),'traveller_id':uid(20001+n%rider_count),'status':'discussion_started' if n%2 else 'rejected','sender_confirmed':False,'traveller_confirmed':False})
        insert('rider_assignments',n,{'id':uid(50000+n),'order_id':uid(30000+n),'rider_id':uid(20001+(n+1)%rider_count),'assignment_round':1,'assignment_status':'sent'})
    statements.append('ANALYZE;')
    sql('\n'.join(statements))

if __name__=='__main__':create()
