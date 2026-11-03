"""Offline arithmetic and source checks. No production connection or causal inference."""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent

def read(name):
    return json.loads((HERE / name).read_text(encoding='utf-8'))

metrics = read('REPORTED_METRICS.json')
m = metrics['12:22']
cpu = metrics['12:24']
groups = read('BUILD_55_WINDOW.json')['rows']
gateway = [x for x in groups if x['source'] == 'edge_logs']
dart = [x for x in gateway if x['family'] == 'Dart']
flow = read('BUILD_55_FLOW_CLASSIFICATION.json')['result']['result']
uploads = [x for x in flow if x['kind'] == 'slow_storage']
audit = [x for x in flow if x['kind'] == 'audit_http']
assert len(groups) == 69 and len(groups) < 100
assert len(uploads) == 3 and sorted(int(x['origin_ms']) for x in uploads) == [8635, 19148, 22676]
assert len(audit) == 3 and all(x['status'] == '409' for x in audit)
assert sum(x['errors_or_timeout_events'] for x in gateway) == 0  # 5XX/timeout filter, NOT all HTTP errors.
assert not any(x['path_or_sqlstate'] == '57014' for x in groups if x['source'] == 'postgres_logs')
assert any(x['family'] == 'Dart' and x['path_or_sqlstate'] == '/rest/v1/orders' and x['origin_p95_ms'] == 2045 for x in groups)
unallocated = m['physical_RAM_MB'] - m['used_RAM_MB'] - m['cache_buffers_MB']
assert round(unallocated, 2) == 36.90
result = {
    'source': metrics['provenance'],
    'commit_ratio_pct': round(100 * m['committed_GB'] / m['commit_capacity_GB'], 2),
    'estimated_unallocated_MB_if_disjoint_components': round(unallocated, 2),
    'estimated_unallocated_pct_if_disjoint_components': round(100 * unallocated / m['physical_RAM_MB'], 2),
    'user_plus_system_CPU_pct': round(cpu['user_CPU_pct'] + cpu['system_CPU_pct'], 2),
    'connection_fraction_of_current_max_60_pct': round(100 * 23 / 60, 2),
    'gateway_requests_in_test_window': sum(x['observations'] for x in gateway),
    'Dart_requests_in_test_window': sum(x['observations'] for x in dart),
    'gateway_5XX_or_timeout_matches': sum(x['errors_or_timeout_events'] for x in gateway),
    'Dart_requests_over_1s': sum(x['over_1s'] for x in dart),
    'Dart_requests_over_5s': sum(x['over_5s'] for x in dart),
    'Dart_requests_over_20s': sum(x['over_20s'] for x in dart),
    'slow_uploads': uploads,
    'audit_409s': audit,
    'limits': [
        'Unallocated is not MemAvailable; cache is not all guaranteed reclaimable.',
        'Commitment and occupied swap do not measure paging rate.',
        'Connection count/CPU/memory/throughput samples are at different times.',
        'Project-wide gateway family is not an identified device/build.',
        'Request size divided by origin duration is not a measured network throughput.',
        'No HTTP start/completion semantics or cross-service request ID join inferred.',
        'No zero latency inferred from missing origin_time on service events.'
    ]
}
(HERE / 'METRIC_ANALYSIS.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
print(json.dumps({k: v for k, v in result.items() if k not in ['slow_uploads', 'audit_409s', 'limits']}))
