"""Real gateway anon JWT + limit-zero selects: no production row data."""
from pathlib import Path
import json,sys,urllib.request,urllib.error
ROOT=Path(__file__).resolve().parents[3];OUT=Path(__file__).parent
phase=sys.argv[1];assert phase in ['before','after']
env={}
for line in (ROOT/'.env').read_text(encoding='utf-8-sig').splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        k,v=line.split('=',1);env[k.strip()]=v.strip().strip('"\'')
assert env['SUPABASE_URL'].rstrip('/')=='https://yvwpchffctiagevpqgwy.supabase.co'
key=env['SUPABASE_ANON_KEY'];headers={'apikey':key,'Authorization':'Bearer '+key}
rows=[]
for table in ['users','riders','rider_kyc','orders']:
    req=urllib.request.Request(env['SUPABASE_URL'].rstrip('/')+'/rest/v1/'+table+'?select=id&limit=0',headers=headers)
    try:r=urllib.request.urlopen(req,timeout=15)
    except urllib.error.HTTPError as e:r=e
    with r:status=r.status;body=json.loads(r.read())
    print(json.dumps({'table':table,'status':status,'code':body.get('code') if isinstance(body,dict) else None}))
    assert (status==200 and body==[]) or (status in [401,403] and isinstance(body,dict) and body.get('code')=='42501'), 'Unexpected anonymous grant result'
    rows.append({'table':table,'status':status,'code':body.get('code') if isinstance(body,dict) else None,'row_data_returned':False})
(OUT/('ANON_'+phase.upper()+'.json')).write_text(json.dumps(rows,indent=2)+'\n',encoding='utf-8')
if phase=='after':assert rows==json.loads((OUT/'ANON_BEFORE.json').read_text(encoding='utf-8'))
print(json.dumps({'phase':phase,'passed':len(rows),'live_anon_gateway_only':True,'authenticated_actor_test':False}))
