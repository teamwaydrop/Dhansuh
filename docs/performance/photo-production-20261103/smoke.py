"""Unauthenticated negative probes only; never fetches/inserts a photo."""
from pathlib import Path
import json,sys,urllib.request,urllib.error
ROOT=Path(__file__).resolve().parents[3];OUT=Path(__file__).parent
phase=sys.argv[1];assert phase in ['before','after']
env={}
for line in (ROOT/'.env').read_text(encoding='utf-8-sig').splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        k,v=line.split('=',1);env[k.strip()]=v.strip().strip('"\'')
base=env['SUPABASE_URL'].rstrip('/');assert base=='https://yvwpchffctiagevpqgwy.supabase.co'
body={'order_id':'00000000-0000-4000-8000-000000000991','rider_id':'00000000-0000-4000-8000-000000000992','photo_type':'pickup','photo_url':base+'/storage/v1/object/public/parcel_images/unused-release-probe.jpg'}
rows=[]
for method,invalid_auth,expected in [('OPTIONS',False,200),('POST',False,401),('POST',True,401)]:
    headers={'Content-Type':'application/json','apikey':env['SUPABASE_ANON_KEY']}
    if invalid_auth:headers['Authorization']='Bearer synthetic-invalid-token'
    req=urllib.request.Request(base+'/functions/v1/process-verification-photo',data=None if method=='OPTIONS' else json.dumps(body).encode(),headers=headers,method=method)
    try:r=urllib.request.urlopen(req,timeout=15)
    except urllib.error.HTTPError as e:r=e
    with r:status=r.status;r.read()
    assert status==expected,f'Unexpected photo {method} status {status}'
    rows.append({'method':method,'invalid_auth':invalid_auth,'status':status,'expected_status':expected})
(OUT/('SMOKE_'+phase.upper()+'.json')).write_text(json.dumps({'cases':rows,'business_writes':0,'no_customer_data':True,'real_authenticated_photo_flow_tested':False},indent=2)+'\n',encoding='utf-8')
if phase=='after':assert rows==json.loads((OUT/'SMOKE_BEFORE.json').read_text(encoding='utf-8'))['cases']
print(json.dumps({'phase':phase,'passed':3,'business_writes':0}))
