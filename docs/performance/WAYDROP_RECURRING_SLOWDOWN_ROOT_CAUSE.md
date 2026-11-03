**Subsequent authorized rollout:** [WAYDROP_AUTHORIZED_ROLLOUT.md](WAYDROP_AUTHORIZED_ROLLOUT.md) records the later two function load fixes, rejection v19 and internal RPC ACL corrections actually applied in production. Earlier read-only snapshots/findings below remain historical; the incident initiating cause is still unproven.

# Waydrop recurring slowdown: evidence and remaining causal gap

Investigation: 2 November 2026, after the second incident. Project `yvwpchffctiagevpqgwy`, region `ap-south-1`, PostgreSQL `17.6.1.113`. **Production read-only. No deployment, migration, persistent configuration change, production test data or paid upgrade.**

## Direct answers

| Question | Evidence-based answer |
| --- | --- |
| Where exactly does the failure originate? | The narrowest demonstrated common failure boundary is **PostgreSQL execution plus database connection admission**, affecting application SQL, cron and a managed monitoring query. A Flutter-only, Chat-only, FCM-only or REST-pool-only explanation cannot account for all these observations. The underlying constrained resource/process is not identified. |
| What operation first creates it? | **Unknown.** First selected November 2 slow gateway record: `GET /rest/v1/dispatch_config`, recorded **06:48:43.405 UTC**, 4,865 ms, followed by users/KYC/riders/orders reads at 4–7 seconds. This identifies an early victim, not the initiating SQL. No retained onset query-start/wait/resource trace establishes which operation first consumes the limiting resource. |
| Why do unrelated APIs take 20–46 seconds? | Their shared upstream is delayed: orders **46,317/46,634 ms** upstream/origin; riders **41,946/42,395**; failed users GET **39,394/39,865**. SQL/connection service delay and occupied connections can propagate into queueing. November 1 explicitly includes `PGRST003`; the second capture does not prove that code or a particular pool-wait duration for each slow request. No valid subtraction gives an exact queue/CPU/lock split. |
| Why do statements and cron startup time out together? | Existing SQL executions are cancelled while distinct cron jobs fail **before successful startup**, consistent with impaired database progress/admission across consumers. The actual reason startup cannot progress—CPU scheduling, memory pressure, I/O, admission/connection pressure, or another shared wait—still needs onset measurements. This is not evidence that each failed cron function ran for the startup interval. |
| What proves/disproves suspected causes? | The chronological tests and discriminator table below eliminate several single-feature explanations; none establishes CPU, swap, disk, lock chain or global connection exhaustion. |
| Which resource/code needs correction? | No specific initiating resource or SQL is proven, so no compute, pool, timeout, index, cron or trigger correction is justified by this pass. Verified dispatch/retry amplification corrections already exist locally in the blocker resolution; their production deployment remains separately gated. |
| What local fix was made? | **No new application/SQL behavior fix.** Added sanitized evidence, reproducible offline chronology checks and a review-only onset wait snapshot. All 16 prior coordinated candidate/dependency hashes remain unchanged. Tests passing would not establish the live cause. |
| Most decisive missing measurement? | **A timestamped per-backend wait/blocker trace at the first latency rise**, with query identity/start time, correlated to host resource series. It would distinguish lock blockers, I/O waits, connection admission and runnable backends; no-wait samples alone do not prove CPU saturation. Historical export/support retrieval comes first; future sampling cannot retroactively prove either incident. |

**The initiating cause remains unproven. This investigation is not declared successful merely because evidence checks pass.** The new findings below narrow the failure boundary and identify precisely what measurement must resolve it.

## Sources, timing and inspection budget

Read Parts [1](PART_1_DATABASE_ROOT_CAUSE.md), [2](PART_2_REALTIME_GPS.md), [3](PART_3_DISPATCH_CRON.md), [4](PART_4_CHAT_NOTIFICATIONS.md), [5](PART_5_FINAL_VERIFICATION.md), the consolidated report and [blocker resolution](WAYDROP_BLOCKER_RESOLUTION_REPORT.md). Those fixes were not rewritten.

November 1 reuses the existing [database/service events](root-cause-20261101/INCIDENT_LOGS.json), [gateway/history evidence](root-cause-20261101/PART_1_EVIDENCE.json), [dispatch traces](dispatch-cron-20261102/INCIDENT.json), and [resource-signature search](root-cause-20261101/PART_1_EVIDENCE.json). **No new November 1 log scan.** Existing filenames containing `20261102` mostly date the investigation, not a second production incident; no saved second-incident raw capture was found before this pass.

November 2 uses [INCIDENT_2_SELECTED.json](recurring-slowdown-20261102/INCIDENT_2_SELECTED.json): one successful filtered query over **06:44–07:00 UTC**, selected PostgreSQL/PostgREST/Realtime events and gateway requests >=1 second or HTTP >=500, limit **320**. A preceding malformed query used `message` instead of the documented `event_message`; it returned a schema error and no evidence. It was corrected once, not polled. The successful query **hit its limit**: its ordered prefix ends **06:58:51.495639**, so late-window completeness is not claimed. All counts here refer to that retained prefix; they are not full-window rates or concurrency counts. It includes the critical interval. Query parameters, quoted SQL literals, UUID values and storage object paths are omitted/redacted; no push token or message body is retained.

One bounded SQL [post-incident snapshot](recurring-slowdown-20261102/POST_INCIDENT_SNAPSHOT.json) at **12:40:20.541 IST / 07:10:20.541 UTC** and one project metadata read were performed. A second read-only cron-history lookup was cancelled by its scoped **2,500 ms** statement timeout; it was **not retried**. That inspection-generated cancellation happened after the incident and is explicitly [recorded separately](recurring-slowdown-20261102/CRON_INSPECTION_ATTEMPT.json), not attributed to the incident. No `EXPLAIN ANALYZE`, broad log retry, stats reset or production benchmark.

**Timestamp discipline:** gateway `timestamp` is retained as an observation clock; this capture does not independently establish its arrival/completion semantics. No HTTP start is inferred by subtracting duration. PostgreSQL errors are cancellation/error observations, not query starts. Cron launcher messages are not function execution durations. Where PostgreSQL explicitly logs completed duration, subtracting it is identified separately: November 1 Realtime duration 13,798.532 ms, completed 16:32:33.663, implies approximately **16:32:19.864468** start for that operation; it does not move Realtime before the earlier broad slowdown. Ingested PostgREST batches can contain earlier embedded timestamps. No request-ID join establishes that every gateway error is a particular PostgreSQL event.

## Incident 1: November 1 chronology

| UTC / IST | Observation and causal value |
| --- | --- |
| 16:22:00 / 21:52:00 | Cron 5/1 execute in 11.428/8.797 ms. Useful retained within-window baseline. |
| 16:23:11–16:24:41 / 21:53:11–21:54:41 | Early PostgREST worker timeout-manager events; without corresponding SQL/request, they cannot identify onset or its cause. |
| 16:24:59.761 / 21:54:59.761 | Audit duplicate key `unique_order_rider_assignment`; verified dispatch amplifier, not proof of database-wide initiation. |
| 16:25 minute / 21:55 minute | 473 gateway records, maximum 864 ms. Increased arrivals precede severe latency, but average ~7.9 requests/sec is not a measured capacity threshold. |
| 16:30:00.504–.633 / 22:00:00.504–.633 | Five scheduled jobs still complete in 20–127 ms. |
| 16:30:36.377–16:31:24.727 / 22:00:36.377–22:01:24.727 | Checkpoint: 419 buffers, paced write phase 48.273 sec, sync 13 ms. Overlap is not proof of saturated disk. |
| 16:30:49.270–.292 / 22:00:49.270–.292 | Selected users/KYC/orders reads take 10.1–14.0 sec, including an Edge-originated read. These predate the main Chat burst in the recorded chronology. |
| 16:31:55.690–16:31:58.513 / 22:01:55.690–22:01:58.513 | Slow Chat successes and failures; maximum origin/upstream 58,813/58,692 ms. |
| 16:32:25.819754 / 22:02:25.819754 | First retained `PGRST003`: REST pool acquisition failure, not proof global `max_connections` was reached. |
| 16:32:29.922 / 16:32:32.507 / 22:02:29.922 / 22:02:32.507 | `57014`, including actual generated Chat INSERT. Trigger/wait breakdown absent. |
| 16:32:33.663 / 22:02:33.663 | `realtime.list_changes` completed in 13.798532 sec; outer Function Scan only. |
| 16:32:36.882–16:32:48.551 / 22:02:36.882–22:02:48.551 | Cron 7 startup failure, 11.669184 sec from retained run history; later than broad slowdown. |
| 16:33:07.407–16:33:17.063 / 22:03:07.407–22:03:17.063 | Cron 5 executes successfully in 9.656285 sec, followed by Auth timeout evidence and more SQL cancellations. Part 1's Auth 504/gateway 200 discrepancy remains unresolved. |

The retained evidence can identify slow operations and later propagation, not the first resource-consuming operation. Historical cumulative Realtime/GPS/matching counts do not date their cost to this onset.

## Incident 2: November 2 chronology

| UTC / IST | Exact observation and causal value |
| --- | --- |
| 06:44:00–06:46:00 / 12:14:00–12:16:00 | Cron launcher start/completion pairs generally tens to hundreds of ms. These are launcher-observed spans, not isolated SQL execution times. |
| 06:45:22.632–.964 / 12:15:22.632–.964 | Checkpoint writes four buffers, 0.333 sec total, 4 ms sync. |
| 06:46:21.574–.932 / 12:16:21.574–.932 | Realtime tenant/replication initialization; connection check 186 ms. It occurs before slowdown, but there is no fanout/WAL/resource spike measurement making it the initiator. |
| **06:48:43.405 / 12:18:43.405** | First selected >=1-second gateway record: dispatch_config GET 4,865 ms / upstream 4,843 ms. |
| **06:48:44.986–06:48:45.149 / 12:18:44.986–12:18:45.149** | Users, riders, KYC and orders reads already 4.1–6.7 sec. Shared degradation is visible before the critical 12:21–22 interval. |
| 06:49:06.961 / 12:19:06.961 | `23505` audit INSERT, same constraint as November 1. This particular error **follows** the first broad slow observations, so it cannot be their preceding trigger. |
| 06:50:01.123–06:50:04.123 / 12:20:01.123–12:20:04.123 | Jobs 6/5/1/10 launch and complete; observed spans around 2–3 sec, unlike earlier subsecond pairs. This is an additional consumer showing impaired progress before peak errors. |
| 06:50:22.608–06:51:15.608 / 12:20:22.608–12:21:15.608 | Checkpoint 518 buffers, write 52.926 sec, sync 19 ms, total 53.002 sec. Starts after the first broad slow reads. No read latency/device queue trace. |
| 06:51:42.821 / 12:21:42.821 | Assignment POST: 27,937 ms origin, 26,188 upstream, HTTP500; actual INSERT/upsert query retained separately in PostgreSQL. |
| 06:51:46.322–06:51:47.680 / 12:21:46.322–12:21:47.680 | Riders GET 42,395 ms; users GET 39,865 ms/500; orders GET 39,653 ms/500 and another 46,634 ms/200. Successful simple reads are also delayed. |
| 06:51:52.687 / 12:21:52.687 | Riders PATCH 39,743 ms. Affected workload includes both reads and writes. Its body is not available, so it is not automatically classified as GPS. |
| 06:52:00.503 / 12:22:00.503 | Backend **878768**, `57014`: generated `INSERT ... rider_assignments ... ON CONFLICT(order_id,rider_id) DO UPDATE`. No blocker/wait sample identifies where it stalled. |
| 06:52:09.870 / :11.252 / :11.949 / 12:22:09.870 / :11.252 / :11.949 | Jobs **7, 5, 1** report **job startup timeout**. Jobs 5/1 are already-starting or failed before a successful SQL execution can be established. Do not call this three expensive completed cron queries. |
| 06:52:11.620 / .786 / 12:22:11.620 / .786 | Two SSL accept connection resets. Consistent with abandoned connection attempts; no proof they belong to a particular cron invocation or that connection slots were full. |
| 06:52:12.262 / :18.937 / 12:22:12.262 / :18.937 | Two further PostgreSQL `57014` events; statements absent from those selected records. PostgREST reports orders/users HTTP500, including the push preference projection. |
| **06:52:29.197 / 12:22:29.197** | Backend **3006625** times out on `SELECT sum(calls), sum(total_exec_time/1000) FROM extensions.pg_stat_statements ... JOIN pg_database`. Later snapshot identifies the same PID as **postgres_exporter**. This adds managed monitoring to the affected consumers; it does not prove the monitoring query started the incident. |
| 06:52:41.271 / 12:22:41.271 | A cron 7 completion message appears after the startup failure. There is no complete run-ID join, so it is not assigned to the failed run. |
| 06:53:00.886–06:53:04.286 / 12:23:00.886–12:23:04.286 | Cron 5 completes again; later cron 7 pair is subsecond. Gateway samples continue at 1–6 sec through the retained prefix. Recovery is uneven, not an immediate universal return to baseline. |

The retained prefix exactly reproduces the supplied **16 requests >20 sec and three HTTP500s**. It contains **four** PostgreSQL 57014 observations: assignment upsert, two unspecified statements, and monitoring. This is a selected-event count, not every cancellation in the database. A second-incident `PGRST003` is not present in this capture.

## Exact operations and source attribution

| Operation | Source / frequency / attribution limit |
| --- | --- |
| Assignment INSERT/upsert | Incident SQL is in `INCIDENT_2_SELECTED.json`, PID 878768, 06:52:00.503. Matching producer shape: captured `dispatch-cron-20261102/production-start-dispatch.ts:622`; audit INSERT at 649; nearby RPC at 454; main loop 298 and wait loop 673. Request duration 27.937 sec is gateway wall time, not isolated INSERT CPU. Missing invocation identity prevents claiming this uniquely identifies one Edge invocation. |
| Duplicate audit INSERT | Incident 2 at 06:49:06.961 and incident 1 at 16:24:59.761. Captured worker line 649; captured rider core `assign_nearby_searching_orders_core.captured.sql` audit/re-offer branches around 158–284. Verified duplicate-work defect; no onset resource accounting. |
| Rider-centric nested matching | `final-verification-20261102/new_order_core.production.sql:38` loops riders; `dispatch-cron-20261102/assign_nearby_searching_orders_core.captured.sql:57` loops searching orders. Cron and trigger paths can amplify work. Historical nearby mean 228.459 ms/max 12,089.528 ms is not this incident's latency or frequency. |
| Cron recovery/startup | Captured `redispatch_stalled_searching_orders.captured.sql:36/49`, `redispatch_freed_riders.captured.sql:15`; expiry job 1 uses `expire_stale_searching_orders`. Known schedules: minute / 45 sec / two minutes. Different jobs and triggers may overlap, but each scheduled job is serialized by pg_cron. Startup failure is not proof of matching cost. |
| Managed monitoring | Exact pg_stat_statements aggregate above, PID 3006625. Later application name provides a PID association, not a historical session-start guarantee. It is not a Flutter call site and its frequency/start/duration are not retained. Do not disable the exporter on this evidence. |
| GPS trigger chain | `lib/core/services/location/location_cache_service.dart:569/589/695` gates and PATCHes rider coordinates/freshness; captured bridge UPSERTs rider_locations and can trigger the near-destination lookup. One row update can create downstream work; incident 2 PATCH body/rate is unknown. Preserve live tracking. |
| Chat/notification path | `chat_message_delivery.dart:74/146` → Chat INSERT → captured `on_new_chat_message.production.sql:16/22/47` → inbox → `deliver_push_notification_http_fnc.production.sql:44` async enqueue. FCM does not synchronously hold the Chat transaction for its network delivery. Push users-preference/device-token GETs are additional slow victims, not proof of provider-caused DB starvation. |
| Client repeat reads/retries | `lib/features/user/home/home_tab.dart:698`, `notification_badge_service.dart:38/64`, chat delivery above. Current local coalescing/backoff/outbox fixes and blocker protocol are preserved. No production Flutter build provenance establishes that local fixes were running during incident 2; no retry storm count is manufactured. |

The captured production sources are earlier read-only snapshots. Current local `supabase/functions/start-dispatch/index.ts` now uses the reviewed fenced protocol; do not attribute its current line numbers/behavior to the earlier deployed worker.

## What the evidence actually discriminates

| Candidate | Evidence test and verdict |
| --- | --- |
| One Chat trigger / synchronous FCM wait | **Insufficient as a common explanation.** Broad reads precede Chat burst on November 1, other consumers fail on November 2, and outbound FCM is async after pg_net enqueue. Inner synchronous trigger SQL can still amplify DB work. |
| Only PostgREST pool exhaustion | **Insufficient alone.** November 1 pool failure is real; November 2 monitoring SQL and cron startup are outside that single REST pool. A server-wide cause can fill the pool secondarily. Global connection exhaustion remains unproven. |
| Cron background-worker slot exhaustion | **Unsupported.** At 12:40, `cron.use_background_workers=off`, max_worker_processes=6, cron.max_running_jobs=32. In default connection mode cron uses database connections, not that background-worker slot limit. Settings are a later snapshot, not independently historical; no actual incident worker-slot count. [pg_cron behavior](https://github.com/citusdata/pg_cron). |
| One order/assignment row lock | **Not a sufficient standalone mechanism for all plain reads/startup.** MVCC reads do not generally wait for ordinary row-update locks. A broader heavyweight lock queue, shared lock, or multi-relation transaction remains possible. No retained blocker PID/wait relation, and no positive lock-wait log. |
| CPU/compute scheduling or throttling | Fits delayed SQL, startup and monitoring, but no incident CPU/user/system/steal/run-queue/throttle measurements. **Not proven.** Compute size is not returned by project metadata; no tier inferred from shared_buffers. |
| RAM/swap pressure | Fits global progress issues, but no available-RAM, paging-rate or commit-pressure measurements. Absence of an OOM message does not prove absence of swapping. **Not proven.** |
| Disk I/O / checkpoints / temp spill | Repeated checkpoint overlap is real, but paced elapsed write time and 13/19 ms sync do not establish device saturation. November 2's slow reads precede this checkpoint. Cumulative temp bytes since May cannot date a spill to onset. **Not proven.** |
| Realtime/GPS/dispatch/retries | Verified multiplication mechanisms and local counterexamples exist. No measured incident fanout, WAL rate, same-order concurrency or initiating resource occupation. **Amplifiers; contribution unquantified, not proven initiators.** |
| Administrative/managed query initiates | Exporter timeout proves it is affected; cumulative introspection spill history does not prove initiation. No corresponding query start/wait/CPU timeline. **Unproven**, not excluded. |
| Database restart/crash | Postmaster is still May 7 in the later snapshot; no restart in the retained windows. This weighs against a full postmaster restart explanation, not against stalls or individual backend failures. |

Post-incident snapshot: max_connections **60**, database numbackends **23** (includes the inspection); no blocked sessions, no active client SQL among other sampled sessions, no idle-in-transaction session. An active WAL sender was waiting for WAL, not demonstrated to be executing a long query. Two active logical slots each retained about **16.76 MB** at that later instant. **None clears the historical incident.** `track_io_timing=off`, `track_functions=none`, `log_min_duration_statement=-1`; pg_stat_monitor/pg_wait_sampling are not installed. Consequently these sources cannot supply historical per-query waits, function times or disk latency. [PostgreSQL activity/statistics semantics](https://www.postgresql.org/docs/17/monitoring-stats.html).

## Dashboard access and exact export request

The user supplied the production dashboard link and confirmed there is **no verified local export path**. Browser inventory returned `apps=[]`, `browsers=[]`; trying the supplied URL returned **“No browser is available.”** No signed-in chart was inspected, and no series' historical availability/retention is assumed. Project metadata says currently ACTIVE_HEALTHY, not which resource was healthy at onset.

Open [project Reports](https://supabase.com/dashboard/project/yvwpchffctiagevpqgwy/reports) → Database. Export available raw samples, or screenshot each chart with its legend, units, time-zone label, resolution and tooltip values just before/on/after the rise. Use identical windows across charts:

- **November 2:** 06:44–07:00 UTC / 12:14–12:30 IST; zoom 06:48:30–06:53:00 UTC.
- **November 1:** 16:20–16:36 UTC / 21:50–22:06 IST; zoom 16:30:00–16:33:30 UTC. Original incident is 16:22–16:34 UTC; wider export supplies baseline/tail.

| Exact chart / location to capture | Required values and caveat |
| --- | --- |
| **CPU usage** | Total plus user/system/IOWait/other breakdown; steal/throttle/burst-credit data if provided. Keep maxima/native resolution, not only a long-window average. |
| **Memory usage** | Used, cache/buffers, free/available and swap, where exposed. Swap-in/out or page-pressure series if retained elsewhere. Missing Swap legend is not independently a zero measurement. |
| **Disk IOPS** | Read/write values and displayed capacity line. Include throughput, read/write latency and queue depth if available elsewhere; IOPS alone cannot identify latency saturation. **Disk usage** measures capacity, not I/O latency. |
| **Database connections** | All role/service series and limit. Active/waiting/idle breakdown and connection acquisition queue if exposed; total connections alone cannot separate execution from waiting. |
| **Dedicated Pooler / Shared Pooler connections**, if used/available | Client/server/queued counts and limit. These are not automatically the internal PostgREST SQL pool; retain PostgREST borrowed/waiting/acquisition data separately if available. |
| Project **Compute and Disk** settings | Current compute size, vCPU/RAM and disk capacity/performance limits; indicate any size change near either incident. Current size alone does not prove historical entitlement. Do not change settings. |

These names follow [Supabase Reports](https://supabase.com/docs/guides/observability/reports); chart detail and retention depend on the account/plan. If a requested series/window is missing, record **unavailable**, rather than assuming it exists or buying an upgrade. Compare resource **first-rise timestamps** with the early broad read observations, not only the peak error minute. A simultaneous coarse-resolution spike is correlation and may still need wait samples.

If charts lack those histories, request a **read-only support evidence export** for the two windows: per-backend wait/blocker/query-start samples and host scheduling/memory/device latency, incident-time compute entitlement, connection-admission failures, and exporter health around PID 3006625 at 06:52:29.197. No support message was sent by this agent. [Metrics API](https://supabase.com/docs/guides/observability/metrics) exposes a scrape feed; it is not a time machine. Do not request new service credentials or start a collector expecting it to reconstruct November 1/2. No secret key was retrieved here.

## Safe checks, preservation and next action

Run `python docs/performance/recurring-slowdown-20261102/analyze_evidence.py` for **offline** checks: event counts, source boundary, truncation, timestamp ambiguity, explicit-duration subtraction, exporter PID association, privacy redaction and unchanged hashes for all 16 prior coordinated candidate/dependency files. Result: **PASS**, [ANALYSIS.json](recurring-slowdown-20261102/ANALYSIS.json). These are evidence consistency checks, not live-load tests. No Flutter/Edge/SQL implementation changed, and no full regression suite was rerun or counted as fresh evidence. Prior 2,118 Flutter passes/17 native groups/15 Edge checks remain historical results.

No likely initiating operation was identified strongly enough to justify a causal load reproduction or an application correction. Generating CPU, disk, lock or connection pressure in production would be unsafe and would not reconstruct the historical event. Existing local blocker reproductions prove their own races/amplification, not why this database node stalled.

For a future recurrence, the review-only [ONSET_WAIT_SNAPSHOT.review.sql](recurring-slowdown-20261102/ONSET_WAIT_SNAPSHOT.review.sql) names the minimum missing measurement: PID/backend start, query ID/fingerprint/start, transaction start, state, wait event and blockers, with no raw SQL/user payloads and a 1.5-second per-read ceiling. It was **not executed or scheduled**. An approved short external collector can take one snapshot/second with a fresh transaction, retain failed-sample timestamps, and correlate with existing host charts. The query needs existing stats visibility; no grants/extensions/settings are installed. It cannot itself measure host CPU, swap or disk latency. A nonresponsive database can prevent sampling; support-side host evidence remains necessary then.

**Next practical action is the chart export above**, followed by a chronological resource comparison. Until it arrives, it would be fabrication to name CPU, disk, a specific SQL query, or a compute tier as the confirmed initiator. Preserve existing local safety fixes and production read-only status; do not increase connection limits/timeouts, disable fallbacks/Realtime, remove indexes or upgrade compute on this evidence alone.


## Live follow-up: persistent slowness reported, November 2 at 13:55 IST

The user clarified that the app is slow "all time" and confirmed a **release APK 1.0.0 (54)**. This follow-up distinguishes routine loading from the earlier 20?46-second incidents. It does not claim a healthy idle sample explains the phone experience.

**Fresh read-only production evidence:** [live database snapshot and selected Edge versions](recurring-slowdown-20261102/LIVE_DATABASE_1355.json), sampled at **13:55:58.150 IST**. Four other client backends, zero active client SQL and zero blockers; max_connections=60. These counts exclude the inspection session and are not a history of activity. Maintenance=false and booking/notification feature flags enabled. All three new durable protocol RPCs are absent. Deployed versions remain start-dispatch **72**, accept-order **60**, create-order **78**, reject-order **18**, push **24**, cancel-order **37**. Local fixes therefore must not be described as already deployed. This inspection changed nothing in production.

The exporter PID 3006625 now has a recorded backend_start of **September 8, 16:32:41 IST**, before the November 2 incident. Its continued existence as postgres_exporter strengthens the earlier timeout attribution and removes the ordinary same-PID-reuse concern for this observed connection; it remains an affected query, not a proven initiator.

**Six sequential public HTTP GETs**, using only the existing anon key, from this Windows host at approximately **13:57 IST**: [timings](recurring-slowdown-20261102/LIVE_HTTP_1355.json). No user session, personal row or response body retained. These are small samples, not percentile estimates or phone measurements.

| Public endpoint | First request, new connection | Next two, reused connection | Upstream header values |
| --- | ---: | ---: | --- |
| production_config, two fields / one row | 1,169.74 ms | 114.69 / 80.28 ms | 436 / 12 / 6 ms |
| Auth public settings | 537.54 ms | 89.30 / 83.31 ms | 80 / 1 / 2 ms |

All six returned HTTP200. First configuration connection setup took 217.85 ms, but this alone does not explain the full first-request duration. Upstream headers are not isolated SQL execution measurements. Results do not reproduce a continuous 20-second outage on these public endpoints, and do not establish authenticated/RLS requests or the handset network are fast.

### Newly reproduced startup request amplifier, fixed locally

`lib/core/services/session/account_profile_service.dart:91?108` wraps an Auth/profile HTTP future with a three-second Future.timeout, then previously treated that TimeoutException as permission to retry after backoff. Future.timeout does not abort the HTTP request. Consequently another HTTP read can start while the original is still pending. The same `_read` path serves authoritative Auth verification and profile loading, which startup awaits (`app_start_screen.dart:125?181`). This is a verified source-level cause of **extra startup requests during slow responses**, not evidence that it starts the historical database stall or explains all normal-day phone latency.

Two actual-service regressions at `test/startup_account_schema_regression_test.dart:194` independently hold Auth and profile responses open and advance the three-second deadline. **Before: both fail, expected one outstanding send, actual two. After: both pass, one send and a bounded TimeoutException, no retry delay.** Auth timeout still prevents the profile request; no eligibility/session verification is bypassed. Completed HTTP503/network failures keep their existing bounded 500/1,000 ms retry policy.

Minimum correction at `account_profile_service.dart:108`: rethrow TimeoutException before the automatic retry branch. This stops automatic overlap caused by this loop; it **does not cancel the original request**, and does not claim all explicit manual retries or every SDK-internal retry have single-flight ownership. A broader request-cancellation/credential-generation design is separate work, not silently introduced here.

Verification: focused startup/session/loading suite **39 passed, zero failed**; full Flutter **2,120 passed, zero failed** (previous 2,118 plus these two tests). Original failed regressions are retained in `.dart_tool/waydrop-local-runtime/live-startup-timeout-before.log`; focused/full logs in `live-startup-focused.log` and `live-full-flutter.log`. No tests removed or skipped. Analyzer outcome is recorded in the live verification artifact. No SQL/Edge implementation was changed by this follow-up. Existing 17 native / 15 Edge results are historical and were not rerun as new proof.

The current workspace release artifact has version 1.0.0/build54 and timestamp 12:11:54 IST; the new fix was made after 14:00. Neither the APK nor production was rebuilt/deployed/installed during this check. Matching version numbers alone do not prove the handset APK has the same source/hash. The device inventory contains Windows/Chrome/Edge, **no Android device**, so no physical startup, API/body, GPS, map or frame timeline was captured. Existing `PerformanceTrace`/`ApiMetricsClient` and opt-in profile export can separate these phases once an authorized handset is connected; do not infer them from these desktop GETs.

**Remaining causal gap:** ordinary persistent slowness on the user's release54 still needs a handset trace and installed artifact provenance. The original incident still needs onset host/wait measurements. The verified retry amplifier is corrected locally, but neither unresolved cause is declared solved. Follow-up production budget: one bounded SQL snapshot, one Edge inventory read, six harmless public GETs, zero log queries, zero production writes, zero paid resources.

Live verification: [LIVE_CHECK_VERIFICATION.json](recurring-slowdown-20261102/LIVE_CHECK_VERIFICATION.json). Targeted analyzer for the two changed files: **no issues**. The full analyzer stalled and its own process was stopped; that attempt is not reported as a pass. Full Flutter compiled and passed all 2,120 tests. Minimal implementation diff: [STARTUP_TIMEOUT_MINIMAL.patch](recurring-slowdown-20261102/STARTUP_TIMEOUT_MINIMAL.patch).
