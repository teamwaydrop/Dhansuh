# Part 1 — Database timeout root cause

Production project: `yvwpchffctiagevpqgwy` (WayDrop). Incident: **1 November 2026, 21:52–22:04 IST / 16:22–16:34 UTC**. Investigation performed against retained incident logs and the existing local evidence. Production inspection was read-only.

## Finding

**The initiating bottleneck is unresolved.** The evidence establishes database execution slowdown, PostgREST pool-acquisition failures, and client request amplification. It does **not** establish CPU saturation, memory/swap pressure, disk saturation, a blocking transaction, or exhaustion of PostgreSQL's global connection limit as the initiating cause.

This is more specific than a generic “backend slow” diagnosis:

1. Unrelated REST reads were already slow before the main Chat failure burst. Gateway records at **16:30:49.270–.292 UTC** show users, KYC and orders reads taking **10.1–14.0 seconds**, including an Edge-originated orders read. Therefore, a Chat-only insert/history problem cannot explain the whole slowdown.
2. Around **16:31:55–16:32**, Chat writes and unrelated reads remained outstanding for tens of seconds. The longest Chat record has **58,813 ms origin / 58,692 ms upstream** and `PostgREST; error=57014`. Most of that request's latency was upstream of the gateway; it cannot be explained by Flutter rendering or the handset's network alone.
3. `PGRST003` establishes that some requests could not acquire a PostgREST pool connection in time. Occupied/slow connections and additional demand can propagate execution slowdown into queueing. Pool-acquisition failure does not identify why connections were unavailable, and does not prove `max_connections` was reached. See [PostgREST's error definition](https://docs.postgrest.org/en/stable/references/errors.html#group-0-connection).
4. Realtime and cron also slowed, despite being separate database consumers. That supports a shared database/resource or concurrency problem beyond one Flutter screen or one REST pool. A sufficiently broad lock/contention path remains possible, but no historical wait graph identifies one.
5. Existing source and incident request shapes identify amplifiers: repeated Home profile reads, notification count reconciliation, and Chat retries after a non-cancelling client timeout. These can increase work while requests remain outstanding. They are verified mitigation targets, **not proof of the initial saturation mechanism**.

The working causal model is **unidentified database service-time degradation + amplified demand → longer connection occupancy/queueing → execution and pool timeouts → application failures/retries**. The direction of feedback is plausible; the logs do not identify a single first SQL statement or a measured hardware limit.

## Evidence and reproducibility

| Source | What it establishes / limitation |
| --- | --- |
| [Existing incident evidence](loading-spike-20261101/EVIDENCE.json) | Original method-specific REST totals, Home query shapes, notification traffic, cron durations, resource-signature search and late errors. Read first; retained unchanged. |
| [Existing catalog evidence](root-cause-20261101/CATALOG_EVIDENCE.json) | Role timeout settings and May-to-date statistics scope. Later catalog state, not incident resource measurements. |
| [New incident logs](root-cause-20261101/INCIDENT_LOGS.json) | 150 selected entries: 89 PostgreSQL, 49 PostgREST, 12 Realtime, ordered by timestamp. Query shapes and process/query identifiers retained; row-detail values and connection addresses omitted. |
| [Part 1 evidence](root-cause-20261101/PART_1_EVIDENCE.json) | 486 gateway workload groups totaling all 2,941 gateway entries, 52 requests with origin time >=10 seconds, minute totals, historical cron runs, current logging/queue definitions, Auth correlation, later health snapshot and advisor results. |
| [Earlier fix report](WAYDROP_PERFORMANCE_FIX_REPORT.md) | Prior local implementations and prior verification. Historical totals lower in that report are not new Part 1 test results. |

Used the project-scoped Supabase `query_logs`, `execute_sql`, `get_advisors` and documentation search tools. Every log query explicitly used `2026-11-01T16:22:00Z` through `2026-11-01T16:34:00Z`. The combined log query returned **448/500** allowed entries, matching the separate per-source counts: PostgreSQL 89, PostgREST 49, PgBouncer 141, Auth 157 and Realtime 12. No log-query result limit was reached. Gateway aggregates independently reconcile to 2,941 entries.

Gateway groups used `request.headers.user_agent`, `request.method`, `request.path`, `response.status_code`, `response.origin_time` and `response.headers.x_envoy_upstream_service_time`. The first minute aggregate used the wrong user-agent attribute and returned empty agent values; those values were discarded. Attribution uses the subsequent correct header-based groups. “Dart” and “other” are client families, not screen, device, build or unique-user identities. Internal Edge-to-REST calls are included, so gateway totals are not unique user actions.

Gateway timestamps and database completion/error timestamps are different observation points. A gateway record includes a duration that can extend into another minute; do not align error counts or subtract statement timeout from origin time to infer exact pool wait. PostgreSQL `session_start_time` is connection age, not query start time. Minute totals below are grouped by the recorded gateway timestamp, not measured live database concurrency.

## Incident timeline

All dates are 1 November 2026. IST = UTC + 05:30.

| UTC | IST | Exact observation and causal significance |
| --- | --- | --- |
| 16:22:00 | 21:52:00 | Cron jobs 5/1 execute in 11.428/8.797 ms in `cron.job_run_details`; useful within-window baseline. |
| 16:22:04 | 21:52:04 | Realtime tenant/replication initialization. Connections check in 189 ms. Initialization alone does not establish a leak or the later trigger. |
| 16:23:11–16:24:41 | 21:53:11–21:54:41 | PostgREST “Thread killed by timeout manager” messages already occur. Without request/SQL correlation these are not proof of statement timeout or the initiating database bottleneck. |
| 16:24:59.761 | 21:54:59.761 | One `23505` on `order_assignment_logs`, constraint `unique_order_rider_assignment`. Separate dispatch conflict; no evidence that this one conflict initiates the later outage. |
| 16:25 minute | 21:55 minute | Gateway traffic rises to 473 records from 39 at 16:22. Maximum origin time still 864 ms. Workload rises before severe latency, but 473/minute (~7.9/sec averaged) is not intrinsically excessive without capacity and concurrency measurements. |
| 16:26:05.245 | 21:56:05.245 | Checkpoint completes: 288 buffers, write 28.919 s, sync 0.010 s. This is elapsed checkpoint write phase, not evidence of a 29-second blocking disk write. |
| 16:30:00.504–.633 | 22:00:00.504–.633 | Five scheduled jobs finish with execution durations 20.100–127.290 ms. A persistent cron execution storm is not demonstrated here. |
| 16:30:36.377–16:31:24.727 | 22:00:36.377–22:01:24.727 | Timed checkpoint writes 419 buffers: write 48.273 s, sync 0.013 s, longest sync 0.003 s. It overlaps worsening latency; it does not establish disk saturation. |
| 16:30:49.270–.292 | 22:00:49.270–.292 | Seven gateway reads across users/KYC/orders, including an Edge orders read, each exceed 10 s; max 14,004 ms. Shared slowdown precedes main Chat burst. |
| 16:31:04.506–16:31:06.379 | 22:01:04.506–22:01:06.379 | Job 5 takes 1,872.386 ms execution. Launcher “starting” log is earlier, at 16:31:01.855; launch delay and execution time must not be conflated. |
| 16:31:55.690–16:31:58.513 | 22:01:55.690–22:01:58.513 | Chat POST records include 11,168/11,030 ms successes and 58,813/58,248 ms failures. Successful writes can also be slow. |
| 16:32:25.819754 | 22:02:25.819754 | First retained `PGRST003` entry. This is first observed pool timeout, not necessarily when pool pressure began. |
| 16:32:29.922 / 16:32:32.507 | 22:02:29.922 / 22:02:32.507 | PostgreSQL `57014`, with actual PostgREST-generated Chat INSERT query shapes. No wait-event or trigger stack identifies where execution spent its time. |
| 16:32:33.663 | 22:02:33.663 | `realtime_rls`: `realtime.list_changes($1,$2,$3,$4)` duration **13,798.532 ms**. Logged plan is only an outer Function Scan, estimated rows 1000; it does not reveal inner-function timings, actual subscriber fanout, buffers or waits. |
| 16:32:33.784 / 16:32:47.613 / 16:32:56.678 | 22:02:33.784 / 22:02:47.613 / 22:02:56.678 | More pool-timeout log entries. The 16:32:47.613 entry contains concatenated messages with embedded 16:32:41 timestamps; ingestion time is not the precise time of each embedded event. |
| 16:32:36.882–16:32:48.551 | 22:02:36.882–22:02:48.551 | Job 7 fails with **job startup timeout**, 11,669.184 ms recorded elapsed time. No completed function execution is established for this run. This is later than the shared slowdown, supporting a victim/possible amplifier interpretation rather than a confirmed initiator. |
| 16:33:07.407–16:33:17.063 | 22:03:07.407–22:03:17.063 | Job 5 succeeds after 9,656.285 ms execution; PostgreSQL completion message arrives at 16:33:18.290. Retained PostgreSQL logs omit its corresponding start message, so cron history supplies the timing. |
| 16:33:14 | 22:03:14 | Auth logs: `GET /user`, status 504, `request_timeout`, `context deadline exceeded`, duration raw 11,238,051,768 (11.238 s if nanoseconds). Endpoint recovered from original JSON event, not the flattened `path='/'`. |
| 16:33:28.326 / 16:33:31.557 | 22:03:28.326 / 22:03:31.557 | Further `57014`, last with Chat INSERT shape. Failures persist after the Realtime duration event. |

**Auth correction:** joining on request ID associates the Auth timeout with gateway path `/auth/v1/user`, timestamp 16:33:01.945, origin 20,099 ms / upstream 19,714 ms. That gateway record reports **200**, while the Auth event reports **504**. The endpoint attribution is stronger than the older evidence's flattened `/` attribution, but the status discrepancy remains unresolved. It may involve upstream attempts or response handling; no retry mechanism or client-visible 504 is proven by this join. Both records are retained in `auth_request_id_join`.

## Workload, connection occupancy and alternative explanations

| Gateway minute UTC | Records | HTTP >=500 | Max origin ms |
| --- | ---: | ---: | ---: |
| 16:22 | 39 | 0 | 565 |
| 16:25 | 473 | 0 | 864 |
| 16:26 | 233 | 0 | 4,914 |
| 16:27 | 411 | 0 | 2,507 |
| 16:28 | 444 | 0 | 4,408 |
| 16:29 | 412 | 0 | 4,447 |
| 16:30 | 269 | 0 | 14,004 |
| 16:31 | 295 | 2 | 58,813 |
| 16:32 | 55 | 7 | 53,193 |
| 16:33 | 169 | 2 | 27,530 |

A fall in recorded request rate at 16:32 does not imply spare database capacity: earlier requests can remain outstanding. Conversely, neither summed request counts nor outstanding HTTP duration measures the number of actively executing PostgreSQL queries. REST calls can wait for a pool connection or a lock and some gateway routes do not execute SQL.

Existing projection evidence finds **133 each** of Home's orders/riders/KYC reads and **141** users-name reads for one JWT session. Notification traffic contains **159 HEAD counts**, 82 PATCHes and one GET. Chat has **28 POST records, 11 HTTP 500s**, versus three history GETs. These support unnecessary repeated work and timeout/replay amplification, not Chat-history polling as the demonstrated load driver. They do not establish duplicate committed message bodies or identify a particular device/build.

| Candidate initiating cause | Evidence assessed | Verdict / discriminator still needed |
| --- | --- | --- |
| CPU saturation | Cross-consumer latency and delayed cron startup are compatible with it. No incident CPU/run-queue samples. | Unresolved. Need per-core busy/system/user, steal/throttle, load/run queue and compute entitlement/burst-credit data. |
| RAM/swap pressure | No OOM/allocation signature in retained logs. Shared-buffer configuration is not RAM utilization. | Unresolved. Need available memory, RSS/cache, swap used and swap-in/out, page faults and kernel memory-pressure/OOM events. |
| Disk I/O bottleneck | Two checkpoint records; low final sync time, no disk-error signature. No historical latency/queue metrics. | Unresolved. Checkpoint elapsed time alone is insufficient. Need read/write latency, IOPS, throughput, queue depth, utilization and provisioned/burst limits. |
| Lock/transaction contention | No retained deadlock, lock-timeout or “still waiting for … lock” signature. Chat inserts execute triggers/constraints. No incident lock graph. | Unresolved, with no positive blocker evidence. Need contemporaneous blocker PIDs, lock relation/mode, transaction/query ages and wait events. Lack of log signatures does not exclude all contention. |
| PostgreSQL global connection exhaustion | `PGRST003` is positive evidence for REST pool-acquisition failure. No “too many connections/remaining slots” signature. | Global exhaustion unproven. Need historical active/idle/transaction counts by role/app, PostgREST pool size/borrowed/waiting, acquisition latency, pooler queues and connection rejects. |
| Excessive concurrent application queries | Traffic increase precedes severe slowdown; repeat Home/count paths and unsafe historical timeout/replay behavior are verified amplifiers. | Contribution plausible; initiating overload unproven. Need in-flight SQL/HTTP counts and capacity at onset, not May cumulative call counts or per-minute arrivals alone. |
| Expensive app/admin query | Timed-out shapes identify Chat INSERT; the only retained long-duration plan is Realtime. Other SQL may be unlogged. | No initiating query identified. Need timestamped slow-query/wait samples and SQL/editor/maintenance activity before onset, including direct connections not represented in gateway logs. |

Checkpoint writes are deliberately paced in PostgreSQL; a 48-second write phase is not 48 seconds of continuous device saturation. The observed 13 ms sync phase does not exclude read I/O or other I/O contention. See [PostgreSQL 17 WAL/checkpoint documentation](https://www.postgresql.org/docs/17/wal-configuration.html).

### Chat trigger chain and Realtime

Current read-only definitions establish this SQL path:

`Chat INSERT → prevent_chat_before_intercity_acceptance → on_new_chat_message → send_push_notification_fnc → notifications INSERT → on_notification_insert → deliver_push_notification_http_fnc → Vault lookup + net.http_post queue INSERT/wake`.

The transaction includes synchronous SQL/constraint/trigger work. **FCM/network delivery is asynchronous:** inspected `net.http_post` inserts into `net.http_request_queue`, wakes the worker and returns an ID. Its `timeout_milliseconds=5000` is not a synchronous five-second FCM wait for every Chat insert. The queue insert/Vault lookup could themselves encounter resource pressure; no incident trigger-level timing or wait establishes them as the root cause. Definitions are later catalog evidence, not a historical execution profile.

Realtime's 13.8-second `list_changes` event proves slow processing, but not a subscription leak or excessive RLS fanout. Its event is later than the 10–14-second reads. Preserve essential tracking/dispatch subscriptions and publications until subscriber counts, WAL/backlog and internal timings establish a specific problem.

### Why cumulative statistics and current health cannot settle this

`pg_stat_statements_info.stats_reset` is **2026-05-07 11:50:14.71209 +05:30 / 06:20:14.71209 UTC**, not the incident start. Current `dealloc=21` also means entries have been evicted. Existing cumulative totals and October 31 extracts span different periods, not incident-boundary snapshots. They cannot establish November 1 query rates, concurrent demand, incident temp spills or an initiating admin query. No statistics reset or expensive production plan execution was performed.

At **23:53:10.142516 IST / 18:23:10.142516 UTC**, later lightweight inspection found `max_connections=60`, four client backends (one active, including inspection), zero blocked sessions and zero idle-in-transaction sessions older than 30 seconds. Postmaster start was May 7. This later healthy snapshot cannot clear a 22:02 connection/lock/resource incident, nor establish a REST pool's size.

Current logging settings: `log_min_duration_statement=-1`, `log_lock_waits=on`, `deadlock_timeout=1000ms`. Thus the retained logs are not a complete duration history of all app/admin SQL; isolated auto-explain/error events cannot rule out an unlogged expensive query. Current settings also do not prove their historical values.

Current performance advisors report one unrelated uncovered foreign key (`lawful_disclosure_requests.handled_by_admin_id`), 43 unused-index findings and 22 multiple-permissive-policy findings. None has a timestamped connection to the incident. These counts are not grounds to add/drop indexes or rewrite RLS in this pass. [Advisor descriptions/remediation](https://supabase.com/docs/guides/database/database-linter).

## Missing measurements and required production actions

**Historical charts were not obtained.** Available connected tools expose logs, SQL/catalog inspection and advisors, but no historical host-metrics/chart endpoint. No authenticated dashboard chart export was available in the existing evidence. This is an access/evidence limitation of this investigation, not a claim that Supabase never retains these metrics.

An operator should export retained measurements for **16:20–16:36 UTC / 21:50–22:06 IST**, preserving native resolution and timestamps, especially 16:30:30–16:33:30:

1. CPU, memory/swap and disk measurements listed in the candidate table, including compute size and resource/burst limits **at incident time**. Dashboard [reports](https://supabase.com/dashboard/project/yvwpchffctiagevpqgwy/reports) or a Supabase support export can supply evidence unavailable through this connection.
2. PostgreSQL activity/wait/blocker samples and PostgREST/connection-pool occupancy and acquisition history. Separate waiting for a pool slot from executing SQL and from lock waits. Check archived observability first; current `pg_stat_activity` cannot reconstruct the past.
3. Slow SQL/query fingerprints, start/end times and activity from direct/admin/SQL-editor connections around onset. Correlate actual execution/lock/I/O cost with the slow interval before naming an expensive query. If absent, arrange bounded, reviewed sampling for a future recurrence; it cannot retroactively prove this incident.
4. Realtime subscriber counts, WAL/replication backlog and `list_changes` internal timing, alongside cron launch delays and actual execution durations. Verify whether their growth precedes or follows pressure.
5. Review and test the existing local client mitigations below before any release. Obtain controlled before/after request counts and latency on an authorized test environment/device. No production after-fix latency result exists.

These are required follow-up actions, **not executed production changes**. Do not respond to `PGRST003` by blindly increasing pool size, global connections or statement timeouts: longer occupancy/more workers can increase contention. Select a production change only after the relevant CPU/I/O/wait/occupancy evidence identifies the limiting mechanism. [Supabase timeout scopes](https://supabase.com/docs/guides/database/postgres/timeouts) differ from whole-request duration.

## Local implementation and focused verification

No newly verified initiating database defect justifies changing app SQL, cron, indexes, triggers, Auth, RLS or production configuration. The existing workspace already contains the verified amplification mitigations; **Part 1 adds regression coverage and evidence/reporting, with no additional application behavior change**. Existing user changes were preserved.

| Existing local mitigation inspected | Source location | Verified scope |
| --- | --- | --- |
| Serialize Chat writes per account; join identical pending sends; stable UUID; preserve HTTP ownership; back off `57014`/`PGRST003` | [chat_message_delivery.dart](../../lib/modules/chat/services/chat_message_delivery.dart), class line 15; retry classification 57; queue 110; retry schedule 126 | Prevents overlapping retries from amplifying an uncertain slow write. Does not repair database resource starvation. |
| Durable outbox and cooldown-aware replay | [order_chat_screen.dart](../../lib/modules/chat/screens/order_chat_screen.dart), `_syncOfflineQueue` line 195; `_sendMessage` 1253 | Keeps unsent messages and reuses IDs rather than assuming a client timeout cancelled a POST. |
| Home order-only refresh/profile reuse | [home_tab.dart](../../lib/features/user/home/home_tab.dart), `_loadMeasured` 697; `_subscribeActiveOrders` 1065; [profile_refresh_window.dart](../../lib/features/user/home/profile_refresh_window.dart) | Reduces redundant profile reads for qualifying events; authorization checks are not cached by this display-profile optimization. |
| Count single-flight ownership and unchanged-event filtering | [notification_badge_service.dart](../../lib/modules/notifications/services/notification_badge_service.dart), `refresh` 26; `_refreshOnce` 47; callback 107 | Reduces redundant count reads while retaining reconciliation for actual/unknown read-state changes. |

Added two behavior regressions in [loading_spike_regression_test.dart](../../test/loading_spike_regression_test.dart):

- **Queued burst under pool failure** (line 169): eight distinct queued sends produce one outstanding HTTP POST. Its `PGRST003` causes seven queued attempts to stop at cooldown without sending. After eight seconds, retry retains the first message's UUID.
- **Repeated database timeout backoff** (line 208): six `57014` failures enforce 8/16/32/64/120/120-second cooldowns; attempts before expiry send no HTTP. Expiry itself schedules no retry. Success remains possible and all writes use the same UUID.

Verification command: `flutter test --no-pub test/loading_spike_regression_test.dart --reporter expanded` — **15 passed, 0 failed**, including both new cases and existing timeout, unknown-commit, pending-send joining, authorization, queue, Home and notification tests. Output: `.dart_tool/part1-loading-spike-tests.log`. Test file formatted with `dart format`.

`flutter analyze --no-pub test/loading_spike_regression_test.dart` — **exit 0, no issues found**. Output: `.dart_tool/part1-analyze.log`. [Verification and source hashes](root-cause-20261101/PART_1_VERIFICATION.json) record this pass. Mock HTTP/controlled clock tests verify request ownership/counts and retry behavior, not real PostgreSQL pool capacity, managed RLS/Realtime behavior, device performance or production latency improvement. Earlier full-suite/PG17 results are historical and were not re-counted as new Part 1 runs.

**Production remained unchanged:** no DDL/DML, migration, deployment, cron/config/pool change, advisory-lock experiment, statistics reset, `EXPLAIN ANALYZE`, load test, test-user write or paid resource creation. Part 1's unresolved item is the initiating bottleneck; its concrete next evidence requirements and safe local protections are documented above.
