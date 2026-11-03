"""Bounded read-only live Edge probes; no order/customer/provider writes."""
from pathlib import Path
import sys,json,time,urllib.request,urllib.error,hashlib,datetime
ROOT=Path(__file__).resolve().parents[3]
OUT=Path(__file__).parent
phase=sys.argv[1]
assert phase in ['before','after']
env={}
for line in (ROOT/'.env').read_text(encoding='utf-8-sig').splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        k,v=line.split('=',1);env[k.strip()]=v.strip().strip('"\'')
url=env['SUPABASE_URL'].rstrip('/')
assert url=='https://yvwpchffctiagevpqgwy.supabase.co'
headers={'Content-Type':'application/json','apikey':env['SUPABASE_ANON_KEY']}
quote=json.loads((OUT/'PUBLIC_QUOTE_PROBE.json').read_text(encoding='utf-8'))
cases=[('calculate-order-pricing','POST',{},400),('get-live-order-status','POST',{},401),
       ('calculate-order-pricing','OPTIONS',None,200),('get-live-order-status','OPTIONS',None,200),
       ('calculate-order-pricing','POST',quote,200)]
rows=[]
for index,(slug,method,body,expected) in enumerate(cases):
    data=None if body is None else json.dumps(body).encode()
    req=urllib.request.Request(url+'/functions/v1/'+slug,data=data,headers=headers,method=method)
    start=time.monotonic()
    try:r=urllib.request.urlopen(req,timeout=30)
    except urllib.error.HTTPError as e:r=e
    with r:
        raw=r.read();status=r.status
        row={'case':index,'slug':slug,'method':method,'expected_status':expected,'status':status,
             'ms':round((time.monotonic()-start)*1000,1),'cors_origin':r.headers.get('access-control-allow-origin')}
    if index==4 and status==200:
        result=json.loads(raw)
        canonical=json.dumps(result,sort_keys=True,separators=(',',':'))
        row['public_quote_sha256']=hashlib.sha256(canonical.encode()).hexdigest()
        row['public_quote_response']=result
    rows.append(row)
    (OUT/('SMOKE_'+phase.upper()+'.json')).write_text(json.dumps({'at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'phase':phase,'no_customer_data':True,'business_writes':0,'results':rows},indent=2)+'\n',encoding='utf-8')
    assert status==expected, f'{slug} {method} unexpected status {status}'
if phase=='after':
    before=json.loads((OUT/'SMOKE_BEFORE.json').read_text(encoding='utf-8'))
    assert before['results'][4]['public_quote_sha256']==rows[4]['public_quote_sha256'],'Public quote changed; investigate before continuing'
print(json.dumps({'phase':phase,'passed':len(rows),'failed':0,'quote_ms':rows[4]['ms'],'auth_denial':rows[1]['status'],'quote_unchanged':phase=='after'}))
