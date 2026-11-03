# Waydrop app production rollout — November 3, 2026

Later app-only follow-up: [current Supabase applied status](WAYDROP_SUPABASE_APPLIED_STATUS.md) additionally applies the independently verified four-SELECT-policy optimization and legacy-compatible photo19 guard/deadline. The two-function/zero-SQL checkpoint below is retained as historical execution evidence. Its final smoke file was refreshed by the later post-RLS5/5rerun (969ms synthetic quote); the earlier1125ms sample is the earlier runner summary, not the current raw probe. Coupled protocol gates remain unresolved. No AAB work or new project was authorized after the user's clarification.

The user clarified the scope is **Waydrop app, not admin**, and explicitly authorized moving completed local fixes to production. Two independent read-path cache changes have now actually been deployed. This is **not completion of the combined SQL/Edge/security rollout**.

## Executed production changes

Project `yvwpchffctiagevpqgwy`.

| Function | Before → deployed | Platform deployment time | Scope |
|---|---|---|---|
| calculate-order-pricing | **75 → 76, ACTIVE** | **10:33:32 UTC / 16:03:32 IST** | Normal active-zone reads use a30second isolate cache and share an in-flight read. Original config prefetch, fresh LIMIT1 fallback and fare/GST calculations preserved. |
| get-live-order-status | **54 → 55, ACTIVE** | **10:34:01 UTC / 16:04:01 IST** | Same-path Storage signing and same-order ETA requests share raw work. Existing handler, Auth/ownership checks, dependency code,5.5hour signed-URL refresh/6hour validity,20second ETA TTL and2second visible budget preserved. |

Bundle SHA256 values:

- Pricing76: `76ab498d0890dddb6d1cd551c351c04dce94edaf42d98cf653be5e00bead94e2`.
- Live-status55: `40c1c6938c0a569797bffcb64aee6c8fdedfb390dd67ef815d2cf8a93a862944`.

[Machine ledger](app-production-20261103/DEPLOYMENT_LEDGER.json), [pricing deployment receipt](app-production-20261103/calculate-order-pricing.deployment-result.json), [live-status receipt](app-production-20261103/get-live-order-status.deployment-result.json).

**No SQL migration, RLS/policy edit, cron/configuration change, production customer/order/payment write or admin deployment was performed.** No test project or paid resource was created. Final inventory confirms acceptance60, push24 and photo18 remain unchanged. The platform-level `verify_jwt=false` setting was preserved for both functions; the live-status handler's existing explicit Auth/ownership enforcement is byte-identical, not removed.

## Review and verification before rollout

1. Fresh production versions/bundle hashes matched the captured75/54 baselines, including an immediate pre-deploy check for each function. A drift mismatch would have aborted that function's deployment.
2. Frozen candidate manifests were verified file by file. Pricing changed only its zone-query import/use and added the zone helper. Live-status changed only two cache helpers; handler and five other dependencies remained exact captured production source. No older local handler or blanket shared folder was uploaded. [Preflight](app-production-20261103/PREFLIGHT.json); individual `.diff` files are adjacent.
3. Fresh local cache/pricing tests: **27 passed,0 failed**. Actual pricing handler before/candidate differential tests: **4 passed,0 failed**. Tested root helper bytes match the exact deployed candidate helper bytes. No formula/security/eligibility test was removed.
4. Both actual candidate entrypoints passed cached-only, **frozen** production-dependency type checking. The initial shared lock was incomplete for11fixed `std@0.168.0` modules. A separate release lock was extended from the existing cache, every previous dependency hash was asserted unchanged, and frozen checking then passed. No SDK upgrade or shared lock edit.
5. Five pre-deploy hosted probes passed: pricing missing-field400, live-status missing-Auth401, both OPTIONS200/CORS, and a successful read-only Auto quote using existing public service-zone configuration. No passenger/rider identity, private order or payment was used.

Logs: `.dart_tool/waydrop-local-runtime/app-production-cache-tests.log`, `app-production-pricing-tests.log`, `app-production-check-frozen.log`. This rollout follows named-function deployment and post-deploy invocation rather than all-functions deployment ([official Supabase procedure](https://supabase.com/docs/guides/functions/deploy)).

## Hosted verification and observation

- Retrieved both newly deployed functions and compared **every hosted source file exactly** with its reviewed payload; metadata/status/version/settings matched.
- **5/5 live probes passed after pricing**, then **5/5 passed after both deployments**. The public quote response was canonically identical to baseline, including fare/GST/configuration fields. Live-status still rejected missing authorization with401.
- The read-only quote used only public configuration; it did not create an order, assignment, payment, notification or provider delivery. There were15bounded hosted probes total across the three phases.
- One bounded log aggregate, limited to these two function IDs, recorded **0HTTP5xx for new76/55** in the short observation window. Pricing76 had6logged requests; live-status55 had2. Some200s are OPTIONS, not successful private-order access. Ingestion/window limitations mean this is not full traffic/peak-load clearance.

[Before probes](app-production-20261103/SMOKE_BEFORE.json), [after pricing](app-production-20261103/SMOKE_AFTER_PRICING.json), [final probes](app-production-20261103/SMOKE_AFTER.json). Exact monitoring start/end and aggregate counts are in the machine ledger.

The local operation-count evidence remains: three same-isolate simultaneous zone reads/sign operations/ETA calls coalesce to one corresponding operation. This is not a measured global production reduction: different isolates keep separate caches. The single synthetic quote samples (1453ms baseline,906ms after pricing,1125ms final) are **not a controlled latency benchmark or Android speed measurement**. No claim of eliminating the original resource constraint is made.

## Risk boundary and rollback

The30second zone cache introduces a bounded zone-edit propagation delay, like the existing30second rate-config cache; it does not cache user fares or orders. Admin zone edits can take up to that window to affect the quote endpoint. Original per-request LIMIT1 fallback remains fresh. Live-status preserves prior cache lifetimes and never reuses authorization decisions; authorization occurs in its unchanged handler before helpers are called. ETA remains approximate/degraded on its established budget/failure path.

This narrow read-path rollout was selected under the user's latest explicit production authorization, supported by exact-source drift checks, local differential tests and hosted read-only/negative smoke tests. Full signed-in active-order/provider/device journeys are **not** claimed: no signed synthetic managed passenger/rider session or test device was available. Prior managed/full-writer gates remain binding for the coordinated protocols and broad security changes below. A negative401 test alone is not complete authorization certification.

Before snapshots and complete rollback payloads are retained:

- `app-production-20261103/calculate-order-pricing.before.json` and `.rollback.json`.
- `app-production-20261103/get-live-order-status.before.json` and `.rollback.json`.

If regressions arise, verify live drift and restore only the affected exact captured read-path function/settings. Rollback is another deployment/version, not data repair. No SQL rollback is required for these two changes. Do not use this permission to revert acceptance/push writers or remove ledgers. No rollback was executed because source and bounded live verification passed.

## Flutter delivery and work not deployed

[Build62 signed APK](../../artifacts/waydrop-1.0.0-build62.apk) remains available for direct APK distribution, as the user clarified. SHA256 `843ba7b998487aabb7a20ba57afb2b8b171305f9922c2e3604ebd287c81773f3`. APK hash and all183frozen app/source hashes rechecked unchanged in this rollout. Last complete Flutter suite remains **2,233passed,0failed,10existing live skips**; it was not rerun for unchanged Flutter source. APK installation was not performed; the latest explicitly confirmed installed build earlier was61. Backend deployment does not update an installed APK.

**Still not deployed / full rollout incomplete:**

- Coordinated dispatch ownership/recovery/coalescing, acceptance and eligibility SQL/Edge protocol.
- Durable push claim/outbox/recovery protocol and real FCM/device validation.
- Atomic photo RPC/handler cutover, Chat sender policy and four-policy RLS optimization.
- Any blanket historical migrations, automatic historical data repair, publication/index changes, compute upgrade, pool/timeout changes or cron changes.

Connected project inventory was checked again: **only production exists**. No isolated managed environment is available, and earlier project creation was declined. Full current-schema triggers, signed managed Auth identities/roles, intercity/payment/provider cases, FCM destination and old-writer admission/cutoff/drain tests are still missing. Deploying these coordinated changes without them would risk active orders, payments or notifications. Existing local concurrency successes do not replace those gates.

The original November1 initiating CPU/RAM/I/O cause, Storage metadata stalls and shared resource-onset attribution remain **unproven/unresolved**. Two cache deployments and an APK are not evidence those problems are fixed. Admin work remains outside this app-only rollout.
