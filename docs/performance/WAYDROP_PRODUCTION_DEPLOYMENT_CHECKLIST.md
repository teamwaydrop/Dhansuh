# Latest Supabase app changes applied - 3 November 2026

**Live:** pricing76, live-status55, photo19, plus the four-SELECT-policy statement-cache migration `20261103162805`. [Current applied status, exact verification, rollback and pending protocols](WAYDROP_SUPABASE_APPLIED_STATUS.md). Post-RLS catalog shows exactly four expressions changed; grants/helpers/write rules unchanged. No new Supabase project, no AAB publication, no admin rollout. Historical blocked/zero-deployment entries below remain scoped to their earlier checkpoints. Full coordinated rollout remains incomplete.

---

# Waydrop app production changes executed - 3 November 2026

**Two independent app cache fixes are now LIVE:** calculate-order-pricing75 to76, get-live-order-status54 to55. Exact hosted files/settings verified;31local tests plus5/5pre and5/5post live checks pass; public test quote unchanged; bounded monitoring has0HTTP5xx. No SQL/cron/policy/admin changes. [Actual execution ledger, verification, rollback and remaining blocks](WAYDROP_APP_PRODUCTION_ROLLOUT.md). Signed Build62 remains ready for direct APK distribution; not remotely installed. Coordinated acceptance/dispatch/push/photo/RLS/Chat bundles remain blocked by their technical gates. Historical zero-deployment statements below describe earlier requests and are superseded only for these two named functions.

---

# Current production authorization - 3 November 2026

User authorized rollout of completed work. **Authorization received; full rollout not executed.** [Current preparation, admin correction/test ZIP, production version checks and exact missing resources](WAYDROP_PRODUCTION_ROLLOUT_2026_11_03.md). Build62 remains a signed local APK; admin production build is packaged but hosting target is missing. Combined backend technical NO-GO gates remain unmet. Historical statements below retain their original scope; do not treat old permission wording as a new request for approval.

---

# Build61 client test artifact - 3 November 2026

- [x] [Final signed APK1.0.0(61)](../../artifacts/waydrop-1.0.0-build61.apk), signer matches60, all182 final source hashes stable, three AOT libraries updated, no plaintext .env asset. [Artifact manifest](proof-wait-20261103/APK_VERIFICATION.json). Earlier source-overlapping61 attempt excluded; final build forced a new compiler environment with an unused public source-fingerprint define.
- [x] Four local critical-path/error/query fixes with proof/OTP, intercity/long-ride and account/disposal safeguards preserved. Local-only metadata query1 to0; intercity/long-ride query retained1 to1.
- [x] Full Flutter **2,216 pass / 10 existing live skips / 0 fail**; focused56 pass; changed-four-file analyzer0 errors/0 warnings/6 legacy infos. No test removed or security invariant relaxed.
- [ ] Real-device matched startup/Home/accept-to-order/proof/OTP/error-retry/completion/account-switch journeys. No install/publication or measured phone speed guarantee. User had not installed60;61 is now the latest test artifact.
- [ ] Existing coordinated SQL/Edge managed Auth/full-trigger/provider/all-writer-drain gates unchanged. No backend implementation/migration/deployment/config changes in this follow-up.
- [ ] Historical/current peak CPU/RAM/swap/disk and Storage/PostgREST pool onset traces. Quiet snapshots are not peak clearance. No host-metrics connector or browser surface available; no assumed historical charts.

[Full source/evidence/limits](WAYDROP_DEEP_RIDER_FLOW_BUILD61.md). Client artifact CONDITIONAL on device/security compatibility; coordinated backend bundles remain NO-GO. No paid resource or new project.

---

# Build60 and additional safe backend candidates - 3 November 2026

- [x] Signed local [1.0.0(60) APK](../../artifacts/waydrop-1.0.0-build60.apk), same signer as59, all182 frozen source files unchanged and all three AOT libraries changed. Newest Home/pricing fixes included. [Artifact verification](safe-speed-20261103/APK_VERIFICATION.json).
- [x] Full Flutter **2,204 pass / 10 existing live skips / 0 fail**. Focused37 pass; changed-six-file analyzer0 errors/0 warnings/6 existing infos.
- [x] Immutable proof upload + screen/account transport ownership; bounded visible deadlines never release raw pending ownership. No automatic replay/bypass of uncertain proof writes.
- [x] Photo full-body deadline tested; native atomic proof9 groups and actual handler/native6 cases pass. Service-only [SQL review candidate](safe-speed-20261103/PHOTO_ATOMIC_RPC.review.sql) and [matching handler manifest](safe-speed-20261103/PHOTO_ATOMIC_MANIFEST.json) prepared. Not installed/deployed.
- [x] [Pricing v75-preserving candidate](safe-speed-20261103/PRICING_V75_MANIFEST.json) differential tests pass; prefetch and fresh LIMIT-1 fallback preserved. Prior v54 cache-only manifest remains separate.
- [x] Existing local safety suites rechecked sequentially: native dispatch/push17, Edge/native15, Chat14 pass. An overlapping-fixture run was discarded, not counted as passing evidence.
- [ ] Managed full-schema triggers, Auth/JWT/RLS, intercity/financial, safe FCM destination and all-writer lock-order/cutover/drain verification. Existing declined cloud-project decision respected; no new project or paid resource.
- [ ] Atomic photo requires additive reviewed RPC plus drained legacy photo writers before compatible handler activation. Never rolling-mix protocols or automatically repair legacy partial records. On regression close admission/fail closed and prefer a forward correction; do not restore known unsafe guards/writers or delete durable state.
- [ ] Actual-device Build60 journeys and matched latency/profile measurements. No installation or publication here. Post-proof refresh/OTP remain backend-dependent; no whole-flow speed guarantee.
- [ ] Storage metadata timeout resource/wait onset evidence. No pool/timeouts/configuration changes or required-write removal.

[Complete implementation, tests and rollout/rollback limits](WAYDROP_SAFE_SPEED_FIXES_BUILD60.md). **No production writes/deployments in this follow-up. Combined SQL/Edge remain NO-GO; Flutter test candidate CONDITIONAL.** Historical ledger entries below retain their own scopes.

---

# Edge/table review candidates ? 3 November 2026

- [x] Read-only captured production pricing v75, live-status v54, photo v18, intercity matching v49; inspect selected FK/index/trigger/view metadata, one plain EXPLAIN without ANALYZE, one 15-minute bounded Edge log aggregate (no traffic rows).
- [x] Local cache concurrency and early photo scope fixes: **77 Deno pass / 0 fail**, Flutter **2,193 pass / 10 existing live skips / 0 fail**. No Edge/SQL/config/data deployment in this follow-up.
- [x] Cache-only candidate preserves captured v54 handler, single-relation/location improvements and all other dependencies. Only eta_cache.ts and signed_url_cache.ts differ. [Manifest](edge-load-20261103/live-status-candidate.manifest.json).
- [x] Photo early-guard candidate preserves captured v18 HTTP helper and changes only the handler. [Manifest](edge-load-20261103/photo-candidate.manifest.json).
- [ ] Hosted authorization/provider/response verification remains unavailable. No new test project or paid resource created. Do not deploy an older local live-status handler over v54 or blanket-deploy all shared files.
- [ ] Photo assignment snapshot is not transaction-time fencing; partial multi-table success/replay and body-download deadline remain unresolved. Early guard does not clear atomicity/security release requirements. Avoid rollback that reintroduces the demonstrated missing order-scope check; prefer reviewed fail-closed/corrected guard recovery.
- [ ] Pricing zone-cache reconciliation with deployed v75 config-prefetch behavior and existing pricing/provider gates remains pending. No fare/tax/eligibility changes authorized by a cache test.

[Full evidence and limitations](WAYDROP_EDGE_TABLE_LOAD_OPTIMIZATION.md). Combined dispatch/push SQL/Edge NO-GO remains in force. Original incident CPU/memory/I/O initiating cause unproven. All historical release ledger entries below remain scoped to their own date/candidate.

---

# Independent backend release ledger ? 3 November 2026

- [x] Only `20261103015444_waydrop_skip_idle_stalled_redispatch_reads` applied under the latest backend-fix request. No pending migration bundle push.
- [x] Guarded original-definition/owner/settings/ACL preflight; candidate MD5 verified `d70d703c15e3ee72834dc627af1fee80` at 01:54:53 IST. An initial CRLF hash mismatch rolled back; normalized LF apply succeeded.
- [x] Original advisory lock, every-minute schedule, service-only EXECUTE permissions and terminal cleanup retained; no business-row repair, acceptance/payment change or Edge deployment.
- [x] Native 12 parity groups + 6 migration/rollback checks pass. Normal 01:55 cron execution succeeded, 8.730ms. Advisors refreshed; existing warnings require separate review.
- [x] Full default Flutter **2,193 pass / 10 explicitly skipped / 0 fail**. Ten existing live pricing cases retained with explicit opt-in; targeted analyzer no issues.
- [ ] Peak-time CPU/RAM/swap/disk onset correlation and Storage/Auth recovery still unverified. No proof that Free plan or this cron function initiated the historical slowdown.
- [ ] Past intercity lifecycle correction (58 orders), RLS candidate and combined dispatch/push bundles are NOT released. Prior safety/managed integration gates remain in force.

[Evidence and release boundaries](WAYDROP_BACKEND_CURRENT_HEALTH_2026_11_03.md). [Rollback review](backend-live-20261103/ROLLBACK.review.sql) defaults to ROLLBACK; verify current hash, normalize LF and explicitly choose COMMIT only when executing a separately selected rollback. Do not run blanket migrations or restore business data. Historical ledger statements below remain scoped to their recorded candidates/date.

---

# Waydrop production deployment checklist

## Build59 client-only candidate

[Redundant work removal and handoff](WAYDROP_REDUNDANT_WORK_REMOVAL.md) | [Verification](build59-20261102/VERIFICATION.json).

Client changes after58: safe immutable photo reconciliation and retained selections; Rider/account request ownership after UI timeout; transient Auth errors remain retryable; owner/NULL-aware conditional notification/mode writes. Full Flutter **2,188 pass/0 fail**, focused30 pass, six native predicate/concurrency groups pass. Changed-five-file analyzer0 errors/0 warnings/1 existing info. Release build PASS:1.0.0(59), same verified signer as58, all three AOT libraries changed and frozen sources unchanged. [APK](../../artifacts/waydrop-1.0.0-build59.apk). No device install, production deployment or latency improvement is inferred.

- Android release gate: both parcel upload flows and uncertain-result Check / retry, Home entry/mode switch/Back to Home, account timeout retry and real KYC/blocked-account denial must be tested against the actual service.
- Client update requires no new SQL/Edge deployment. Other old clients still issue their old requests/writes. Storage metadata INSERT remains required; its backend stall is unresolved.
- Production SQL/Edge combined **NO-GO** and all existing fencing, managed-integration and old-writer-drain requirements remain. No new production changes, configuration edits, paid resources or cloud test project in this follow-up.

## Build 58 completion transition / Storage timeout - 2 November 2026

[Completion/Storage evidence and handoff](WAYDROP_COMPLETION_PHOTO_2050_2105.md) | [Frozen verification](completion-2050-20261102/VERIFICATION.json).

Client candidate preserves fresh KYC/rider/payout validation while reusing its response once per consumer. Actual guarded recreation drops **3 rider reads to1**; the pending access view uses the rider theme. **2,147 full Flutter tests pass**, focused18 pass, changed-file analyzer no issues. Signature/artifact result is in the manifest; actual phone transition/frame checks remain required. The existing root-stack policy and non-cancelling guard timeout ownership are not declared solved.

Photo backend has a confirmed **Storage DatabaseTimeout544 / PostgreSQL57014**, with 33.2-second service execution. **No production Storage fix is selected/applied** without the missing SQL/wait/pool/resource trace. Do not claim this APK or the separate public-table RLS candidate repairs that failure. No blind timeout/pool increase, automatic proof bypass or object cleanup. A support draft exists but was not submitted.

Production remains read-only. Independent RLS candidate is conditional/unapproved; combined SQL/Edge rollout gates remain unchanged. No new paid resources or automatic deployment.

## RLS hot-path candidate and Build 57 - 2 November 2026

**Current work remains production read-only.** [RLS validation, measurements and exact rollout/rollback sequence](WAYDROP_RLS_HOTPATH_VALIDATION.md) | [Frozen verification](rls-hotpath-20261102/VERIFICATION.json). The prior authorized deployments below are historical and do not authorize this candidate.

- Standalone four-SELECT-policy RLS candidate: **CONDITIONAL, local validation passed; not production-approved/deployed**. Guarded [review candidate](rls-hotpath-20261102/RLS_INITPLAN_CANDIDATE.sql) and [rollback](rls-hotpath-20261102/RLS_INITPLAN_ROLLBACK.sql) both default to ROLLBACK. No automatic migration. Freeze reviewed hashes, recheck helper/policy drift, complete controlled managed authenticated allow/deny smoke coverage, then obtain explicit approval before any committed production apply.
- Local evidence: nine-actor rowset parity, unchanged anon denials/UPDATE target sets, prepared-identity/admin-revocation checks, 16 concurrent identity reads and guarded rollback. Existing inactive-admin versus users.role KYC access distinction is preserved, not declared resolved. No permission widening/helper rewrite.
- Observed helper calls per nine local reads: **342â†’18** at 25 riders, **1,341â†’18** at 250. Counterbalanced timings improve but are not production latency guarantees. Original initiating database resource cause remains unproven.
- Build 57 is a separately versioned client candidate for the already-tested nearby-preview single-flight fix. It does not activate this RLS candidate or any combined backend protocol. Use its manifest/signature result and actual-device checks; do not infer a phone speed measurement from compilation.
- **Combined dispatch/acceptance/push SQL and Edge remain NO-GO** under their existing managed business-rule, ownership/fencing and old-writer-drain gates. No cloud test project or paid resource was created; local PostgreSQL was stopped after tests.

## Authorized limited rollout update - 2 November 2026

The user subsequently authorized production fixes. [Applied changes and verification](WAYDROP_AUTHORIZED_ROLLOUT.md): two SQL function workload corrections, reject-order **v19**, and service-only ACLs on three internal dispatch RPCs are deployed. Cron schedules/owners remain unchanged. Current local files use the server-recorded migration versions **20261102143243** and **20261102144946**. Do not replay their original CLI draft timestamps.

**The coordinated SQL/Edge bundle remains NO-GO**, not a statement that no independent change has shipped. Atomic acceptance v60 replacement, worker generation takeover, eligibility tightening and durable push v24 replacement still require their integration/drain gates. The user declined creating a quoted $0/month test project; none was created. No paid resource or broad log query.

Release **candidate** APK build55 is available, signature/version checked, not installed/published or phone-profiled. Existing tests: 2,120 full Flutter; fresh rollout 5 native dispatch groups / 8 rejection handler tests / native lock and ACL checks. See the rollout manifest for precise scope. The historical approval/status text below records earlier phases and is superseded only for the exact applied independent changes above.


**Review document only. No deployment is authorized or executed.** Project `yvwpchffctiagevpqgwy`. Decisions from [Part 5](PART_5_FINAL_VERIFICATION.md): Flutter reviewed subset **CONDITIONAL GO**; combined SQL **NO-GO**; combined Edge **NO-GO**. Individual approval must identify the exact files/hashes and action. A green local test matrix is not a production GO.

## Blocker resolution update ? 2 November 2026

The five demonstrated blockers now have local coordinated implementations: ownership-token dispatch, canonical eligibility, durable enqueue coalescing, per-device push claims, and bounded delivery recovery. Native **17/17**, actual Edge/native **15/15**, full Flutter **2,118/2,118**, analyzer **0 errors / 73 warnings / 384 infos**. See [blocker report](WAYDROP_BLOCKER_RESOLUTION_REPORT.md), [exact hashes/evidence](blocker-resolution/VERIFICATION.json), and [reproduction](blocker-resolution/README.md).

**SQL and Edge remain production NO-GO until managed gates pass.** Flutter remains CONDITIONAL GO. No production action is authorized. The old stale-recovery/full-function candidates and acceptance-only frozen manifest are superseded for this protocol, not deployable alongside it. The original incident initiating cause remains unproven.

Required approval packet must include the disabled additive migration `20261102044001_waydrop_dispatch_fencing_and_delivery_outbox.sql`, separately fingerprint-guarded `blocker-resolution/CUTOVER.candidate.sql`, the exact Edge dependency inventory/hash manifest, business signoff for stricter KYC/freshness, complete intercity tests, and explicit acceptance of the `uncertain` FCM delivery policy. FCM cannot guarantee exactly-once receipt across a database commit; ambiguous sending is quarantined rather than automatically resent.

## Exact inventory and exclusions

| Component | Local implementation / review source | Status and production action |
| --- | --- | --- |
| Passenger Home repeated reads | `lib/features/user/home/home_tab.dart`, `profile_refresh_window.dart` | Preserve orders-only refresh/profile reuse/subscription ownership. Flutter subset, device/managed checks pending. |
| GPS/Realtimes | `lib/core/services/location/location_cache_service.dart`, `realtime_order_controller.dart`, `realtime_manager.dart`, `rider_update_filter.dart`; Rider Home/Orders/Home diff consumers | Preserve earlier single-flight/tracking fixes and Part 2 SDK-recovery/incomplete-diff fixes. Test map accuracy, availability and reconnect. No publication/identity or coordinate-rate change approved. |
| Chat | `lib/modules/chat/screens/order_chat_screen.dart`, `services/chat_message_delivery.dart`, `services/chat_message_merge.dart` | UUID/outbox/serialization, history merge/catch-up, account/lifecycle guards and type-safe duplicate recovery. Managed role/reconnect/offline tests pending. Fake-agent greeting removed. Attachment/auto-info guarantees are narrower. |
| Notification client | `notification_badge_service.dart`, `notification_count_events.dart`, `notification_service.dart` in `lib/modules/notifications/services` | Preserve read-state filtering/coalescing/backoff/cleanup and token/payload log sanitation. Test badge/read/recovery/account switches and device token rotation. |
| Diagnostics | `lib/core/services/diagnostics/{api_metrics_client,performance_trace}.dart`, existing `main.dart` wiring | Opt-in profile export `WAYDROP_PERF_EXPORT=true`; release guard/default-off. Numeric/allowlisted samples only. No backend configuration required. |
| Five failing source fixtures | Readers in incoming-order, production-control, rider-orders duplicate-work, missed-ride and subscription-trial tests | LF/CRLF normalization only; do not strip assertions. See exact filenames and errors in final verification JSON. Tests are not production migrations. |
| Atomic `accept-order` | `acceptance_sql.ts:2`, readable `blocker-resolution/ACCEPTANCE_SQL.review.sql:100`; existing handler/executor | Shared eligibility now required. Old frozen Edge-only manifest is superseded. New coordinated SQL dependency and admission/drain gate; missing helper fails closed. |
| `reject-order` | `supabase/functions/reject-order/index.ts:218/298` | Part 3 dead-read removal plus Part 5 conditional status PATCH/409-before-audit. 8 handler tests and native lock-wait check pass. Freeze a **new separate** Edge manifest; not part of acceptance Wave A. Missing-assignment and other concurrent writers still require managed testing. |
| `send-push-notification` | `index.ts`, `delivery_result.ts`, existing `fcm_result.ts`, shared HTTP/config helpers | Durable recipient/device claims, intent/ack, bounded retries, typed registration CAS. 15 actual Edge/native tests pass. Managed FCM and uncertainty/operator signoff required; no blind historic replay. |
| `start-dispatch` | `index.ts`, `durable_dispatch.ts`, shared HTTP helper | All worker mutations use fenced SQL step. Local takeover/replay tests pass. Requires coordinated cutover and old-writer drain; no rolling mix with old unfenced writers. |
| Dispatch audit SQL | Historical Part 3 candidate | Superseded within new atomic dispatch step. Do not apply this older whole-function definition after cutover. |
| Empty sweep SQL | Historical Part 3 candidate | Superseded within bounded durable recovery wrappers. Existing minute/45-second schedules remain enabled and unchanged. |
| Stale recovery SQL | Historical Part 3 candidate; replacement additive migration and separate cutover | Historical candidate remains excluded. Replacement locally proves resumed-owner fencing; managed drain/activation verification still required before approval. |
| Chat INSERT RLS | `chat-notifications-20261102/CHAT_SENDER_POLICY.candidate.sql` | Two restrictive policies; local role tests pass. Not deployed. Managed actor/agent/legacy-client compatibility and broader UPDATE/DELETE scope review required. |
| Internal dispatch RPC ACL | `final-verification-20261102/INTERNAL_DISPATCH_ACL.candidate.sql` | Revoke untrusted EXECUTE on new-order core; retain service_role. Native captured-body role tests pass. Review external callers; capture exact current ACL/owner before a separately approved migration. |
| Matching performance proposals | `../production-performance/waves/01_find_nearby_riders.sql`, `02_assign_nearby_searching_orders_core.sql` and rollbacks | Existing scale benefit only. Preserve owner/ACL/drift guards and reconcile Part 3 audit edits; do not apply two incompatible full-function definitions in sequence. Eligibility/cross-writer gates remain. |
| Index/Realtime changes | Wave 03/04 rider index removals; Part 2 publication/identity leads | **Deferred.** No demonstrated GPS removal benefit; no external-consumer/managed deletion proof. Keep existing indexes, all publication tables and identities. |
| Legacy overload migration | `docs/migration-review/not-applied/20261026000000_remove_legacy_find_nearby_riders_overload.sql` | Inherited unexecuted draft; dependency/necessity proof insufficient. Exclude from release. **Never run blanket `db push`.** |
| Other dirty-tree Auth/KYC/payments/startup changes | Existing baseline predates Part 5 | Preserve them; independently review provenance and scope. Do not assume every working-tree difference belongs to this release. |

Phase 5 hashes and source-delta proof: [VERIFICATION.json](final-verification-20261102/VERIFICATION.json). Existing acceptance-only payloads: [release manifest](../production-performance/edge-only/RELEASE_MANIFEST.json), [preflight/drain plan](../production-performance/edge-only/WAVE_A_PREFLIGHT.md). Those historical payloads do not describe the changed acceptance SQL or the coordinated dispatch/push protocol. Use the new blocker verification manifest; no existing frozen artifact authorizes deployment.

## Required ordering and gates

1. **Freeze scope.** Preserve the current tree; choose individual changes, capture dependency lockfiles/hashes and obtain action-specific approval. Refetch relevant production function definitions, grants, policy/index/trigger state and Edge versions immediately before any approved change; current captures are evidence, not a deployment-time drift check.
2. **Validate an existing isolated environment.** Use authorized synthetic accounts and a notification sink/test devices. No paid project/upgrade is approved. Exercise actual JWT/RLS, actor forgery, staff/self/foreign support threads, service RPCs, direct database role/budget/TLS and token rotation. No synthetic writes to production to satisfy a gate.
3. **Rehearse the coordinated protocol.** Install disabled additive storage in an existing isolated Supabase environment and test the exact cutover plus new Edge artifacts. Local ownership/eligibility/queue tests now pass; verify actual managed JWT/RLS, full intercity capacity/fare/request-expiry, all real writers/triggers, pg_net/Vault, cron catch-up, registration rotation and test FCM destination. No paid project is approved. Capture business signoff for approved/active KYC and configured freshness.
4. **Acceptance admission/drain rehearsal.** Follow the existing Wave A plan: hosted fail-closed 503 rehearsal, confirmed old-v60 admission cutoff, bounded old invocation/transaction drain, zero unsafe old write transactions, then an approved corrected acceptance candidate. Do not treat elapsed worker cap as proof every awaited operation stopped. Verify all privileged offer writers alongside acceptance.
5. **Security migrations separately.** After managed tests and approval, create migration history with the installed CLI's help/new-migration workflow from the exact reviewed policy/ACL SQL. Preserve existing participant checks and service-role paths. Ship compatible client greeting behavior before/with INSERT policies; retain trusted staff messages. Do not combine this with unapproved performance indexes/overload drops.
6. **Coordinated SQL/Edge activation only after approval.** Close writer admission, drain old invocations/transactions, verify zero legacy writers, install additive disabled storage and pinned Edge artifacts, then run fingerprint-guarded transactional cutover to replace entry points/guards and enable runtime. New artifacts fail closed until compatible SQL exists. Reopen only after approved-boundary checks. Do not apply historical whole-function rewrites afterward, run blanket db push, or change cron schedules. Capture all replaced function owner/ACL/hash drift; four executable cutover fingerprints do not replace review of every changed object.
7. **Delivery recovery gate.** Persistent per-device intent/claims/retry/recovery now pass local concurrency/crash tests. Validate actual hosted handlers and device delivery, aggregate observability, operator ownership of terminal/uncertain outcomes and privacy. No automatic resend of ambiguous sending, no historical bulk backfill, and no resetting sent/uncertain to pending. Rejection/security candidates retain separate compatibility gates and manifests.
8. **Flutter release last, after required compatibility gates.** Confirm release has diagnostics disabled and only the reviewed subset. Run Android/managed journeys below. Application rollback cannot undo committed database effects; plan forward compatibility with policy changes.

These are gates and ordering, **not executable approval to change production**. Unknown initiating root cause does not justify increasing connections/timeouts or upgrading paid compute without measurements and separate approval.

## Protocol rollback constraint

Before activation, leave additive storage disabled. After activation, close admission/drain, preserve all jobs and device outcomes, and prefer a forward repair. Never restore unfenced dispatch/split acceptance writers or drop/reset delivery ledgers. Keep guards until a reviewed compatible rollback is proven. Restore captured SQL ownership/ACL only with drift checks and explicit approval; a generic legacy function rollback can reopen the exact races fixed here. Transactional cutover failure rolls back activation, not committed acceptance, payment or FCM delivery. See the blocker report for ordering, observability and missing managed resources.

## Rollback and post-deployment verification

- Capture exact pre-change SQL definitions **and owner/ACL**, named policies, trigger/index dependencies and deployed Edge manifests before an approved action. Match expected hashes and reviewed current versions. Do not guess `GRANT TO PUBLIC` for ACL rollback; that can re-open the verified unauthorized RPC.
- For acceptance, use the existing **fail-closed 503** recovery artifact while repairing/draining. The reconstructed legacy v60 type-checks but retains its unsafe split writes; **do not restore it as an active writer**. Edge rollback does not repair already committed orders or charges.
- For function-only performance candidates, guarded rollback files must restore the captured definition/owner/ACL only if no later change drifted. For chat INSERT policies, rollback comments name only the two new policies; dropping security fixes restores known gaps and needs an explicit mitigation/approval decision. Never disable RLS globally.
- A Flutter rollback must remain compatible with active restrictive policies. Reverting diagnostics does not require backend changes. Push rollback does not unsend FCM or remove committed inbox notifications; do not delete messages or rerun payments to repair delivery.
- After each individually approved deployment, record exact version/hash/time, then verify ownership/negative-role checks, duplicate acceptance, accept/reject race, offered-rider eligibility, expiry/cooldown, fallback recovery, chat ordering/outbox, inbox/read counts, token cleanup and per-device push outcomes in the approved test boundary. Compare 5XX, client request counts, pool waits, connection occupancy, WAL/replication backlog and queue age under matched load.
- Require measurable, pre-agreed regression thresholds and an operator-owned abort/rollback decision. Do not infer GO from a healthy idle snapshot. Historical metric export for the original incident remains a separate operator action; no repeated broad log queries.

## Android profile procedure

**No Android device appeared in the current inventory.** No APK/device timings were measured. Use an isolated test handset/profile, approved non-production configuration, synthetic users and test-mode payments/KYC/FCM. Keep actual keys in an untracked local env file; never paste them into reports or logs.

From PowerShell in the workspace, replace the two placeholders:

```powershell
$deviceId = '<ANDROID_SERIAL>'
$testEnv = '<APPROVED_NONPRODUCTION_ENV_FILE>'
flutter devices
flutter build apk --profile --dart-define-from-file=$testEnv --dart-define=WAYDROP_PERF_EXPORT=true
flutter run --profile -d $deviceId --dart-define-from-file=$testEnv --dart-define=WAYDROP_PERF_EXPORT=true
```

The env file must supply the existing `SUPABASE_URL` and public `SUPABASE_ANON_KEY` compile-time values, plus existing app-specific required settings. No service-role key belongs in Flutter. Do not run against production just to fill measurement gaps.

In a second PowerShell window, capture **only** sanitized export lines:

```powershell
New-Item -ItemType Directory -Force .dart_tool/perf-captures | Out-Null
adb -s $deviceId logcat -v raw flutter:I '*:S' |
  Where-Object { $_ -like 'WAYDROP_PERF *' } |
  Set-Content -Encoding utf8 .dart_tool/perf-captures/candidate.log
```

Stop capture with Ctrl+C, then summarize offline:

```powershell
python docs/performance/final-verification-20261102/summarize_device_metrics.py .dart_tool/perf-captures/candidate.log --frame-budget-ms 16.6667 > .dart_tool/perf-captures/candidate-summary.json
```

Set `--frame-budget-ms` to **8.3333 for 120 Hz** or the actual refresh budget. Do not save/share unfiltered logcat, network headers, provider bodies, messages, phone numbers, positions, tokens or DevTools memory dumps. Export uses fixed labels/numbers, small JSON chunks and nonduplicated drained batches. Monitor invalid batches/sample counts; rings are bounded and can lose samples during stalls.

Run at least ten process-cold launches and ten warm resumes on **each compatible baseline/candidate**, with identical handset, build mode, configuration, refresh rate, synthetic data, network and instrumentation. A hot restart is not process-cold; label cache/session state. Do not substitute an old passing test log for a device baseline. Do not compare debug and profile timings.

| Journey | Required observation |
| --- | --- |
| Passenger/Rider Home | Video/timestamp from launch/resume to first usable controls/map/content, plus `screen_work` and API counts. `screen_work` ends at the measured function, **not necessarily first usable paint**. |
| Profile/KYC | Usable profile/KYC state and failure/retry recovery; actual approved test-mode eligibility only. No real identity upload. |
| Order/dispatch/accept | Synthetic order-to-offer, one winning rider, accept/reject race and no extra financial/event effects. Include two devices/actors. |
| Tracking | Passenger map freshness/accuracy, rider online/offline/service changes and foreground/background behavior. Do not infer row writes solely from HTTP success counters. |
| Chat | Send/receive latency, FIFO queue, lost response/replay, restart persistence, offlineâ†’online, history/join gap and account isolation. |
| Badge/push | Read state, failure backoff/recovery, multiple devices, rotated/unregistered token, partial success and handler crash/replay. Known concurrent push duplication remains a failure until fixed. |
| Reconnect/frame timing | Disconnect/reconnect using test device network controls; video first restored content and inspect existing Realtime counters locally. Successful manager fallback metrics do not count every SDK rejoin. Record DevTools Performance timeline for complete frame evidence. |

Offline summary uses nearest-rank API **body-completion p50/p95**, including recorded failed responses; it is not SQL time. Header status samples are separate. Frame output is sampled build/raster budget overruns, **not a complete jank rate**; use DevTools timeline and adequate sample counts. Realtime timing and first-usable/KYC journeys require video/trace/manual correlation; they are not magically exported by an API timer. Record these limits with any before/after claim.

**Final production ledger: no actions executed. Shipping decisions remain subject to individual approval and the unmet gates above.**

## November 3 Choose Route candidate — separate Flutter-only review

See [WAYDROP_CHOOSE_ROUTE_LOADING_FIX.md](WAYDROP_CHOOSE_ROUTE_LOADING_FIX.md). User tested Build61 at 09:54–10:04 IST. These local progressive-pricing, failure/Retry, route-generation, lifecycle and promo-ownership corrections are **not in the installed Build61 APK**. No new APK or production deployment was made by this task.

- [x] Read-only bounded incident evidence saved; pricing/config endpoints had 13–19 second outliers. No initiating CPU/RAM/disk explanation claimed.
- [x] Local deterministic first-quote, failure/timeout/retry, stale directions, duplicate provider work, Cash/UPI, promo, invalid fare and disposal tests.
- [ ] Native Android profile measurements: first visible quote, first enabled Book frame, real map drawing, cold/warm journeys and slow/offline recovery.
- [ ] Fare/promo/Cash-UPI/create-order smoke test using an approved isolated environment. No synthetic production booking for verification.
- [ ] Reviewed Flutter release artifact and phone installation; local source edits do not alter Build61.

Rollback is a Flutter artifact rollback to a known compatible prior app; no database rollback is involved. Existing SQL/Edge NO-GO gates remain in force. Do not deploy the broader local Edge or migration bundle with this screen correction. Required incident resource charts and source/timing limits are listed in the linked report.

### Build62 artifact follow-up

- [x] [Signed Build62 APK](../../artifacts/waydrop-1.0.0-build62.apk) prepared; version62/package/same signer as61 verified, all architecture AOT outputs changed, source freeze stable, no plaintext `.env` asset.
- [x] Additional prefilled-route defect corrected: pricing starts independently of WebView page readiness; late map callbacks paint instead of restarting the batch.
- [x] Full suite **2,233 passed / 0 failed / 10 existing live skips**; focused **30 passed**; analyzer **0 errors / 1 warning / 17 infos**.
- [ ] User installation and native Android speed/provider/map/payment validation. No attached ADB device; no physical-device speed claim.

[Build62 evidence and remaining limits](WAYDROP_BUILD62_SPEED_FIXES.md). Production unchanged by this follow-up; paid resources not created; original backend initiating cause unresolved.
