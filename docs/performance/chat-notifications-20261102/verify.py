"""Offline/local Part 4 verification. Does not use a Supabase credential or endpoint."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[3]
ART=Path(__file__).parent
RUNTIME=ROOT/'.dart_tool/waydrop-local-runtime'
env=dict(os.environ,DENO_DIR=str(RUNTIME/'deno-cache'))
env.pop('PART4_BASELINE',None)
deno=str(RUNTIME/'deno-2.9.8-core/deno.exe')
dart=Path(shutil.which('dart')).parent/'cache/dart-sdk/bin/dart.exe'
flutter=Path(shutil.which('flutter'))
commands=[]
def run(name,args,expected=0,extra=None):
    target=RUNTIME/('part4-'+name+'.log')
    with target.open('w',encoding='utf-8') as out:
        result=subprocess.run(args,cwd=ROOT,env={**env,**(extra or {})},stdout=out,stderr=subprocess.STDOUT)
    commands.append({'name':name,'command':args,'return_code':result.returncode,'expected_return_code':expected,
        'log':str(target.relative_to(ROOT)).replace('\\','/'),'expected_exit':result.returncode==expected})
    print(json.dumps(commands[-1]))

push=[deno,'test','--cached-only','--config','docs/production-performance/edge-only/deno-handler.json','--allow-env','--allow-read']
baseline=RUNTIME/'part4-push-baseline'
(baseline/'send-push-notification').mkdir(parents=True,exist_ok=True)
shutil.copyfile(ART/'production-push-v24.ts',baseline/'send-push-notification/index.ts')
shutil.copytree(ROOT/'supabase/functions/_shared',baseline/'_shared',dirs_exist_ok=True)
run('push',push+['docs/performance/chat-notifications-20261102/push_test.ts'])
run('push-baseline',push+['--filter','/token cleanup:|sibling:|scope:|sequential recorded|foreign notification|empty tokens|network-only/','docs/performance/chat-notifications-20261102/push_test.ts'],1,{'PART4_BASELINE':'1'})
focused=['part4_chat_lifecycle_test','part4_chat_notifications_test','loading_spike_regression_test','chat_regression_test','waydrop_gps_and_badge_test','part2_realtime_gps_test','notification_failure_tracking_regression_test','send_push_notification_token_cache_regression_test','notification_sound_channel_consistency_regression_test','notification_icon_regression_test','notification_and_gps_traffic_regression_test','realtime_manager_release_safe_collision_guard_regression_test']
run('flutter-focused-final',['cmd.exe','/d','/c',str(flutter),'test','--no-pub',*['test/'+name+'.dart' for name in focused],'--reporter','expanded'])
implementation=['lib/modules/chat/screens/order_chat_screen.dart','lib/modules/chat/services/chat_message_delivery.dart','lib/modules/chat/services/chat_message_merge.dart','lib/core/services/realtime/realtime_manager.dart','lib/modules/notifications/services/notification_badge_service.dart','lib/modules/notifications/services/notification_service.dart','supabase/functions/send-push-notification/index.ts','supabase/functions/send-push-notification/fcm_result.ts']
run('analyze-final',[str(dart),'analyze',*implementation[:6],'test/part4_chat_notifications_test.dart'],2)
def read_log(name):
    raw=(RUNTIME/name).read_bytes()
    return raw.decode('utf-16') if raw.startswith(b'\xff\xfe') else raw.decode('utf-8',errors='replace')
full=read_log('part4-flutter-full.log')
failures=[line for line in full.splitlines() if '[E]' in line]
focused_count=re.search(r'\+(\d+): All tests passed!',read_log('part4-flutter-focused-final.log'))
push_counts=re.search(r'ok \| (\d+) passed \| (\d+) failed',read_log('part4-push.log'))
assert focused_count and push_counts
review_files=implementation+['docs/performance/chat-notifications-20261102/CHAT_SENDER_POLICY.candidate.sql',
  'test/part4_chat_notifications_test.dart','test/part4_chat_lifecycle_test.dart','test/chat_regression_test.dart']
artifact={'production_access':{'project':'yvwpchffctiagevpqgwy','mode':'READ_ONLY','new_log_queries':0,'catalog_queries':1,'edge_source_fetches':1,'deployments':0,'migrations':0,'paid_resources':0},
    'commands':commands,'focused_flutter':{'passed':int(focused_count[1]),'failed':0},'push':{'passed':int(push_counts[1]),'failed':int(push_counts[2]),'includes_restore_globals':True},
    'push_captured_v24_baseline':{'passed':0,'failed_expected':7},
    'native':json.loads((ART/'DATABASE_RESULTS.json').read_text()),
    'full_flutter':{'passed':2096,'failed':16,'log':'.dart_tool/waydrop-local-runtime/part4-flutter-full.log',
      'scope':'Broader run before final additional merge assertion and cosmetic cleanup. Failure paths are outside Part 4 edits. No clean pre-Part-4 full-suite baseline was run in this turn.',
      'failures':failures},
    'analysis':{'errors':0,'warnings':3,'infos':11,'initial_attempt':'Analysis server crashed with closed pipe; direct SDK rerun completed.'},
    'source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in review_files},
    'initiating_incident_cause':'UNPROVEN','part5_started':False}
assert len(failures)==16,len(failures)
assert all(x['expected_exit'] for x in commands),commands
(ART/'VERIFICATION.json').write_text(json.dumps(artifact,indent=2)+'\n',encoding='utf-8')
