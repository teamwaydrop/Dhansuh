# Wave A: Edge-only acceptance preflight

Status: **NO-GO for production; local tests PASS. Nothing deployed.** This is the current plan and supersedes the SQL/RPC/index Wave A. The previously unverified database-backup risk is explicitly accepted by the user and is not a release gate.

Current verified update: accept-order/index.ts line 132 classifies the observed ECONNRESET as retryable 503. Atomic SQL/helper hashes are unchanged. Revised payload/manifest prepared after 16 native, 4 handler, 8 Edge, 8 network and 2065 Flutter checks passed; the detailed current evidence is ../../performance/VERIFICATION.json. No deployment occurred.

## Exact change

The prepared RPC is absent in production, so the earlier handler could not deploy alone. The local candidate now bundles the verified acceptance logic as an anonymous PL/pgSQL block in one direct PostgreSQL transaction. It creates no function, index, table or policy. Auth still uses getUser; the authenticated actor, not a body parameter, establishes rider ownership. Rider then order row locks serialize claims; fare/promo helpers, subscription waiver, matching eligibility and existing notification triggers are preserved. A successful response waits for COMMIT. Losers receive 409; duplicate winners return the existing result without rewriting timestamps/events. Statement and deferred-commit failures roll back. Inconsistent pre-existing accepted rows fail closed; no repair is attempted.

Release files:
- `supabase/functions/accept-order/index.ts`: Auth, feature gates and one transaction call; no split writes/RPC fallback.
- `supabase/functions/accept-order/atomic_acceptance.ts`: postgres.js 3.4.5, one connection per isolate, strict project endpoint/TLS validation, READ COMMITTED transaction, transaction-local role/claims/search_path/timeouts.
- `supabase/functions/accept-order/acceptance_sql.ts`: bundled anonymous transaction logic; no DDL.
- `supabase/functions/accept-order/deno.json`: Supabase JS 2.118.0 pin matching the verified dependency graph.
- `supabase/functions/_shared/production_config_cache.ts`: unchanged dependency; hash verified against captured production.

No production data was touched during this work. Normal future acceptance requests would update existing orders, assignments and logs; the release includes no data repair or test writes. Matching/GPS/push/index-removal/config/payment/KYC changes are excluded.

## Verification

| Check | Actual result | Scope |
|---|---|---|
| Additional real SDK/PostgREST/direct-DB network checks | 8 passed, 0 failed | Restricted non-superuser login, real signed-JWT REST, HTTP Auth adapter, concurrent winner/409, actor denial, no duplicate events, missing role grant, real lock timeout and terminated connection/retry |
| Local TLS driver checks | 3 passed, 0 failed | Untrusted CA rejected; trusted CA encrypted connection; wrong hostname rejected. Explicit synthetic CA; managed chain/factory branch still unverified |
| Read-only drain-query rehearsal | 2 assertions passed | Detects held writer and old transaction; clears after completion; routing cutoff still unverified |
| Native PG17 direct-driver tests | 16 passed, 0 failed | 7 competing riders; 12 duplicates; same-rider concurrent orders; eligibility; canonical fares/promo; subscription; rollback including deferred COMMIT failure; retry; inconsistent rows; no schema changes |
| Existing handler concurrency regression and recovery rehearsal | 4 passed, 0 failed | Real transaction driver/native PG; Auth/REST transport emulated; original and proposed matching fixtures compared locally only; emergency 503 makes no writes; restoring verified handler returns owner 200 |
| Auth/feature/error Edge regressions | 8 passed, 0 failed | Missing/invalid Auth, malformed input, actor binding, flags, retries, 409, fail-closed errors; transport mocked |
| Full Flutter suite | 2065 passed, 0 failed | Actual local rerun |
| Related Flutter tests | 176 passed, 0 failed | Seven relevant files, actual rerun |
| Analyzer | 0 issues | Seven changed Dart regression files |
| Deno builds | 3 passed | Release frozen check; compatible v60 frozen check; emergency handler check |
| v60 runtime equivalence | PASS | One type annotation only; erased JavaScript byte-identical |

Raw local logs: `.dart_tool/waydrop-local-runtime/edge-only-{native,handler,unit,flutter-targeted,flutter-full,analyzer}.log`. Machine-readable summaries/hashes: [RESULTS.json](RESULTS.json), [release manifest](RELEASE_MANIFEST.json), [handler results](HANDLER_RESULTS.json), [v60 proof](recovery-compatible/RECOVERY_PROOF.json). Older RPC/PostgREST results are historical evidence, not proof of this new direct-connection transport. Synthetic event capture proves transactional behavior locally, not managed notification delivery. No production benchmark or before/after improvement is claimed.

## Exact preparation/deployment commands

Preparation only, safe now:

```powershell
node docs/production-performance/edge-only/verify-recovery.mjs
node docs/production-performance/edge-only/build-wave.mjs
```

After all remaining gates and an artifact-specific final GO, use the exact Codex tool call in [DEPLOY_REQUEST.codex.js](DEPLOY_REQUEST.codex.js) through functions.exec. This file is orchestration code, not a Node CLI script. It calls `tools.mcp__codex_apps__supabase_deploy_edge_function` exactly once with project `yvwpchffctiagevpqgwy`, name `accept-order`, entrypoint `functions/accept-order/index.ts`, existing `verify_jwt:false`, and the five listed files. The function retains its own getUser verification. The same arguments are reviewable in [DEPLOY_REQUEST.json](DEPLOY_REQUEST.json). Do not run migrations, db push, SQL repair, secret updates or other deployments. Current read-only MCP authorization must not be silently broadened.

Order: satisfy managed gates below; confirm source/settings still match captured v60 and shared helper; record baseline acceptance status/latency and connection usage; establish acceptance ingress pause and prove old v60 requests drained; use the two-step acceptance-only pause/deploy procedure below; check hosted version/bundle; run authorized synthetic acceptance smoke checks; resume gradually and monitor. No implicit authority for test writes in production is granted by this plan.

## Tested recovery and exact commands

1. Pause new acceptance ingress and drain requests. A deployment cannot undo already committed orders; preserve winners and investigate inconsistent state without automated repairs.
2. If correctness regresses, execute the reviewed tool call [RECOVER_FAIL_CLOSED_REQUEST.codex.js](RECOVER_FAIL_CLOSED_REQUEST.codex.js). It deploys only accept-order: every non-OPTIONS request returns retryable 503, no dependencies/DB access. This trades acceptance availability for correctness. Local runtime rehearsal passed; hosted deployment/propagation remains untested.
3. Once corrected, redeploy the frozen verified payload using DEPLOY_REQUEST.codex.js, verify Auth/acceptance before restoring ingress. No database rollback SQL is needed or permitted for this Edge-only release.
4. The optional [RECOVER_LEGACY_PAUSED_ONLY_REQUEST.codex.js](RECOVER_LEGACY_PAUSED_ONLY_REQUEST.codex.js) reconstructs captured v60 with `let finalAssignment: Record<string, unknown> | null = assignment;` to fix TS2353. Original bytes remain archived. Build passes and emitted JS matches. **Never resume acceptance traffic on v60: its known race remains.** It is a forensic compatibility artifact, not a safe active-traffic rollback.

Immediate stop/fail-closed: any duplicate accepted assignment, accepted rider/assignment mismatch, fare/promo or ownership regression, successful loser, uncommitted-success response, Auth bypass, or missing transactional notifications. For availability, hold/resume only after reviewing sustained 5xx above 1% over 5 minutes (minimum 20 requests), repeated connection/lock timeouts, acceptance p95 above 2x freshly measured baseline, or database connections above 80% of the verified limit. These are proposed operational thresholds, not measured production results. Do not generate load benchmarks.

## Remaining GO/NO-GO gates and risks

- [ ] An authorized non-production managed test target with synthetic users is unavailable. Need valid Auth sign-in/refresh/logout, cross-user denial, competing acceptance requests, losing 409/no writes, winner retry, transactional notification enqueue, Realtime ownership isolation/reconnect and downstream trigger checks. No paid target or account was created. Read-only production Auth/publication/trigger evidence is retained in ../acceptance/MANAGED_AUTH_READ_ONLY.json and MANAGED_WIRING_READ_ONLY.json; it does not satisfy these tests.
- [ ] Managed direct-Postgres validation: SUPABASE_DB_URL is a documented default, but its actual availability, endpoint, TLS trust, role permissions, connection capacity and hosted Deno/npm compatibility have not been exercised. One connection per isolate still scales across isolates. Validate against the managed synthetic target, including connection failure/timeout/commit uncertainty. Never print connection strings or credentials. Official references: https://supabase.com/docs/guides/functions/secrets and https://supabase.com/docs/guides/functions/connect-to-postgres .
- [ ] Hosted recovery deployment/propagation and old-request drain are unproven. Rehearse the candidate -> emergency 503 -> candidate sequence on the managed test target. Available read-only tools do not expose historical hosted bundles. Reconstructed v60 source/settings are evidence, not a proven hosted rollback.
- [ ] No global unique index is added under this scope. The tested invariant applies to cooperating calls through this handler; an independent service/legacy writer changing assignments without the order lock can violate it. Saved policy definitions restrict rider client writes to sent/expired and passenger writes to accepted_by_user/rejected; clients cannot directly mark accepted under those policies (ASSIGNMENT_WRITER_EVIDENCE.json). Privileged external writers are not inventoried. Confirm those paths and drain old v60 invocations before opening traffic. A database-wide constraint would require a separately approved scope.
- [ ] Fresh drift/baseline check, agreed monitoring operator, authorized deployment/recovery channel and explicit final GO. Final GO is not requested while the above gates remain unresolved.

Push is excluded and remains gated on real delivery testing. No test destination is available. No resource provisioning, production mutation or charge was performed.

## Remaining operator actions (current checkpoint)

No isolated hosted target is exposed: current read-only inventory returns only production, zero branches, and browser inventory returns zero browsers/apps. Production remains v60 with captured source SHA 521fd8533d8a6d0fde15ccf9ceb211a8c631e3822f82c7f324b9e629736c9dfc and verify_jwt=false. No hosted tests were performed.

1. Provide access to an existing isolated managed project containing sanitized equivalent schema/triggers/RLS and synthetic fixtures. Do not copy production rows, credentials, Vault values, Firebase tokens or webhook secrets. No resource was created. If a new environment is needed, its provisioning/cost must be approved separately.
2. Supply four authorized synthetic accounts through an approved secure setup: passenger, two eligible riders, unrelated observer. Do not paste passwords/tokens in chat. Make a signed-in dashboard accessible through the connected browser, or have the operator capture the evidence below.
3. On that isolated target, deploy the exact candidate files with only project-specific identifiers changed. Verify SUPABASE_DB_URL/TLS/role and hosted npm/Deno runtime; record hosted source/settings hashes. Sign in, refresh and log out; verify refresh-session revocation and expired/invalid JWT denial. Do not assume logout immediately invalidates every previously issued access JWT. Race the two rider sessions on one synthetic order: exactly 200+409, one accepted assignment, unchanged loser writes, same fare/promo values; winning retry yields idempotent 200 with no additional rows/events.
4. Observe authorized Realtime order/assignment/notification events after commit, reconnect and re-read consistent state; verify the unrelated observer cannot read or receive another account's private rows. Check notification rows/transactional pg_net enqueue and downstream handler responses using isolated test sinks only. No real-device push delivery is claimed or required to ship excluded push changes. Record IDs/counts/statuses and hashes, never keys or real user payloads. If no safe isolated notification sink exists, leave that managed side effect explicitly unverified.
5. Hosted recovery rehearsal: candidate -> exact emergency 503 payload -> candidate. During 503, POST/GET return 503 with Retry-After=30 and OPTIONS returns 200; snapshot synthetic business rows/events before/after and confirm no changes. Reopen candidate and accept a fresh synthetic order. Capture deployed versions, propagation timestamps, source/settings hashes and request/response evidence. Local source reconstruction alone does not prove hosted recovery.

## v60 drain: acceptance-only two-step deployment (prepared, never executed)

This replaces the earlier single-deployment assumption. An eventual GO must cover both temporary acceptance unavailability and the atomic deployment. Other functions and database configuration stay unchanged.

1. Deploy the already prepared RECOVER_FAIL_CLOSED_REQUEST.codex.js to accept-order, then obtain a confirmed cutoff T after which the platform admits no new v60 invocations. Collect control-plane version/source confirmation plus version-attributed invocation evidence for all serving regions. A deployment acknowledgement, a single 503 probe, or absent logs alone is insufficient to prove global cutoff. If an ingress pause covers all callers instead, document that coverage. Without either verified cutoff mechanism, do not advance.
2. After T, keep acceptance paused for at least 480 seconds (400-second documented maximum worker lifetime plus an 80-second margin). Check the actual project's limits first; if its bound is higher/unknown, use the verified higher bound or stop. Do not substitute the 150-second request idle timeout. The current official limits distinguish worker lifetime (150 seconds Free / 400 seconds paid) from request idle timeout: [Supabase limits](https://supabase.com/docs/guides/functions/limits). This wait is a proposed safety margin, not evidence that a global routing cutoff has occurred.
3. Old database operations may outlive their HTTP worker. Run drain-check.read-only.sql with pause_cutoff_utc=T using an approved read-only channel. Require older_transactions=0, older_prepared_transactions=0 and order_write_locks=0; repeat once after five seconds while the cutoff remains confirmed. Investigate persistent activity; do not kill sessions automatically. The exact query was tested locally with an active synthetic writer and after release (DRAIN_RESULTS.json).
4. Only then submit DEPLOY_REQUEST.codex.js, confirm hosted code/settings, and resume under the existing monitoring thresholds. Any new v60 admission resets T. If rollout evidence or counters cannot be obtained, stay paused/recover safely and do not mark drain complete. Do not revert to active v60.

The pause and candidate calls are existing accept-order-only payloads. They are not approved for production execution. No secret/config/table/index/RLS/migration change is part of this procedure.

## Additional checks completed without repeating earlier suites

Runtime execution exposed missing remote-module hashes in the prior typecheck-only lock. The existing cache supplied the runtime graph; frozen actual network execution and root runtime cache/check now pass. Release source and all three deployment/recovery payload hashes are unchanged. verify-wave.mjs checks the five release files, three payload hashes and exact command arguments. Evidence: NETWORK_RESULTS.json, TLS_RESULTS.json, DRAIN_RESULTS.json, RELEASE_CHECKS.json. Re-run commands if needed: node network-integration.mjs; ./tls-integration.ps1 (both from this directory, with existing isolated PG17 running). At that checkpoint the unchanged suites were retained; the later ECONNRESET response update reran native/handler/Edge/network and full Flutter suites successfully (../../performance/VERIFICATION.json).
