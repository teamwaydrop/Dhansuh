# Waydrop Supabase applied status — November 3, 2026

User instruction: **Waydrop app only; no AAB work and no new Supabase test project.** AAB packaging was stopped after clarification; no Play upload/publication or AAB artifact delivery is claimed. No new cloud project or paid resource was created. The existing local loopback PostgreSQL fixture was used for regression tests and stopped afterward.

## Actually applied

| Change | Production state | Evidence |
|---|---|---|
| Pricing zone read cache/coalescing | `calculate-order-pricing` **v76 ACTIVE** | [Prior actual rollout](WAYDROP_APP_PRODUCTION_ROLLOUT.md); exact source verified; fare/GST unchanged in public read-only probe. |
| Live-status ETA/signing request coalescing | `get-live-order-status` **v55 ACTIVE** | Same rollout; handler/Auth/ownership byte-identical; existing cache TTLs preserved. |
| Repeated admin-check evaluation in normal app reads | **Four existing SELECT policies updated** on orders, rider_kyc, riders, users | [Recorded migration](rls-production-20261103/DEPLOYED_MIGRATION.json), [canonical SQL](../../supabase/migrations/20261103162805_waydrop_cache_admin_rls_checks_per_statement.sql). This is app RLS optimization, not an admin-panel publication. |
| Early photo order scope and body deadline | `process-verification-photo` **v19 ACTIVE** | [Receipt](photo-production-20261103/DEPLOYED.json), exact hosted source/settings match; legacy protocol maintained. |

The RLS migration version is the **server-recorded canonical identifier** `20261103162805`. CLI initially created draft `20261103105157`; that local file was renamed to the recorded version without changing its SQL hash. Do not create/replay a second migration from the draft timestamp. No blanket migrations or all-functions deploy occurred.

## RLS verification

The migration changes only `is_admin()` to `(SELECT public.is_admin())` in four existing authenticated SELECT predicates. It does not replace the STABLE/security-invoker helper, widen roles, modify INSERT/UPDATE/DELETE rules, change grants, disable RLS or read/update customer rows.

- Fresh preflight matched **all40policies,5helpers and7table security/ACL settings** in the prior captured graph. Migration checks full policy/helper/grant fingerprints again while holding bounded locks;500ms lock timeout and5second statement timeout prevent waiting indefinitely on live writers.
- Fresh local PostgreSQL: **6 native groups pass**, including9actors/57rowset comparisons, unchanged anonymous denials and UPDATE targets, prepared-statement identity changes and admin revocation. **16concurrent identity reads** and **3original rollback checks** pass.
- **5exact-migration tests pass**: real production fingerprints reject another fixture, fixture-only fingerprint substitution changes precisely four expressions, rollback restores all policy state, graph drift aborts atomically, and an observed concurrent writer lock causes the500ms lock timeout. Only synthetic loopback data was modified by these tests.
- Local helper operation counts over9queries: **342→18** at25riders; **1,341→18** at250. These are actual local call counts, not production CPU/latency claims. Multiple policy contexts can still produce multiple InitPlans; not every query is guaranteed exactly one helper call globally.
- Post-apply catalog comparison verifies **exactly those four expressions changed**; all other40-policy fields,5helper definitions/ACLs and7table security settings are unchanged. [Before](rls-production-20261103/LIVE_DRIFT_PREFLIGHT.json), [after](rls-production-20261103/LIVE_AFTER.json), [exact tests](rls-production-20261103/EXACT_MIGRATION_TESTS.json).
- Real anonymous gateway/JWT checks: **4/4before and4/4after**, using limit-zero selects with no row data returned. users returns empty200; riders/KYC/orders deny with42501/401. This is anonymous coverage, **not managed signed-in actor validation**.
- Public quote/Auth/CORS Edge smoke after migration: **5/5pass**, quote unchanged. [Checks](rls-production-20261103/EDGE_SMOKE_AFTER.json).

Security advisor notices remain unchanged (64existing notices, including57anonymous-sign-in policy notices); this migration is not a whole-system security clearance. Local fixture startup first hit an interrupted-server recovery/connection failure; after the fixed loopback server recovered, all final suites above passed and it was shut down cleanly. No failed startup run is counted as passing regression evidence.

## Photo verification and boundary

The v19 candidate is built from captured v18. It checks valid pickup/dropoff type and confirms the authenticated rider belongs to the requested order **before image download, hashing or service-role writes**. Wrong/unassigned/missing-order requests fail early; backend order-read errors return retryable503 rather than proceeding. Photo bytes/checksum and legitimate legacy writes are preserved. A20second abort deadline remains active through full body consumption, including a stall after headers.

**14actual-candidate tests pass**, covering invalid Auth/rider/order/type, backend read failures, legitimate pickup/dropoff write paths and header/body download timeout cases. Strict cached/frozen production typecheck passes. Two legacy TypeScript annotations (timer type and caught-error type) required type-only compatibility correction; runtime logic of the retained HTTP helper is unchanged. The first check rejected the old annotations; it was corrected and rechecked rather than bypassing type checking.

Live v18 preflight drift check matched; v19 was deployed and every hosted file/settings compared exactly. **3/3hosted negative/CORS probes pass before and after**; no real photo was uploaded/downloaded and no order/photo/customer rows written by probes. [Before/after](photo-production-20261103/SMOKE_AFTER.json). Short v19 log observation:3requests,0HTTP5xx, two401denials and one OPTIONS200. [Monitor](photo-production-20261103/MONITOR.json).

**This is not the atomic-photo protocol.** Snapshot assignment validation can race a later reassignment; existing multi-table writes are still not one transaction. The old four-write race and durable idempotency requirements are not marked solved. Real signed-in customer/rider/photo/provider end-to-end testing was not available. On a regression, prefer a forward correction or reviewed [fail-closed recovery payload](photo-production-20261103/FAIL_CLOSED_RECOVERY.json); do not casually restore the known missing-order-scope v18 handler. The recovery payload is prepared, **not deployed or runtime-certified**. Old source snapshot remains audit evidence, not recommended active recovery.

## Current observation and outstanding work

Post-change DB snapshot **16:38:24 IST**:6client connections including inspection,0blocked sessions. [Snapshot](rls-production-20261103/POST_HEALTH.json). This quiet short observation does not prove peak-time CPU/RAM/I/O or timeout recovery. API cache probes, anonymous RLS checks and local fixtures do not prove the original November1 initiating cause or repair Storage metadata504s.

**Not applied:** coordinated acceptance/dispatch ownership/recovery/eligibility/enqueue protocol; durable push outbox/claims/recovery; atomic-photo RPC/cutover; restrictive Chat sender-policy candidate; blanket historical migrations/data repair/index/publication/pool/compute changes. Acceptance remains60 and push24. These coupled changes still require complete writer/schema/provider validation and a demonstrated cutover/drain; local regressions do not supply missing managed identities/full-trigger/device cases. No live orders/payments were used as a test environment. The user declined a new project, so none was created.

Build62 Flutter sources/APK are unchanged by these Supabase deployments; the last complete Flutter suite is2,233passes/10existing live skips/0failures. These Flutter changes take effect on a phone only after installing that build. **The independent changes above are live; full combined rollout is incomplete.**

Logs: `.dart_tool/waydrop-local-runtime/rls-production-native-final.log`, `rls-production-concurrent.log`, `rls-production-rollback.log`, `rls-production-exact-migration.log`, `photo-production-tests-final.log`, `photo-production-check-verified.log`. No tokens, messages, KYC records or production-user data are included in these reports.
