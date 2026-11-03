# Production authorization and readiness — November 3, 2026

Later clarification: user confirmed **Waydrop app only** and direct APK distribution. [Actual app-only rollout](WAYDROP_APP_PRODUCTION_ROLLOUT.md) subsequently deployed pricing76/live-status55. The zero-deployment ledger below is retained as the earlier preparation checkpoint, not the current overall production state. No admin APK/site publication followed this clarification.

The user explicitly authorized production rollout of completed work. **Authorization is recorded; no further permission is requested for the same scope.** Approval does not supply hosting credentials/targets, signed managed test identities, provider test destinations or old-writer drain evidence. These are missing technical resources, not a renewed approval gate.

**Execution ledger for this request: zero production migrations, Edge deployments, cron/config/policy changes, data writes or site publications.** No paid resource or test project created. Full production rollout is **not complete**.

## Concrete prepared releases

| Component | Prepared result | Actual rollout state |
|---|---|---|
| Flutter | [Signed Build62](../../artifacts/waydrop-1.0.0-build62.apk), version1.0.0(62), verified matching signer/source freeze; 2,233 Flutter passes,10 existing live skips,0 failures | Already available as a local APK. Not installed, published to Play or uploaded to a hosting/distribution service. Need chosen distribution target/account; native phone validation remains unperformed. |
| Admin web | [Production candidate ZIP](../../artifacts/waydrop-admin-20261103-production-candidate.zip), Vite build successful,95 files, valid index asset references, no plaintext `.env`, no detected service-role JWT or `sb_secret_` key in text bundles | Built and packaged only. No configured `.vercel`/Netlify/Firebase deployment target or Git remote found in the confirmed project. README contains generic hosting instructions, not the actual site. Existing hosting URL/service requested; not yet supplied. |
| Independent pricing/live-status caches | Exact production-preserving manifests already exist | Current deployed baselines rechecked, unchanged. Their hosted Auth/provider/response gates in existing release documents remain unperformed. Not blanket-deployed with shared dependency candidates. |
| Dispatch/acceptance/push/photo/RLS/Chat candidates | Prior local native/mock regressions and proposals retained | Combined backend **NO-GO** pending the separately documented integration and cutover requirements. No stale-worker recovery, acceptance pause or writer-cutover attempted. |

Admin ZIP SHA256: `58e7422fe367d0230507b0e502b68234913a6b4724c9041f40b97cf718e87939` (960,751bytes). [Artifact/source manifest](rollout-20261103/ADMIN_ARTIFACT.json). Flutter artifact SHA256 and evidence remain in [Build62 report](WAYDROP_BUILD62_SPEED_FIXES.md).

## Admin correction implemented while preparing deployment

Confirmed source root: `C:/Users/karth/Desktop/waydrop-admin (7)/waydrop-admin`.

- `src/pages/Dashboard.jsx`: failure of get_dashboard_stats previously triggered6additional queries for any error. Now transient/rate-limit/Auth/pool failures reject into the page's existing error handling; only recognized missing-function compatibility errors use the legacy fallback.
- `src/pages/Revenue.jsx`: same correction for get_revenue_data; ordinary backend failure no longer triggers3additional historical-data reads.
- `src/lib/adminRpcErrors.js`: shared code classification (`PGRST202`/`42883` compatibility). No message/token parsing, service-role client, changes to formulas, SQL, Auth, payment writes or permissions.
- `src/lib/adminRpcErrors.test.js`:21 focused cases exercising the actual exported page data-fetch functions through mocked Supabase query transport.

Baseline reproduction: temporarily restored the previous unconditional fallback behavior while retaining test exports; **14 failed /7 passed**, then corrected sources restored exactly. No production requests were made. Final complete admin suite: **58 passed /0 failed**, including37existing pricing cases and21new request-budget/compatibility cases. Vite build passed using existing dependencies/lockfile; existing React plugin/esbuild deprecation warnings remain. Logs: `.dart_tool/waydrop-local-runtime/admin-rollout-before.log`, `admin-rollout-final-tests.log`, `admin-rollout-build.log`.

Operation counts verified by the request-spy tests: successful fetch remains3requests; explicit missing-RPC fallback remains dashboard9/revenue6; timeout/pool/429/500/504/Auth/network error path now stops at the initial3requests. This is deterministic client fan-out prevention, **not a production latency benchmark**. Pending failure does not replace cached statistics with new zero-valued fallback results. This task did not redesign account-scoped caches or certify every admin security journey.

The previously reported LiveTracking whole-list reload, Ongoing overlapping batches, support inbox refetch and repeated revenue SQL aggregates are **not silently marked resolved**. They require their own implementation/parity/concurrency work. No new SQL financial optimization was rushed into this authorization.

## Production baseline rechecked

[Current Edge metadata](rollout-20261103/LIVE_EDGE_VERSIONS.json): pricing75, live-status54, accept-order60 and push24. Pricing/live-status bundle hashes match their captured baselines. These are inspections, not deployments. Source baselines and bundle hashes are different hash scopes; do not compare an old single-file hash with a bundle hash and label it drift.

No broad log query or data scan was used. The original November1 CPU/RAM/I/O initiating cause remains unproven. A successful app/site publication cannot be represented as repairing the demonstrated Storage metadata or shared API stalls.

## Required resources and safe execution order

1. **Admin hosting:** identify the existing site/account and retain its current deployment for rollback. Upload the reviewed ZIP to that target, preserve existing domain/TLS/security headers and SPA fallback, invalidate only relevant stale HTML, then verify normal/denied Auth and failure behavior. Do not invent a new production site or overwrite an unknown deployment. Source-only rollback restores the two `.before` page files and rebuilds with the retained lockfile; hosting rollback should use its retained previous release.
2. **Flutter distribution:** select direct APK distribution or the existing Play release channel. A locally signed APK is not a Play publication. Keep Build61 available; do not clear user queues/data to roll back. No attached ADB phone is available for installation/profile measurements.
3. **Managed backend validation:** provide an existing isolated Supabase environment with full current schema/triggers, actual signed Auth identities/roles, managed pg_net/Vault/Cron/Realtime, intercity capacity/fare scenarios, safe FCM/provider destinations and authorized Android test devices. Earlier test-project creation was declined and was not inferred from approval to deploy production. Local passing fixtures do not supply these resources.
4. **Cutover/drain:** for coordinated protocols, validate the exact current deployment manifest and all writer definitions/ACLs; rehearse hosted admission pause/cutoff and demonstrate no old worker/transaction remains before changing protocol. Do not pause live acceptance merely to discover the next prerequisite is missing. Preserve existing recovery schedules, ledger state and order/payment invariants.
5. **Rollback:** admin/Flutter can use retained compatible releases. Acceptance/push/dispatch must use reviewed fail-closed/forward-correction recovery; never restore known unfenced writers or reset sent/uncertain notification work. No blanket `db push` or all-functions deploy.

The acceptance preflight explicitly states **“NO-GO for production; local tests PASS”** ([WAVE_A_PREFLIGHT.md](../production-performance/edge-only/WAVE_A_PREFLIGHT.md)). The [blocker report](WAYDROP_BLOCKER_RESOLUTION_REPORT.md) separately requires managed full-trigger/Auth/provider validation and old-writer drain. The user's current approval clears authorization, while these technical conditions remain unresolved. This report records exactly what is prepared and what has not been executed.
