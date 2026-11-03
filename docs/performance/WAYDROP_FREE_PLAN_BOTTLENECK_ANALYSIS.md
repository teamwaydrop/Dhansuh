# Build 55 slowness: application, Storage and compute evidence

Investigation date: 2 November 2026. Project: `yvwpchffctiagevpqgwy`. This investigation was **read-only in production**. No migrations, deployments, settings, paid resources or new test project. Prior authorized independent deployments remain in place; the combined worker/acceptance/push candidates remain gated.

## Verdict

**UNRESOLVED — MISSING CRITICAL EVIDENCE** for the overall Free-plan-versus-infrastructure cause and the initiating November database-wide slowdown. This is not a finding that the app is healthy: the supplied Build 55 test interval exposes concrete slow foreground uploads and REST tail latency, and a separate reproducible client request amplifier has been fixed locally.

The strongest verified slow stage during the new test is **Supabase Storage POST processing observed by the gateway: 8.635–22.676 seconds**. A booking image of only 19,751 request bytes took 19.148 seconds. Rider proof upload is awaited before verification processing. This explains a real waiting stage in those flows; it does not identify whether body transfer, Storage infrastructure, authorization/database work or network conditions caused the elapsed time. It does not explain every screen. Increasing PostgreSQL compute is not a demonstrated remedy for these uploads.

The historical memory and I/O samples support concern about resource pressure on a Free/Nano-class deployment, but do not establish active swapping, a depleted I/O budget, or which resource constrained first. No confirmed CPU execution saturation. No evidence that a monthly Log Query allowance caused data-plane timeouts.

## The user's Build 55 test: 15:51–16:00 IST

The user supplied this interval on November 2: **10:21–10:30 UTC**. One bounded aggregation returned 69 groups below its 100-group cap; two small follow-ups classified slow uploads and audit conflicts. Sources/queries/results are retained in [BUILD_55_WINDOW.json](free-plan-analysis-20261102/BUILD_55_WINDOW.json), [targeted detail](free-plan-analysis-20261102/BUILD_55_TARGETED_DETAIL.json), and [flow classification](free-plan-analysis-20261102/BUILD_55_FLOW_CLASSIFICATION.json). No broad log scan was run.

These are project-wide observations. `Dart` identifies a user-agent family, **not this phone, build or session**. The gateway records 1,986 requests, including 957 Dart requests; 90 Dart requests took at least one second, six at least five seconds and one at least twenty seconds. These totals cannot establish requests per user or redundant requests. Origin duration is a gateway measurement, not a handset stopwatch or a network-throughput measurement.

| Dart request group | Requests | Median ms | p95 ms | Maximum ms |
|---|---:|---:|---:|---:|
| orders GET | 249 | 50 | 2,045 | 7,996 |
| riders GET | 142 | 72 | 3,153 | 5,050 |
| rider_assignments GET | 137 | 54 | 1,914 | 5,017 |
| rider KYC GET | 37 | 107 | 2,979 | 3,567 |
| users GET | 47 | 67 | 2,200 | 3,090 |
| notifications HEAD | 55 | 38 | 2,959 | 3,560 |
| dispatch_config GET | 70 | 22 | 680 | 2,190 |
| Auth user GET | 4 | 188 | 590 | 590 |

Per-group exact quantiles; do not average these p95 values. Mostly fast medians with multi-second tails differ from the morning database-wide outage. There are no gateway 5XX/timeout matches or PostgreSQL `57014` events in these retained groups. This does **not** mean zero errors: three audit HTTP 409 responses occurred. Eight PostgREST Warp timeout-manager events occurred, without proof that each represented a failed SQL request. This gateway aggregation does not count every Edge invocation or prove absent failures in unqueried sources.

| UTC timestamp / IST timestamp | Upload flow | Duration ms | Request bytes | Status |
|---|---|---:|---:|---:|
| 10:24:39.697 / 15:54:39.697 | parcel booking image | 19,148 | 19,751 | 200 |
| 10:25:28.682 / 15:55:28.682 | pickup verification | 8,635 | 690,122 | 200 |
| 10:25:57.119 / 15:55:57.119 | dropoff verification | 22,676 | 544,967 | 200 |

Object names and private identifiers are omitted. Request bytes are not necessarily decoded image size. A small request being slow rules out treating large-image compression alone as an adequate explanation. No unsupported upload timeout/retry or bypass was added: a timed-out upload may already have succeeded, and order proof must remain authoritative.

Three Deno audit POSTs returned 409 at 10:21:17.956, 10:25:09.106 and 10:26:59.005 UTC, taking 42, 63 and 623 ms. Adjacent PostgreSQL `23505` records identify `unique_order_rider_assignment` on audit INSERTs. These demonstrate residual conflict work, not a 20-second bottleneck. The captured deployed start-dispatch source has a compatible blind audit insert at [production-start-dispatch.ts:649](dispatch-cron-20261102/production-start-dispatch.ts#L649); no invocation-ID join proves it was the unique writer. Previously deployed SQL-core conflict handling does not change this Edge path. The local coordinated dispatch candidate already handles audit deduplication; it was not activated or rewritten here.

## Exact implementation paths and remaining boundaries

| Flow / source | Causal relevance and status |
|---|---|
| `lib/features/local_parcels/services/parcel_upload_service.dart:11–47` | File uploads start concurrently; `Future.wait` waits for the slowest upload before returning URLs. Verified upload waiting stage; underlying Storage cause unresolved. |
| `lib/features/rider/orders/screens/rider_active_order_screen.dart:422–490` | Camera → bytes → awaited `uploadBinary` at line 440 → location/device work → `process-verification-photo` at line 457 → verification reload/OTP. Slow upload necessarily delays later proof work. Do not skip security checks. |
| `lib/main.dart:84`; `lib/app_start_screen.dart:125–181` | Initialization precedes rendering; startup config/profile work is parallelized. Auth/profile routing remains authoritative. No handset startup/frame sample was captured. |
| `lib/features/user/home/home_tab.dart:698,793` | Existing profile reuse and parallel secondary reads preserved. Slow members can delay completion; no measured screen-level duration or unjustified query removal. |
| `lib/features/rider/home/rider_home_tab.dart:163,173,379–428` | Existing earnings coalescing preserved. Rider and then earnings reads have eight-second timeout budgets; the possible serial budget is not a measured 16-second journey. |
| `lib/core/services/session/account_profile_service.dart:108` | Previous non-cancelling timeout retry correction is in the Build 55 source context. Manual retry ownership/cancellation is not declared solved. |
| `lib/core/services/location/location_cache_service.dart:399,569,589,695` | Existing single tracker and movement/heartbeat gates preserved. Nine rider PATCHes in this interval are not all proven GPS. Trigger/Realtime work remains an amplifier candidate, not the incident initiator. |
| `lib/modules/chat/screens/order_chat_screen.dart:1162–1213` | Existing coalesced history merge and stable-send/outbox fixes preserved. No measured chat send/history latency for this phone in this interval. Pagination/deadlines remain follow-up concerns. |
| Captured production `start-dispatch` lines 298,454,622,649,673 | Existing polling, matching, offer and audit operations remain in v72. Current local source is a different coordinated protocol and is not proof of deployed behavior. |

Acceptance, matching, RLS, chat INSERT → notification → push trigger chains, GPS bridge/index and cron findings remain documented in Parts 1–5. This investigation does not relabel historical cumulative SQL statistics as new root-cause evidence. No new plan, index, policy, publication, trigger or cron modification is justified by this interval alone.

## New defect reproduced and fixed locally

**Confirmed request amplifier:** [production_config_service.dart:74](../../lib/core/services/config/production_config_service.dart#L74). The documented once-per-session configuration attempt was marked complete only on success. A completed failed fetch used cached/default configuration but every later routine `init()` fetched again. Concurrent calls were already coalesced; sequential calls after failure were not.

The minimal correction marks the session attempt complete in `finally` at lines 84–88, before clearing the shared in-flight future. Explicit `refresh(force: true)` still retries. Cached maintenance, forced-update and notification gates survive failed refresh; server authorization, KYC, payments and acceptance are unchanged. This preserves the existing fallback policy rather than introducing a new fail-open policy.

[production_config_failed_init_test.dart:89](../../test/production_config_failed_init_test.dart#L89) uses the actual service, Supabase SDK and stub HTTP transport, with temporary encrypted configuration cache. Three tests cover shared failure plus eight sequential callers, explicit retry and cached gates, and a missing active row.

| Verification | Before | After |
|---|---|---|
| Failed fetch followed by eight routine init calls | **9 HTTP reads** | **1 HTTP read** (88.9% reduction in this reproduction) |
| Three new tests against original source | 2 passed, **1 expected failure** | 3 passed |
| Focused startup/config regression suite | — | **85 passed, 0 failed** |
| Full Flutter regression suite | Previous run 2,120 passed | **2,123 passed, 0 failed** |
| Analyzer on the changed service and test | Initial new-test style info corrected | **No issues**, exit 0 |

Logs: `.dart_tool/waydrop-local-runtime/free-plan-config-before.log`, `free-plan-config-after.log`, `free-plan-full-flutter.log`, `free-plan-analyze-final.log`. Full-project analyzer cleanliness is not inferred from the targeted analyzer. Three additional tests explain the count difference from 2,120 (and five from the older 2,118 baseline). No SQL/Edge implementation changed in this investigation, so previous native/Edge passes are historical, not newly rerun.

There was **no Dart production_config request** in the test window. Thus this is a demonstrated degraded-session defect, **not a proven explanation of that live interval**. Seventy-seven Deno configuration reads across isolates do not establish seventy-seven duplicate client requests. No measured handset speed improvement is claimed. The correction is not in Build 55 and requires a future reviewed APK.

## Historical host metrics: what the numbers establish

Source: numbers supplied in the user's request, retained in [REPORTED_METRICS.json](free-plan-analysis-20261102/REPORTED_METRICS.json). No raw chart export, resolution, aggregation or device legend was supplied; authenticated dashboard/browser access was unavailable. Calculations and limitations are reproducible with [analyze_metrics.py](free-plan-analysis-20261102/analyze_metrics.py) and [METRIC_ANALYSIS.json](free-plan-analysis-20261102/METRIC_ANALYSIS.json).

| Question | Evidence and conclusion |
|---|---|
| Was usable RAM exhausted? | 12:22 IST: physical 408.51 MB, used 249.51 MB, cache/buffers 122.1 MB. Subtraction yields 36.90 MB (9.03%) only if components are disjoint. This is **not MemAvailable**; reclaimability and allocation failures are unknown. |
| Was active paging occurring? | Swap occupied 677.26 MB does not measure swap-in/out. Inactive pages can remain swapped. No paging rate, major-fault rate or system-disk latency was supplied. |
| Did commitment cause the stall? | 1.85 GB / 1.40 GB is 132.14% commitment, a warning about commitments, not allocated resident RAM. No pre-onset trajectory, overcommit policy or allocation-failure evidence identifies direction of causation. |
| Why 32.81% IOWait? | At 12:24 IST, CPU waited for I/O during part of the sample. Device and initiator are unknown: database reads/writes, paging, temp spills or maintenance remain hypotheses. |
| CPU ceiling? | User + system = 11.46%; idle 53.62%. Reported total 44.28% may include IOWait and other components. This sample does not show execution saturation; chart definitions/rounding differ. |
| Disk ceiling or latency? | 12:18 throughput about 961.7 KB/s is below documented Nano baseline throughput, but low bytes can coexist with high IOPS/latency. No I/O budget, device latency/queue or concurrent peak sample. System disk versus data disk must be distinguished. |
| Connection ceiling or accumulation? | 23 connections at 12:18 is 38.33% of current max_connections 60. Idle versus active/waiting and peak admission are unknown. This cannot exclude a separate PostgREST pool limit. |

The three samples are at **different times** and cannot be treated as simultaneous measurements. Supabase explains occupied swap and memory accounting in [memory and swap guidance](https://supabase.com/kb/troubleshooting/memory-and-swap-usage-explained-aPNgm0); default documented swap is 1,024 MB, so 677 MB is not evidence of a 90%-full 750 MB swap device. Actual project swap capacity was not directly obtained. [I/O chart guidance](https://supabase.com/kb/troubleshooting/interpreting-supabase-grafana-io-charts-MUynDR) describes interpreting device waits; it does not identify this incident's device.

## Two outages versus the afternoon test

November 1: 16:22–16:34 UTC / 21:52–22:04 IST, critical approximately 16:32. Backend timeouts preceded the main Chat burst and cron failure. No host charts establish the initiating resource.

November 2 morning: requested incident 06:46–07:00 UTC / 12:16–12:30 IST, with prior collection starting 06:44. Retained broad reads were already slow at **06:48:43–45**, before the 06:51–53 critical period. Monitoring's pg_stat_statements aggregate timed out at **06:52:29.197** on a backend associated with postgres_exporter. Orders/users/KYC, assignment/chat writes, monitoring and cron all suffered. This is evidence of a shared backend failure boundary, not merely Flutter rendering or one Chat trigger. The 06:52 memory and 06:54 IOWait samples do not establish what happened before the earliest slow reads. A completion timestamp minus response duration is not an independently observed SQL start time. Existing retained log prefix is capped and is not the full incident.

November 2 afternoon: the user's 10:21–10:30 UTC test has Storage waits and REST tail delays, but no retained gateway 5XX or PostgreSQL statement-timeout burst. It must not be described as a measured recurrence of the identical morning mechanism. Neither memory nor I/O charts for this afternoon interval were obtained.

## Live configuration versus documented plan limits

Connected metadata confirmed organization **Free / tier_free**, project active/healthy, region ap-south-1, PostgreSQL 17.6.1.113. Metadata did not return an independent `instance_size`; **Nano-class is a plan/documentation inference**, consistent with reported memory, not an obtained compute-size field.

The lightweight SQL snapshot at **16:08:16 IST**, after the test, found max_connections 60; shared_buffers 224 MiB; work_mem 2,184 kB (~2.13 MiB per applicable operation); maintenance_work_mem 32 MiB; effective_cache_size 384 MiB (**planner estimate, not allocated memory**). Twenty-one client backends were idle/ClientRead; no blocked backend. Active walsender was waiting for WAL, not executing a long SQL query. Both logical slots were active with approximately 5.4 KB retained each at that instant. This does not measure historical WAL rate or clear an earlier incident.

`track_io_timing=off`, `track_functions=none`, `log_min_duration_statement=-1`; zero accumulated I/O time is not zero physical I/O. Temp bytes 1,532,212,209,261 and 373,996 files accumulated since May 1 are not an incident-specific workload. Cron background-worker mode is off, cron max running jobs 32; cron startup timeout does not establish worker-slot exhaustion. No peak wait graph, autovacuum timeline or historical lock holder was available. Exact snapshot: [LIVE_DATABASE.json](free-plan-analysis-20261102/LIVE_DATABASE.json).

Fresh Edge metadata: start-dispatch **72**, create-order **78**, accept-order **60**, push **24**, reject-order **19** ([versions](free-plan-analysis-20261102/EDGE_VERSIONS.json)). Do not confuse local fenced sources with these deployed versions. Prior independently deployed SQL audit dedup/empty-sweep and RPC ACL changes remain documented in [authorized rollout](WAYDROP_AUTHORIZED_ROLLOUT.md).

## Free Nano versus paid Micro and Small

Official documentation checked November 2. The following are documented limits, not measured throughput of this project. [Compute and disk specifications](https://supabase.com/docs/guides/platform/compute-and-disk):

| Item | Free Nano | Micro | Small |
|---|---:|---:|---:|
| RAM | up to 0.5 GB | 1 GB | 2 GB |
| CPU | shared | shared | shared |
| Compute charge/month, approximately | $0 | $10 | $15 |
| Baseline disk MB/s | 5 | 11 | 22 |
| Baseline IOPS | 250 | 500 | 1,000 |
| Direct database connections | 60 | 60 | 90 |
| Pooler client connections | 200 | 200 | 400 |

Documented burst ceilings are not sustained guarantees. Budget depletion returns performance toward baseline; actual disk provisioning and compute limits interact. No measured budget balance was obtained. Default documented pool size 15 does not establish this project's actual internal PostgREST pool. Shared CPU is not a claim of two dedicated cores or a measured CPU-credit limit.

[Pricing](https://supabase.com/pricing) and [compute billing](https://supabase.com/docs/guides/platform/manage-your-usage/compute): Pro starts at **$25/month**, including $10 compute credit. For one project, approximately **$25 total/month for Micro** or **$30 for Small** ($25 + $15 − $10), before taxes, usage and billing-period variation. Increment from Free is about $25/$30, not $10/$15. Micro→Small is about $5. No purchase or resize was performed.

Monthly storage/egress/Realtime/Edge/log quotas are separate from RAM, IOPS and admission. Exact current usage/enforcement was not exposed by the available metadata; unlimited API requests do not imply every service quota is unlimited. Log Query overage is not evidence that REST/SQL was throttled. [Disk-budget troubleshooting](https://supabase.com/kb/troubleshooting/exhaust-disk-io) supports checking budgets and workload before resizing; it does not prove exhaustion here.

**Recommendation:** do not promise an upgrade cures this case. Historical resource pressure makes more memory/I/O headroom a plausible mitigation, but Small is not a substitute for identifying Storage delays or deploying a concurrency-safe worker. Micro adds RAM while retaining the documented 60 direct connections. Conditional upgrade evaluation is justified if time-aligned available-memory/paging or I/O-budget evidence confirms the constraint. No spending decision is made here.

## Free-plan options and cheapest decisive next step

1. Review the small config change and deliver a separately versioned APK after normal release checks. Preserve Build 55 as the reference. Do not claim its 9→1 synthetic request reduction measures the user's speed gain.
2. Repeat the **same booking/pickup/dropoff flow**, two or three times, recording per-stage handset times (image preparation, upload headers/body/completion, verification Edge call, subsequent reload), numeric startup/Home durations and frame timings. Existing development/profile instrumentation is disabled in release by `kReleaseMode`; production gateway data cannot reconstruct frames. Collect no tokens, object paths, messages or coordinates. A transport timeout alone cannot safely imply upload cancellation.
3. Export existing charts for **Nov 2 10:20–10:31 UTC**, and both original incidents with at least five minutes before onset. Required series: MemAvailable, resident/cache components, swap capacity and swap-in/out rates, major faults, CPU modes, per-device system/data read/write latency and IOPS/queue/utilization, throughput and minimum I/O-budget balance, active/idle/waiting connections and PostgREST queue/acquisition latency. Include resolution and legends. These distinguish paging/system-disk stalls, data-disk limits and admission pressure. A newly started metrics scraper cannot reconstruct historical measurements.
4. Correlate one slow upload by a safe request identifier with existing Storage/gateway/server timings, separating request transfer from Storage authorization/database and object-write duration. The 20 KB request taking 19 seconds makes this a higher-value test than blindly changing JPEG quality. No broad log scan or production EXPLAIN ANALYZE is needed.
5. Keep prior coalescing, GPS gates and retry fixes. Review remaining v72 audit conflicts through the already gated durable worker rollout; preserve fallback, atomic acceptance, KYC and fencing. Do not disable cron, Realtime, proof steps or notification security to reduce counts.

The user declined a new test project. Managed verification of the combined SQL/Edge protocol, old-worker drain/admission, eligibility business-rule approval, full intercity/payment and FCM crash scenarios remain explicitly blocked. This investigation does not resolve those gates. No stale-worker recovery activation, production write or automatic Part 5 restart is authorized by this report.

## Build and evidence boundaries

Reference APK: `artifacts/waydrop-1.0.0-build55.apk`, SHA-256 `0f9f687603a103878fb76b8ef1082b6e9bb42daa07037494cf3f02f277fb7904`. User reports Build 55 installed and tested; no handset artifact hash or AOT source-map attestation was obtained. Prior signer/build verification and source chronology support the reference, not proof of device identity. New config change is local only; no new APK was built. [BUILD_55_CONTEXT.json](free-plan-analysis-20261102/BUILD_55_CONTEXT.json).

Actual phone startup, Passenger/Rider Home duration, dispatch end-to-end duration, chat duration, reconnect time and frame jank remain **unmeasured**. Gateway durations above are actual measurements of their own scope. No zero or improvement is inferred from absent data. The initiating November 1 CPU/I/O cause remains unproven.
