> **Superseded checkpoint.** Current Wave A is Edge-only; follow [current preflight](edge-only/WAVE_A_PREFLIGHT.md) and [hashed payloads](edge-only/RELEASE_MANIFEST.json). Historical RPC/index deployment instructions below are excluded. Current test and release status is in [RESULTS.json](edge-only/RESULTS.json).

# Waydrop production deployment checklist — 1 November 2026

**Status: acceptance fixed locally; production approval and managed recovery gates remain open.** Target `yvwpchffctiagevpqgwy`. No production SQL, migrations, deployments or configuration changes were executed.

Latest minimal acceptance-only release package, exact prepared tool requests and read-only managed evidence: [MINIMAL_PRODUCTION_WAVE.md](MINIMAL_PRODUCTION_WAVE.md). Auth health/JWKS and invalid-session rejection are now verified; Realtime/notification wiring is verified. Valid sessions and live event delivery remain unverified. Current verdict remains **NO-GO**.

The three remaining gates now have exact manual closure procedures and a retained legacy recovery build failure in [REMAINING_GATE_VERIFICATION.md](REMAINING_GATE_VERIFICATION.md). Do not treat the reconstructed v60 source as a proven deployable recovery bundle.

## Verified

- [x] Atomic acceptance implementation and accepted-assignment uniqueness constraint prepared. Losing request returns 409 without partial acceptance; duplicate retries preserve committed state.
- [x] Latest rerun: **15 native PG17 acceptance groups and 2 handler concurrency tests passed**, including the formerly failing one-accepted-assignment assertion. Frozen-dependency Deno check passed.
- [x] Existing unchanged-code evidence retained: **2,064 full Flutter tests**, **214 related Flutter tests**, **58 Node tests**, **8 Edge tests**, **6 actual local REST/JWT/SDK checks**, **17 mocked push tests** passed; analyzer on 7 changed Dart test files found no issues. No unnecessary full-suite rerun or test skipping.
- [x] Local guarded rollback/reapply and synthetic restore passed. Restore compared 10 table-content hashes plus functions, owners/ACLs, policies, indexes and triggers.
- [x] All **5 acceptance release artifact hashes** match [RELEASE_MANIFEST.json](acceptance/RELEASE_MANIFEST.json).
- [x] Read-only MCP retrieved the current production acceptance handler: **v60**, `verify_jwt=false`, source matches the captured baseline; project metadata reports ACTIVE_HEALTHY. This is metadata verification, not an end-to-end production health test.
- [x] Index removals, speculative config changes and push deployment excluded from the acceptance release.

## Required before final GO

- [ ] Managed GoTrue/session, Supabase gateway/runtime, Realtime and transactional vault/pg_net notification behavior verified in an approved isolated environment or otherwise explicitly accepted with evidence. Local PostgREST is real transport testing, not proof of hosted runtime parity.
- [ ] **Backup availability pending:** the available MCP operations/project metadata do not expose backup inventory, restore-point dates/retention or restoration proof. This does not establish that no backups exist.
- [ ] **Hosted Edge rollback pending:** current source/version/bundle identifier are accessible; historical version inventory, retrievable old bundles, dependency reproducibility and managed restore/redeploy proof are not exposed. Captured v60 source alone is insufficient.
- [ ] Refresh duplicate/mismatched acceptance guards, deployed source hashes and a bounded acceptance API latency/error baseline immediately before the release window. Existing read-only checks found zero inconsistent acceptance aggregates at their check times; no historical rows were repaired.
- [ ] Explicit final GO naming **only** the acceptance SQL and Edge artifact hashes, deployment window, traffic-drain procedure and incident rollback authority. Do not infer approval from local test success.

Real push delivery is separately pending: the user confirmed no safe Firebase test destination. Keep all push deployment gated.

## Execution after all required gates and final GO

1. Pause and drain acceptance traffic using the explicitly approved operational procedure. Do not mix legacy split-write v60 requests with the new path and assume the transition is proven safe.
2. Apply only [01_atomic_acceptance.deploy.sql](acceptance/01_atomic_acceptance.deploy.sql) as one reviewed migration through the rehearsed deployment tool. The exact COMMIT payload is already saved and hashed. Its guards refuse existing objects or duplicate accepted assignments; lock/statement timeouts abort the operation. Do not run test-fixture SQL or a repository-wide migration push.
3. Verify private service-only RPC ACL, function hash/search path, valid accepted-assignment unique index and REST schema visibility. Deploy only [accept-order/index.ts](../../supabase/functions/accept-order/index.ts), preserving `verify_jwt=false` and the unchanged shared config helper. Change no secrets, Auth settings, payment formulas or KYC flows.
4. Validate application auth, winner/loser responses, duplicate retries, unchanged fares/promos/commission, dispatch, tracking and notifications before progressing. Observe genuine traffic; create no synthetic production orders, payments or push probes.
5. Stop acceptance traffic and rollout immediately for any duplicate/wrong accepted rider, wrong amount, authorization regression, or missed critical dispatch/tracking event. Proposed quantitative stop thresholds: comparable p95 > baseline +20% or server-error rate > baseline +1 percentage point. Count business 409s separately. Require at least 20 genuine accepts before a subsequent release; insufficient traffic means continued observation, not success.
6. The first fail-closed incident option is [03_disable_atomic_rpc.sql](acceptance/03_disable_atomic_rpc.sql), retaining the unique index. It is review-only and defaults to ROLLBACK; commit only under the approved incident procedure. Never silently reactivate the known-racy v60 write path.
7. Full object rollback uses [02_rollback_atomic_acceptance.sql](acceptance/02_rollback_atomic_acceptance.sql) only with traffic paused/drained, exact drift guards satisfied, verified Edge recovery and session acknowledgement `app.acceptance_rollback_traffic_drained='approved'`. It removes only the new objects, uses RESTRICT and changes no historical business rows. Keep traffic paused until a safe handler is restored. Code rollback cannot reverse genuine accepted orders or unsend notifications.

Implementation details and repeatable commands: [acceptance/README.md](acceptance/README.md). Latest MCP evidence: [FINAL_READ_ONLY_CHECK.json](acceptance/FINAL_READ_ONLY_CHECK.json). Production remains unchanged; **no final GO is requested while required gates remain open**.
