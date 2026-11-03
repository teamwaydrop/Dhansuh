# Waydrop authorized rollout — 2 November 2026

The user explicitly authorized fixing the reported problems and using production write access. This supersedes the earlier report-only/read-only instruction **for this new rollout**. It does not turn an unverified candidate into a safe deployment. Two SQL migrations and one Edge deployment below were applied; the coordinated dispatch/acceptance/push protocol was not activated. No paid resources, test project, test user/order, payment repair, data backfill, index removal or cron schedule change.

## Applied and verified

| Change | Exact production/local artifact | Verification / limit |
| --- | --- | --- |
| Ignore expected duplicate audit keys during valid re-offers | `assign_nearby_searching_orders_core(uuid,uuid,double precision,double precision,partner_service_mode_enum)`; three audit INSERTs add `ON CONFLICT(order_id,rider_id,assignment_round) DO NOTHING` | Native valid re-offer fixture: **6 → 0 audit exceptions**; one offer/audit retained. No eligibility, fare or matching predicate rewrite. |
| Skip empty freed-rider sweeps | `redispatch_freed_riders()` returns after taking its existing advisory lock when no searching order exists | Native three empty sweeps: **3 → 0 matching-core calls**; nonempty fallback still runs. New-order trigger/worker and scheduled fallback retained. |
| Narrow rejection query, remove dead read, condition rejection writes on observed status | `reject-order` **v18 → v19**, active; `supabase/functions/reject-order/index.ts`, `deno.json` | **8/8 handler tests**, real local PostgreSQL accept-lock/reject-wait test preserves accepted state and changes **0 rows**. Ordinary rejection assignment SELECT count **2 → 1**. Status-changed conflict returns 409 before audit. This is not a complete atomic reject/accept/offer-generation protocol; missing-assignment and same-status replacement races remain part of the coordinated safety review. |
| Restrict internal dispatch RPC execution | `assign_new_order_to_nearby_online_riders_core(uuid)`, `redispatch_freed_riders()`, `redispatch_stalled_searching_orders()` | Before: anon/authenticated could execute SECURITY DEFINER matching. After: both denied; service_role remains permitted, owners unchanged. Six actual untrusted-role calls denied locally; **three production anonymous calls return 401/42501** before function execution. No direct Flutter callers found; cron and pg_net service-role paths retained. |

SQL workload migration: [20261102143243_waydrop_independent_dispatch_load_fixes.sql](../../supabase/migrations/20261102143243_waydrop_independent_dispatch_load_fixes.sql). ACL migration: [20261102144946_waydrop_internal_dispatch_rpc_acl.sql](../../supabase/migrations/20261102144946_waydrop_internal_dispatch_rpc_acl.sql).

Both files were initially generated with the installed Supabase CLI. MCP assigned different production migration versions; local filenames were reconciled to those recorded versions **without changing their bytes or repairing production history**. [History](authorized-rollout-20261102/MIGRATION_HISTORY.json). Do not blanket-push other inherited drafts or reapply these changes under the old local filenames.

## Definition, access and deployment proof

Production function hashes after workload changes:

- Rider core: `444701b2f06a4dc8f49be3ddd9cd564b` → `510865164c19f127b0b7c9cacc0c9811`.
- Freed sweep: `fed68d68ff41d65164ba29e055ceabdd` → `74afe7767f445453e4fbff3dbae87c9a`.

Exact pre-change definition/owner/ACL guards and postconditions are in the migration. The local replay verified real definition hashes; local fixture owner/ACL values were substituted only in that local rehearsal. Production retained owner `postgres`. The workload migration retained existing ACLs; the later separate ACL migration intentionally narrowed the three internal functions to `{postgres=X/postgres,service_role=X/postgres}`. ACL hardening does not change function bodies.

At **14:33:49 IST**, workload hashes/owners/ACL matched. At **14:50:09 IST**, all three internal RPCs had anon/authenticated=false and service=true. Cron 1/5/7 remain active on **two minutes / one minute / 45 seconds**. No expiry, recovery or tracking fallback was disabled.

Edge v19 deployed artifact SHA-256 reported by Supabase: `8a04911d3aba50424cf177196fca230b04de21356a0045a7cbc7389cc6fe0567`. Retrieved deployed source exactly matches the uploaded candidate. `verify_jwt=false` is retained from v18; existing handler `auth.getUser(token)` and rider ownership checks remain in force. SDK resolution is pinned to 2.118.0 through the included Deno import configuration; frozen cached real-dependency type-check passes. An uploaded local lockfile is in the exact request archive, but server retrieval exposes source/config rather than proof of the bundler's full dependency graph.

Production Edge smoke: OPTIONS=200, missing Auth=401, invalid Auth=401, invalid arguments=400. These tests stop before business writes. **No authenticated customer rejection was manufactured** merely to test deployment. Real-user positive-path and incident load/latency observation remain outstanding. Negative HTTP timings include cold startup/network and are not throughput benchmarks.

Security Advisor highlighted the existing anonymously executable freed-rider RPC; current SQL privileges and production 401 checks prove the targeted ACL correction. This is not a clean bill of health for the other advisor findings. [Advisor definition](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable).

## Android artifact

Built a **release candidate 1.0.0, build 55**, preserving the former build54 APK in the local runtime backup directory. Deliverable: [waydrop-1.0.0-build55.apk](../../artifacts/waydrop-1.0.0-build55.apk).

- Package `com.waydrop.app`, versionCode 55 verified from the actual APK using aapt.
- apksigner verification passes; signer matches the preserved build54 artifact.
- SHA-256: `0f9f687603a103878fb76b8ef1082b6e9bb42daa07037494cf3f02f277fb7904`.
- Release build succeeded. Latest unchanged-app regression run: **2,120 passed / 0 failed**; two changed startup files had no analyzer findings. Those tests ran in the prior live-startup pass and were not falsely recounted as a new full run here. New Edge/config/SQL changes were tested separately in this rollout.
- Contains the existing startup/Home/unread/GPS/Realtime/chat client corrections, including the new non-cancelling startup timeout retry correction. No new Dart implementation changes were made in this rollout.
- **Not installed or published.** No Android device is attached, so handset first-usable time, map/GPS behavior, authentication journeys and frame latency are not measured. It remains a release candidate, not a demonstrated phone speedup. It was built from the current working tree, which contains inherited changes; this is not an isolated, independently certified release subset.

Gradle echoed build-time arguments into its local log. The stored build log was sanitized before inclusion in verification; reports contain no credential values. The `.env` file was not changed, and no service-role key was embedded by this work. Do not publish raw build arguments/logs.

## Current observation and remaining work

Final production snapshot at **14:52:20 IST**: four other client connections, zero active client SQL and zero blocked sessions. This later idle observation does not measure November incident capacity or establish a production latency improvement.

Still **not activated/deployed**:

1. Generation/token dispatch fencing, canonical eligibility parity and durable dispatch enqueue coalescing.
2. Atomic acceptance candidate and its old-writer admission/drain handoff. Acceptance remains **v60**; do not treat rejection v19 as a substitute for atomic acceptance.
3. Per-device push claims, bounded durable retry/recovery and uncertain-send reconciliation. Push remains **v24**.
4. Stricter KYC/freshness policy and intercity capacity/expiry/fare compatibility review.
5. Chat restrictive INSERT policy rollout, broader authorization/legacy-client verification, deferred index/publication and timestamp-schema concerns.

The connected account has only the production project and no development branch. The user authorized a cost lookup: a new project was quoted **$0/month**, then explicitly instructed **not to create it**. No cost confirmation/create call occurred. Managed Auth/RLS/pg_net/Cron/intercity/full-worker crash validation therefore remains unavailable. Existing local 17-group/15-Edge blocker tests do not erase that gap. Do not activate stale takeover, introduce a missing acceptance dependency, or mix old/new worker protocols in production to bypass it. Production write permission remains acknowledged; this hold is about unverified behavior, not repeatedly requesting the same permission.

Original November 1/2 CPU/RAM/I/O/lock initiating cause remains **unproven**. The deployed changes remove demonstrated avoidable work and close limited races/access gaps; they do not prove the entire persistent slowness problem is solved. No new broad log scan or production load test was performed.

## Recovery and reproducibility

- Exact original definitions and v18 source, focused diffs, deployment payload, hashes, native results and production checks are under [authorized-rollout-20261102](authorized-rollout-20261102/VERIFICATION.json).
- Workload-only rollback is [ROLLBACK_LOAD_FIXES.sql](authorized-rollout-20261102/ROLLBACK_LOAD_FIXES.sql). It checks post-change body hashes and refuses to overwrite a coordinated protocol; CREATE OR REPLACE retains current hardened ACLs. Do not restore anonymous grants or overwrite a later migration. Prefer a forward correction.
- Edge emergency recovery artifact [REJECT_FAIL_CLOSED.ts](authorized-rollout-20261102/REJECT_FAIL_CLOSED.ts) returns retryable 503 without database work. It is prepared, **not deployed**. Do not automatically restore v18's stale-write defect.
- Local commands: existing Part 3 PG17 suite (5 pass); rejection handler/race suites (8 pass); additional native lock-wait and ACL denial tests; real-dependency frozen Deno check. Exact results/manifests and raw log hashes are in verification. The portable PostgreSQL instance is stopped after work.
