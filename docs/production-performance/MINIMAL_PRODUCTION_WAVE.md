> **Superseded checkpoint.** Current Wave A is Edge-only; follow [current preflight](edge-only/WAVE_A_PREFLIGHT.md) and [hashed payloads](edge-only/RELEASE_MANIFEST.json). Historical RPC/index deployment instructions below are excluded. Current test and release status is in [RESULTS.json](edge-only/RESULTS.json).

# Wave A — atomic acceptance only

**Verdict: NO-GO pending managed integration and production recovery evidence. Nothing deployed.** All production activity in this pass was read-only; no charges or resources were created. Verified acceptance and matching code were preserved.

Latest blocker evidence and exact manual verification: [REMAINING_GATE_VERIFICATION.md](REMAINING_GATE_VERIFICATION.md). Only production is available, no test branches/dashboard are exposed, and reconstructed legacy v60 fails the local frozen typecheck (TS2353). The atomic candidate still passes its frozen check and all five release hashes are unchanged. Source reconstruction is not hosted rollback proof.

## Remaining integration checks: exact status

| Area | Read-only evidence completed | Still unverified |
| --- | --- | --- |
| Managed Auth | Health GET 200; public JWKS GET 200 with ES256 key; invalid-session GET rejected 403 with an invalid-JWT reason | Valid user sign-in/session refresh/logout and actual user-scoped access. No test users/sessions were created |
| Realtime | `orders`, `rider_assignments`, `riders`, `rider_locations`, `notifications` published; INSERT/UPDATE/DELETE enabled; all five tables have RLS | Authorized live event delivery, reconnect behavior and user isolation. No subscription to production data was opened |
| Notifications | Relevant triggers enabled; pg_net 0.20.0; wrapper references Vault, HTTP POST and timeout; own-user notification policies present; no recorded failures in the bounded last-24-hour aggregate | Transactional enqueue and managed delivery after acceptance. An empty failure log is not delivery proof |
| Backup recovery | Local synthetic restore and rollback already passed | Actual production backup inventory/dates/retention/restore not exposed by available read-only MCP methods |
| Edge recovery | Current v60 source, settings and bundle identifier captured and checked against baseline | Historical hosted bundle inventory, retrieval, dependency reproducibility and actual managed restoration not exposed |
| Push | 17 existing mocked full-handler tests passed | No safe real destination exists; **push deployment stays blocked** |

Evidence: [Auth probes](acceptance/MANAGED_AUTH_READ_ONLY.json), [Realtime/notification wiring](acceptance/MANAGED_WIRING_READ_ONLY.json), [current Edge/recovery limitations](acceptance/FINAL_READ_ONLY_CHECK.json). These distinguish configuration checks from successful managed end-to-end tests.

The unperformed managed tests require an approved isolated managed test target and authorized synthetic accounts/destinations. They cannot be honestly completed by reading production metadata or invoking writes in production. No target was provisioned. A production GO must not waive these gaps implicitly.

## Minimal scope and exact artifacts

1. [01_atomic_acceptance.deploy.sql](acceptance/01_atomic_acceptance.deploy.sql): one transaction adding the private service-only RPC and a correctness unique index on accepted assignments. No historical-row repair or unrelated policy change.
2. [accept-order/index.ts](../../supabase/functions/accept-order/index.ts): single acceptance-write RPC, actor from validated user session, existing flags retained, 409 conflict and retryable 503 handling.
3. `supabase/functions/_shared/production_config_cache.ts`: unchanged dependency, verified against captured production source.

This wave excludes matching performance changes, GPS/index removals, config experiments, push updates, payment/KYC changes and paid resources. Matching remains preserved for a **separate** later wave after acceptance is stable.

Exact file hashes: [RELEASE_MANIFEST.json](acceptance/RELEASE_MANIFEST.json). Exact source-inclusive tool arguments and recovery requests: [WAVE_A_REQUESTS.json](acceptance/WAVE_A_REQUESTS.json). Its SHA256 and unchanged shared-helper hash: [WAVE_A_MANIFEST.json](acceptance/WAVE_A_MANIFEST.json).

## Exact command preparation and deployment operations

The following local preparation command performs **no deployment**:

```powershell
node docs/production-performance/acceptance/build-wave.mjs
```

After all gates and explicit final GO, invoke the following MCP operations with the **exact materialized arguments** in `WAVE_A_REQUESTS.json`:

| Sequence | Tool command | Exact argument object |
| --- | --- | --- |
| 1 | `mcp__codex_apps__supabase_apply_migration` | `ordered_requests[0].arguments` — project `yvwpchffctiagevpqgwy`, name `waydrop_atomic_order_acceptance`, exact reviewed SQL bytes |
| 2 | `mcp__codex_apps__supabase_deploy_edge_function` | `ordered_requests[1].arguments` — only `accept-order`, exact two uploaded source files, `verify_jwt=false` preserved |

These are prepared commands, **not calls executed by this work**. The current MCP configuration stays read-only. Any future deployment needs a separately approved write-capable channel. Do not toggle its permissions or use a different credential as an implicit workaround.

## GO / NO-GO checklist

- [x] Local correctness: 15 native acceptance groups, 2 handler concurrency tests, 8 Edge tests and 6 real local REST/JWT/SDK checks pass; failing assertion retained and passing.
- [x] Full existing Flutter suite 2,064 passed, Node 58 passed; unchanged verified results reused. No new acceptance/matching implementation changes in this pass.
- [x] Local object rollback/reapply and synthetic restore verified; exact candidate hashes checked.
- [x] Read-only managed health/negative-auth and wiring evidence saved with limitations.
- [ ] Approved managed test of valid sessions, acceptance event delivery, Realtime and deployment-tool transaction/bundle/schema-cache behavior.
- [ ] Evidence of available production backups/restore and retrievable/restorable previous Edge artifacts with reproducible dependencies. Source snapshots alone are insufficient.
- [ ] Fresh bounded acceptance baseline, zero duplicate/mismatched acceptance guards, unchanged production hashes and approved pause/drain procedure.
- [ ] Explicit final GO for Wave A artifact/request hashes and incident authority. No broader performance/push approval inferred.

While any required box remains open: **NO-GO**.

## Deployment, monitoring and recovery

Pause/drain acceptance traffic before the coordinated SQL + Edge release; do not mix old split writes with the new RPC and call it a proven safe rolling transition. Verify ACL, function/index hashes and schema visibility before reopening. Observe genuine orders only; no synthetic production write probes.

Stop traffic and rollout immediately for any duplicate/wrong accepted rider, wrong fare/promo/commission, authorization failure or missing critical event. Proposed quantitative stops: comparable p95 > baseline +20% or infrastructure errors > baseline +1 percentage point; count expected business 409s separately. At least 20 genuine acceptances before a subsequent wave; insufficient traffic means more observation.

Recovery commands are fully materialized under `incident_requests` in the request file. **Do not execute them now.** `fail_closed.arguments` commits the guarded [03_disable_atomic_rpc.sql](acceptance/03_disable_atomic_rpc.sql) body, revoking only the new RPC while retaining the unique index. It prevents the new handler from making acceptance writes and does not restore the unsafe old path.

`full_object_rollback.arguments` commits [02_rollback_atomic_acceptance.sql](acceptance/02_rollback_atomic_acceptance.sql) with explicit traffic-drain session acknowledgement. Only use it after the traffic is actually paused/drained and previous Edge recovery is verified; the acknowledgement is not a substitute for that check. It uses drift guards and RESTRICT, removes only the new objects and rewinds no business rows. Keep traffic paused until a safe handler is restored. Never silently route traffic back to known-racy v60. Rollback cannot unsend notifications or reverse genuine accepted orders/payments.

Detailed tested procedure: [acceptance/README.md](acceptance/README.md). No production before/after improvement is claimed because no change was deployed.
