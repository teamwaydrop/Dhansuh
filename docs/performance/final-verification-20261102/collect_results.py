"""Collect local logs and changes; never connects to Supabase or runs a deployment."""
import hashlib
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[3]
ART=Path(__file__).parent
RUNTIME=ROOT/'.dart_tool/waydrop-local-runtime'
def read(name):
    data=(RUNTIME/name).read_bytes()
    return data.decode('utf-16') if data.startswith(b'\xff\xfe') else data.decode('utf-8',errors='replace')
def failures(text):
    lines=text.splitlines();out=[]
    for i,line in enumerate(lines):
        if '[E]' not in line: continue
        end=next((j for j in range(i+1,len(lines)) if re.match(r'^\d\d:\d\d ',lines[j])),min(i+22,len(lines)))
        match=re.search(r'/test/([^:]+\.dart): (.*) \[E\]',line)
        assert match,line
        out.append({'file':'test/'+match[1],'exact_test_name':match[2],
          'original_error':'\n'.join(lines[i+1:end]).strip(),
          'classification':'deterministic outdated CRLF-sensitive source fixture',
          'resolution':'Normalize CRLF to LF in the source reader; every assertion retained.'})
    return out
baseline=failures(read('part5-sixteen-baseline.log'))
prior=failures(read('part4-flutter-full.log'))
assert len(baseline)==16
assert {x['exact_test_name'] for x in prior}=={x['exact_test_name'] for x in baseline}
for case in baseline:
    p=case['file'];before=(RUNTIME/'part5-baseline'/p).read_text()
    after=(ROOT/p).read_text()
    expected=before.replace('String _read(String path) => File(path).readAsStringSync();',
      "// Source contracts are independent of the checkout's LF/CRLF line endings.\nString _read(String path) => File(path).readAsStringSync().replaceAll('\\r\\n', '\\n');")
    assert after==expected,p
full=read('part5-flutter-full-final.log')
count=re.search(r'\+(\d+): All tests passed!',full)
assert count and '[E]' not in full,'Final full Flutter run has not passed'
analysis=read('part5-analyze-final.log')
diagnostics={kind:len(re.findall(r'^\s*'+kind+r' -',analysis,re.M)) for kind in ['error','warning','info']}
assert 'issues found.' in analysis and diagnostics['error']==0
suite_logs={'push':'part5-push.log','reject':'part5-reject-final.log','edge_auth_flags':'part5-edge-unit.log',
    'acceptance_native':'part5-acceptance-native.log','acceptance_handler':'part5-acceptance-handler-final.log'}
suites={}
for name,file in suite_logs.items():
    text=read(file);match=re.search(r'ok \| (\d+) passed \| (\d+) failed',text)
    assert match and match[2]=='0',(name,text[-1200:])
    suites[name]={'passed':int(match[1]),'failed':0,'log':'.dart_tool/waydrop-local-runtime/'+file}
for folder,key in [('docs/production-performance/local-tests','postgres_matching_gps'),('docs/performance/dispatch-cron-20261102','postgres_dispatch')]:
    data=json.loads((ROOT/folder/'PG17_RESULTS.json').read_text())
    assert all(x['status']=='PASS' for x in data['results'])
    (ART/(key+'_RESULTS.json')).write_text(json.dumps(data,indent=2)+'\n')
    suites[key]={'passed':len(data['results']),'failed':0}
snap=json.loads((RUNTIME/'part5-baseline/SOURCE_HASHES.json').read_text())
changed=[p for p,h in snap.items() if hashlib.sha256((ROOT/p).read_bytes()).hexdigest()!=h]
review=[*changed,'test/part5_safe_metrics_test.dart',
 'docs/performance/dispatch-cron-20261102/reject-handler-test.ts',
 'docs/performance/final-verification-20261102/INTERNAL_DISPATCH_ACL.candidate.sql',
 'docs/performance/chat-notifications-20261102/CHAT_SENDER_POLICY.candidate.sql']
out={'production':{'project':'yvwpchffctiagevpqgwy','writes':0,'deployments':0,'log_queries':0,'sql_inspections':5,'project_metadata_reads':1,'paid_resources':0},
 'sixteen_original_failures':baseline,'same_failure_names_as_part4':True,'assertions_unchanged':True,
 'pre_part4_baseline_limit':'Older retained 2065-pass log is not an exact source-matched pre-Part-4 baseline; Part 4 and current unmodified-reader failures match all sixteen names.',
 'targeted_fixture_run':{'before_passed':105,'before_failed':16,'after_passed':121,'after_failed':0},
 'full_flutter':{'passed':int(count[1]),'failed':0,'log':'.dart_tool/waydrop-local-runtime/part5-flutter-full-final.log'},
 'analyzer':{**diagnostics,'log':'.dart_tool/waydrop-local-runtime/part5-analyze-final.log','exit':2},
 'suites':suites,'worker_audit':{'passed':5,'failed':0},'chat_rls':json.loads((ROOT/'docs/performance/chat-notifications-20261102/DATABASE_RESULTS.json').read_text()),
 'adversarial_safety':json.loads((ART/'SAFETY_RESULTS.json').read_text()),
 'reject_baseline':{'passed':1,'expected_failures':4,'log':'.dart_tool/waydrop-local-runtime/part5-reject-race-baseline.log'},
 'phase5_changed_existing_sources':changed,'source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in review},
 'android_device_available':False,'initiating_root_cause':'UNPROVEN','stale_worker_recovery':'BLOCKED_FOR_DEPLOYMENT',
 'decision':{'flutter':'CONDITIONAL_GO_FOR_REVIEWED_SUBSET','sql':'NO_GO_AS_COMBINED_BUNDLE','edge':'NO_GO_AS_COMBINED_BUNDLE'}}
(ART/'VERIFICATION.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps({'full_flutter':out['full_flutter'],'analyzer':diagnostics,'changed_existing_sources':changed}))
