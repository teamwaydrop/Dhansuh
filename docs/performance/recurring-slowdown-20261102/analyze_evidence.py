"""Offline evidence checks. Never connects to Supabase or infers unknown event starts."""
from pathlib import Path
from datetime import datetime, timedelta, timezone
import hashlib
import json

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]

def read(path):
    return json.loads(path.read_text(encoding='utf-8'))

def observed_interval(timestamp, duration_ms, timestamp_semantics='unknown'):
    stamp = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    delta = timedelta(milliseconds=float(duration_ms))
    if timestamp_semantics == 'start':
        return stamp.isoformat(), (stamp + delta).isoformat()
    if timestamp_semantics == 'end':
        return (stamp - delta).isoformat(), stamp.isoformat()
    return None  # Never subtract an HTTP duration from an unspecified event clock.

def analyze():
    capture = read(HERE / 'INCIDENT_2_SELECTED.json')
    rows = capture['rows']
    edge = [x for x in rows if x['source'] == 'edge_logs']
    long_requests = [x for x in edge if float(x['origin_ms']) > 20000]
    pg = [x for x in rows if x['source'] == 'postgres_logs']
    startup = [x for x in pg if 'job startup timeout' in x['message']]
    timeouts = [x for x in pg if x['sqlstate'] == '57014']
    slowest = sorted(edge, key=lambda x: float(x['origin_ms']), reverse=True)
    # These checks validate the retained capture, not completeness of the whole window.
    assert len(rows) == 320 and len(rows) == capture['limit']
    assert len(long_requests) == 16
    assert len([x for x in edge if x['status'] == '500']) == 3
    assert len(startup) == 3 and len(timeouts) == 4
    assert edge[0]['path'] == '/rest/v1/dispatch_config'
    assert edge[0]['timestamp'] == '2026-11-02T06:48:43.405000'
    assert slowest[0]['origin_ms'] == '46634'
    assert observed_interval(slowest[0]['timestamp'], 46634) is None
    assert observed_interval('2026-11-01T16:32:33.663000', 13798.532, 'end')[0] == '2026-11-01T16:32:19.864468+00:00'
    assert not any('919392860726' in json.dumps(x) for x in rows)
    snapshot = read(HERE / 'POST_INCIDENT_SNAPSHOT.json')[0]['jsonb_build_object']
    exporter = next(x for x in snapshot['activity'] if x['pid'] == 3006625)
    assert exporter['app'] == 'postgres_exporter'
    assert any(x['pid'] == '3006625' and 'pg_stat_statements' in x['query'] for x in timeouts)
    baseline = read(ROOT / 'docs/performance/blocker-resolution/VERIFICATION.json')
    drift = [p for p, digest in baseline['coordinated_candidate_files_sha256'].items()
             if hashlib.sha256((ROOT / p).read_bytes()).hexdigest() != digest]
    assert drift == [], drift
    result = {
        'production_writes': 0,
        'root_cause_proven': False,
        'capture_limit_reached': True,
        'last_retained_timestamp': rows[-1]['timestamp'],
        'counts_in_retained_prefix_only': {'over_20s': 16, 'http500': 3, 'sql57014': 4, 'cron_startup_failures': 3},
        'earliest_selected_gateway_slow_observation': edge[0],
        'slowest_requests': [{k: x[k] for k in ['timestamp', 'method', 'path', 'status', 'origin_ms', 'upstream_ms']}
                             | {'upstream_fraction': round(float(x['upstream_ms']) / float(x['origin_ms']), 6)}
                            for x in slowest[:6]],
        'cron_failure_events': [{'timestamp': x['timestamp'], 'message': x['message']} for x in startup],
        'timed_out_queries': [{'timestamp': x['timestamp'], 'pid': x['pid'], 'query': x['query']} for x in timeouts],
        'exporter_pid_association': 'Incident PID 3006625 matches later postgres_exporter activity; not a query-start/resource sample.',
        'http_timestamp_semantics': 'unverified; no derived HTTP start/end claimed',
        'prior_coordinated_candidate_hash_drift': drift,
        'offline_evidence_assertions_passed': True,
    }
    (HERE / 'ANALYSIS.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: result[k] for k in ['root_cause_proven', 'counts_in_retained_prefix_only', 'prior_coordinated_candidate_hash_drift', 'offline_evidence_assertions_passed']}))

if __name__ == '__main__':
    analyze()
