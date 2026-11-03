# Atomic acceptance implementation — local verification complete

Production `yvwpchffctiagevpqgwy` remains unchanged. No paid resources or staging projects were created. The previously failing concurrency test now passes; no failing tests were disabled.

## Exact implementation

- `supabase/functions/accept-order/index.ts`: retains verified-user authentication, existing booking feature flags and HTTP response shape. Replaces separate assignment/order/expiry/log writes with one `claim_order_assignment_atomic` call. Actor identity comes from `auth.getUser`, never the request body. Normal losing claims return 409; serialization/deadlock/lock/statement-timeout errors return retryable 503. Missing RPC fails closed without a split-write fallback.
- `01_atomic_acceptance.sql`: draft outside automatic migrations, defaults to ROLLBACK. Adds the private service-role-only RPC and a **correctness** unique index on accepted assignments per order. It removes no indexes and changes no existing RLS policies, Auth configuration or fare formulas.
- The RPC serializes each rider, then each order, using NO KEY UPDATE row locks compatible with foreign-key checks. It validates ownership, status, service mode, online state, tax, COD, busy state and allowed assignment statuses under the locks. READ COMMITTED is required; pinned-snapshot callers fail closed with 40001 rather than risk cross-order write skew.
- Canonical `calculate_fare_breakdown` computes the locked order's fare and existing promo discount, including subscription/free-trial commission waiver. Successful acceptance commits the order, exactly one winning accepted assignment, other pending-offer expirations and audit logs together. Any database/trigger/commit failure rolls back all these writes and transactional notification records. Retries return committed state without repeating writes/events. The unique index enforces **at most one accepted assignment across all writers**; successful RPC acceptance requires exactly one matching winner.
- A dispatch insert of the same winning pair is reconciled with ON CONFLICT. A direct acceptance without an existing offer gets a valid expiry from dispatch configuration (the old insert omitted this required field).

Intentional failure-path correction: eligibility, expiry or audit-write database errors now abort acceptance instead of proceeding with partial/unchecked writes. Normal business formulas and matching rules are unchanged. Existing notification triggers are retained; local tests capture effects transactionally, but managed pg_net/vault delivery and Realtime ordering still need integration verification.

## Actual results

| Test | Result |
| --- | --- |
| Native PG17 matching/GPS/index regression with atomic schema installed | 8 groups PASS, including 144 original/proposed matching comparisons |
| Native acceptance concurrency, duplicates, eligibility, failure/commit rollback, dispatch race and isolation | **15 groups PASS** |
| Previously failing full-handler acceptance race and one-accepted invariant | **2 PASS / 0 FAIL** |
| Full handler Auth, actor binding, feature gates, 409/503 mapping, fail-closed errors | **8 PASS / 0 FAIL** |
| Real local PostgREST 16.5 + signed JWTs + actual Supabase SDK against PG17 | **6 PASS / 0 FAIL** |
| Guarded object rollback/reapply and fail-closed switch | PASS, business-row/event fingerprints unchanged |
| Synthetic acceptance-schema dump/restore | PASS: 10 table content hashes plus function/owner/ACL/policy/index/trigger definitions matched |
| Targeted Flutter acceptance/payment/trial contracts | **214 PASS** |
| Full Flutter suite | **2,064 PASS** |
| Analyzer on the 7 changed Dart test files | **No issues** |
| Offline Node suite | **58 PASS / 0 FAIL / 0 skipped** |
| Available push handler tests, mocked transports | **17 PASS / 0 FAIL** |
| Acceptance Edge function frozen-dependency Deno check | PASS |

Evidence: `ATOMIC_RESULTS.json`, `../local-tests/ACCEPTANCE_RESULTS.json`, `REST_INTEGRATION_RESULTS.json`, `ROLLBACK_RESULTS.json`, `RESTORE_RESULTS.json`. Logs: `build/acceptance_flutter_full.log`, `build/acceptance_flutter_related.log`, `build/acceptance_analyze.log`, `.dart_tool/waydrop-local-runtime/acceptance-atomic-handler.log`, `acceptance-edge.log`, `push-tests.log` and `build/production_preflight_node_regressions.log`.

Old source-layout contracts that demanded Promise.all split writes were updated only after native transaction tests passed. Existing tax/COD/busy/free-trial/feature-flag expectations now follow the RPC boundary. The original one-accepted-assignment assertion remains enabled and passes.

## Repeatable local execution

Use the existing portable tools and synthetic cluster; no production URL input is accepted:

```powershell
& ./docs/production-performance/local-tests/start-postgres.ps1
node docs/production-performance/local-tests/pg17-tests.mjs --with-atomic-acceptance
node docs/production-performance/acceptance/atomic-tests.mjs
node docs/production-performance/acceptance/rest-integration.mjs
node docs/production-performance/acceptance/prepare-release.mjs
node docs/production-performance/acceptance/rollback-tests.mjs
```

The Deno handler concurrency command is in the updated `../local-tests/README.md`. Use its existing mock import map and include `supabase/functions` in allowed reads. `install-local.mjs` supports iterative updates only on the fixed loopback test database; the production proposal deliberately refuses pre-existing objects or drift.

PostgREST was downloaded from the [official v16.5 release](https://github.com/PostgREST/postgrest/releases/tag/v16.5); ZIP SHA256 matched `17f595b0d8dd37473d0231417dea07c5ac9f791282ff5b017fae51ff29e5de2f`. Its Windows libpq dependency is supplied through the child process's PATH from the existing portable PG17 bin directory. The helper starts only on 127.0.0.1:54327, uses ephemeral synthetic JWT credentials, stops in finally and removes its temporary credential config. The SDK prefix adapter replaces only the managed `/rest/v1` proxy prefix. Actual PostgREST JWT verification, role switching, schema cache, SQL grants/guards, JSON RPC and transactions are exercised. Managed GoTrue, the platform gateway/runtime versions, Realtime and external notification delivery are not reproduced.

## Remaining gates and read-only production evidence

A bounded production metadata/aggregate check found **0 duplicate accepted orders**, **0 accepted assignments with the wrong accepted-order owner**, **0 accepted assignments on searching orders**, and **0 accepted orders missing a matching accepted assignment** at the check times. The new RPC and index are absent in production. Repeat all guards immediately before an approved release; these counts do not authorize writes or guarantee future state. Do not auto-repair historical rows if a guard fails.

Still required: managed GoTrue/session and queued notification/Realtime behavior; available production backup timestamps/retention and restore procedure; retrievable previous Edge bundles/dependencies and a managed restore drill. Authenticated read-only MCP now confirms production v60 source matches the captured baseline. Its available operations and project metadata do not expose backup inventory or historical hosted Edge bundles/restore verification, so those checks remain pending. See FINAL_READ_ONLY_CHECK.json and ../PRODUCTION_DEPLOYMENT_CHECKLIST.md. A source snapshot and local synthetic restore are not substitutes for production recovery evidence.

No safe Firebase test destination exists, confirmed by the user. Push deployment remains separately gated. Unproven duplicate-index removals and config API changes remain excluded.

## Exact coordinated deployment after gates and final GO

1. Capture a fresh bounded acceptance error/latency baseline, object hashes and duplicate/inconsistency counts. Verify recovery evidence and freeze the artifact SHA256 values in `RELEASE_MANIFEST.json`.
2. Obtain explicit final GO for this acceptance fix only. Arrange an approved acceptance-traffic pause and drain old v60 requests before rollout. SQL and Edge are one coordinated correctness release: mixed old split writers and the new RPC must not be treated as a proven safe rolling transition. No maintenance/config setting is changed automatically by these files.
3. Rehearse the chosen migration/deployment tool's transaction and schema-cache behavior in an approved managed test environment. The exact committed payload is `01_atomic_acceptance.deploy.sql`; its SHA256 is in the manifest. It is the locally tested proposal with terminal ROLLBACK replaced by COMMIT, saved for review and **not executed against production**. Include that exact file/hash in final approval. Apply one reviewed migration, never a repository-wide push. It fails on duplicates, pre-existing objects, lock timeout or unexpected errors and changes no historical business rows.
4. Deploy **only accept-order** from the changed repository source, with the unchanged shared production-config helper. Preserve captured v60 `verify_jwt=false`; do not update secrets or authentication settings. Stored v60 bundle identifier is `9e6101aa857a902aefaa82d64d066f845e506e18e60f34441f85a4dc08af9f01`; this identifier and source snapshot do not prove that the old hosted bundle is retrievable or reproducibly redeployable.
5. Verify RPC owner/ACL/search-path, valid unique index, SDK schema visibility and actual application Auth/error responses before reopening acceptance. Observe genuine traffic; no synthetic production order/payment/notification probes. Confirm exactly one accepted assignment matching each successful order claim, valid losing 409s, idempotent retries, unchanged promo/fare/commission and correct notification/tracking transitions.
6. Any accepted-assignment invariant violation, wrong rider/amount, missed critical dispatch/tracking event or authorization regression: immediately stop acceptance traffic and stop rollout. For comparable representative traffic, proposed quantitative stop thresholds are server-error rate > baseline +1 percentage point or p95 latency > baseline +20%. Record sample sizes; at least 20 genuine accepts before any next release. Low traffic means HOLD, not proof of success. 409 conflicts are business outcomes and must be counted separately from infrastructure errors.
7. The first safe emergency option is `03_disable_atomic_rpc.sql`, which revokes execution on the new RPC while retaining the uniqueness index; the new handler fails closed. Review and approve COMMIT/hash before use. Do not silently reactivate the known-racy v60 write path.
8. Full object rollback uses `02_rollback_atomic_acceptance.sql` only after traffic is paused/drained, previous Edge recovery is verified and its hash guards match. In that session acknowledge `SET app.acceptance_rollback_traffic_drained='approved'`; replace terminal ROLLBACK with COMMIT only for the separately reviewed operation. The script drops only the new function/index with RESTRICT and does not rewind accepted orders, payments or notifications. Keep acceptance paused until a safe handler is restored. Code rollback cannot unsend notifications or reverse a genuine successful acceptance.

After this correctness release is independently verified, consider matching performance waves separately. GPS index removals, config experiments and push deployment are not included in acceptance approval. Production remains unchanged and final GO has **not** been requested while the remaining managed/recovery gates are open.
