# WayDrop P0 Performance Baseline

## Baseline identity

- Baseline document created: 2026-10-25 23:39:18 IST (+05:30)
- Supabase Query Performance export file timestamp: 2026-10-25 23:06:24 IST (+05:30)
- Application package: `waydrop`
- Application version/build: `1.0.0+54`
- Git commit inspected: `d249388`
- Workspace state at collection: existing user changes were present; they were not modified
- Supabase project shown in the supplied Dashboard evidence: `waydrop`, production branch `main`
- Statistics source: Supabase Query Performance / `pg_stat_statements`
- `pg_stat_statements.stats_reset`: `2026-05-07 11:50:14.71209+05:30` (confirmed by a read-only live query)
- Query IDs: unavailable; the supplied export does not contain a `queryid` column

## Collection scope and safety

This baseline was assembled from the user-supplied Supabase Query Performance CSV-style export, the supplied Dashboard screenshot, and read-only repository inspection. No live SQL was executed. No statistics were reset. No application source, database object, Supabase setting, cron job, index, production data, Git branch, commit, or deployment was changed.

The supplied export is preserved at its original attachment location. This document is a separate summary and does not contain credentials, tokens, personal location values, or row-level production data.

## Supabase report-level metrics

The supplied Dashboard screenshot reported:

| Metric | Value |
|---|---:|
| Slow query entries under the displayed filter | 624 |
| Displayed filter | Total time > 1000 ms |
| Cache hit rate | 100.00% |
| Average rows per call | 11.9 |

These values are cumulative over an unknown statistics interval. They are not a current-period rate.

## Preserved query baseline

Times below are converted from the export's millisecond values. Query IDs were not included, so each entry is identified by a stable descriptive label and normalized-query prefix.

| # | Query / role | Calls | Mean ms | Max ms | Total ms | Rows | Cache hit | Share |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | Realtime `list_changes` A / `supabase_admin` | 2,578,845 | 11.535 | 15,866.217 | 29,748,225.779 | 2,591,709 | 100.0000% | 51.1795% |
| 2 | Realtime `list_changes` B / `supabase_admin` | 479,595 | 6.376 | 7,033.736 | 3,058,068.756 | 479,667 | 100.0000% | 5.2612% |
| 3 | Realtime subscription upsert A / `supabase_admin` | 33,742 | 90.124 | 9,651.141 | 3,040,963.622 | 33,742 | 99.9998% | 5.2317% |
| 4 | `redispatch_stalled_searching_orders()` / `postgres` | 177,612 | 16.661 | 13,317.322 | 2,959,172.026 | 177,612 | 99.999999% | 5.0910% |
| 5 | Rider GPS/status PostgREST UPDATE / `authenticated` | 25,858 | 79.240 | 9,689.460 | 2,049,000.625 | 25,858 | 99.9999% | 3.5251% |
| 6 | Available extensions metadata / `postgres` | 3,508 | 576.112 | 54,966.534 | 2,021,001.530 | 273,624 | 100.0000% | 3.4770% |
| 7 | `redispatch_freed_riders()` / `postgres` | 210,342 | 9.432 | 24,488.931 | 1,983,974.488 | 210,342 | 99.999999% | 3.4133% |
| 8 | `pg_timezone_names` / `authenticator` | 2,795 | 654.033 | 5,876.357 | 1,828,021.677 | 3,342,820 | 0% | 3.1450% |
| 9 | PostgREST request context `set_config` / `authenticated` | 937,859 | 1.604 | 2,754.094 | 1,504,011.365 | 937,859 | 100.0000% | 2.5875% |
| 10 | `find_nearby_riders` RPC / `authenticated` | 6,142 | 228.459 | 12,089.528 | 1,403,197.393 | 6,142 | 100.0000% | 2.4141% |
| 11 | Unread notification IDs / `authenticated` | 12,632 | 97.814 | 10,185.031 | 1,235,590.308 | 12,632 | 99.9996% | 2.1257% |
| 12 | Studio table metadata inspection / `postgres` | 7,981 | 135.392 | 32,488.090 | 1,080,564.392 | 7,980 | 100.0000% | 1.8590% |
| 13 | pg_net response cleanup / `supabase_admin` | 7,425 | 144.646 | 16,356.588 | 1,073,993.811 | 3,640 | 100.0000% | 1.8477% |
| 14 | Realtime subscription upsert B / `supabase_admin` | 33,522 | 27.385 | 8,383.655 | 917,991.305 | 33,354 | 99.9999% | 1.5793% |
| 15 | Realtime publication-table lookup / `supabase_admin` | 46,328 | 18.499 | 14,093.294 | 857,021.228 | 827,845 | 99.99999% | 1.4744% |
| 16 | Rider assignments with order embed / `authenticated` | 26,147 | 30.147 | 5,061.951 | 788,244.011 | 26,147 | 100.0000% | 1.3561% |
| 17 | `expire_stale_searching_orders()` / `postgres` | 61,837 | 12.251 | 4,337.508 | 757,551.737 | 61,837 | 99.999997% | 1.3033% |
| 18 | User orders with rider/review embeds / `authenticated` | 11,102 | 62.328 | 9,807.883 | 691,960.584 | 11,102 | 100.0000% | 1.1905% |
| 19 | PgBouncer authentication / `pgbouncer` | 11,592 | 49.953 | 7,923.721 | 579,055.684 | 11,592 | 100.0000% | 0.9962% |
| 20 | Cron run-detail insert / `supabase_admin` | 484,939 | 1.129 | 20,834.187 | 547,639.942 | 484,939 | 99.9999% | 0.9422% |

The export also included minimum times. They remain preserved in the original attachment but are omitted here because the requested baseline fields were calls, total, mean/max, rows, and cache hit.

### Index Advisor result preserved

The only non-null Advisor suggestion in the supplied rows was a B-tree index on `public.rider_reviews(order_id)` for the user-orders query. Local migration history defines a unique `(order_id, rated_by)` constraint whose backing B-tree can normally serve the leading `order_id` predicate. The suggestion must not be applied until the deployed constraint/index and a current execution plan are verified.

## Workload-specific baseline metrics

### Realtime

| Metric | Available baseline |
|---|---:|
| WAL/list-change calls | 3,058,440 |
| WAL/list-change total time | 32,806,294.535 ms |
| WAL/list-change share | 56.4407% |
| Subscription-upsert calls | 67,264 |
| Subscription-upsert total time | 3,958,954.927 ms |
| Publication-table lookup calls | 46,328 |
| Client subscription creates/disposes | Unavailable |
| Client reconnect count and duration | Unavailable |
| Client channel-error and heartbeat-failure counts | Unavailable |
| Peak/current active client channels | Unavailable |

`RealtimeObservability` contains process-memory counters for these client metrics, but no runtime snapshot or persistent export was available. Static source proves the counters exist; it does not establish their production values.

### Rider GPS updates

| Metric | Available baseline |
|---|---:|
| Matching PostgREST UPDATE calls | 25,858 |
| Mean execution | 79.240 ms |
| Maximum execution | 9,689.460 ms |
| Total execution | 2,049,000.625 ms |
| Rows returned/processed in report | 25,858 |
| Device-side attempted/skipped/coalesced writes | Unavailable |
| Writes per rider-hour | Unavailable |

The normalized SQL updates `current_heading`, `current_lat`, `current_lng`, `last_active_at`, `last_location_updated_at`, and `updated_at`, filtered by `user_id` and online account status. No personal coordinates were exported into this document.

### Notifications

| Metric | Available baseline |
|---|---:|
| Unread-ID query calls | 12,632 |
| Mean execution | 97.814 ms |
| Maximum execution | 10,185.031 ms |
| Total execution | 1,235,590.308 ms |
| Refresh attempts/coalesced requests | Unavailable |
| Response bytes | Unavailable |

### Dispatch and recovery

| Metric | Calls | Mean ms | Max ms | Total ms |
|---|---:|---:|---:|---:|
| `find_nearby_riders` RPC | 6,142 | 228.459 | 12,089.528 | 1,403,197.393 |
| Stalled-order redispatch | 177,612 | 16.661 | 13,317.322 | 2,959,172.026 |
| Freed-rider redispatch | 210,342 | 9.432 | 24,488.931 | 1,983,974.488 |
| Searching-order expiry | 61,837 | 12.251 | 4,337.508 | 757,551.737 |

End-to-end order creation-to-assignment latency, p50/p95/p99 dispatch latency, recovery success rate, candidate counts, and no-op cron rates are unavailable. `pg_stat_statements` measures database statement execution, not the entire user-visible dispatch operation.

## Cron baseline

### Deployed state

Verified from the supplied output of this read-only live query:

```sql
SELECT jobid, jobname, schedule, active
FROM cron.job
ORDER BY jobname;
```

| Job ID | Live job name | Live schedule | Active |
|---:|---|---|---|
| 4 | `cleanup-abandoned-kyc-uploads` | `0 3 * * *` | Yes |
| 6 | `expire-stale-active-orders` | `*/10 * * * *` | Yes |
| 1 | `expire-stale-searching-orders` | `*/2 * * * *` | Yes |
| 3 | `intercity-expiry-checks` | `*/15 * * * *` | Yes |
| 7 | `redispatch-freed-riders` | `45 seconds` | Yes |
| 5 | `redispatch-stalled-searching-orders` | `*/1 * * * *` | Yes |
| 10 | `retry-pending-order-completion-side-effects` | `*/5 * * * *` | Yes |
| 2 | `rider-dormant-and-expiry-checks` | `0 * * * *` | Yes |

The live schedules supersede schedule assumptions derived from local migrations. In particular, freed-rider redispatch runs every 45 seconds and stalled-order redispatch runs every minute. No schedule was changed during P0.

### Local migration schedules retained for drift comparison

These remain repository intent rather than live configuration. Differences are now confirmed for both redispatch jobs:

| Job | Latest local schedule |
|---|---|
| `redispatch-freed-riders` | Every 20 seconds |
| `redispatch-stalled-searching-orders` | Every 30 seconds |
| `expire-stale-searching-orders` | Every 2 minutes |
| `expire-stale-active-orders` | Every 10 minutes |
| `intercity-expiry-checks` | Every 15 minutes |
| `rider-dormant-and-expiry-checks` | Hourly |
| `cleanup-abandoned-kyc-uploads` | Daily at 03:00 |
| `reconcile-cashfree-settlements` | Local migration requests unscheduling |

The local September advisory-lock migration contains an older 15-second description for stalled redispatch, while the earlier frequency migration changes it to 30 seconds. Only a live read of `cron.job` can settle the deployed value.

The live read now settles the deployed value at one minute. It also shows a live `retry-pending-order-completion-side-effects` job that was not included in the earlier local schedule summary.

### Live cron execution baseline — collected 24-hour window

| Job | Status | Runs | Average duration | Maximum duration |
|---|---|---:|---:|---:|
| `cleanup-abandoned-kyc-uploads` | Succeeded | 1 | 0.06 s | 0.06 s |
| `expire-stale-active-orders` | Succeeded | 144 | 0.02 s | 0.51 s |
| `expire-stale-searching-orders` | Succeeded | 720 | 0.02 s | 1.14 s |
| `intercity-expiry-checks` | Succeeded | 96 | 0.06 s | 0.08 s |
| `redispatch-freed-riders` | Succeeded | 1,917 | 0.02 s | 9.20 s |
| `redispatch-stalled-searching-orders` | Failed | 2 | 10.29 s | 10.49 s |
| `redispatch-stalled-searching-orders` | Succeeded | 1,438 | 0.03 s | 3.58 s |
| `retry-pending-order-completion-side-effects` | Succeeded | 288 | 0.01 s | 0.65 s |
| `rider-dormant-and-expiry-checks` | Succeeded | 24 | 0.05 s | 0.17 s |

Observation: most recorded runs succeeded quickly. The data confirms two failures for stalled-order redispatch and a 9.20-second maximum for freed-rider redispatch. It does not reveal how many successful runs performed useful work.

Hypothesis only: intermittent startup or resource contention may explain the two failures and nearby slower runs. The available evidence does not establish the precise cause and does not prove that either job is unnecessary.

### Confirmed stalled-redispatch failures

The corrected seven-day failed-run query used `jobid = 5`, because the actual cron job name is hyphenated. An earlier query used an underscore-separated function-style name and incorrectly returned no rows.

| Job ID | Start time (IST) | End time (IST) | Status | Return message |
|---:|---|---|---|---|
| 5 | 2026-10-25 13:41:00.000704+05:30 | 2026-10-25 13:41:10.495471+05:30 | Failed | `job startup timeout` |
| 5 | 2026-10-25 13:43:00.000776+05:30 | 2026-10-25 13:43:10.089691+05:30 | Failed | `job startup timeout` |

Most cron executions between 13:35 and 13:50 IST succeeded. `redispatch-freed-riders` took approximately 9.20 seconds near 13:43:12, and stalled-order redispatch subsequently returned to successful runs. This confirms a short intermittent failure window, not a persistent outage.

## Index baseline

### Deployed state and validity

Not verified. The supplied performance export does not contain `pg_index` definitions or validity flags, and no live database connection was available.

### Relevant indexes expressed by local migrations

These are repository intent only:

| Table | Local definition |
|---|---|
| `rider_reviews` | `(rider_id, rated_by) INCLUDE (rating)` |
| `rider_reviews` | `(user_id, rated_by) INCLUDE (rating)` |
| `rider_reviews` | Unique `(order_id, rated_by)` constraint in migration history |
| `rider_travel_plans` | `(rider_id)` |
| `notifications` | `(user_id, is_read)` |
| `notifications` | `(user_id, created_at DESC)` |
| `riders` | Unique `user_id`, plus a separate local `user_id` index |
| `riders` | `account_status`, `last_location_updated_at DESC`, individual latitude/longitude indexes |
| `rider_assignments` | Individual indexes on `rider_id`, `order_id`, `assignment_status`, `expires_at`, and round |

No statement is made here that these indexes are deployed, valid, ready, or used.

## Historical-data qualification

The baseline is cumulative and includes historical behavior. Evidence includes normalized queries whose selected fields differ from current source, plus cron counts spanning local schedule changes. The report therefore establishes cumulative workload, not the current release's isolated rate.

The live read-only query now confirms `stats_reset = 2026-05-07 11:50:14.71209+05:30`. All supplied `pg_stat_statements` counters span the interval since that timestamp and must not be treated as current-day rates. Some normalized query shapes differ from current source, further confirming that the report contains historical application behavior.

## Missing information

1. Query IDs for all exported rows.
2. Cron no-op and useful-action counts, plus queued-run information where available.
3. Deployed index definitions, validity/readiness, sizes, and scan counts.
4. Production region and a timestamped correlation between slow calls and Supabase incidents.
5. Client Realtime creates, disposes, reconnects, errors, heartbeat failures, and peak channels.
6. GPS attempted, sent, skipped, failed, and coalesced writes per rider-hour.
7. Notification refresh attempts, overlapping/coalesced calls, and response sizes.
8. End-to-end order-dispatch latency and recovery outcome metrics.
9. Timestamped p50/p95/p99 metrics; `pg_stat_statements` supplies cumulative mean/min/max rather than request distributions.
10. Confirmation that the inspected Git commit exactly matches the currently deployed application build.
11. PostgreSQL logs for 2026-10-25 13:35–13:50 IST (08:05–08:20 UTC), covering the two cron startup timeouts.
12. The root cause of the two cron startup timeouts.

## Inspection completion matrix

| Inspection | Status | Evidence/source |
|---|---|---|
| Current P0 document timestamp | Completed | Local client time |
| App version/build | Completed | `pubspec.yaml` |
| Git revision/workspace state | Completed | Read-only Git inspection |
| Query Performance export preservation | Completed | Original attachment plus this separate summary |
| Query calls/times/rows/cache hit | Completed where supplied | User-supplied export |
| Query IDs | Unavailable | Not present in export |
| `stats_reset` | Completed | Read-only `pg_stat_statements_info` output supplied |
| Live cron inspection | Completed | Read-only `cron.job` output supplied |
| Live cron 24-hour execution summary | Completed | Bounded `cron.job_run_details` summary supplied |
| Stalled-redispatch failed runs | Completed | Corrected `jobid = 5` output supplied |
| Local cron intent | Completed | SQL migrations |
| Live deployed-index inspection | Unavailable | No live database/browser surface |
| Local index intent | Completed | SQL migrations |
| Realtime backend aggregate baseline | Completed | Query Performance export |
| Realtime client runtime counters | Unavailable | No runtime snapshot |
| GPS database-query baseline | Completed | Query Performance export |
| Notification-query baseline | Completed | Query Performance export |
| Database portion of dispatch baseline | Completed | Query Performance export |
| End-to-end dispatch baseline | Unavailable | No timestamped application telemetry export |

## Change confirmation

No application code, tests, dependencies, environment configuration, Supabase configuration, database schema, production data, cron schedules, indexes, statistics, Git branches, commits, or deployments were changed. The only new workspace artifact is this explicitly requested P0 audit document.

---

## P0 continuation — missing-item collection attempt

### Continuation timestamp

- Inspection continued: 2026-10-25 23:46:31 IST (+05:30)
- Scope: only the baseline items previously marked missing
- Supabase browser availability: unavailable to the automation session
- Supabase CLI: not installed
- PostgreSQL `psql` client: not installed
- Local Supabase link metadata: present and identifies the linked project as `waydrop`; project identifiers and connection details are deliberately omitted

### 1. Current app version and release identifier

Completed for the inspected source tree:

| Field | Value |
|---|---|
| Flutter application version | `1.0.0` |
| Flutter build number | `54` |
| Combined version | `1.0.0+54` |
| Full Git commit | `d249388c74a41e21e9f1ab0816ca18f7f6d89069` |
| Commit timestamp | `2026-09-09T17:18:40+05:30` |
| Commit subject | `Merge origin/team into team` |

This is the current local source release identifier. No deployment manifest, build artifact metadata, or production runtime version was available to prove that production is running this exact commit/build. The production release-to-commit mapping remains missing.

### 2. `pg_stat_statements.stats_reset` — subsequently completed

Status at the earlier continuation attempt: unavailable. Status after the supplied live read-only output: **COMPLETED**.

Confirmed value: `2026-05-07 11:50:14.71209+05:30`.

Safe collection query for a Supabase SQL Editor or an already-authorized read-only PostgreSQL session:

```sql
SELECT stats_reset
FROM pg_stat_statements_info;
```

This reads one extension metadata row. It does not reset or alter statistics. Do not run `pg_stat_statements_reset()`.

If `pg_stat_statements_info` is unavailable on the deployed extension version, record the exact error rather than trying a write or enabling an extension.

### 3. Live cron job names and schedules — subsequently completed

Status at the earlier continuation attempt: unavailable. Status after the supplied live read-only output: **COMPLETED**. The authoritative schedules and 24-hour run summary are recorded in the Cron baseline section above.

Safe low-impact catalog query:

```sql
SELECT
  jobid,
  jobname,
  schedule,
  command,
  database,
  username,
  active
FROM cron.job
ORDER BY jobname, jobid;
```

This reads the small pg_cron job catalog. The output should be preserved with its collection timestamp. Connection strings, secrets, or personal data are not expected in these fields, but commands should still be reviewed before sharing because a job command can contain an embedded secret in a poorly configured system.

To collect recent execution health without scanning an unlimited history, use a bounded window:

```sql
SELECT
  j.jobname,
  d.status,
  count(*) AS runs,
  min(d.start_time) AS first_start,
  max(d.end_time) AS last_end,
  avg(d.end_time - d.start_time) AS average_duration,
  max(d.end_time - d.start_time) AS maximum_duration
FROM cron.job_run_details AS d
JOIN cron.job AS j ON j.jobid = d.jobid
WHERE d.start_time >= now() - interval '24 hours'
GROUP BY j.jobname, d.status
ORDER BY j.jobname, d.status;
```

The bounded run summary is optional for P0 and should be skipped if `cron.job_run_details` is unusually large or access is denied.

### 4. Deployed index definitions and validity

Status: **not collected**. Local definitions remain documented above; live validity/readiness and usage are unverified.

Safe targeted catalog query for only the performance-relevant tables:

```sql
SELECT
  ns.nspname AS schema_name,
  tbl.relname AS table_name,
  idx.relname AS index_name,
  pi.indisprimary AS is_primary,
  pi.indisunique AS is_unique,
  pi.indisvalid AS is_valid,
  pi.indisready AS is_ready,
  pi.indislive AS is_live,
  pg_get_indexdef(idx.oid) AS definition
FROM pg_index AS pi
JOIN pg_class AS idx ON idx.oid = pi.indexrelid
JOIN pg_class AS tbl ON tbl.oid = pi.indrelid
JOIN pg_namespace AS ns ON ns.oid = tbl.relnamespace
WHERE ns.nspname = 'public'
  AND tbl.relname IN (
    'rider_reviews',
    'rider_travel_plans',
    'riders',
    'notifications',
    'rider_assignments',
    'orders'
  )
ORDER BY tbl.relname, idx.relname;
```

This reads PostgreSQL catalogs only. It does not inspect table rows or force an execution plan.

Optional usage counters can be collected separately:

```sql
SELECT
  schemaname,
  relname AS table_name,
  indexrelname AS index_name,
  idx_scan,
  last_idx_scan
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
  AND relname IN (
    'rider_reviews',
    'rider_travel_plans',
    'riders',
    'notifications',
    'rider_assignments',
    'orders'
  )
ORDER BY relname, indexrelname;
```

Index usage counters are cumulative and require their own statistics-window qualification. A zero value does not by itself justify dropping an index.

### 5. Available operational baseline metrics

No new runtime telemetry became available during the continuation. The production query aggregates recorded earlier remain the available baseline:

| Area | Available production proxy | Still missing |
|---|---|---|
| Realtime | 3,058,440 WAL/list-change calls; 67,264 subscription-upsert calls; publication lookup totals | App creates/disposes, reconnect count/duration, errors, heartbeat failures, current/peak active channels |
| GPS updates | 25,858 matching rider UPDATEs; 79.240 ms mean; 9,689.460 ms maximum; 2,049,000.625 ms total | Writes per rider-hour, device attempts, skips, failures, coalescing, state-specific cadence |
| Notifications | 12,632 unread-ID queries; 97.814 ms mean; 10,185.031 ms maximum; 1,235,590.308 ms total | Refresh triggers, overlap, coalescing, response bytes, exact-count calls |
| Dispatch | 6,142 `find_nearby_riders` calls; 228.459 ms mean; 12,089.528 ms maximum; cron function aggregates recorded above | End-to-end creation-to-assignment p50/p95/p99, candidates examined, successful matches, no-op recovery runs |

The application contains process-memory Realtime counters in `RealtimeObservability`, displayed through the admin dashboard. These reset when the process restarts and were not captured from a running production client. They must be labelled as a single-device, single-process snapshot if collected; they are not fleet-wide production metrics.

Safe collection method for existing client counters:

1. Open the already-running WayDrop Admin Dashboard on a representative device.
2. Record the existing telemetry values without triggering refresh/load-test actions.
3. Record device session start time and app version.
4. Do not include user IDs, coordinates, tokens, or account details.

GPS, notification-overlap, and end-to-end dispatch counters are not currently persisted in the supplied evidence. Collecting them would require existing external logs or later instrumentation, which is outside P0 and was not performed.

### Supabase log exports and coverage limits

#### `supabase_logs (5).csv` — PARTIALLY COMPLETED

- Rows inspected: 1,000
- Log types: Edge 947, PgBouncer 38, Realtime 11, Storage 4
- Levels in the export: all `success`
- Earliest event: 2026-10-25 13:43:57.946 IST
- Latest event: 2026-10-25 23:52:07.464 IST

Observation: this export does not contain PostgreSQL logs and begins after both cron startup-timeout attempts began. It cannot diagnose the 13:41 and 13:43 failures.

#### `supabase_logs (6).csv` — PARTIALLY COMPLETED

- Rows inspected: 1,000 PostgreSQL log entries
- Levels in the export: all `success`
- Earliest event: 2026-10-25 21:34:59.858 IST
- Latest event: 2026-10-26 00:01:00.044 IST
- Matching timeout, failure, or error messages: none in this exported interval

Observation: this export begins almost eight hours after the failures. The absence of errors in it is not evidence that PostgreSQL produced no relevant error at 13:41–13:43.

#### Required log window — NOT VERIFIED

A PostgreSQL log export is still required for:

- IST: 2026-10-25 13:35–13:50
- UTC: 2026-10-25 08:05–08:20

Until that window is collected, the cron failure root cause remains unverified.

### Continuation completion status

| Missing item | Result |
|---|---|
| Current source app version | Completed: `1.0.0+54` |
| Current source release identifier | Completed: full Git commit recorded |
| Production release identifier | Missing: no deployment/runtime metadata access |
| Current `stats_reset` | Completed: `2026-05-07 11:50:14.71209+05:30` |
| Live cron definitions | Completed: eight active jobs recorded |
| Live cron 24-hour summary | Completed: success/failure counts and duration aggregates recorded |
| Deployed index definitions/validity | Missing: requires the targeted catalog query above |
| Realtime runtime metrics | Missing: no representative running-client snapshot |
| GPS production aggregate | Available only through the recorded PostgREST query totals |
| Notification production aggregate | Available only through the recorded unread-query totals |
| Dispatch database aggregate | Available through the recorded RPC/cron totals |
| End-to-end dispatch latency | Missing: no timestamped trace/log export |

### Consolidated P0 evidence status

| P0 item | Status | Basis |
|---|---|---|
| Current local app version and source release | **COMPLETED** | `pubspec.yaml` and Git metadata |
| Production release-to-commit mapping | **NOT VERIFIED** | No deployment/runtime version evidence |
| Query Performance CSV preservation and analysis | **COMPLETED** | Original attachment retained; normalized metrics recorded above |
| `pg_stat_statements.stats_reset` | **COMPLETED** | Live read-only output supplied |
| Live cron job names, schedules, and active state | **COMPLETED** | Live read-only `cron.job` output supplied |
| Live cron 24-hour execution summary | **COMPLETED** | Bounded live summary supplied |
| Two stalled-redispatch startup timeouts | **COMPLETED** | Corrected `jobid = 5` failed-run output supplied |
| Cron useful-work/no-op rate | **NOT VERIFIED** | Run status and duration do not show useful actions |
| Cron startup-timeout root cause | **NOT VERIFIED** | Relevant PostgreSQL log window is missing |
| General Supabase logs | **PARTIALLY COMPLETED** | Two 1,000-row exports inspected; neither covers the failure window |
| Deployed index definitions and validity/readiness | **NOT VERIFIED** | No live index catalog output supplied |
| Index usage | **NOT VERIFIED** | No live `pg_stat_user_indexes` output supplied |
| Realtime database aggregate metrics | **COMPLETED** | Historical Query Performance export |
| Realtime client lifecycle metrics | **NOT VERIFIED** | No running-client telemetry snapshot |
| GPS database UPDATE aggregate | **COMPLETED** | Historical Query Performance export |
| GPS device/session metrics | **NOT VERIFIED** | No attempt/failure/skip/coalescing or rider-hour telemetry |
| Notification database-query aggregate | **COMPLETED** | Historical Query Performance export |
| Notification overlap and payload size | **NOT VERIFIED** | No client/network telemetry supplied |
| Dispatch database aggregate | **COMPLETED** | Historical RPC and cron query metrics |
| End-to-end dispatch latency | **NOT VERIFIED** | No timestamped order lifecycle trace supplied |

No application, database, configuration, statistics, cron, index, production-data, deployment, or Git changes were made during this continuation. Only this requested audit document was extended; the original CSV/export evidence was not overwritten or modified.
