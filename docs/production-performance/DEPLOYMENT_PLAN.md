> **Superseded checkpoint.** Current Wave A is Edge-only; follow [current preflight](edge-only/WAVE_A_PREFLIGHT.md) and [hashed payloads](edge-only/RELEASE_MANIFEST.json). Historical RPC/index deployment instructions below are excluded. Current test and release status is in [RESULTS.json](edge-only/RESULTS.json).

# Waydrop production performance preflight — 1 November 2026

**Decision: HOLD. Nothing deployed.** Project `yvwpchffctiagevpqgwy`; PostgreSQL 17.6. The existing Phase 2 investigation was reused. This preflight performed bounded read-only metadata/log/aggregate queries and local file/test operations only. No database, function, RLS, configuration, resource or billing changes were made.

The latest separately deployable acceptance-only package and exact request/incident commands are in [MINIMAL_PRODUCTION_WAVE.md](MINIMAL_PRODUCTION_WAVE.md). New read-only evidence verifies Auth health/JWKS/invalid-session rejection and Realtime/notification wiring; it does not close valid-session, live event delivery or production recovery gates. No production change was executed.

The local tooling blocker has been resolved: portable PostgreSQL **17.11** and Deno **2.9.8** were installed inside the workspace without Docker, WSL, administrator installation, service or PATH changes. Native tests, locked dependency checks and a synthetic restore drill have now run. **The acceptance race is now fixed locally; the previously failing invariant passes.** Managed integration, real push delivery and production recovery gates also remain. Final production GO is premature.

### Latest execution: atomic acceptance fix implemented and verified

Setup and repeatable commands: [local-tests/README.md](local-tests/README.md). The previous [ENVIRONMENT_GATE.json](ENVIRONMENT_GATE.json) records historical absence; it is superseded by the successful local setup. No staging resources or paid services were created. Production reads were restricted to missing source/schema/trigger metadata. The local PostgreSQL cluster was stopped after verification.

| Verification actually performed | Result / evidence |
| --- | --- |
| Native PG17 fixture: seven tables with exact types/typmods/defaults/constraints, 22 RLS policies, eight relevant triggers; actual service-mode/tax/COD/busy helpers | PASS; [PG17_RESULTS.json](local-tests/PG17_RESULTS.json), 8 check groups |
| Nearby matching equivalence across eight order types, six radii, three limits and exclusions | PASS; 144 original/proposed comparisons |
| Twelve concurrent real offer writes, six concurrent reoffers, unique-pair/log handling, earnings preservation | PASS on both original/proposed functions |
| Actual deployed accept-order **v60** handler through a local SQL transport adapter, two forced simultaneous riders | Atomic handler PASS: HTTP 200/409, exactly one accepted assignment, payable fare 100, discounted final fare 90, commission 9.52 and rider earning 90.48 preserved; [ACCEPTANCE_RESULTS.json](local-tests/ACCEPTANCE_RESULTS.json) |
| GPS bridge, stationary heartbeat after order becomes ongoing, proximity notification idempotency, heading propagation | PASS. Existing heading-only UPDATE does not fire the coordinate-targeted bridge; coordinate-targeted heartbeat carries heading. No trigger change proposed |
| Duplicate-index drop guards, lock timeout, exact recreation; matching-function rollback hashes/owners/ACL | PASS on PG17 |
| Complete baseline/proposed push handlers with actual RSA signing/verification and timeout helper, mocked DB/Auth/provider, network denied | **17 PASS / 0 FAIL**; includes auth, preferences, cache expiry, concurrent cold starts, OAuth failure recovery, DB errors, FCM 401/404/429/500, cleanup and timeout |
| Actual remote Supabase client dependency smoke test, frozen cached lockfile and Deno check | PASS; local graph resolves supabase-js **2.118.0**. Managed v24 dependency graph remains unknown |
| Synthetic dump/restore into separate native PG17 database | PASS; content hashes for 10 tables plus function definitions/owners/ACL, policies, indexes and triggers match; [RESTORE_RESULTS.json](local-tests/RESTORE_RESULTS.json) |
| Existing offline Node regressions / audit groups / preflight groups | 58 tests PASS, 0 skipped; 6 audit groups PASS; 4 preflight groups PASS |
| Actual test-device notification | NOT RUN: user explicitly confirmed no safe test destination exists |
| Production backups, actual restore and historical Edge bundle rollback | NOT VERIFIED: connector has no backup/history listing; computer/browser inventory exposes no dashboard session. Source copies are available, not evidence of managed restore capability |

**Acceptance fixed locally:** [atomic SQL](acceptance/01_atomic_acceptance.sql) adds a service-only transaction and a unique accepted-assignment index; the [Edge handler](../../supabase/functions/accept-order/index.ts) now delegates acceptance writes to it. The previously failing invariant passes. Fifteen native transaction groups, two handler concurrency tests, eight Edge auth/flag/error tests and six real local PostgREST/JWT/SDK integration tests pass. Full Flutter: **2,064 passed**; targeted related tests: **214 passed**; changed-test analyzer: **0 issues**; offline Node: **58 passed**. See [acceptance implementation and release instructions](acceptance/README.md). No production deployment occurred. Managed Auth, Realtime, async side effects and production recovery remain gates.

**Measured local performance (not production):** in fresh backend samples with 60 riders, nearby median execution was 15.588 → 16.573 ms; GPS heartbeat median was 5.165 → 5.358 ms and reported median WAL bytes were 135 → 135 after duplicate-index removal. These samples include PL/pgSQL preparation, cache/WAL noise and do **not** establish a gain. In a separate same-backend synthetic scale check (3 warmups, 12 measured calls), nearby matching with 560 riders including 500 distant riders measured 2.156 → 1.832 ms; core matching with 1,000 distant searching orders measured 1.677 → 0.679 ms. See [LOCAL_PERFORMANCE_RECOVERY.json](local-tests/LOCAL_PERFORMANCE_RECOVERY.json) and [SCALED_PERFORMANCE.json](local-tests/SCALED_PERFORMANCE.json). Scaled results demonstrate the prefilter mechanism; they do not establish a win for the current production distribution. GPS index removals are **deferred for lack of demonstrated benefit**.

**Push mechanism:** ten concurrent cold requests minted 10 OAuth tokens on baseline versus 1 on proposal, while preserving 10 mocked sends. This is an actual test count, not a production latency benchmark. Provider errors are not automatically retried inside the existing handler; an explicit subsequent request can retry. This pre-existing behavior was preserved, not upgraded into an unverified retry guarantee.

## Baseline and current health

API window: **31 October 2026 07:37:38 UTC through 1 November 2026 07:37:38 UTC**. Catalog captured at **1 November 13:09:07 IST**. Machine-readable evidence: [BASELINE.json](BASELINE.json).

| Measurement | Before | After |
| --- | --- | --- |
| Config GET, 20 requests | Mean 684.5 ms; p95 1,146 ms; 0 HTTP errors | Not deployed |
| Orders GET, 10 requests | Mean 88.9 ms; p95 287 ms; 0 HTTP errors | Not deployed |
| Push POST, 23 requests | Mean function time 2,265.48 ms; p95 3,053 ms; 0 HTTP errors | Not deployed |
| Users / rider KYC / riders GET | Means 40.85 / 49.5 / 27.25 ms; n=27 / 8 / 4; 0 HTTP errors | Not deployed |
| Matching SQL, authenticated | Cumulative mean 228.459 ms; 6,142 calls | Not deployed |
| Rider PATCH SQL, authenticated | Cumulative mean 79.452 ms; 25,917 calls | Not deployed |
| Config SQL, authenticated | Cumulative mean 2.235 ms; 189 calls | Not deployed |

SQL statistics reset on **7 May 2026**: those means are historical cumulative observations, not current-window latencies. No matching RPC or rider PATCH appeared in the bounded API result, so their current API p95 and error rates remain unknown. Old/new cumulative means must not be compared directly. Future interval SQL mean = delta(total_exec_time) / delta(calls), separated by queryid and role, with reset detection. Do not reset production statistics.

Health snapshot: 4 client connections / maximum 60, zero blocked sessions and zero waiting locks. Last 100 cron runs succeeded. No CPU/RSS measurement was available. These snapshots do not prove capacity or end-to-end correctness.

Push HTTP 200 is not delivery proof. The additional bounded 24-hour notification aggregate contained 8 `sent/push_sent=true` and 15 `pending/push_sent=false`. Pending may include intentional skips; failures were not established. Their causes and eligible-delivery denominator must be resolved before treating HTTP success as notification health.

## Exact proposed changes and dependencies

All SQL below defaults to **ROLLBACK**, remains outside automatic migrations, and has not run against production. [ARTIFACT_MANIFEST.json](ARTIFACT_MANIFEST.json) contains SHA256 hashes. Replacing terminal ROLLBACK with COMMIT creates a new release artifact requiring a new hash and final GO; never execute the earlier bundled proposals.

| Wave | Exact artifact and intended change | Dependencies / acceptance gate | Recovery |
| --- | --- | --- | --- |
| 01 | [find_nearby_riders](waves/01_find_nearby_riders.sql): conservative latitude band before original spherical distance; materialize candidates to avoid repeated distance evaluation | Existing production definition MD5 `3eb2e46c08b3d5af5a14ed1b39115aa7`; original service-mode, busy, tax and eligibility helpers. Prove result equivalence including limited rounded-distance ties and invalid coordinates. Prove MATERIALIZED helps at current small and larger synthetic cardinalities; otherwise revise/retest rather than deploy | [01 rollback](waves/01_find_nearby_riders.rollback.sql) restores captured definition; requires actual verified post-deployment MD5 |
| 02 | [assign_nearby_searching_orders_core](waves/02_assign_nearby_searching_orders_core.sql): latitude prefilter only in searching-order loop | Existing definition MD5 `444701b2f06a4dc8f49be3ddd9cd564b`; assignment/redispatch triggers and helpers. Preserve financial checks, reoffers, exact distance limits, ordering and concurrent assignment behavior | [02 rollback](waves/02_assign_nearby_searching_orders_core.rollback.sql); same post-deployment drift guard requirement |
| 03 | [drop idx_riders_user_id](waves/03_drop_idx_riders_user_id.sql): remove ordinary duplicate; retain UNIQUE `riders_user_id_key` | Equivalent live index must pass guarded DDL, key, opclass, collation, option, predicate/expression and dependency checks immediately before execution. PG17 lock/write test required | [03 recreate](waves/03_restore_idx_riders_user_id.rollback.sql), exact original CREATE INDEX |
| 04 | [drop idx_riders_kyc_id](waves/04_drop_idx_riders_kyc_id.sql): remove ordinary duplicate; retain UNIQUE `riders_kyc_id_key` | Same checks; independently validate wave 03 before continuing | [04 recreate](waves/04_restore_idx_riders_kyc_id.rollback.sql), exact original CREATE INDEX |
| 05a | [Deno compatibility only](waves/05_compat.index.ts) plus [shared timeout helper](waves/shared/http.ts) | Current Deno check exposed BufferSource typed-array and Node/Deno timer-type incompatibilities. Copy the DER bytes into an ArrayBuffer and use ReturnType for timer type. Business logic unchanged; full-handler tests pass | Captured v24 source/settings; actual managed redeployment remains unverified |
| 05b | [push phase timing only](waves/05_push_timing.index.ts), cumulative on 05a | Capture non-PII phase durations; auth, feature flags, preferences, provider requests and retries unchanged. Deployment and restore drill required first | Redeploy 05a bundle/settings |
| 06 | [push shared OAuth mint](waves/06_push_oauth.index.ts), cumulative on wave 05 | Existing token expiry/cache stays; share in-flight mint per warm isolate, clear on failure. No cross-isolate caching claim. Full Deno/auth/provider failure tests required | Redeploy wave 05 bundle/settings |
| 07 | [push concurrent reads](waves/07_push_prefetch.index.ts), cumulative on wave 06 | Start token read alongside preference read after auth/global flag. All opt-outs still precede OAuth/send. Extra internal read on opt-out is an acknowledged tradeoff; benchmark eligible and skipped paths before accepting | Redeploy wave 06 bundle/settings |

For each push stage deploy **only** `send-push-notification`, with prepared `_shared/http.ts` and captured `_shared/production_config_cache.ts`. Preserve existing `verify_jwt=false` and application authorization checks; no secret or Auth changes. The final stage differs from the audited proposal only by the two verified Deno compatibility corrections. Earlier artifact hashes are superseded by [ARTIFACT_MANIFEST.json](ARTIFACT_MANIFEST.json). Execute stages separately, never as a bundled rollout. Deployment dependency reproducibility is still a gate: local frozen-lock verification alone does not prove the managed deploy tool honors that lock or restores the old graph.

The deployment tool must explicitly target the production reference; no wildcard Edge deployment or repository-wide migration push. For SQL use a reviewed single-change migration through the Supabase migration mechanism after gates and GO; append bounded transaction settings and only the relevant statement/guards. Rehearse that tool's transaction behavior before finalizing the committed payload. Record migration name, payload SHA256, timestamp and resulting function-definition hash. The current files are rehearsal drafts, not executable production migrations.

### GPS proof and limits

Fresh catalog evidence shows both target indexes are ordinary 16 KiB btree indexes. Their retained UNIQUE counterparts have identical key attributes, UUID opclass `10065`, collation `0`, options `0`, no expressions/predicates/includes, and are valid/ready/live. Targets are not constraint-backed, partition-linked, extension-owned or replica identities; a separate `pg_depend` dependent-object query returned none. Unique constraints remain in place. Evidence is in the private catalog snapshot.

This proves equivalent lookup coverage at capture time, **not a measured write-speed benefit**. Index keys do not change with coordinate-only updates, and indexed GPS fields may still prevent HOT updates. Do not attribute the historical 79.452 ms mean to these two indexes or promise a reduction. Skip either removal if synthetic PG17 write/WAL measurement shows no worthwhile benefit.

Use bounded **ordinary** DROP/CREATE only after a PG17 lock/restore drill proves an acceptable maintenance window (draft lock timeout 1 second, statement timeout 10 seconds). No retry loop on lock timeout. `DROP INDEX CONCURRENTLY` cannot be substituted inside this transactional migration; an autocommit deployment/recovery path would require a separately reviewed plan. No CASCADE. Failed lock/statement timeout must leave the retained unique index and application available.

Do not change the GPS bridge or proximity trigger in this release. A stationary rider can enter an ongoing order and still require a proximity check; skipping every unchanged-position event is unsafe. Replay changed-coordinate, heading-only, heartbeat, stationary-to-ongoing, offline/reconnect and duplicate-update paths in the isolated test environment.

### Config decision and excluded proposals

**No config mutation approved or justified.** Prior role-scoped plan evidence: one 744-byte row, execution 2.622 ms, one cached block, no physical reads; current config API mean remains 684.5 ms. API/gateway/connection/cold-request contributors are still unseparated. The opt-in `05_config_latency_probe.mjs` remains unexecuted. If later approved, make at most three public GETs, record timing/response bytes/status and correlate server origin/upstream timings without printing configuration values or keys. Do not infer gateway responsibility solely from the latency gap.

Exclude the optional proximity index (existing plan cost 2.38, benefit unproven) and the admin RLS initplan proposal (outside this release's authorized scope). Do not change payments, KYC, assignment rules, tables, security settings or production configuration.

## Recovery verification and remaining blockers

Private local recovery materials: `.dart_tool/production_performance_preflight_20261101/` (gitignored). Eight files capture both current SQL definitions, owner/ACL/search-path metadata, all four index definitions, push v24's three source files and deployment metadata. Every saved file was reread and SHA256 verified; no user rows or environment secrets were exported. The backup manifest lists exact bytes/hashes. This is a machine-local **object/source snapshot**, not an off-site database backup.

CREATE OR REPLACE restores an existing function without dropping its identity, owner or ACL. Verify all three plus function settings against the snapshot after deploy and rollback; never issue blanket GRANTs. Function rollback drafts deliberately refuse to run until their placeholder is replaced by the actual deployed function-definition MD5. This prevents overwriting another operator's intervening change. Index recovery deliberately fails if its name already exists: inspect definition drift rather than silently using IF NOT EXISTS. Push rollback must include the shared files and captured settings, not just index.ts.

**Recovery progress:** native PG17 lock/function/index rollback tests and a synthetic full-content restore drill now pass. **Remaining gaps:** no validated off-machine recovery copy, no verified existing production data-backup/recovery capability, and no managed Edge restore/dependency drill. Current source imports mutable `@supabase/supabase-js@2`; the local lock captures resolution to 2.118.0 but does not identify the original deployed graph. Resolve managed deploy/rollback reproducibility before push deployment. Do not buy PITR or upgrade a plan. Official [backup documentation](https://supabase.com/docs/guides/platform/backups) describes paid-plan automatic backups and recommends Free-project exports; it does not establish a usable backup for this project. No production user-data export was attempted. Required operator evidence: actual available backup timestamps/retention and authorized restore procedure from the production dashboard, plus retrievable historical Edge bundle/version and its restore rehearsal. An authenticated dashboard session was unavailable in this run; no restore action was attempted.

Rollback restores code/DDL prospectively. It cannot unsend a notification or undo an assignment that already happened. Critical behavioral regression requires stopping further waves immediately; do not repair business rows, rerun dispatch or restore the whole database without a separately reviewed incident action. Existing data recovery must be verified by the administrator through their authorized backup procedure, without copying sensitive data into this workspace.

## Tests and gate checklist

Commands actually run locally:

```powershell
node docs/supabase-phase2/proposals/validate_local.mjs
node docs/production-performance/validate_preflight.mjs
node --experimental-strip-types --check docs/production-performance/waves/05_push_timing.index.ts
node --experimental-strip-types --check docs/production-performance/waves/06_push_oauth.index.ts
node --experimental-strip-types --check docs/production-performance/waves/07_push_prefetch.index.ts
```

Results: **6 existing audit check groups passed**, including 56 synthetic original/proposed nearby result comparisons and ten overlapping OAuth requests sharing one mint with failure/retry; **4 additional preflight groups passed**, including each split index's guarded drop/recreation, rejection of index drift, and ROLLBACK defaults; all three push stages passed Node TypeScript syntax checks. See [PREFLIGHT_LOCAL_TESTS.json](PREFLIGHT_LOCAL_TESTS.json), existing [LOCAL_VALIDATION.json](../supabase-phase2/evidence/LOCAL_VALIDATION.json), and `build/production_performance_preflight_tests.txt`. Existing audit tests include an RLS proposal parse check; passing it does not bring that proposal into deployment scope.

The preceding commands describe the older PGlite checks. Native PG17/Deno commands and current evidence are now in [local-tests/README.md](local-tests/README.md) and the result table above. Actual service-mode/busy/tax helpers, offer writes and relevant GPS triggers now run locally. **Managed end-to-end behavior remains unproven:** auth claim SQL functions emulate gateway settings, unrelated FK targets are key-only placeholders, actual payment-provider settlement and Supabase PostgREST/Realtime/vault/pg_net/Cron are not reproduced. Real JWT verification and notification device delivery require an approved isolated integration environment; no such resource was provisioned.

Before final GO, require all of:

1. Approved no-cost isolated PG17/Supabase-equivalent target; reviewed schema/helper/trigger/Auth parity and synthetic users only. Disable production outbound targets, cron and webhooks. No resources are implicitly authorized by this plan.
2. Original-versus-proposed matching tests: authenticated owner/nonowner and server caller; every actual rider eligibility/service/vehicle/financial rule; exact radius edge, stale location, excluded rider, invalid coordinates and limited/tied ordering. Concurrent claim races, busy transitions, reoffer uniqueness and real assignment writes must preserve results and invariants.
3. GPS replay tests listed above, one arrival notification per intended transition, correct tracking/dispatch updates, unchanged unique constraints; PG17 before/after plans, request latency, WAL/write work and bounded lock/rollback tests with synthetic workloads. No production benchmark.
4. Deno check/tests of the **full handler** with mocked Supabase/OAuth/FCM: unauthorized callers, global flag, all preference gates, no tokens, concurrent cache hits/misses, mint failure/expiry, DB failures, provider 401/429/5xx/timeouts, invalid-token cleanup, delivery status and existing retry semantics. Test-device smoke delivery only in isolated configuration. No production push probes.
5. Recovery drills restore matching definitions/ACL/owners/settings, each removed index, and each prior push stage with reproducible dependencies. Verify existing data-recovery arrangements separately. Retain evidence and sanitized recovery artifacts durably.
6. Refresh production drift hashes, bounded baseline and health immediately before the release window. Obtain **explicit final GO naming only the eligible waves and immutable deployment hashes**. A matching-only approval must not authorize index or push deployments.

No full Flutter suite rerun was needed: this preflight changes only documentation/rehearsal artifacts. Earlier Phase 1 results are not evidence for backend changes.

## Approved-window procedure, once all gates pass

1. Freeze the one-wave deployment and rollback payload hashes. Confirm project reference, unchanged dependencies/grants, working recovery materials and baseline. If any prerequisite is missing, STOP.
2. Deploy wave 01 only. Immediately verify definition/owner/ACL/settings and health. Observe genuine application traffic; no synthetic production order, payment, GPS or push writes. Record matching outputs/invariants and interval SQL counters. Require representative matching traffic before wave 02; hold rather than declare success if traffic is absent.
3. Repeat for wave 02. Then evaluate waves 03 and 04 independently only if their PG17 measurements justify them; verify retained UNIQUE indexes and tracking/proximity/dispatch after each. Do not roll out both at once.
4. Perform wave 05 only after push recovery gates pass. Establish phase timing and eligible-send outcomes before choosing wave 06 or 07. Deploy each separately, measuring per-isolate OAuth mint behavior, preference outcomes, delivery/provider failures and latency.
5. Proposed observation minimums: 20 representative matching requests for each matching wave, 50 real GPS writes for each GPS wave, and 20 eligible push attempts for each push wave; compare like caller/workload classes and record sample sizes. These are operational checkpoints, not statistical proof. If not reached within 60 minutes, HOLD the next wave and agree a longer observation window; do not manufacture traffic.
6. Roll back the current wave immediately on changed eligibility/assignment invariants, duplicate/missing critical delivery events, broken authorization or tracking. Proposed quantitative stop thresholds: p95 regression above 20% or server-error rate above baseline by 1 percentage point in a comparable adequately sampled window. Any critical failure overrides sample thresholds. Check pending/skipped/sent outcomes separately from HTTP status; fresh baseline zero errors with small samples is not a reliable service SLO.
7. If recovered, verify old behavior and stop rollout. Record exact deployed/reverted artifact hashes, timestamps, counters, API error denominators, delivery/tracking observations and unresolved incidents. No automatic continuation after rollback.

**Top priorities after prerequisites are satisfied:** atomic acceptance correctness release first (see acceptance/README.md), then performance wave 01 and wave 02; push timing/OAuth after its separate recovery gate. GPS duplicate-index cleanup is conditional because lookup redundancy is proven but performance gain is not. There is no justified config database fix yet.

**Current outcome:** local setup and substantial PG17/Deno/restore verification completed; **the acceptance invariant is fixed and all executed local tests pass**, real device delivery is unavailable, and production recovery/managed integration are unverified. Zero production changes, no production after metrics and no production improvement claim. Resolve or explicitly accept critical issues with evidence before any final GO request. GPS index cleanup is deferred; config changes remain excluded.
