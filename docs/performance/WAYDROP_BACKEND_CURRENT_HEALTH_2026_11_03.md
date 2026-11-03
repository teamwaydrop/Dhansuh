# Backend current health — November 3, 2026

Project `yvwpchffctiagevpqgwy`. Scope: bounded read-only health investigation followed by one independently tested function optimization under the latest instruction to fix verified backend load. No Edge deployment, schedule edit, row repair, RLS change, compute change or paid resource.

## Current observations and limits

- At **01:36:08 IST**, project ACTIVE_HEALTHY, PostgreSQL 17.6, max_connections 60; six client backends including this monitoring session, zero blocked sessions and no other active client query. Other cron/pg_net background processes are not client connection exhaustion. See [snapshot](backend-live-20261103/SNAPSHOT.json).
- Bounded log window: **November 2 19:55:30–20:05:30 UTC / November 3 01:25:30–01:35:30 IST**. Twelve pricing config/zone REST reads returned 200, max 1,038ms; six pricing-function invocations returned 200, max 1,311ms. No HTTP 5xx or >5s REST response in this sample. PostgreSQL 72 records, zero timeout/57014 records. PostgREST contained two copies of one Warp timeout-manager event at 20:01:27.817368 UTC, without a correlated failed API/SQL operation. This event alone does not establish pool exhaustion. See [bounded aggregate](backend-live-20261103/RECENT_AGGREGATE.json).
- No Storage or Auth traffic in that window. **Upload/Auth recovery is unverified**, and low traffic does not reproduce peak load. Historical or current host CPU utilization, available RAM, swap activity, disk latency/IOPS/queue depth and correlated resource-onset charts were not obtained. `track_io_timing` is off. Cumulative temporary bytes since May 1 cannot identify current I/O pressure.
- Last 160 cron executions all succeeded. Job 5: 50 runs, average 12.875ms, max 34.113ms; job 7: 66 runs, average 13.100ms, max 38.150ms. These are current normal executions, not the November 1 incident. See [cron sample](backend-live-20261103/CRON.json).
- **58 old searching intercity orders** (53 ride, 5 parcel), past travel/search dates, older than seven days, payment pending, worker false. Expiry and stalled-local redispatch intentionally exclude intercity. This is unresolved lifecycle/data quality evidence, not proof of substantial current load. No order was cancelled/expired or repaired. See [aggregated recovery evidence and definitions](backend-live-20261103/RECOVERY_DETAIL.json). Product policy, payment reconciliation and notification effects must be reviewed before a separate lifecycle correction.

The original November 1/2 database-wide initiating cause remains **unproven**. Free-plan CPU/memory/I/O limitation is not established by these observations.

## Verified unnecessary cron work — fixed in production

`public.redispatch_stalled_searching_orders()` acquired its existing advisory lock, then read Vault and dispatch_config even when neither dispatch nor terminal-worker cleanup had any work. The live preflight observed both work predicates false. See [preflight](backend-live-20261103/PREFLIGHT.json).

Migration [20261103015444_waydrop_skip_idle_stalled_redispatch_reads.sql](../../supabase/migrations/20261103015444_waydrop_skip_idle_stalled_redispatch_reads.sql:35) adds an empty-work guard **after the original advisory lock and before Vault/config**. Its dispatch predicate deliberately omits the configured age limit, making it a safe superset of existing work. Terminal cleanup has its own predicate so a terminal-only tick is retained. Existing selection, HTTP payload, advisory key, age/eligibility rules, missing-key behavior, cleanup and fallback remain unchanged. Orders arriving after an empty observation retain new-order/next-tick fallback. Stale running searching-worker takeover is not enabled.

This is a **verified minor idle-work amplifier**, not a proven incident cause. Two existence probes are added; active-work ticks gain those probes. It is not a fix for all observed app slowness.

### Production execution and verification

- Applied only this migration, recorded version **20261103015444**, name `waydrop_skip_idle_stalled_redispatch_reads`.
- Original function MD5 `b486cd2e7650778ba2a41fe3eac5ea0a`; final `d70d703c15e3ee72834dc627af1fee80`.
- First attempt failed the postcondition because PowerShell transported CRLF into the function body; the transaction rolled back, and a read confirmed the original MD5. LF-normalized SQL then succeeded. Artifacts are stored as UTF-8/LF. Earlier local migration replay also caught a missing statement separator before any production attempt; corrected replay passed.
- **01:54:53 IST** verification: postgres owner, SECURITY DEFINER, search_path public, service-only ACL preserved; anon/authenticated EXECUTE false. Cron job 5 still active, every minute, same command. Zero blocked sessions. [Post-apply evidence](backend-live-20261103/POST_APPLY.json).
- First observed normal cron tick after apply, **01:55 IST**, succeeded in **8.730ms**. Previous individual ticks 6.798–20.080ms; no defensible production latency/CPU improvement can be inferred from one tick. [Cron evidence](backend-live-20261103/POST_CRON.json).

## Verification and measured effect

- Native PostgreSQL 17.11 synthetic fixture: **12 groups passed, 0 failed**. Actual captured original/candidate definitions tested; Vault/config and HTTP are local probes/stubs. Empty/intercity-only ticks: **Vault reads 1→0, config reads 1→0**; no HTTP or row-effect difference. Ready local orders enqueue once; throttle, age bounds, missing key, terminal cleanup, next-tick arrival, existing advisory-lock contention and ACL restrictions remain equivalent. Stale running searching workers remain untouched. [Runner](backend-live-20261103/native_idle_dispatch_test.py), [results](backend-live-20261103/NATIVE_IDLE_GUARD_RESULTS.json).
- Guarded migration/rollback: **6 checks passed, 0 failed**: apply hash, repeated apply rejects drift, rollback defaults to dry-run, explicit rollback restores original, repeated rollback rejects drift, ACL preserved. Only local-fixture substitution is owner postgres→waydrop_local. [Runner](backend-live-20261103/native_migration_test.py), [results](backend-live-20261103/NATIVE_MIGRATION_RESULTS.json). Synthetic server stopped afterward. Managed HTTP/Vault integration and peak-load behavior are not proved by these tests.
- Flutter focused: **10 passed, 10 skipped, 0 failed** across pricing integration/lifecycle files. Full default suite: **2,193 passed, 10 skipped, 0 failed**; total retained cases 2,203. Previous 2,203-pass run included those ten live-dependent cases; none was deleted. [Full log](../../.dart_tool/waydrop-local-runtime/backend-live-full.log). Targeted analyzer: **no issues**. [Analyzer log](../../.dart_tool/waydrop-local-runtime/backend-live-analyze.log).

## Test-driven production API calls — prevented by default locally

`test/intercity_parcel_pricing_regression_test.dart:76` read `.env` and used raw HTTP against its configured project; four cases can issue six pricing invocations. `test/pricing_dedup_regression_test.dart:56` also loaded the live SDK endpoint for six legacy cases. The sampled six pricing invocations plus twelve config/zone reads are consistent with the first file's requests; they are not uniquely attributed by request ID, nor evidence of an app retry storm.

Both files now require `--dart-define=WAYDROP_RUN_LIVE_PRICING_TESTS=true`; default runs do not load their live configuration and explicitly skip the ten dependent cases. Run the opt-in only against an approved endpoint. The ten actual SDK lifecycle/mock tests continue by default. This removes avoidable test-origin traffic from these files; it does not establish that the entire suite is network-free. No application implementation or APK was changed this turn. Build 59 still does not include the subsequent local Rider Realtime/pricing fixes.

## Outstanding backend/security work

Post-DDL advisors were refreshed: [summary](backend-live-20261103/POST_ADVISOR_SUMMARY.json). Existing [multiple permissive policies](https://supabase.com/docs/guides/database/database-linter?lint=0006_multiple_permissive_policies), [unindexed FK](https://supabase.com/docs/guides/database/database-linter?lint=0001_unindexed_foreign_keys), [SECURITY DEFINER views](https://supabase.com/docs/guides/database/database-linter?lint=0010_security_definer_view), mutable search paths and executable privileged-function advisories remain. Advisor output alone does not prove exploitation or incident causation. No blanket index removal or ACL revocation was performed. Direct metadata found zero auth.users policies despite an advisor associating public-user policy names with auth.users; do not modify Auth based on that discrepancy.

The previously prepared RLS optimization remains unapplied with its prior managed-auth gates. Combined dispatch/push SQL and Edge bundles retain their existing NO-GO requirements: cross-writer eligibility, resumed-owner fencing, managed authorization/provider behavior and durable push integration are not cleared by this guard. No stale-worker recovery deployment, acceptance/payment change or notification repair occurred.

Next material verification is correlated resource/API/upload evidence during an actual slow window, plus the existing isolated integration gates. Current idle snapshots cannot establish a resource upgrade requirement or guarantee app response times.

## Rollback / release scope

Only this independent cron migration is released. [Captured original](backend-live-20261103/redispatch_stalled.before.sql), [guarded apply](backend-live-20261103/APPLY.sql), [guarded rollback](backend-live-20261103/ROLLBACK.review.sql). Rollback checks the candidate hash/owner/settings/ACL, restores only the original function and defaults to **ROLLBACK** for review. An explicitly chosen production rollback must use LF-normalized contents and change the final transaction decision to COMMIT; do not blanket-push pending migrations. No business data is reversed. All previous combined-bundle gates remain in force.
