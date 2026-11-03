# Remaining release gates — NO-GO

Checked 1 November 2026. Production was not modified; no resources or charges were created. Wave A remains **acceptance-only**. Push, matching changes, index removals and config changes remain excluded.

## 1. Managed Auth / Realtime / transactional notifications — BLOCKED

**Access evidence:** the connected project inventory contains only production `yvwpchffctiagevpqgwy`; its development-branch inventory is empty. Computer/browser inventory exposes no dashboard. No existing managed test target is available to this agent. Local tests and read-only production wiring/health checks cannot prove the missing hosted write/session/event paths.

**Exact manual verification in an already-approved isolated managed target:**

1. Record the test project reference and prove it differs from production before any operation. Reproduce the reviewed schema, helper functions, RLS, triggers and grants using synthetic fixtures only. Keep production URLs, keys, device tokens, Storage objects, cron jobs and webhooks out. No new project/branch, upgrade or other charge is authorized by this runbook.
2. Create two synthetic passengers and two synthetic riders using the target's supported test-user method, with no real email/SMS delivery. Use target-only credentials through the operator's secure tooling, never chat. Preserve the intended KYC/eligibility and feature-flag checks.
3. Sign in, access the owning user's test order, refresh the session, retry access, then sign out and verify refresh/session behavior against the intended Auth contract. Verify missing, malformed, expired and wrong-user credentials are rejected. Do not assume logout immediately invalidates every previously issued access JWT.
4. Apply and deploy the **exact Wave A payload** only to that target; substitute the test reference in the invocation, not production. Rehearse the chosen deployment tool's transaction behavior, dependency bundling, `verify_jwt=false` with handler authentication, RPC ACL and REST schema cache. Do not copy production secrets.
5. Open target-only authenticated Realtime clients for the test passenger/riders. Verify own order/assignment/notification events, cross-user isolation and reconnect. Send two simultaneous acceptance requests for one synthetic order: 200/409, one matching accepted assignment, preserved fare/promo/commission. Repeat duplicate-request and one-rider/two-order cases.
6. Use a **test-only HTTP capture sink** for notification dispatch, not FCM or a production destination. Observe committed order and notification records, Realtime delivery and the target's pg_net enqueue/capture. Inject failure before commit and prove order/assignment/log changes, notification rows and queued HTTP side effects are rolled back. Confirm no losing/idempotent request creates extra notifications.
7. Save target ref, exact artifact hashes, request/status counts, observed event counts, error/rollback evidence and redacted logs. No personal records, passwords or tokens belong in the report. Actual push delivery remains separately blocked.

**Closure evidence needed:** hosted session tests, authorized/isolated Realtime events, commit-versus-rollback notification capture, and exact-payload deployment results. Until then this gate is pending, regardless of local test success.

## 2. Actual production backup and isolated recovery — BLOCKED

**Access evidence:** available read-only MCP methods expose project/current-source metadata, not backup inventory, restore-point timestamps or restoration proof. No dashboard is connected. This does not establish that backups do not exist. The successful existing restore drill used synthetic local data, not an actual production backup.

**Exact manual verification by an authorized administrator:**

1. Open production **Database → Backups** read-only. Record project ref, backup type, last completed backup timestamp/timezone, completion state, retention and the displayed available recovery/restore options. If no usable backup is shown, explicitly record that result. Do not enable PITR, upgrade, create a restore project or click production Restore.
2. Establish whether an existing backup can be recovered into an **already-approved isolated environment at zero additional cost**. Record its reference and recovery method. If the interface requires a paid restore/new project or no compatible target exists, STOP: no backup restore is authorized under that condition.
3. Perform the administrator-controlled restore only in that isolated target under the organization's data-handling rules. Do not download real user/KYC/payment data into this workspace or chat. Block production outbound connections and scheduled work before the target can execute restored jobs/webhooks. Keep any restored sensitive data restricted; use separate synthetic fixtures for functional tests.
4. Verify restore completion/job ID and data/schema consistency there: critical table counts/checksums, matching/acceptance/fare function hashes, RLS/grants, indexes, triggers, and required extension behavior. Check the actual supported recovery scope for Auth, Storage, Vault and Edge settings; database restore alone is not evidence for those services.
5. Save backup identifier/timestamp, target reference, successful restore status, duration and redacted aggregate verification results. Verify a durable, access-controlled copy of required recovery artifacts is available independently of this workstation.

A physical managed backup is not interchangeable with the local Windows logical-dump drill. If no approved compatible target/download/restore capability is available, this gate stays pending; do not substitute the previous synthetic restore result.

## 3. Previous acceptance Edge recovery — SOURCE RECONSTRUCTED; BUILD/HOSTED ROLLBACK BLOCKED

**New local evidence:** [recovery-v60/RECOVERY_MANIFEST.json](acceptance/recovery-v60/RECOVERY_MANIFEST.json) records four reread/hash-verified reconstruction files, including the exact captured v60 entrypoint and unchanged relative config helper. The captured hosted bundle identifier is `9e6101aa857a902aefaa82d64d066f845e506e18e60f34441f85a4dc08af9f01`. This is source reconstruction, not retrieval of that executable hosted bundle.

**Failed check retained:** the reconstructed unmodified source fails Deno 2.9.8 typechecking with the frozen local dependency snapshot: **TS2353**, `responded_at` is not a property of the inferred `{ id; assignment_status }` assignment object, `functions/accept-order/index.ts:483`. The original production runtime/dependency graph is not captured. No type annotation, SDK version or captured source was changed to hide this failure. This failure concerns the legacy recovery build; it is not a regression in the verified atomic candidate.

**Exact manual recovery demonstration:**

1. In the dashboard's `accept-order` version/deployment details, record pre-Wave-A version **60**, entrypoint, `verify_jwt=false`, bundle/deployment identifier and the available code/export/download method. If hosted historical artifacts cannot be retrieved, record that explicitly. Do not redeploy or restore production.
2. Retrieve the exact baseline artifact plus its relative dependencies and original build/runtime/lock information if available. Compare source SHA256 with the captured [FINAL_READ_ONLY_CHECK.json](acceptance/FINAL_READ_ONLY_CHECK.json). A matching source file alone does not prove matching dependency resolution.
3. In the approved isolated target, demonstrate an original reproducible build or a **separately reviewed compatible reconstruction**. A compatible reconstruction must preserve runtime semantics and pass tests; it must not be described as the original hosted binary. The current frozen-local build failure must be resolved with evidence, not `--no-check` or an unreviewed dependency update.
4. Keep acceptance traffic paused/drained. Rehearse fail-closed RPC disable while retaining the accepted-assignment unique index. Restore the prior Edge artifact only while traffic is blocked; verify its source/settings and absence of unintended side effects. Demonstrate the guarded object rollback/reapply as appropriate, without rewinding genuine business rows.
5. **v60 contains the known acceptance race. Do not reopen traffic on it.** Reapply the verified atomic release, rerun the synthetic acceptance/invariant and session/event checks, then restore test traffic only when the safe handler is verified.
6. Save target ref, artifacts/runtime/dependency hashes, deployment/rollback IDs, preserved ACL/settings, blocked-traffic evidence and test results. Agree a fail-closed incident plan; restoring a known-racy source file is not a safe operational recovery by itself.

## Final decision

**NO-GO.** Required closure evidence is missing for all three managed/recovery gates, with a concrete legacy recovery typecheck failure now recorded. No production deployment or resource creation was attempted. Exact candidate/recovery requests remain prepared in [MINIMAL_PRODUCTION_WAVE.md](MINIMAL_PRODUCTION_WAVE.md); they must not run before the gates and explicit final approval are satisfied.
