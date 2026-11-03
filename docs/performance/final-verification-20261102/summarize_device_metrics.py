"""Read ONLY opt-in WAYDROP_PERF JSON lines; no app connection or credentials."""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('capture',type=Path)
parser.add_argument('--frame-budget-ms',type=float,default=1000/60)
args=parser.parse_args()
api=defaultdict(list);screens=defaultdict(list);frames=[];invalid=0
for line in args.capture.read_text(encoding='utf-8-sig').splitlines():
    if not line.startswith('WAYDROP_PERF '): continue
    try: batch=json.loads(line[len('WAYDROP_PERF '):])
    except json.JSONDecodeError: invalid+=1;continue
    for sample in batch.get('samples',[]):
        value=sample.get('ms')
        if not isinstance(value,(int,float)) or not math.isfinite(value): continue
        if sample.get('kind')=='api_complete': api[sample.get('operation','other')].append(value)
        if sample.get('kind')=='screen_work': screens[sample.get('screen','other')].append(value)
    frames+=batch.get('frames',[])
def summary(values):
    values=sorted(values)
    return {'n':len(values),'p50_ms':values[math.ceil(len(values)*.50)-1],
        'p95_ms':values[math.ceil(len(values)*.95)-1],'max_ms':values[-1]}
over=sum(max(f.get('build_us',0),f.get('raster_us',0))>args.frame_budget_ms*1000 for f in frames)
print(json.dumps({'quantile':'nearest rank','api_body_completion':{k:summary(v) for k,v in api.items()},
    'screen_work_not_first_usable':{k:summary(v) for k,v in screens.items()},
    'sampled_frames':len(frames),'sampled_frames_over_budget':over,
    'frame_budget_ms':args.frame_budget_ms,'invalid_batches':invalid,
    'limits':'Bounded buffers can lose samples during stalls. Use DevTools timeline/video for complete frame and first-usable measurements; do not compare debug timings to profile.'},indent=2))
