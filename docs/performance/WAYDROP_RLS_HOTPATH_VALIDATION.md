# RLS hot-path candidate: local validation, 2 November 2026

Later execution: [November3 current applied status](WAYDROP_SUPABASE_APPLIED_STATUS.md) records fresh40-policy/5-helper/7-table drift checks, rerun local suites, guarded exact migration tests and actual application of only the four SELECT-expression changes. Canonical migration `20261103162805`; no helper/grant/write-policy change. Historical read-only statements and measurements below describe the original November2 validation checkpoint.

Production project: `yvwpchffctiagevpqgwy`. Scope: validate the existing admin-helper optimization against the authorization graph implicated in the Build 56 incident. **Production remained read-only**: two bounded metadata reads, zero log queries, writes, deployments, configuration changes or paid resources. An isolated database in the existing loopback PostgreSQL engine was used; no Supabase project was created. That local server was stopped after tests, with the original policy expressions restored.

## Result

The candidate reduces repeated `is_admin()` work while preserving the tested authorization results. It changes **only four existing authenticated SELECT policy expressions**, from `public.is_admin()` to `(SELECT public.is_admin())`, on riders, rider_kyc, users and orders. It does not change the helper, grants, audiences, permissive relationships, write predicates, dispatch/payment logic or KYC data exposure.

This is a **verified workload reduction candidate**, not proof that RLS initiated the November 1 or November 2 database-wide stalls. Millisecond local timings do not explain or certify removal of the observed 48-second production delay. It also does not eliminate the cross-table policy graph.

## Evidence and reproduction

The earlier [17:43–17:55 investigation](WAYDROP_BUILD56_1743_1755_INVESTIGATION.md) captured a timeout in the booking-map riders/KYC read with `SQL function is_admin` context. Its illustrative authenticated plan expanded into five tables despite existing coordinate/KYC indexes.

This follow-up captured metadata only: **40 policies, 243 column definitions, actual enum types, indexes, table data-operation grants, RLS flags and authorization helper definitions**. Sources: [LIVE_METADATA.json](rls-hotpath-20261102/LIVE_METADATA.json) and [LIVE_COLUMN_METADATA.json](rls-hotpath-20261102/LIVE_COLUMN_METADATA.json). No production rows, tokens, personal messages or KYC records were copied.

[local_fixture.py](rls-hotpath-20261102/local_fixture.py) creates only `waydrop_rls_hotpath_test` on **127.0.0.1:54329**, refuses to overwrite an existing database, and seeds synthetic data. Follow-up test mutations require its fixed fixture marker. It reconstructs the RLS-relevant schema, captured policies/indexes and data-operation grants, using actual helper bodies. All column ACLs in the capture were null. The relevant helper EXECUTE permissions include PUBLIC, matching effective execution in this fixture.

Fixture limits: PostgreSQL **17.11**, versus captured production **17.6**; no managed Auth gateway/JWT signature verification, application triggers, foreign keys, network/pool admission, Realtime, payment provider or FCM end-to-end simulation. These tests validate RLS semantics and the selected query, not the complete production stack. Security-definer helpers are owned by the local fixture owner to model their owner-context access.

Reproduction uses the existing local runtime/roles from prior native tests. Start its loopback server, then run the following from the workspace. `local_fixture.py` is for first creation only; on this workspace the marked fixture already exists, so reuse the three test runners. They reset only their fixed synthetic database, never another test database or a remote endpoint.

```powershell
& '.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/pg_ctl.exe' start -D '.dart_tool/waydrop-local-runtime/pg17-synthetic-data' -l '.dart_tool/waydrop-local-runtime/rls-hotpath-postgres.log' -o '-h 127.0.0.1 -p 54329 -c max_connections=24 -c shared_buffers=32MB' -w
python docs/performance/rls-hotpath-20261102/native_test.py
python docs/performance/rls-hotpath-20261102/counterbalanced_test.py
python docs/performance/rls-hotpath-20261102/rollback_test.py
```

After confirming no other local client is using the server, stop it with `pg_ctl.exe stop` against that same data directory. The fixture and test evidence remain available for review.

## Security and recovery checks

[native_test.py](rls-hotpath-20261102/native_test.py) passes six native groups:

1. **Nine actors / 57 table-rowset comparisons** before versus after: active admin, inactive admin, support, offline rider owner, assignment rider, unrelated identity, forged user_metadata admin fields, service role and anon. Explicit checks include owner access to an offline rider and own KYC, support access, unrelated KYC denial, forged metadata having no effect and service-role access.
2. **Eight anon grant-denial probes** across four tables before/after.
3. **18 UPDATE target-rowset comparisons**, using 36 rolled-back transactions. This covers the interaction between SELECT visibility and existing UPDATE policies without certifying absent production triggers.
4. Prepared query identity changes: KYC counts **25 → 1 → 25** for admin → owner → support. Admin revocation takes effect on the next statement for rider access, and restoration recovers the original result.
5. Function/policy drift guards, candidate default rollback, no partial application after a guard failure, and restoration of original expressions.
6. Actual local EXPLAIN ANALYZE/BUFFERS and helper call measurements at 25 and 250 synthetic riders.

[counterbalanced_test.py](rls-hotpath-20261102/counterbalanced_test.py) additionally verifies **16 simultaneous identity reads across four workers**, with no admin result leaking between sessions. [rollback_test.py](rls-hotpath-20261102/rollback_test.py) passes three checks against the actual rollback file: dry run preserves the candidate, committed local rollback restores the original, and a second rollback rejects unexpected state.

Important baseline distinction: inactive `admins.is_active` does **not** remove all KYC visibility when the same synthetic identity still has `users.role='admin'`. A separate existing support/admin KYC policy grants that access. The initial test's assumption of zero KYC rows failed; inspection identified this independent policy, and the test was corrected to preserve the actual baseline. The candidate does not silently change that business/security rule. Whether deactivation should revoke that separate role-based access needs a distinct decision and complete write/trigger review.

The first fixture seed also assumed a `car` enum label; live metadata uses `cab`. The fixture now seeds from captured enum labels. These were setup/assertion corrections, not production changes or ignored candidate failures. Final native groups and rollback checks pass; exact output is retained.

## Actual workload and timing measurements

On nine measured executions of the bounded illustrative riders/KYC query, local `pg_stat_user_functions` with tracking enabled only in the test session measured:

| Synthetic riders | Before helper calls | After helper calls | Reduction |
|---|---:|---:|---:|
| 25 | 342 (38/query) | 18 (2/query) | **94.7%** |
| 250 | 1,341 (149/query) | 18 (2/query) | **98.7%** |

These are actual function-call counts for this query/fixture, not a guarantee that every application query invokes the helper twice. The benchmark has LIMIT 50 and illustrative coordinates; it is not an execution of a user's recorded request. Raw results and plans: [BENCHMARK.json](rls-hotpath-20261102/BENCHMARK.json).

The first timing run was mixed: the 25-rider owner median increased **4.541 → 5.455 ms** despite fewer helper calls. That result is retained. A justified repeat alternated before/after order across six batches, excluded one warmup per actor/phase/batch and retained 24 execution measurements for each actor/phase:

| 25-rider actor | Before median ms | After median ms |
|---|---:|---:|
| Active admin | 5.252 | 3.302 |
| Owner | 7.597 | 2.864 |
| Unrelated user | 6.802 | 2.194 |

[COUNTERBALANCED.json](rls-hotpath-20261102/COUNTERBALANCED.json) includes all samples/ranges. Timing ranges overlap; this Windows host is not controlled production hardware, samples within a batch are correlated, and no statistical or production latency guarantee is inferred. Helper-count reduction is the stronger deterministic workload result.

Plan nodes increased **50 → 59** locally because additional InitPlans cache the checks. A larger plan node count is not automatically more runtime work. Existing indexes remain; no index is added. The policy graph still reaches users/orders/intercity requests. This candidate is not presented as a complete RLS redesign or cure for an I/O/admission stall.

## Concrete candidate, ordering and rollback

The earlier `docs/supabase-phase2/proposals/04_admin_rls_initplan.sql` is preserved. The separately reviewed [RLS_INITPLAN_CANDIDATE.sql](rls-hotpath-20261102/RLS_INITPLAN_CANDIDATE.sql) strengthens its preflight: exact captured helper-definition fingerprint, STABLE/security-invoker properties, expected policy name/expression, SELECT command, authenticated audience and permissive flag. It uses bounded lock/statement timeouts and **ends in ROLLBACK by default**. No automatic migration was added.

The paired [RLS_INITPLAN_ROLLBACK.sql](rls-hotpath-20261102/RLS_INITPLAN_ROLLBACK.sql) accepts only the expected wrapped policy state and restores the four original expressions. It also defaults to ROLLBACK. Native tests commit only inside the fixed local fixture.

Required production sequence, **pending explicit approval**:

1. Refresh metadata and compare against the approved snapshot; stop for helper/policy drift. Obtain controlled managed authenticated positive/negative smoke coverage, including the existing inactive-admin KYC distinction. Do not use service-role-only success as proof of client authorization.
2. Approve a frozen apply artifact with an explicit commit, separately from the review file. Apply only these four policy changes in one short transaction during a quiet interval; no Edge, cron, worker, table-data or index change.
3. Verify the four expressions and unchanged grants/helper/other policies, then compare authenticated map/Home reads and error rates under matched conditions. Measure production latency rather than transferring the local percentages to it.
4. If access or latency regresses, use the reviewed rollback against the expected state in one transaction. PostgreSQL plan invalidation must be allowed to take effect; validate the next reads. No application data rollback is needed for this policy-only change.

Standalone RLS assessment: **CONDITIONAL, locally validated; not production-approved/deployed**. Combined dispatch/acceptance/push SQL and Edge bundles remain **NO-GO under their previous gates**. No stale-worker recovery is enabled by this candidate. Historical CPU/paging/disk/admission onset measurements remain missing.

## Client delivery

Build 57 packages the already-tested nearby booking single-flight correction that was made after Build 56. It does not depend on the RLS candidate being applied and does not activate any SQL/Edge protocol. The latest full Flutter suite remains **2,138 passed / 0 failed**, from the preceding exact client-source run; it was not rerun as evidence of this SQL-only work. The only later app metadata change is the release build number. The existing screen analyzer findings remain 0 errors / 2 warnings / 28 infos; no new Dart implementation changed in this RLS follow-up.

APK build/signature outcome, hashes and remaining gates are recorded in [VERIFICATION.json](rls-hotpath-20261102/VERIFICATION.json). Neither installing the APK on a phone nor real-phone timing is claimed here. A new Flutter build can reduce duplicate preview requests; it cannot certify that the shared production backend stall is fixed.

**Build result: PASS.** [Signed APK 1.0.0 (57)](../../artifacts/waydrop-1.0.0-build57.apk), same verified signer as Build 56. Existing Build 55/56 artifacts are preserved. The APK contains the client guard; the RLS candidate remains undeployed. No app install, publication or live order/payment action was performed.
