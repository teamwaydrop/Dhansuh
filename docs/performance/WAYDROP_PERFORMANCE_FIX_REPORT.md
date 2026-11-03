# Deep Rider flow corrections and verified Build61 - 3 November 2026

[New concrete findings and evidence](WAYDROP_DEEP_RIDER_FLOW_BUILD61.md) | [Final verification](proof-wait-20261103/VERIFICATION.json).

- Four verified defects corrected locally: successful proof spinner blocked by display refresh/OTP; accepted order blocked by passenger enrichment; completed API failure left loading forever; local orders unnecessarily queried/waited on intercity metadata.
- Actual-screen tests preserve explicit intercity and existing long-ride classification, proof/OTP rules, account/disposal ownership and confirmed-state ordering. Local metadata query count1 to0; intercity/long ride1 to1; rapid manual retry starts one request. No production latency percentage claimed.
- Full Flutter **2,216 pass / 10 existing live skips / 0 fail**, focused56 pass. Changed-four-file analyzer0 errors/0 warnings/6 existing infos. A previous30ms success-fixture timeout was corrected without changing application deadlines; its dedicated timeout test remains.
- [Signed Build61 test APK](../../artifacts/waydrop-1.0.0-build61.apk), same verified signer as60, final182 source hashes stable and all three AOT libraries updated. Final source-fingerprinted rebuild supersedes an earlier attempt made before the last source refinement. Not installed/published/device-profiled. User confirmed60 had not been installed.
- Two read-only Supabase health aggregates showed four clients, zero blocked/other active clients at their timestamps; no host metrics tool or browser surface available. No broad logs, production writes/deployments, paid resources or new projects. Existing backend NO-GO/integration gates and original unresolved resource cause remain.

---

# Safe corrections and Build60 - 3 November 2026

[Implemented changes, evidence and remaining gates](WAYDROP_SAFE_SPEED_FIXES_BUILD60.md).

- Signed local [Build60 APK](../../artifacts/waydrop-1.0.0-build60.apk) now includes latest Home/pricing changes and immutable, account/lifecycle-owned rider proof transport. Same signer as59; all182 frozen source files unchanged; three AOT libraries updated. Not installed/published/phone-profiled.
- Full Flutter **2,204 pass / 10 existing live skips / 0 fail** (+11 new cases), focused37 pass; changed-six-file analyzer0 errors/0 warnings/6 existing infos.
- New full-body photo deadline, v75-preserving pricing zone-cache candidate (normal three reads to one; original fresh fallback retained), and service-only atomic proof SQL/handler candidate. Photo atomic native9 groups and actual handler/native6 cases pass, including reassignment, rollback and committed/lost-response replay.
- Existing safety candidates rechecked: native dispatch/push17, Edge/native15, Chat policy/trigger14 pass. Managed Auth/full triggers/FCM/intercity and cutover gates remain. Combined SQL/Edge NO-GO; no production changes, paid resources or new project here.
- Required initial Storage metadata writes retained; underlying Storage/CPU/RAM/I/O initiating cause remains unproven. No promise of measured handset latency reduction.

---

# Edge/table-load correction ? 3 November 2026

[Exact findings, source lines, tests and release limits](WAYDROP_EDGE_TABLE_LOAD_OPTIMIZATION.md).

- New local fixes: same-path Storage signing and same-order ETA pending-work coalescing; ETA ownership retained after visible timeout and unused timers cleared. Deterministic concurrent calls each **3 to 1**; cache baseline 7 pass/5 fail to 12 pass/0 fail.
- Actual photo handler accepted an owned rider against another assigned order in the synthetic baseline. Early order/rider/type validation now stops that path before download/hash/writes; valid pickup/dropoff preserved. Original photo baseline 3 pass/5 fail; corrected 10 pass/0 fail including two additional cases. Assignment remains a snapshot; atomic photo writes/replay fencing are NOT resolved.
- Production v75 pricing lacks the existing local zone cache. Existing helper tested: three quotes share one zone read per isolate; production rollout still pending version-prefetch reconciliation. Selected table FK/index links exist; intercity reliability view hides per-rider history work inside a batched HTTP query, with no measured incident causation.
- Deno **77 pass / 0 fail**; full Flutter **2,193 pass / 10 existing opt-in live skips / 0 fail**. No Flutter edits or APK this turn.
- Separate captured-v54 cache-only and captured-v18 photo-guard review manifests prepared. **No production changes this turn**; combined SQL/Edge NO-GO and managed integration gates preserved. Historical resource initiating cause still unproven.

---

# Current backend follow-up ? 3 November 2026, 01:55 IST

[Current evidence, independent production correction and limitations](WAYDROP_BACKEND_CURRENT_HEALTH_2026_11_03.md).

- Current low-traffic sample: no HTTP 5xx / SQL timeouts; zero blocked sessions. No Storage/Auth traffic or host-resource charts, so peak-time/upload recovery remains unproved.
- Released only `20261103015444_waydrop_skip_idle_stalled_redispatch_reads`: skip Vault/config on provably empty cron ticks while preserving terminal cleanup, original lock, schedule and service-only ACL. Expected/final function MD5 `d70d703c15e3ee72834dc627af1fee80`. First normal post-apply tick succeeded in 8.730ms; not a measured causal latency improvement.
- Native parity: 12 groups passed; migration/rollback: 6 checks passed. Empty-tick synthetic Vault/config reads each 1?0. Full Flutter: **2,193 passed, 10 explicitly skipped, 0 failed**; previous 2,203 cases retained. Ten live pricing cases now opt-in to prevent default production test traffic; targeted analyzer clean.
- 58 past searching intercity orders remain unrepaired pending lifecycle/payment review. Existing RLS candidate, managed integration gates and combined SQL/Edge NO-GO are unchanged. Original incident initiating cause unproven. No new APK/Edge/cron schedule/RLS changes this turn.
- Historical zero-execution statements below describe their original scope/date; this entry records the new independent SQL release, not release of those blocked bundles.

---

# Deep pricing/booking code correction — 3 November 2026

[Exact source defects and correction](WAYDROP_PRICING_CODE_OPTIMIZATION.md) | [Verification](pricing-code-20261103/VERIFICATION.json).

Removed the never-rendered Parcel Specifications fare preview: actual widget Edge requests **2→0**, while real Booking pricing remains. PricingController no longer forces a500ms minimum after a fast response; latest generation/account alone publishes quote/error/loading; reset/dispose invalidate pending results; exact input/credential JSON keys prevent unsafe rounded-input sharing;15-second caller deadlines retain raw pending ownership rather than issuing another identical request. Backend fare math, vehicle/weight eligibility, boost/tax/subscription/payment validation and previous Home/upload fixes remain. No production incorrect-fare claim is inferred from the synthetic key-collision reproduction.

Original pricing cases **1 pass/8 expected failures**, then **10 corrected passes** with a separately added account-switch case. Hidden-preview original one-case failure observes2 calls; corrected preview observes0. Focused **37 pass**; final full Flutter **2,203 pass/0 fail**, previous2,192 plus11 cases. Controller/test analyzer subset clean; changed-four-file analyzer **0 errors/0 warnings/8 existing infos**, exit1. No device-wide timing or project-wide request-rate improvement claimed. Distinct inputs now intentionally require separate requests; already-started distinct work is not cancelled.

**Local after Build59**, artifact unchanged and no new APK this batch. Zero production connector reads/writes/deployments, paid resources or new projects. Storage504/57014 initiating wait/resource cause and all prior combined SQL/Edge rollout gates remain unresolved/unchanged. Android quote/route/boost/vehicle/payment flow validation remains required.

---

# Rider Home Realtime responsiveness — local after Build59

[Exact defects and correction](WAYDROP_RIDER_REALTIME_RESPONSIVENESS.md) | [Verification](rider-realtime-home-20261102/VERIFICATION.json).

Four actual widget defects reproduced: Realtime wallet fields waited for secondary earnings; older suspended callback could overwrite a newer offline status; earnings failure replaced a confirmed display with0; an eight-second visible timeout released ownership while raw transport continued, permitting another earnings GET. Local correction publishes rider state first and uses the existing guarded nonblocking earnings refresh, preserving last confirmed value on failure. Raw request ownership survives timeout, with rider-keyed/fenced cleanup and unchanged query math/status/day filters. GPS-only filtering, offline tracking teardown, KYC, payment and assignment rules remain.

Original widget suite **5 pass/4 expected failures → 9 pass**. Focused **78 pass**; final full Flutter **2,192 pass/0 fail**, previous2,188 plus four new cases. Changed-four-file analyzer **no issues**, exit0. Actual SDK pending earnings reads after timeout/refresh **2→1**; wallet applies before the controlled earnings response resolves. No Android latency guarantee inferred. Intermediate full suite exposed two fixed30ms assumptions in existing upload tests; explicit request-start barriers replace them. An edit-time UTF-8 issue was caught and corrected; all30 original non-ASCII source lines are preserved. Initial/final logs are retained.

**Local only after Build59**: its artifact/hash is unchanged, no new APK in this batch, zero production reads/writes/deployments or paid resources. Backend Storage504/57014 and initiating resource/lock cause remain open. Existing SQL/Edge rollout gates remain; these client changes await a subsequent reviewed APK and Android verification.

---

# Remove redundant writes and account-check overlap / Build59

[Exact changes, test provenance and release scope](WAYDROP_REDUNDANT_WORK_REMOVAL.md) | [Verification](build59-20261102/VERIFICATION.json).

User-requested local follow-up stops repeat notification-read row updates and no-op user/rider mode row updates with atomic owner/value/NULL-aware predicates. This avoids redundant row mutation; HTTP PATCH/admission work is not eliminated. Controlled write-contract fixture: original five cases fail; corrected six pass. No database-wide no-op trigger or new preflight query. KYC and other required writes remain.

AccountProfileService now retains actual read ownership after UI timeout and shares outstanding Auth checks between startup/resume. Both raw Auth and profile owners survive timeouts; credential renewal admits a replacement with fenced old cleanup. No completed Auth/profile permission cache or skipped ban/deletion checks. Actual SDK overlapping held-endpoint reads2â†’1; old-owner/new-owner cases pass. Original19 pass/3 expected failures; corrected24 pass. Prior RiderAccessService and Storage recovery corrections remain.

Focused **30 passed / 0 failed**; final full Flutter **2,188 passed / 0 failed**, previous2,177 plus11 cases. Changed-five-file analyzer **0 errors / 0 warnings / 1 existing info**, exit1. No actual PostgreSQL write/WAL reduction or Android latency guarantee inferred from mocks. **Production untouched in this follow-up**: zero connector reads/writes/deployments/paid resources. Combined SQL/Edge gates remain NO-GO; required Storage metadata write and its unidentified backend wait remain open.

Additional **six native PostgreSQL17.11 groups pass** for no-op, nullable state, owner targeting and actual concurrent row-lock/predicate-recheck behavior. One notification race produces1/0 updated rows and one trigger effect. Synthetic schema removed, local server stopped. This validates database semantics separately; no managed RLS/provider-stack, production workload reduction or WAL benchmark is claimed.

Build59 packages these client corrections plus previously local post-Build58 upload/account fixes; build/signature/artifact status is recorded in the linked manifest. Device installation and real Storage/account tests remain required. No production change or combined SQL/Edge activation is implied by APK packaging.

Release build **PASS**,1.0.0(59), same signer as58, three changed AOT libraries and unchanged frozen sources. [Build59 APK](../../artifacts/waydrop-1.0.0-build59.apk). Not installed/published or Android-validated; production unchanged.

---

# November 2 night: Storage 504 and Rider account failure paths

[Exact incident report, failure/action table and next capture](WAYDROP_NOV_2_2157_2203_INCIDENT.md) | [Verification](night-2157-20261102/VERIFICATION.json).

Read-only21:57â€“22:03:30 IST inspection confirms another shared backend stall: Storage gateway504 at60.012 seconds, a separate aborted upload at36.936 seconds, two Storage metadata INSERT query57014 cancellations, required rider/KYC reads22â€“25 seconds, users27 seconds and Auth11.850 seconds. The504 and abort have **different request IDs**; exact Storage-to-PostgreSQL request linkage is missing. At22:27:21 IST neither failed object's active metadata row existed; no production blob was downloaded/deleted. Historical208ms completed INSERT average does not diagnose the cancelled operations. Initiating resource/lock cause remains unproven; zero accessible browser surfaces and no historical host/wait export. A bounded review-only next-onset capture and unsent service-trace draft identify decisive missing measurements.

Local targeted corrections: immutable account/content photo keys, non-upsert creates with zero automatic write retries, exact-content verification before creating or recovering, retained raw request ownership past UI timeout, partial-batch preservation, explicit Check / retry in both parcel screens and mounted/account guards. Temporary Auth exceptions no longer automatically mean invalid Login; required KYC/account/payout validation is preserved. Existing Rider proof uploader and broader SQL/Edge candidates are not declared repaired.

Actual original photo-widget source: **2 pass / 2 expected failures** (selection lost). Corrected focused **34 pass / 0 fail**, including16 upload SDK transport/concurrency cases,4 parcel widgets and14 Rider cases. Final full Flutter **2,177 pass / 0 fail**, previous2,153 plus24 new tests. New service/access/entry/test analyzer subset clean; changed-nine-file result **0 errors / 2 existing warnings / 22 existing infos**, exit1. Healthy uploads add one exact-object verification GET; request counts are not universally reduced. No measured Android latency gain or backend cure is asserted.

**Local after Build58; no new APK/deployment. Production unchanged.** Nine bounded log queries, three successful lightweight SQL inspections and two corrected inspection errors; no broad history scans, EXPLAIN ANALYZE, DML/DDL, policy/cron/config change, upload, restart, paid resource or new project. Client remains conditional pending real Android upload/account verification; combined SQL/Edge NO-GO gates remain. Full failure paths, source lines, tradeoffs and production dependencies are in the linked report.

---

# Local follow-up: stop rider access retry overlap - 2 November 2026

[Exact reproduction, implementation and limits](WAYDROP_APP_REQUEST_OWNERSHIP.md) | [Verification](request-ownership-20261102/VERIFICATION.json).

Confirmed client amplifier: the eight-second access-check timeout cleared shared ownership while its HTTP reads continued. Entry/retry could duplicate rider/KYC reads and profile work during a pending payout request. Local correction holds ownership until transport settlement, admits renewed credentials safely and prevents old cleanup from deleting its replacement. An account check before payout also stops unnecessary reads after sign-out. Existing eligibility decisions and phase deadlines remain; late timed-out results never authorize entry, and completed checks are revalidated.

Actual pinned-SDK controlled tests: baseline five cases **2 pass / 3 expected failures**; corrected six cases **6 pass / 0 fail**, including credential renewal and resumed-owner cleanup. Timeout/retry request pairs **2 â†’ 1**; payout reads after sign-out **1 â†’ 0**. Full Flutter **2,153 pass / 0 fail**, previous 2,147 plus six cases. Changed-file analyzer **no issues**. No measured handset speed gain is inferred.

**After Build 58, local only**: no APK rebuilt, production queries/writes, SQL/Edge deployment or paid resources in this batch. Build 58 hash remains unchanged while the user tests it. Same-credential retries retain the timeout until the original transport settles; transport cancellation and AccountProfileService/Auth-resume overlap are not claimed solved. Storage DatabaseTimeout and original initiating CPU/I/O cause remain unresolved; all existing combined rollout gates remain.

---

# Build 57 feedback: completion white page and confirmed Storage timeout - 2 November 2026

[Exact 20:50â€“21:05 IST investigation and client correction](WAYDROP_COMPLETION_PHOTO_2050_2105.md) | [Verification](completion-2050-20261102/VERIFICATION.json).

User confirms Build 57 and a white page after Back to Home. Actual widget reproductions identify an explicitly white RiderEntry pending scaffold and fresh-entry seed rejection by process-lifetime flags. Local correction keeps the rider-themed access loader and reuses each newly validated response once per consumer; old/expired/wrong-account/future seeds are rejected. Guarded recreation **3 rider readsâ†’1** while KYC/payout/Auth validation remains. Original **1 pass/3 expected failuresâ†’4 widget passes**, plus five new seed tests. Focused **18 pass**, full Flutter **2,147 pass/0 fail**, changed-file analyzer **no issues**. No root-stack or guard cancellation rewrite.

Photo evidence is now direct: booking upload **16.111 s / 200**, pickup **33.209 s / 544**, dropoff **15.094 s / 200**. Storage's own log reports **DatabaseTimeout**, **33,200 ms execution**, raw PostgreSQL**57014**. A Supabase Storage API statement timeout is logged 85 ms before the Storage error record. The failed SQL text/wait/resource is missing; this does not establish pool exhaustion or a CPU/I/O initiator. No blind pool/timeout/quality change, automatic retry, deletion or proof bypass. [Privacy-safe support draft, not submitted](completion-2050-20261102/STORAGE_SUPPORT_DRAFT.md).

Build 58 packages only the client correction and prior fixes; artifact/signature outcome is in the manifest. **Production remains read-only**: five bounded log queries and one role-settings read, no deployment/configuration change or paid resources. The independently tested public-table RLS proposal is still unapplied and is not asserted to repair the unidentified Storage statement. Original resource cause and prior combined rollout gates remain open.

---

# RLS hot-path local validation / Build 57 - 2 November 2026

[Measured RLS candidate and release handoff](WAYDROP_RLS_HOTPATH_VALIDATION.md) | [Exact verification](rls-hotpath-20261102/VERIFICATION.json).

Captured the actual 40-policy authorization graph and built a separate synthetic loopback fixture. The existing statement-independent admin-helper proposal now has a separately fingerprint-guarded candidate changing only four authenticated SELECT predicates. **Six native groups pass**, including nine-actor rowset parity, anon denials, UPDATE target parity, prepared identity/revocation, drift/dry-run checks and actual plans/helper counts. **16 concurrent identity reads and three actual rollback checks pass**. No production rows copied; no production DML/DDL/deployment, log scans, paid resource or new Supabase project.

Actual local helper-call counts over nine reads: **342â†’18** at 25 riders, **1,341â†’18** at 250. First-run timings included one owner regression and are retained. Alternating-order repeats at 25 riders measured medians **5.252â†’3.302 ms admin, 7.597â†’2.864 ms owner, 6.802â†’2.194 ms unrelated**. This is not a promise that 48-second production stalls disappear. The cross-table RLS graph remains; plan nodes can increase with cached InitPlans while execution work falls.

Security distinction retained: inactive admins may still see KYC through an independent `users.role='admin'` policy. No business rule was silently changed. Managed Auth/complete production-stack verification and explicit apply approval remain pending. The candidate and rollback default to ROLLBACK, outside automatic migrations. Combined SQL/Edge gates remain NO-GO. Native server stopped after tests.

Build 57 packages the previously tested client single-flight fix, independently of the undeployed SQL candidate. Latest full Flutter remains **2,138 pass / 0 fail** from the preceding exact client-source run; not rerun to certify SQL. Only the release build number changes in this follow-up. Artifact/signature status is recorded in the handoff manifest; no phone install or measured device gain is inferred. Original initiating resource cause remains unproven.

---

# Build 56 real test: 17:43â€“17:55 IST backend recurrence - 2 November 2026

[Exact investigation, causal distinctions and next actions](WAYDROP_BUILD56_1743_1755_INVESTIGATION.md) | [Verification](evening-1743-20261102/VERIFICATION.json).

User confirms Build 56, with Home/booking/photo-flow delay. Bounded project-wide logs demonstrate another **shared backend stall**: Dart riders **47.939 s / one HTTP500**, Edge dispatch status **47.330 s**, Edge orders **43.435 s**, Edge config **42.994 s**, Dart orders **35.849 s**. First selected cross-path >5 s records are at **17:47:45 IST**, before the main **17:50** cluster. Five explicit PostgreSQL statement timeouts plus one user-request cancellation; not six statement timeouts. Twenty-two Warp timeout-manager records reduce to six distinct timestamp/message pairs; no explicit PGRST003 detected in this window.

One timeout is the booking-map riders/vehicle-type query inside `is_admin`. A read-only authenticated non-ANALYZE plan uses existing coordinate/KYC indexes but expands through **five tables / 53 nodes** because of RLS. Node counts are not measured SQL round trips/runtime. Existing RLS proposal remains unmodified and undeployed; security-equivalence and runtime verification are pending. Initiating CPU/paging/disk/lock cause remains unproven; no historical host charts were accessible.

**New minimum local fix:** both nearby booking previews now coalesce unfinished fetches, snapshot pickup and discard obsolete/disposed results. Actual SDK controlled test: **10 overlapping reads â†’ 1**; five focused checks pass. Full Flutter **2,138 pass / 0 fail**, five more than 2,133. Analyzer: **0 errors / 2 warnings / 28 infos** in existing screen code, not a clean run. The correction is **after Build 56**; existing APK untouched, no new APK/deployment this follow-up.

Photo-flow distinction: no object upload is recorded within the exact window; Storage has **107 Edge signing POSTs** and **85 Dart signed-image downloads**, max 1.767/0.685 s. Earlier 8â€“23-second uploads do not measure this test. Order-verification read reaches **20.687 s**; exact handset stage remains untraced. **Production read-only**, no paid resources and all combined rollout gates unchanged.

---

# Build 56: Passenger Home and zone readiness corrected - 2 November 2026

[Release handoff and remaining bottlenecks](BUILD_56_PERFORMANCE_HANDOFF.md) | [Exact verification](build56-20261102/VERIFICATION.json).

Two additional actual defects were reproduced and corrected locally. Passenger Home's skeleton ignored `loading`, so it persisted after successful or failed data loading whenever GPS was unavailable and there was no startup seed. The minimum condition change clears that permanent loader while retaining location permission/setup and service checks (**2 original widget failures â†’ 2 passes**). Zone prefetch used a busy boolean that let concurrent callers return before zones/resolver were ready; all callers now await the same in-flight result, including during forced refresh (**2 original service failures â†’ all 3 passes**, TTL and failure-cache behavior retained).

Focused actual Home/service tests: **10 passed / 0 failed**. Full Flutter: **2,133 passed / 0 failed**, previous 2,128 plus five new tests. Analyzer on the newly changed files/tests: **no issues**. Build 56 packages these corrections plus prior Rider Home earnings/config retry fixes; artifact/signature verification and release result are in the linked handoff/manifest. Build 55 is preserved. No phone is attached, so no handset latency guarantee or installation is claimed.

**Production unchanged** in this follow-up. Slow API tails and 8â€“23-second Storage requests remain unresolved at their underlying server/network boundary. Current pinned storage_client defaults to zero retries; a presumed ten-retry SDK storm is not established. No blind compression, timeout/retry rewrite, proof bypass, paid upgrade or combined SQL/Edge activation. Original database initiating cause and prior managed rollout gates remain open.

---

# App flow: Rider Home secondary wait removed - 2 November 2026

[Flow correction and exact verification](WAYDROP_APP_FLOW_OPTIMIZATION.md). Actual widget reproduction confirms that the completed rider/KYC read was followed by an awaited display-only earnings query before clearing Home's full-screen skeleton and starting assignment subscriptions/reconciliation. Local correction publishes core Home immediately and refreshes earnings separately using the existing single-flight query. Loading/failure is explicit on the earnings card; cached numeric value survives failure; mounted/user/rider guards reject late secondary results.

**5 actual widget tests pass**: pending earnings does not block Home/assignments; success applies; disposal is safe; failed refresh retains value; repeated refreshes share one pending read; sign-out ignores late earnings. Success is checked within the first case. Full Flutter: **2,128 passed / 0 failed**, five more than the previous 2,123. Controlled result: original skeleton remains during the withheld secondary response; corrected Home and assignment reconciliation proceed while it is still withheld. No handset speed gain or reduced total SQL workload is inferred.

Passenger Home already uses a parallel batch and profile reuse; required cooldown/eligibility/order state must remain accurate before separating its UI states. Normal parcel details passes uploaded URLs to booking, so no normal-path duplicate upload was found. Slow Storage proof/upload remains a distinct boundary. **No production reads/writes or deployment, no new APK** in this follow-up. This and the config fix remain absent from Build 55. Existing combined SQL/Edge gates and original incident uncertainty remain unchanged.

---

# Build 55 correlated investigation - 2 November 2026

[Full-stack / Free-plan analysis](WAYDROP_FREE_PLAN_BOTTLENECK_ANALYSIS.md) | [Bounded evidence and calculations](free-plan-analysis-20261102/METRIC_ANALYSIS.json) | [Verification](free-plan-analysis-20261102/VERIFICATION.json).

User reports Build 55 tested **15:51â€“16:00 IST / 10:21â€“10:30 UTC**. Project-wide gateway evidence shows three foreground parcel/proof Storage POSTs taking **19.148 s (19,751 request bytes), 8.635 s and 22.676 s**. Source awaits uploads before later verification. REST p95: orders **2.045 s**, riders **3.153 s**, notifications HEAD **2.959 s**. No gateway 5XX or PostgreSQL statement-timeout burst appears in the bounded results; three audit HTTP409/nearby unique-conflict events remain, compatible with unchanged dispatch v72. Project-wide Dart requests are not identified handset/build traffic. No phone startup/frame timing or Storage server/network split was obtained.

New verified **local-only** correction: `production_config_service.dart:74â€“89` completes the once-per-session attempt even after failure; routine init no longer repeatedly refetches, explicit refresh still retries and cached security gates remain. Actual-service reproduction: **9 to 1 HTTP reads**, original source **2 pass / 1 expected fail**, corrected focused suite **85 pass / 0 fail**, full Flutter **2,123 pass / 0 fail** (three new tests), changed-file analyzer **no issues**. This change is not in Build 55; no new APK was built. No Dart config read occurred in the test interval, so the defect is not claimed as its demonstrated cause.

Final infrastructure verdict: **UNRESOLVED â€” MISSING CRITICAL EVIDENCE**. User-reported 132% memory commitment, occupied swap and 32.81% IOWait support resource-pressure concern but do not prove paging, a depleted disk budget or initiating resource. Free organization confirmed; exact compute-size field and historical host charts unavailable. Current official single-project totals are approximately **Pro Micro $25/month, Small $30/month**, not compute-only $10/$15. No upgrade was purchased or promised to cure the slow uploads. Cheapest next test: time the same upload journey and correlate existing per-device disk/paging/admission charts for this exact window.

**Production read-only throughout this investigation.** Previous authorized deployments below are historical facts, not repeated. Combined SQL/Edge rollout gates, managed verification, worker fencing/eligibility/old-writer drain and durable push signoff remain. Original November 1 initiating CPU/I/O cause is unproven.

---

# Authorized production rollout - 2 November 2026

[Exact rollout report](WAYDROP_AUTHORIZED_ROLLOUT.md) | [Verification](authorized-rollout-20261102/VERIFICATION.json) | [APK candidate build55](../../artifacts/waydrop-1.0.0-build55.apk).

**Actually deployed:** rider-core expected audit-key deduplication; empty-search freed-sweep early return; reject-order **v18 to v19** with narrow/dead-read removal and conditional rejection; internal matching/recovery RPCs restricted to service role/owner. Production hashes, ACLs, active cron schedules and seven negative/preflight HTTP checks verified. Native counts: **6 to 0 audit exceptions**, **3 to 0 empty-sweep core calls**, **2 to 1 normal-rejection assignment reads**. These are local controlled counts, not measured live latency gains.

Fresh checks: **5 native dispatch groups**, **8 handler tests**, actual reject/accept row-lock preservation, **6 role-denial tests**, frozen dependency typecheck. Latest full app suite remains **2,120 pass / 0 fail** from the startup correction. Build55 release candidate compiles, matches build54 signer, not installed/published; handset speed remains unmeasured.

**Remaining:** coordinated worker fencing/eligibility/coalescing, atomic acceptance replacement, durable push/recovery and real-device/managed integration gates. The user declined creating the quoted $0/month test project; none created. Production acceptance stays v60, push v24, dispatch v72. Original database-wide initiating cause remains unproven. Earlier zero-production-write statements below are historical, superseded for this explicitly authorized independent batch only.

---

# Live app check and startup retry correction - 2 November 2026

User reports persistent slowness on **release 1.0.0 (54)**. [Detailed live follow-up](WAYDROP_RECURRING_SLOWDOWN_ROOT_CAUSE.md#live-follow-up-persistent-slowness-reported-november-2-at-1355-ist), [current DB/versions](recurring-slowdown-20261102/LIVE_DATABASE_1355.json), [public HTTP samples](recurring-slowdown-20261102/LIVE_HTTP_1355.json).

At 13:55 IST, no blocked or active client query was observed outside inspection; production still uses dispatch v72, accept v60 and push v24, and new durable RPCs are absent. Six desktop public GETs returned HTTP200: reused connections 80-115 ms, first config 1.17 sec. These do not measure authenticated phone journeys or prove the database was healthy during incidents.

A new actual-service reproduction exposes automatic timeout retries while the original Auth/profile HTTP read is still pending: **two expected regression failures before, both pass after; outstanding sends 2 to 1**. Minimal local correction in `account_profile_service.dart:108` stops automatic retry on non-cancelling Future.timeout; completed 503/network retries and authoritative security checks remain. Explicit manual retry/underlying cancellation ownership is not claimed solved. Focused **39 pass**, full Flutter **2,120 pass / 0 fail**, two more than the previous suite. No production/SQL/Edge change or new APK build/install. Analyzer details in live verification artifact.

**Original initiating CPU/I/O/lock cause remains unproven; persistent handset delay is not yet traced.** No Android device is attached. Existing safety fixes and deployment gates are preserved.

---

# Recurring slowdown investigation - 2 November 2026

[Two-incident causal report](WAYDROP_RECURRING_SLOWDOWN_ROOT_CAUSE.md) | [Sanitized November 2 events](recurring-slowdown-20261102/INCIDENT_2_SELECTED.json) | [Offline evidence checks](recurring-slowdown-20261102/ANALYSIS.json).

**The initiating resource/query remains unproven.** New evidence reproduces 16 API requests over 20 seconds, three HTTP500s, four PostgreSQL 57014 observations and three distinct cron startup failures in the retained November 2 prefix. Broad dispatch-config/users/KYC/riders/orders reads were already slow at 06:48:43-45 UTC, before the 06:51-53 peak. The same backend PID later identified as postgres_exporter timed out on its pg_stat_statements aggregate at 06:52:29.197. This widens the demonstrated failure boundary beyond Flutter, Chat and one REST pool; it does not identify which resource was constrained first.

Dashboard access was attempted with the supplied URL: no browser is available. No historical CPU, memory/swap, disk latency/IOPS or connection-wait chart was viewed. Exact chart/export instructions and both UTC/IST windows are in the report. The user has no verified local export path. A later healthy snapshot does not clear either incident. Cron currently has background-worker mode off; startup failures alone do not prove worker-slot exhaustion.

Production remains read-only: one successful bounded log query (320-row limit reached), one corrected schema-error attempt, one successful SQL snapshot, one 2.5-second-capped cron-history attempt cancelled and not retried, one project metadata read; no deployment, persistent configuration change, production DML/DDL or paid resource. No new application correction was justified. All 16 prior coordinated candidate/dependency hashes are unchanged. Offline evidence checks pass; previous full-suite results remain historical, not rerun as proof of a live fix.

---

# Five-blocker local resolution update ? 2 November 2026

[Resolution report](WAYDROP_BLOCKER_RESOLUTION_REPORT.md) ? [Deployment checklist](WAYDROP_PRODUCTION_DEPLOYMENT_CHECKLIST.md) ? [Exact verification](blocker-resolution/VERIFICATION.json).

Coordinated local candidates now implement token-fenced atomic dispatch, canonical rider eligibility, durable request coalescing, per-device push claims and bounded crash recovery. **17 native groups and 15 actual Edge/native tests pass; Flutter remains 2,118 passed / 0 failed; analyzer 0 errors / 73 warnings / 384 infos.** No application `lib/` file changed. Previous completed fixes are preserved.

Production SQL/Edge remain **NO-GO pending managed integration, business-rule/uncertain-delivery signoff and writer admission/drain validation**; Flutter reviewed subset remains CONDITIONAL GO. No deployment or production mutation occurred. Historical manifests/candidates below are historical evidence and are superseded where the new coordinated protocol changes their payload. Original November 1 initiating CPU/I/O/database cause remains unproven.

---

# Part 5 final verification â€” 2 November 2026

[Final report](PART_5_FINAL_VERIFICATION.md) Â· [Deployment checklist and Android procedure](WAYDROP_PRODUCTION_DEPLOYMENT_CHECKLIST.md) Â· [Exact failures/results/hashes](final-verification-20261102/VERIFICATION.json) Â· [Native adversarial results](final-verification-20261102/SAFETY_RESULTS.json).

**Production unchanged. Zero writes/deployments/migrations/configuration changes, zero new log queries and no paid resources. The original initiating database cause is still unproven.** Current health/temp/maintenance data and one EXPLAIN were read, but incident host charts/wait graphs remain unavailable; browser inventory was empty. Seven of eight top retained spill statements are introspection, not Flutter workload; cumulative totals cannot locate the incident or prove a disk bottleneck.

All sixteen Part 4 broader-suite failures reproduced as **CRLF-sensitive source fixtures**, not newly found application defects. Five readers now normalize line endings with every assertion unchanged. Targeted **105 pass/16 fail â†’ 121 pass/0 fail**. Final full Flutter: **2,118 pass / 0 fail**. Analyzer: **0 errors / 73 warnings / 384 infos**, exit 2; not described as clean. Exact original names/errors and baseline limits are preserved in verification.

New actual local corrections:

- `reject-order` conditionally updates the exact observed assignment state and returns 409 before audit work when it changed. This prevents a stale rejection/cooldown write after acceptance/re-offer. Four race probes fail against the pre-Part-5 source; all eight candidate rejection checks pass. Native lock-wait test changes zero accepted rows.
- A captured SECURITY DEFINER internal new-order matching RPC permits anon/authenticated execution without ownership validation. Local **ACL review SQL** revokes untrusted execution while retaining service_role; native role tests pass. Production grants are untouched.
- Opt-in development/profile metric export reuses existing numeric instrumentation, allowlists labels/fields, chunks log entries and drains batches. Three privacy/chunk checks pass; release remains disabled. No Android device was present, so no real-device performance gain is claimed.

**Safety remains blocked:** an old dispatch worker's unfenced offer/state writes can overwrite after lease replacement, even though its release cannot clear the new lease. Native core call offers to an offline rider; two recovery selections enqueue twice before a worker claims. These are counterexamples, not safety passes. **Do not deploy stale-worker recovery** before every-writer server-side fencing, eligibility parity and durable enqueue coalescing. Concurrent push replay and delivery/status crash ambiguity also remain; Part 4 INSERT-only policies do not certify every chat authorization path.

Final matrix: matching/GPS **8 native groups**, dispatch **5**, atomic acceptance **16**, actual acceptance handler **4**, worker/audit **5**, rejection **8**, push **16**, Edge auth/flags **8**, chat RLS/trigger **14**, plus **10 adversarial diagnostic assertions** (four expose unsafe/amplifying behavior). Frozen acceptance/recovery artifact checks pass. No payment-provider/managed Auth/Realtime/FCM or Android end-to-end certification is inferred.

Assessment: **Flutter reviewed subset CONDITIONAL GO** after device/managed/scope-freeze gates; **combined SQL NO-GO; combined Edge NO-GO**. Isolated security/acceptance/rejection candidates have explicit separate conditions in the checklist. No blanket `db push`, no index/publication changes, no automatic deployment. Earlier reports and fixes below remain as historical evidence; their old failure totals are superseded by this final run.

# Part 4 update â€” Chat, notifications and API failures, 2 November 2026

Detailed investigation and exact source coordinates: [PART_4_CHAT_NOTIFICATIONS.md](PART_4_CHAT_NOTIFICATIONS.md). [Captured metadata](chat-notifications-20261102/CATALOG.json), [push v24](chat-notifications-20261102/production-push-v24.ts), [verification/source hashes](chat-notifications-20261102/VERIFICATION.json), [native results](chat-notifications-20261102/DATABASE_RESULTS.json).

**Production stayed read-only; zero new log queries, deployments, migrations, configuration changes or paid resources. Part 5 has not started. The initiating database root cause remains unproven.** Retained `57014` Chat INSERT cancellations and `PGRST003` are backend failure mechanisms. Ordinary push delivery happens asynchronously; FCM `UNREGISTERED` cannot directly cause the originating Chat INSERT to wait for provider delivery. Native fault tests distinguish whole-transaction cancellation from ordinary enqueue exceptions that preserve chat/inbox and log a failure.

New local corrections:

- Preserve optimistic/realtime/outbox messages when delayed history arrives; append a confirmation whose temp bubble was lost; prefer confirmed UUIDs and deterministic display ordering. Recover missed history after successful channel joins/resume using single-flight/coalescing and owner/disposal guards. Preserve Part 2 pooling/SDK recovery.
- Stop starting subsequent outbox POSTs after screen disposal/background/account change; retain unsent entries. Existing stable-ID serialization, durable persistence and send backoff remain. Duplicate-key recovery additionally compares message type.
- Stop immediate queued unread-count retry after a failure; apply bounded 8/16/32/64/120-second backoff and account-owned reconciliation timer. Preserve prior read-state event filtering and subscription cleanup.
- Push candidate: structured `UNREGISTERED` cleanup fenced by recipient/token/registration timestamp; sanitized token/provider/payload logs and responses; preserve successful devices when a sibling fails; validate notification ownership and suppress sequential recorded-success replays; scope service-role status writes after authorization; record empty-token skips. **Concurrent replay and acceptance/status-write ambiguity remain reproducible**, not declared fixed.
- Native RLS proves forged senders and unsolicited other-user support messages are admitted by the captured policy. Remove Flutter's forged-agent welcome and prepare **two restrictive INSERT policies**, outside automatic migrations. Preserve self-support, authenticated agent replies, passenger/rider messages and trusted-server sends. No production policy changed.

Before/after controlled handler results: arbitrary HTTP404 **1â†’0 token deletions**; Auth lookup exception **1â†’0 unauthorized status writes**; partial device exception **HTTP500/failedâ†’HTTP200/sent**; recorded-success replay **2â†’1 provider sends**. Twelve competing identical UUID inserts (up to eight in parallel) commit **one message + one notification + one enqueue**. These are local mechanisms, not measured production latency gains. Edge ownership checks add one PK read; explicit no-token status adds a write.

Final focused checks: **120 Flutter pass / 0 fail; 16 full-handler Deno pass / 0 fail; 14 native PostgreSQL pass / 0 fail**. Captured v24 fails seven selected defect tests as expected. Broader Flutter run: **2,096 pass / 16 fail**, in pre-existing source-contract tests targeting files this part did not edit; exact names and limits are in the Part 4 report/verification. No clean pre-Part-4 full-suite baseline was run this turn. Analysis: **0 errors, 3 existing warnings, 11 infos**. No tests were disabled to hide failures.

Outstanding: durable push claims/retries/reconciliation, bounded cancellable read/error UX, full-history pagination, notification-tap account transitions, attachment/auto-info idempotency, managed/device tests and broader failure triage. Part 3 cross-writer races, eligibility parity, enqueue coalescing and resumed-owner fencing remain open. **Do not deploy stale-worker recovery without fencing validation.** Flutter release, the exact push candidate and the two policy candidates each require explicit production approval; none was executed. Existing Wave A release artifacts are unchanged.

# Part 3 update â€” Dispatch, cron and matching, 2 November 2026

Detailed findings and exact source coordinates: [PART_3_DISPATCH_CRON.md](PART_3_DISPATCH_CRON.md). [Read-only incident evidence](dispatch-cron-20261102/INCIDENT.json), [captured SQL/triggers](dispatch-cron-20261102/CATALOG.json), [native results](dispatch-cron-20261102/PG17_RESULTS.json), [verification](dispatch-cron-20261102/VERIFICATION.json).

**Initiating database root cause remains unproven.** Cron job 5's 9.656-second execution and job 7's 11.669-second startup failure remain incident symptoms. Multiple dispatch entry points were active; totals do not prove same-order overlap. pg_cron serializes each individual scheduled job, contrary to an older test comment; different jobs/direct/async paths can still overlap.

New local work:

- `start-dispatch`: recover NULL-timestamp worker flags with an atomic IS NULL CAS; require a searching order for acquisition; preserve exact-token release. Audit writes now ignore duplicate order/rider/round keys.
- Three captured-definition SQL review candidates: eliminate expected audit unique conflicts in the rider core; skip freed-rider matching when no searching order exists; allow stalled recovery to enqueue old/timestamp-less true flags under the existing stale policy. These are outside automatic migrations and were not applied to production.
- `reject-order`: remove its unused remaining-assignment read, keeping rejection/auth/cooldown behavior and recovery ownership. Shared timeout helper receives a type-only timer compatibility correction.

Measured locally: six valid re-offers produce **6â†’0 audit exceptions**; three empty sweeps **3â†’0 rider-core calls**; ordinary rejection **2â†’1 assignment SELECTs**; recovery selector **1â†’3 recoverable fixtures**. Twelve concurrent claims produce one lease winner; twelve rematches produce one offer/audit/notification effect. The current acceptance implementation is unchanged.

Final verification: **82 passing checks, zero final failures** across native dispatch (5), worker/audit (5), rejection handler (3), Flutter dispatch guards (49), native direct-SQL acceptance (16) and acceptance handler (4). Captured old Edge baseline fails three worker/audit tests and one rejection test as expected. Deno checks pass. Initial acceptance harness/fixture failures were diagnosed and corrected locally; they are documented rather than counted as passes.

**Production remains unchanged.** Audit/read/empty-sweep changes are isolated from automatic stale-true recovery. A worker's response timeout can exceed its nominal execution cap; comprehensive stale-owner/offer/accept fencing and managed failure tests remain production gates. Parts 4/5 handoff covers those races, eligibility parity, enqueue coalescing and controlled load/fault measurements. No schedule, trigger, publication, RLS, index or production Edge deployment changed. Parts 1/2 fixes and earlier matching proposals are preserved.

# Part 2 update â€” Realtime and GPS, 2 November 2026

Detailed investigation: [PART_2_REALTIME_GPS.md](PART_2_REALTIME_GPS.md), [read-only evidence](realtime-gps-20261102/EVIDENCE.json), [client bindings](realtime-gps-20261102/CLIENT_BINDINGS.json), [verification](realtime-gps-20261102/VERIFICATION.json).

**Classification: verified workload amplifier, not a proven initiating cause of the November 1 slowdown.** Actual incident logs contain only 13 Dart `riders` PATCH records, none HTTP >=500, with no rise at 22:02 IST. Twelve recorded WebSocket GETs all precede 21:58 IST; these do not count channel joins/rejoins on existing sockets. Realtime/GPS incident contribution remains unquantified. Historical 2.6 million `list_changes` calls and 25,957 GPS-shaped statements are not incident rates.

Two verified defects are fixed locally:

- `RealtimeManager._reconnectChannel` now checks subscribed status after backoff and connectivity waits, preserving an SDK-recovered channel. Tests show one unnecessary removal/recreation eliminated in each recovery race, while failed-channel recovery and last-owner disposal remain intact. Connectivity is injectable only through the test factory.
- `rider_update_filter.dart` centralizes a conservative GPS-only diff, used by Rider Home, Rider Orders and Passenger Home. Missing previous business fields now follow normal processing instead of suppressing possible availability/COD/service-mode updates. Known full-row GPS-only changes still skip. No GPS rate, precision, payload, online filter or tracking/assignment subscription was removed.

The database bridge synchronously UPSERTs `rider_locations` after qualifying `riders` GPS updates. Existing-row updates run the intercity near-destination lookup even for stationary heartbeat timestamps. Three rider indexes reference coordinates/freshness and impede HOT updates; later cumulative snapshots show about 9.13% HOT on riders versus 100% on rider_locations. These establish amplification mechanisms, not incident CPU/I/O causation or isolated trigger costs.

All 13 publication tables and seven FULL identities were reviewed individually. `riders` publication and FULL remain necessary for current map/diff consumers. No Flutter `rider_locations` subscriber was found; its 58 incident Deno GETs do not require publication. `rider_locations` and `order_verifications` are publication-review candidates, and payment UPDATE consumers are a possible DEFAULT-identity candidate, subject to external-consumer/managed-flow verification and explicit production approval. No production publication, identity, index, trigger, RLS, configuration or deployment changed.

Verification: **51 distinct focused tests passed** (39-test main run plus 12 additional pooling guards; the six new cases appear in both relevant runs). Same new tests against reconstructed previous behavior: **2 pass, 4 fail**; final behavior: **6/6 pass**. Targeted analysis: zero errors, one existing unused-variable warning. Physical-device GPS accuracy, production before/after latency/WAL savings, historical subscriber fanout and trigger timings remain unmeasured. Part 1's initiating-cause uncertainty is unchanged. All earlier local work is preserved; historical results below are not new Part 2 runs.

# Current loading-spike fixes â€” 1 November 2026

**Scope: production read-only; 16:22:00â€“16:34:00 UTC (21:52â€“22:04 IST).** All fixes below are local. No database/schema/RLS/cron/configuration writes, Edge deployments or paid resources. Existing atomic acceptance remains intact. This section supersedes historical totals and source coordinates below.

[Sanitized evidence](loading-spike-20261101/EVIDENCE.json) Â· [Exact locations](loading-spike-20261101/CHANGES.json) Â· [Results and source hashes](loading-spike-20261101/VERIFICATION.json)

## Verified problems and implementation

| Problem | Evidence / timestamp | Root cause and local fix |
| --- | --- | --- |
| Shared backend congestion | Chat POSTs carry HTTP500/57014. At16:31:57:58,813ms origin,58,692ms upstream. PGRST003 at16:32:25,:33,:47,:56. | Execution cancellations and pool acquisition pressure confirmed; most latency is upstream rather than Flutter rendering. **Initiating CPU/I/O/lock cause remains unknown:** historical wait/compute samples were unavailable. No speculative SQL/index/cron changes. |
| Chat replay and lost queue entries | 28 POSTs,11 HTTP500s; POST p9558,248ms/max58,813ms. Successful POSTs also reached47,940ms. Flutter timed out after8s without cancelling HTTP; replay removed its ID. Queue sync overwrote its pre-POST snapshot and discarded non-network errors. | Persist a stable UUID before POST; serialize writes per account and join identical pending sends. Recover23505 only through own-row/conversation-scoped SELECT with matching content. Preserve queue appends/errors; retry transient failures after8/16/32/64/120s; stop background replay. Logs do not prove specific production messages were duplicates. |
| Passenger Home request amplification | One JWT session:133 each of Home's orders projection, riders(id), KYC(id,blocked_until,kyc_status); users(full_name)141. | Order events fetched all four collections and recreated the order subscription. Use order-only refresh with account-scoped display-profile reuse for<30s; retain existing subscription. Manual/resume/full loads still fetch profiles. Pause covered-route passive polling; failed/dirty refreshes retain fallback despite continuing events. |
| Notification unread-count amplification | 159 HEADs,p957,613ms/max48,728ms;82 PATCHes and1 GET. Source counted on every event, including delivery-only UPDATEs. | Bounded observed read-state cache skips known unchanged UPDATEs; unknown/INSERT/DELETE/read transitions still reconcile. Clear observations on account change/failure. Preserve actual HTTP in-flight ownership rather than release it after an ineffective Future timeout. Exact number of incident PATCHes that were delivery-only is unproven. |
| Realtime and cron delays | list_changes13,798.532ms at16:32:33; redispatch-freed startup timeout16:32:36â€“48. | Shared pressure confirmed; neither a subscription leak nor cron as initiating cause established. Preserve jobs/publications and essential tracking/dispatch listeners. Numeric event-age instrumentation added. |
| Edge/Auth/push | send-push87 calls,p9514,932/max32,738ms; live-status70,p956,002/max34,745ms; listed Edge gateway calls had no>=500. Auth logs confirm one504/request_timeout, recorded path '/'. Eight UNREGISTERED log entries. | Edge wall time does not localize SQL/provider delay. Chat trigger chain inserts notification, then Vault lookup and **asynchronous pg_net enqueue**; it does not synchronously wait for FCM delivery. Eight entries are not eight proven distinct tokens. No push changes/deployment. |

Method-specific Dart GET aggregates: orders346/p952,976ms/max40,428ms; riders277 GET+13 PATCH/GET p953,228ms/max41,046ms; users161 GET+4 writes/GET p953,144ms/max39,229ms; KYC146 GET/p952,533ms/max39,056ms. Exact quantiles and method grouping differ slightly from the user's aggregation. At16:32,30 Dart REST requests included7 errors,p9552,446ms. **These span up to2 accounts; JWT session is not a device/build identity.** Home source/projection correlation does not establish that all requests came from the tested phone.

## Exact files/functions changed locally

| File | Current function / line | Change |
| --- | --- | --- |
| [lib/modules/chat/services/chat_message_delivery.dart](../../lib/modules/chat/services/chat_message_delivery.dart#L15) | ChatMessageDelivery, line 15 | Stable UUID, one outstanding account write, pending-send joining, scope-checked duplicate recovery and 8/16/32/64/120s backoff |
| [lib/modules/chat/screens/order_chat_screen.dart](../../lib/modules/chat/screens/order_chat_screen.dart#L1253) | _sendMessage, line 1253 | Durable outbox before POST; no non-cancelling eight-second INSERT timeout; preserve send guards and optimistic UI |
| [lib/modules/chat/screens/order_chat_screen.dart](../../lib/modules/chat/screens/order_chat_screen.dart#L195) | _syncOfflineQueue, line 195 | Persist legacy UUID before replay, acknowledge against fresh queue, keep failures, merge realtime/REST bubbles |
| [lib/modules/chat/screens/order_chat_screen.dart](../../lib/modules/chat/screens/order_chat_screen.dart#L140) | _startSyncTimer / didChangeAppLifecycleState, line 140 | Stop background/disposed replay timers; remove unrelated Google DNS prerequisite |
| [lib/features/user/home/home_tab.dart](../../lib/features/user/home/home_tab.dart#L695) | _load / _loadMeasured, line 695 | Order events reuse account-scoped display profiles for <30s; full/manual/resume loads revalidate; retain true in-flight read lane |
| [lib/features/user/home/home_tab.dart](../../lib/features/user/home/home_tab.dart#L1065) | _subscribeActiveOrders, line 1065 | Keep same-account subscription; order events request orders-only refresh |
| [lib/features/user/home/home_tab.dart](../../lib/features/user/home/home_tab.dart#L221) | _startSilentRefreshTimer, line 221 | Pause covered-route passive polling; dirty/failed refresh still gets bounded fallback despite continuing realtime |
| [lib/features/user/home/profile_refresh_window.dart](../../lib/features/user/home/profile_refresh_window.dart#L3) | reuseFor / recordSuccess, line 3 | Account/age-bound display reuse; never an authorization cache |
| [lib/modules/notifications/services/notification_badge_service.dart](../../lib/modules/notifications/services/notification_badge_service.dart#L47) | _refreshOnce / startListening / stopListening, line 47 | Hold count lane until HTTP ends; filter metadata-only changes using observed read state; clear observations on account change or failed count |
| [lib/modules/notifications/services/notification_count_events.dart](../../lib/modules/notifications/services/notification_count_events.dart#L3) | needsRefresh, line 3 | Bounded 256-row observations; unknown, INSERT, DELETE and read transitions reconcile |
| [lib/core/services/diagnostics/api_metrics_client.dart](../../lib/core/services/diagnostics/api_metrics_client.dart#L25) | send / _measureBody, line 25 | Development/profile numeric HTTP header/body completion timing and collection-level counts |
| [lib/core/services/diagnostics/performance_trace.dart](../../lib/core/services/diagnostics/performance_trace.dart#L7) | measure / record / startFrames, line 7 | Separate bounded screen/API/retry and build/raster samples; disabled in release |
| [lib/core/services/realtime/realtime_manager.dart](../../lib/core/services/realtime/realtime_manager.dart#L279) | Postgres callback, line 279 | Numeric commit-to-receive age; includes client/server clock skew |
| [lib/main.dart](../../lib/main.dart#L49) | main, line 49 | Register development/profile frame timings |
| [lib/app_start_screen.dart](../../lib/app_start_screen.dart#L89) | checkUserFlow, line 89 | Startup span only; Auth, suspension, maintenance and KYC gates preserved |
| [lib/features/rider/home/rider_home_tab.dart](../../lib/features/rider/home/rider_home_tab.dart#L376) | _loadRiderOnce, line 376 | Rider Home span only; GPS and essential order listeners preserved |
| [lib/features/rider/orders/rider_orders_screen.dart](../../lib/features/rider/orders/rider_orders_screen.dart#L791) | fetchSearchingOrders, line 791 | Rider Orders span only; dispatch and atomic acceptance preserved |
| [lib/features/local_rides/tracking/screens/ride_tracking_screen.dart](../../lib/features/local_rides/tracking/screens/ride_tracking_screen.dart#L180) | initialize, line 180 | Ride Tracking initialization span only |
| [lib/modules/notifications/screens/notifications_inbox_screen.dart](../../lib/modules/notifications/screens/notifications_inbox_screen.dart#L50) | _load, line 50 | Notifications inbox load span only |

No SQL/Edge changes were written in this pass. Chat already has PK(id), history(order_id,created_at), sender_id/user_id/rider_id indexes. Existing PK supplies retry idempotency; no new index/removal is justified. Read-only cumulative query statistics since May are not incident-window execution timings. Auth, suspension, KYC, fare, promo, dispatch, matching and atomic acceptance logic were preserved.

## Screen attribution and safe timing

Chat POST latency is backend/API delay; only3 history GETs occurred, so history polling is not this incident's demonstrated driver. Passenger Home's exact four-query shape identifies a client amplification path. Other screen queries overlap the shared slow collections; historical logs lack screen trace IDs, so exact Startup/Rider Home/Orders/Tracking/Notifications screen p95 or rendering costs cannot be reconstructed.

Development/profile spans now cover Startup, both Homes, Rider Orders, Chat, ride Tracking initialization and Notifications. Parcel/intercity tracking remains collection-level timing unless called under a tagged span. **PerformanceTrace.samples** records screen-work wall time, HTTP headers/body completion, planned retry wait and signed Realtime commit age. **frameSamples** separately records build/raster microseconds. Each buffer is bounded256; no IDs, coordinates, bodies, tokens or query values are recorded. Release builds record nothing. Screen-work time includes awaits; HTTP timing cannot separate SQL from pool/gateway/network time; Realtime age includes clock skew. These are not interchangeable measurements.

## Results and before/after observations

- **Flutter full:2,095 passed,0 failed. New focused:13 passed,0 failed**, included in the full count. Final equivalent style cleanup was followed by focused tests and analyzer. Four stale assertions were updated after verifying behavior: two require sanitized genuine send errors, one permits profile reuse while retaining own-account rider filtering, one requires true in-flight Home ownership instead of a non-cancelling Future timeout. No skipped/deleted tests.
- **Local PostgreSQL17:3 passed,0 failed.** [Results](loading-spike-20261101/PG17_RESULTS.json):16 concurrent same-ID attempts yield1 commit/15 duplicate rejections/**one AFTER INSERT effect**; lost-response replay adds no effect; rollback retains no effect. Synthetic fixture proves PK/transaction semantics, not managed RLS/Realtime/pg_net or real delivery.
- Controlled tests: identical direct/timer send now produces **one pending POST**; cooldown attempts issue **zero extra POSTs**; replay reuses the same UUID. One unknown notification UPDATE reconciles, then20 same-read-state metadata updates cause **zero further refreshes**. Qualifying Home order refresh uses1 order query rather than4 collection reads; account/TTL/manual refresh policy is tested. These are functional request-count observations, **not production latency benchmarks**.
- **Analyzer:0 errors,73 warnings,381 information diagnostics.** Nonzero exit remains for existing findings; new helpers/test have no diagnostics. Legacy unused Chat builders and UI deprecations remain outside scope.
- Wave A bundle integrity:**PASS**, five files/three request hashes and deployment/recovery commands. No production calls. Prior PG17/Deno acceptance tests remain preserved and are not re-counted here.
- Devices: Windows/Chrome/Edge only. **No physical Android startup/frame/GPS-write-rate measurements or production after-fix timings obtained. No live p95 improvement claimed.**

Commands executed: flutter test --no-pub --reporter expanded; flutter analyze --no-pub; node docs/performance/loading-spike-20261101/chat-pg17-test.mjs after existing loopback start script (stopped afterward); node docs/production-performance/edge-only/verify-wave.mjs. Logs remain in .dart_tool/loading-spike-*.log.

## Remaining work / release status

1. Review/rebuild and test a physical Android device with an authorized destination: flutter devices, then flutter run --profile -d <android-id> --dart-define-from-file=<authorized-test-env-file>. Record DevTools build/raster frames, numeric buffers and request counts through the same screen sequence. No test resources were provisioned; production stays read-only, including active-flow tests.
2. Obtain retained managed CPU/memory/I/O and database wait/lock evidence for16:30â€“16:34UTC to determine the initiating bottleneck. Later metadata showed max_connections60 and no blocked sessions; this cannot clear the historical incident. No production EXPLAIN ANALYZE/load benchmark was run.
3. Validate client UUID replay under managed test-account RLS and transactional notifications. Real push delivery remains untested without a safe destination; push deployment stays gated.
4. Existing backend matching/GPS/index/config proposals remain unchanged and undeployed. **Local fixes verified; live loading improvement and production release readiness not established. No production approval inferred or requested.**

---

# Historical checkpoint â€” superseded counts and source coordinates

> **Later urgent startup hotfix:** the earlier profile suspension assumptions and source-line inventory below are historical. See [startup hotfix](../startup-fix/README.md) for the schema-correct Auth/profile implementation, 176 checked SELECTs, 57 focused / 2082 full passing tests and rebuild instructions. No production backend change occurred.

# Waydrop Flutter + Supabase performance implementation report

1 November 2026 (Asia/Calcutta). Project: waydrop / yvwpchffctiagevpqgwy. This consolidates preserved implementations and the two verified fixes completed in this pass. No production writes, deployments, migrations, provider payments, paid resources or upgrades occurred. Production accept-order was last read-only verified as v60 with the captured source/settings; the local atomic candidate has not reached production.

## Result and counting rules

- **29 documented problem groups:** 21 Flutter groups, 4 implemented backend groups and 4 deferred backend groups.
- **25 groups implemented locally**, including the preserved fixes; this is not a claim that 25 production/device problems are proven resolved. **Two groups newly fixed in this pass: F19 and B02.** The four B05â€“B08 groups remain deferred/unresolved. Physical-device and managed integration gaps are cross-cutting verification gates, not additional counted code fixes.
- **37 Flutter application source files** modified/added relative to current Git HEAD, including retained earlier work. Tests/pubspec/docs are excluded from this count.
- **5 Supabase-tree files** modified/added: four accept-order bundle files and one inherited unexecuted migration. One Edge Function is changed in the active source tree. Six additional staged matching/push implementation source files are listed separately; rollback/test/deferred-index files are not counted as active source modifications. Four distinct backend objects have implemented candidates: accept-order, send-push-notification and two matching SQL functions. **Zero objects deployed.**
- **2,118 final test/check executions PASS, 0 FAIL in this pass:** Flutter 2,065; native transaction 16; handler/recovery 4; Edge Auth/error 8; actual SDK/PostgREST/direct DB 8; mocked push 17. Overlapping targeted Flutter run (7) and historical TLS (3), drain (2), Node (58), matching/GPS (8 groups) are not added again. The intentionally failing before-fix badge reproduction is evidence, not a remaining failure.
- Full static analysis: **0 errors, 73 existing warnings, 382 existing information diagnostics (455 total)**; no diagnostic in the two changed Dart files. Analyzer exits 2 for existing findings; it is not reported as a clean zero-diagnostic run. New Edge frozen check passes.
- Production release verdict: **NO-GO** until managed integration/hosted recovery and v60 drain prerequisites are evidenced. No production performance gain is claimed.

## New implementation completed in this pass

1. NotificationBadgeService: generation field line 22, request capture line 46, stale-result gate lines 62â€“66, listener-scope increment line 77 and stop increment line 110. Regression begins test/waydrop_gps_and_badge_test.dart line 232.
2. accept-order/index.ts line 132: observed ECONNRESET is now retryable 503; no transaction logic changed.

[Exact focused source diff](NEW_VERIFIED_FIXES.patch), [current verification and log hashes](VERIFICATION.json), [readable copy of the actual anonymous transaction SQL](ATOMIC_ACCEPTANCE_REVIEW_ONLY.sql). The SQL copy is for review, not a standalone migration or execution instruction.

Dependency support retained: pubspec.yaml line 50 declares http directly for the existing instrumentation import; pubspec.lock reflects direct dependency classification. No package version changed in this pass.

## Summary table: exact current source files and changed lines

Ranges are current new-side diff hunks against Git HEAD, including earlier retained work. Added files show their whole current extent; deletion-only ranges identify the surviving deletion boundary. They are source coordinates, not claims that every line is new executable logic. Full hashes/ranges: [CHANGED_SOURCE_FILES.json](CHANGED_SOURCE_FILES.json); declaration coordinates: [FUNCTION_LINES.json](FUNCTION_LINES.json). Group details below explain previous behavior, implementation, functions, evidence and risks for every mapped file.

| Problem | Flutter/Supabase | Exact File or DB Object | Lines | Fix Applied | Test Result | Deployment Status |
|---|---|---|---|---|---|---|
| F01,F04 | Flutter | [lib/app_start_screen.dart](../../lib/app_start_screen.dart#L2) | 2, 27, 45â€“46, 56, 63, 65â€“76, 81â€“84, 112â€“131, 136â€“139, 174â€“180, 231 (deletion boundary), 248, 251â€“252, 307, 350 (deletion boundary), 356, 364â€“370, 596 | initState @ 54; listenAuthChanges @ 62; checkUserFlow @ 88; changeScreen @ 331; dispose @ 365; shouldRepaint @ 593; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F03 | Flutter | [lib/core/providers/initial_data_provider.dart](../../lib/core/providers/initial_data_provider.dart#L8) | 8, 15, 21â€“22, 27â€“32 | isUsableFor @ 30; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F01 | Flutter | [lib/core/services/config/production_config_service.dart](../../lib/core/services/config/production_config_service.dart#L94) | 94â€“97, 109, 111, 122 | _fetch @ 93; _loadAppVersion @ 97; _fetchConfig @ 111; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F20 | Flutter | [lib/core/services/diagnostics/api_metrics_client.dart](../../lib/core/services/diagnostics/api_metrics_client.dart#L1) | 1â€“43 (added) | send @ 24; close @ 42; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F09,F10,F11 | Flutter | [lib/core/services/location/location_cache_service.dart](../../lib/core/services/location/location_cache_service.dart#L70) | 70â€“73, 325â€“326, 345â€“347, 349â€“353, 356, 359, 372â€“376, 382â€“385, 402â€“404, 437, 480, 486â€“490, 492â€“494, 502, 517â€“521, 523â€“525, 527â€“528, 560â€“561, 569â€“576, 578â€“580, 582â€“583, 584 (deletion boundary), 588 (deletion boundary), 666â€“667, 678â€“680, 694, 709, 758â€“759, 766, 1043 | _notifyListeners @ 41; _performHeartbeatUpdate @ 324; startRiderLiveTracking @ 399; _handlePositionUpdate @ 569; stopRiderLiveTracking @ 663; updateRiderLocation @ 695; clearCache @ 1030; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F12 | Flutter | [lib/core/services/realtime/realtime_manager.dart](../../lib/core/services/realtime/realtime_manager.dart#L58) | 58, 62â€“65, 80â€“90, 188, 239 (deletion boundary), 242, 245, 272â€“275, 294â€“299, 334, 348, 352, 363, 365, 380, 433 | _isCurrentChannel @ 80; _removeChannelSafely @ 83; subscribe @ 93; unsubscribe @ 222; _subscribeToChannel @ 293; _reconnectChannel @ 322; dispose @ 429; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F13,F14 | Flutter | [lib/core/services/realtime/realtime_order_controller.dart](../../lib/core/services/realtime/realtime_order_controller.dart#L3) | 3, 11, 13â€“25, 53, 62â€“65, 68â€“76, 84, 88, 101â€“102, 109, 114, 132, 177â€“178, 194, 206â€“207, 209, 226, 252â€“273, 281, 297â€“313, 321â€“322, 389, 405â€“426, 433, 477â€“478, 547â€“548, 565, 569â€“575, 578, 587, 591, 598, 600, 611, 624, 633, 640, 646, 648, 655â€“663, 666, 668, 671, 675 | start @ 68; _start @ 73; _refreshOrderAndLiveState @ 179; _applyOrderData @ 220; fetchOrder @ 251; _drainOrderReads @ 265; _queryOrder @ 272; _fetchUserName @ 297; _queryUserName @ 313; fetchLiveOrderState @ 329; _fetchRider @ 405; _queryRider @ 426; _updateRiderLocation @ 559; _setRiderLocation @ 569; _subscribeOrder @ 577; _subscribeRider @ 607; didChangeAppLifecycleState @ 656; dispose @ 665; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F04 | Flutter | [lib/core/services/session/auth_routing_policy.dart](../../lib/core/services/session/auth_routing_policy.dart#L1) | 1â€“20 (added) | shouldRecheck @ 9; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F05 | Flutter | [lib/core/services/session/rider_access_service.dart](../../lib/core/services/session/rider_access_service.dart#L1) | 1â€“119 (added) | resolve @ 58; _fetch @ 75; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F06 | Flutter | [lib/core/services/session/user_session_service.dart](../../lib/core/services/session/user_session_service.dart#L0) | 0 (deletion boundary), 3â€“6, 13, 21â€“23, 36â€“52, 54â€“102, 107â€“111, 113 | listenUserSuspension @ 27; handleAccountRestriction @ 56; stopListening @ 106; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F07,F08 | Flutter | [lib/features/auth/screens/profile_setup_screen.dart](../../lib/features/auth/screens/profile_setup_screen.dart#L99) | 99â€“103, 107, 122, 130, 462 | saveProfile @ 60; build @ 383; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F08 | Flutter | [lib/features/intercity/shared/screens/intercity_tracking_screen.dart](../../lib/features/intercity/shared/screens/intercity_tracking_screen.dart#L2025) | 2025, 2027, 2031, 2036 | _performCancel @ 1995; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F08 | Flutter | [lib/features/local_parcels/booking/screens/parcel_location_screen.dart](../../lib/features/local_parcels/booking/screens/parcel_location_screen.dart#L1141) | 1141 | continueFlow @ 1112; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F08 | Flutter | [lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart](../../lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart#L1539) | 1539, 1541, 1545, 1550 | _performCancel @ 1509; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F08 | Flutter | [lib/features/local_rides/booking/screens/ride_location_screen.dart](../../lib/features/local_rides/booking/screens/ride_location_screen.dart#L1232) | 1232 | continueFlow @ 1203; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F08 | Flutter | [lib/features/local_rides/tracking/screens/ride_tracking_screen.dart](../../lib/features/local_rides/tracking/screens/ride_tracking_screen.dart#L1654) | 1654, 1656, 1660, 1665 | _performCancel @ 1623; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F03,F17 | Flutter | [lib/features/rider/earnings/rider_earnings_tab.dart](../../lib/features/rider/earnings/rider_earnings_tab.dart#L26) | 26â€“30, 37â€“38, 70â€“71, 151, 162, 167, 187, 192, 201, 209, 213, 226, 262â€“281, 310, 314, 329, 1226 | didUpdateWidget @ 143; dispose @ 160; _subscribeWithdrawals @ 182; _subscribeRider @ 208; fetchData @ 262; _drainDataRequests @ 274; _fetchDataOnce @ 281; _showWithdrawBottomSheet @ 1104; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F03,F09,F16 | Flutter | [lib/features/rider/home/rider_home_tab.dart](../../lib/features/rider/home/rider_home_tab.dart#L151) | 151, 160â€“169, 177â€“178, 225, 230, 240â€“244, 258, 260, 309â€“312, 314, 353â€“354, 356â€“376, 406, 475â€“476, 698, 1634, 1652, 1670, 1688â€“1689, 2263, 2289, 2297â€“2298, 2340, 3221, 3235, 3257, 3267, 3278, 3322, 3331, 3334 | _fetchTodayEarnings @ 161; _queryTodayEarnings @ 169; initState @ 201; _startSilentRefreshTimer @ 251; didChangeAppLifecycleState @ 308; dispose @ 319; loadRider @ 355; _loadRiderOnce @ 375; subscribeRider @ 608; _showFreeTrialBottomSheet @ 1508; _showSubscriptionBottomSheet @ 1870; _handleOrderAction @ 3216; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F02,F05 | Flutter | [lib/features/rider/navigation/rider_main_navigation_screen.dart](../../lib/features/rider/navigation/rider_main_navigation_screen.dart#L2) | 2, 4, 17â€“18, 21â€“28, 31, 34, 54, 62, 82, 135, 222â€“224 | build @ 22; initState @ 60; _subscribeServiceMode @ 126; build @ 203; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F04,F05 | Flutter | [lib/features/rider/onboarding/screens/rider_entry_handler.dart](../../lib/features/rider/onboarding/screens/rider_entry_handler.dart#L2) | 2â€“7, 20â€“22, 25, 28, 30â€“34, 39â€“44, 49â€“50, 52â€“63, 65â€“69, 71, 73â€“74, 76, 78â€“82, 99â€“101, 103â€“123, 124 (deletion boundary), 702 | initState @ 37; load @ 48; dispose @ 79; build @ 86; build @ 541; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F03 | Flutter | [lib/features/rider/orders/rider_orders_screen.dart](../../lib/features/rider/orders/rider_orders_screen.dart#L248) | 248 | resolveRiderAndLoad @ 204; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F08 | Flutter | [lib/features/rider/orders/screens/rider_active_order_screen.dart](../../lib/features/rider/orders/screens/rider_active_order_screen.dart#L2161) | 2161 | confirmCancellation @ 2060; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F12 | Flutter | [lib/features/rider/orders/widgets/incoming_order_card.dart](../../lib/features/rider/orders/widgets/incoming_order_card.dart#L10) | 10, 41â€“44, 59â€“62, 64â€“70, 174â€“184, 202â€“203, 207, 209â€“217, 226â€“227 | dispose @ 56; _subscribeToOrder @ 173; _subscribeToAssignment @ 206; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F03 | Flutter | [lib/features/rider/profile/rider_profile_tab.dart](../../lib/features/rider/profile/rider_profile_tab.dart#L153) | 153, 159 | loadProfileData @ 137; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F05 | Flutter | [lib/features/rider/services/rider_status_service.dart](../../lib/features/rider/services/rider_status_service.dart#L2) | 2, 106â€“108, 110â€“111 | switchToRiderMode @ 104; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F08 | Flutter | [lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart](../../lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart#L699) | 699 | _confirmDeletePlan @ 680; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F15 | Flutter | [lib/features/user/activity/activity_tab.dart](../../lib/features/user/activity/activity_tab.dart#L25) | 25â€“27, 88â€“90, 122, 125, 143â€“155, 158â€“165, 288â€“290, 328â€“329, 365â€“370, 476â€“477, 483 | _startSilentRefreshTimer @ 120; didUpdateWidget @ 144; didChangeAppLifecycleState @ 157; loadOrders @ 287; _subscribeRealtime @ 454; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F01,F08,F15 | Flutter | [lib/features/user/home/home_tab.dart](../../lib/features/user/home/home_tab.dart#L48) | 48â€“49, 74â€“81, 91â€“93, 188â€“190, 218, 221, 250, 271â€“272, 275â€“278, 282â€“287, 688â€“690, 705â€“706, 712, 721â€“724, 771, 776, 843â€“848, 918 | _removeMultiplexedHomeChannel @ 75; initState @ 157; _startSilentRefreshTimer @ 216; dispose @ 241; didChangeAppLifecycleState @ 270; didUpdateWidget @ 283; _load @ 687; _subscribeRealtime @ 904; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F05,F08 | Flutter | [lib/features/user/profile/profile_tab.dart](../../lib/features/user/profile/profile_tab.dart#L490) | 490, 816, 949 | _pickAndUploadProfilePhoto @ 473; build @ 528; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F01,F20 | Flutter | [lib/main.dart](../../lib/main.dart#L3) | 3â€“4, 28â€“29, 48, 92 | main @ 44; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F02,F15 | Flutter | [lib/main_navigation_screen.dart](../../lib/main_navigation_screen.dart#L1) | 1, 4, 30, 33 (deletion boundary), 42â€“43, 45, 70, 73, 75â€“80, 117, 119 | setIndex @ 29; initState @ 39; build @ 50; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F21 | Flutter | [lib/modules/admin/admin_dashboard_screen.dart](../../lib/modules/admin/admin_dashboard_screen.dart#L1) | 1, 8, 10â€“16, 19, 22 | build @ 11; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F08,F12 | Flutter | [lib/modules/chat/screens/order_chat_screen.dart](../../lib/modules/chat/screens/order_chat_screen.dart#L71) | 71â€“72, 83 (deletion boundary), 103â€“106, 1240, 1243â€“1253, 1274â€“1275, 2146 | mergeSentMessage @ 29; dispose @ 102; _subscribeChat @ 1239; build @ 1604; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F18,F19 | Flutter | [lib/modules/notifications/services/notification_badge_service.dart](../../lib/modules/notifications/services/notification_badge_service.dart#L20) | 20â€“22, 24â€“46, 53, 55, 59â€“66, 77, 106â€“128 | refresh @ 24; _drainRefreshQueue @ 38; _refreshOnce @ 45; startListening @ 74; stopListening @ 109; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F12 | Flutter | [lib/modules/payments/services/payment_service.dart](../../lib/modules/payments/services/payment_service.dart#L12) | 12, 340â€“342, 344â€“347, 359, 361â€“362, 685 | listenPaymentStatus @ 332; startPayment @ 519; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F21 | Flutter | [lib/shared/widgets/account_guard.dart](../../lib/shared/widgets/account_guard.dart#L1) | 1â€“86 (added) | initState @ 23; _check @ 42; dispose @ 59; build @ 65; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| F02 | Flutter | [lib/shared/widgets/lazy_indexed_stack.dart](../../lib/shared/widgets/lazy_indexed_stack.dart#L1) | 1â€“45 (added) | build @ 24; group implementation below | Full suite PASS | Local source only; app/device release not verified |
| B01 | Supabase | [supabase/functions/accept-order/acceptance_sql.ts](../../supabase/functions/accept-order/acceptance_sql.ts#L1) | 1â€“2 (added) | Atomic Edge bundle / exact dependency configuration | PG17/Edge/network PASS | NOT deployed |
| B01 | Supabase | [supabase/functions/accept-order/atomic_acceptance.ts](../../supabase/functions/accept-order/atomic_acceptance.ts#L1) | 1â€“58 (added) | Atomic Edge bundle / exact dependency configuration | PG17/Edge/network PASS | NOT deployed |
| B01 | Supabase | [supabase/functions/accept-order/deno.json](../../supabase/functions/accept-order/deno.json#L1) | 1â€“6 (added) | Atomic Edge bundle / exact dependency configuration | PG17/Edge/network PASS | NOT deployed |
| B01,B02 | Supabase | [supabase/functions/accept-order/index.ts](../../supabase/functions/accept-order/index.ts#L5) | 5â€“6, 95â€“122, 126â€“133, 135â€“136, 139â€“140 | Atomic Edge bundle / exact dependency configuration | PG17/Edge/network PASS | NOT deployed |
| B08 (deferred) | Supabase | [docs/migration-review/not-applied/20261026000000_remove_legacy_find_nearby_riders_overload.sql](../../docs/migration-review/not-applied/20261026000000_remove_legacy_find_nearby_riders_overload.sql#L1) | 1â€“24 (added) | Inherited draft; NOT applied | Deployment necessity unverified | NOT deployed |

### F01 â€” Startup waits and duplicate initial reads

- **Exact functions/SQL:** main; AppStartScreen.checkUserFlow/changeScreen; ProductionConfigService.init/_fetch/_fetchConfig.
- **Files and modified lines:** [lib/app_start_screen.dart](../../lib/app_start_screen.dart#L2) (2, 27, 45â€“46, 56, 63, 65â€“76, 81â€“84, 112â€“131, 136â€“139, 174â€“180, 231 (deletion boundary), 248, 251â€“252, 307, 350 (deletion boundary), 356, 364â€“370, 596); [lib/core/services/config/production_config_service.dart](../../lib/core/services/config/production_config_service.dart#L94) (94â€“97, 109, 111, 122); [lib/features/user/home/home_tab.dart](../../lib/features/user/home/home_tab.dart#L48) (48â€“49, 74â€“81, 91â€“93, 188â€“190, 218, 221, 250, 271â€“272, 275â€“278, 282â€“287, 688â€“690, 705â€“706, 712, 721â€“724, 771, 776, 843â€“848, 918); [lib/main.dart](../../lib/main.dart#L3) (3â€“4, 28â€“29, 48, 92)
- **Previous behavior / actual root cause:** Config/profile/package work was sequential; a splash floor and secondary dashboard reads delayed navigation.
- **Implementation / why it fixes the problem:** Overlap independent initialization and bounded profile/config work, evaluate maintenance/version gates before handling profile failures, remove the splash floor, navigate with the startup user snapshot.
- **Tests / results:** Actual startup/maintenance widget regressions and full Flutter suite.
- **Measurements:** Passenger blocking code path: 5 reads to 2 before navigation; splash floor 500 ms to 0. These are source facts, not mobile latency measurements.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** No physical cold/warm or first-usable timings; existing config outage defaults remain.

### F02 â€” Eager hidden tabs and animation work

- **Exact functions/SQL:** LazyIndexedStack.build; MainNavigationScreenState.build/setIndex; rider navigation build/_buildTabs.
- **Files and modified lines:** [lib/features/rider/navigation/rider_main_navigation_screen.dart](../../lib/features/rider/navigation/rider_main_navigation_screen.dart#L2) (2, 4, 17â€“18, 21â€“28, 31, 34, 54, 62, 82, 135, 222â€“224); [lib/main_navigation_screen.dart](../../lib/main_navigation_screen.dart#L1) (1, 4, 30, 33 (deletion boundary), 42â€“43, 45, 70, 73, 75â€“80, 117, 119); [lib/shared/widgets/lazy_indexed_stack.dart](../../lib/shared/widgets/lazy_indexed_stack.dart#L1) (1â€“45 (added))
- **Previous behavior / actual root cause:** IndexedStack initialized every tab; visited hidden tickers continued running.
- **Implementation / why it fixes the problem:** Mount selected tabs lazily, retain keyed State, mute hidden tickers; retain eager rider Home because it owns essential dispatch/GPS services.
- **Tests / results:** Real widget State/key/ticker tests.
- **Measurements:** Two simulated hidden frames: 2 ticker callbacks to 0; initial probe children [1,0,0].
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** No physical frame trace; essential rider services intentionally remain active.

### F03 â€” Stale or other-account initial tab seeds

- **Exact functions/SQL:** InitialRiderData.isUsableFor; rider Home/Orders/Earnings/Profile seed consumers.
- **Files and modified lines:** [lib/core/providers/initial_data_provider.dart](../../lib/core/providers/initial_data_provider.dart#L8) (8, 15, 21â€“22, 27â€“32); [lib/features/rider/earnings/rider_earnings_tab.dart](../../lib/features/rider/earnings/rider_earnings_tab.dart#L26) (26â€“30, 37â€“38, 70â€“71, 151, 162, 167, 187, 192, 201, 209, 213, 226, 262â€“281, 310, 314, 329, 1226); [lib/features/rider/home/rider_home_tab.dart](../../lib/features/rider/home/rider_home_tab.dart#L151) (151, 160â€“169, 177â€“178, 225, 230, 240â€“244, 258, 260, 309â€“312, 314, 353â€“354, 356â€“376, 406, 475â€“476, 698, 1634, 1652, 1670, 1688â€“1689, 2263, 2289, 2297â€“2298, 2340, 3221, 3235, 3257, 3267, 3278, 3322, 3331, 3334); [lib/features/rider/orders/rider_orders_screen.dart](../../lib/features/rider/orders/rider_orders_screen.dart#L248) (248); [lib/features/rider/profile/rider_profile_tab.dart](../../lib/features/rider/profile/rider_profile_tab.dart#L153) (153, 159)
- **Previous behavior / actual root cause:** Process-lifetime seed flags allowed a delayed first tab visit to use old data.
- **Implementation / why it fixes the problem:** Require matching authenticated identity and seed age below five seconds; otherwise fetch fresh data.
- **Tests / results:** Actual seed expiry/account tests and existing tab contracts.
- **Measurements:** No field latency measurement.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Five-second reuse is a bounded startup optimization, not long-lived eligibility caching.

### F04 â€” Refresh-driven rerouting and null-session rider spinner

- **Exact functions/SQL:** AuthRoutingPolicy; AppStartScreen.listenAuthChanges/checkUserFlow; RiderEntryHandler.load/build.
- **Files and modified lines:** [lib/app_start_screen.dart](../../lib/app_start_screen.dart#L2) (2, 27, 45â€“46, 56, 63, 65â€“76, 81â€“84, 112â€“131, 136â€“139, 174â€“180, 231 (deletion boundary), 248, 251â€“252, 307, 350 (deletion boundary), 356, 364â€“370, 596); [lib/core/services/session/auth_routing_policy.dart](../../lib/core/services/session/auth_routing_policy.dart#L1) (1â€“20 (added)); [lib/features/rider/onboarding/screens/rider_entry_handler.dart](../../lib/features/rider/onboarding/screens/rider_entry_handler.dart#L2) (2â€“7, 20â€“22, 25, 28, 30â€“34, 39â€“44, 49â€“50, 52â€“63, 65â€“69, 71, 73â€“74, 76, 78â€“82, 99â€“101, 103â€“123, 124 (deletion boundary), 702)
- **Previous behavior / actual root cause:** Routine token refresh could redo routing; null/error entry paths could strand loading or apply stale identity results.
- **Implementation / why it fixes the problem:** Route meaningful identity transitions, use request generations/mounted checks, clear loading on every terminal path, retain login/retry screens.
- **Tests / results:** Actual session/entry widget tests.
- **Measurements:** Suppresses redundant route work; no device milliseconds measured.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Real provider session expiry, OTP and process restoration remain device/managed checks.

### F05 â€” Inconsistent rider eligibility requests and mode switching

- **Exact functions/SQL:** RiderAccessService.resolve/_fetch/decide; RiderStatusService.switchToRiderMode; RiderEntryHandler.load.
- **Files and modified lines:** [lib/core/services/session/rider_access_service.dart](../../lib/core/services/session/rider_access_service.dart#L1) (1â€“119 (added)); [lib/features/rider/navigation/rider_main_navigation_screen.dart](../../lib/features/rider/navigation/rider_main_navigation_screen.dart#L2) (2, 4, 17â€“18, 21â€“28, 31, 34, 54, 62, 82, 135, 222â€“224); [lib/features/rider/onboarding/screens/rider_entry_handler.dart](../../lib/features/rider/onboarding/screens/rider_entry_handler.dart#L2) (2â€“7, 20â€“22, 25, 28, 30â€“34, 39â€“44, 49â€“50, 52â€“63, 65â€“69, 71, 73â€“74, 76, 78â€“82, 99â€“101, 103â€“123, 124 (deletion boundary), 702); [lib/features/rider/services/rider_status_service.dart](../../lib/features/rider/services/rider_status_service.dart#L2) (2, 106â€“108, 110â€“111); [lib/features/user/profile/profile_tab.dart](../../lib/features/user/profile/profile_tab.dart#L490) (490, 816, 949)
- **Previous behavior / actual root cause:** Multiple entry paths duplicated checks and could disagree about KYC, activation, payout, block or mode.
- **Implementation / why it fixes the problem:** Use one account-scoped in-flight eligibility decision; revalidate the next entry; preserve every required eligibility gate.
- **Tests / results:** Actual decision/coalescing tests plus entry/source regressions.
- **Measurements:** Concurrent eligibility callers share one request set; no unsafe persistent authorization cache.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Flutter checks do not replace backend authorization; managed KYC/payout lifecycle remains unverified.

### F06 â€” Logout/restriction cleanup and leaked account listeners

- **Exact functions/SQL:** UserSessionService.handleAccountRestriction/stopListening.
- **Files and modified lines:** [lib/core/services/session/user_session_service.dart](../../lib/core/services/session/user_session_service.dart#L0) (0 (deletion boundary), 3â€“6, 13, 21â€“23, 36â€“52, 54â€“102, 107â€“111, 113)
- **Previous behavior / actual root cause:** Cleanup could wait on remote signout or leave account-owned services alive.
- **Implementation / why it fixes the problem:** Stop local GPS/listeners/badge, tolerate remote signout failure, invalidate startup state and resolve login navigation safely.
- **Tests / results:** Session/logout fixture regressions.
- **Measurements:** No production timing measurement.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Actual server revocation and background process cleanup require managed/device checks.

### F07 â€” Auth identity with missing profile and disposed form writes

- **Exact functions/SQL:** ProfileSetupScreen.saveProfile.
- **Files and modified lines:** [lib/features/auth/screens/profile_setup_screen.dart](../../lib/features/auth/screens/profile_setup_screen.dart#L99) (99â€“103, 107, 122, 130, 462)
- **Previous behavior / actual root cause:** Missing profile could leave routing inconsistent; late form results could use disposed UI state.
- **Implementation / why it fixes the problem:** UPSERT only current Auth id/canonical phone/form fields, require returned identity, preserve conflict fields and mounted checks.
- **Tests / results:** Actual HTTP form/disposal test and profile contracts.
- **Measurements:** No speed claim; removes a broken routing/write completion path.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** No automatic production backfill; live onboarding not exercised.

### F08 â€” Async navigation and disposed context failures

- **Exact functions/SQL:** Booking continueFlow; tracking _performCancel; profile saveProfile; chat/travel-plan async UI callbacks.
- **Files and modified lines:** [lib/features/auth/screens/profile_setup_screen.dart](../../lib/features/auth/screens/profile_setup_screen.dart#L99) (99â€“103, 107, 122, 130, 462); [lib/features/intercity/shared/screens/intercity_tracking_screen.dart](../../lib/features/intercity/shared/screens/intercity_tracking_screen.dart#L2025) (2025, 2027, 2031, 2036); [lib/features/local_parcels/booking/screens/parcel_location_screen.dart](../../lib/features/local_parcels/booking/screens/parcel_location_screen.dart#L1141) (1141); [lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart](../../lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart#L1539) (1539, 1541, 1545, 1550); [lib/features/local_rides/booking/screens/ride_location_screen.dart](../../lib/features/local_rides/booking/screens/ride_location_screen.dart#L1232) (1232); [lib/features/local_rides/tracking/screens/ride_tracking_screen.dart](../../lib/features/local_rides/tracking/screens/ride_tracking_screen.dart#L1654) (1654, 1656, 1660, 1665); [lib/features/rider/orders/screens/rider_active_order_screen.dart](../../lib/features/rider/orders/screens/rider_active_order_screen.dart#L2161) (2161); [lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart](../../lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart#L699) (699); [lib/features/user/home/home_tab.dart](../../lib/features/user/home/home_tab.dart#L48) (48â€“49, 74â€“81, 91â€“93, 188â€“190, 218, 221, 250, 271â€“272, 275â€“278, 282â€“287, 688â€“690, 705â€“706, 712, 721â€“724, 771, 776, 843â€“848, 918); [lib/features/user/profile/profile_tab.dart](../../lib/features/user/profile/profile_tab.dart#L490) (490, 816, 949); [lib/modules/chat/screens/order_chat_screen.dart](../../lib/modules/chat/screens/order_chat_screen.dart#L71) (71â€“72, 83 (deletion boundary), 103â€“106, 1240, 1243â€“1253, 1274â€“1275, 2146)
- **Previous behavior / actual root cause:** Handlers reused BuildContext after awaits without checking the correct context lifetime.
- **Implementation / why it fixes the problem:** Add mounted/context.mounted guards and use the surviving State context before navigation/snackbars.
- **Tests / results:** Analyzer plus relevant booking/tracking/chat regression contracts.
- **Measurements:** 37 historical use_build_context_synchronously findings resolved; no UI redesign.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Static/source checks do not prove every physical navigation flow.

### F09 â€” Duplicate GPS subscription/upload ownership and failed-write dedup

- **Exact functions/SQL:** LocationCacheService.startRiderLiveTracking/_handlePositionUpdate/updateRiderLocation.
- **Files and modified lines:** [lib/core/services/location/location_cache_service.dart](../../lib/core/services/location/location_cache_service.dart#L70) (70â€“73, 325â€“326, 345â€“347, 349â€“353, 356, 359, 372â€“376, 382â€“385, 402â€“404, 437, 480, 486â€“490, 492â€“494, 502, 517â€“521, 523â€“525, 527â€“528, 560â€“561, 569â€“576, 578â€“580, 582â€“583, 584 (deletion boundary), 588 (deletion boundary), 666â€“667, 678â€“680, 694, 709, 758â€“759, 766, 1043); [lib/features/rider/home/rider_home_tab.dart](../../lib/features/rider/home/rider_home_tab.dart#L151) (151, 160â€“169, 177â€“178, 225, 230, 240â€“244, 258, 260, 309â€“312, 314, 353â€“354, 356â€“376, 406, 475â€“476, 698, 1634, 1652, 1670, 1688â€“1689, 2263, 2289, 2297â€“2298, 2340, 3221, 3235, 3257, 3267, 3278, 3322, 3331, 3334)
- **Previous behavior / actual root cause:** Concurrent starts crossed async checks; skipped callbacks could release another upload lock; failed writes advanced dedup state.
- **Implementation / why it fixes the problem:** Guard startup synchronously, serialize uploads by owner/generation, advance last-success state only on successful current-generation requests; retain online-only rider update filter.
- **Tests / results:** Real geolocator-platform/HTTP fixture concurrency, failure and retry tests.
- **Measurements:** Blocked upload issues one PATCH while additional fixes arrive.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Physical background permissions and battery behavior unmeasured.

### F10 â€” Heartbeat reverse-geocode work and stale GPS freshness

- **Exact functions/SQL:** LocationCacheService._performHeartbeatUpdate/_shouldUploadPosition.
- **Files and modified lines:** [lib/core/services/location/location_cache_service.dart](../../lib/core/services/location/location_cache_service.dart#L70) (70â€“73, 325â€“326, 345â€“347, 349â€“353, 356, 359, 372â€“376, 382â€“385, 402â€“404, 437, 480, 486â€“490, 492â€“494, 502, 517â€“521, 523â€“525, 527â€“528, 560â€“561, 569â€“576, 578â€“580, 582â€“583, 584 (deletion boundary), 588 (deletion boundary), 666â€“667, 678â€“680, 694, 709, 758â€“759, 766, 1043)
- **Previous behavior / actual root cause:** Heartbeat performed an unnecessary reverse geocode and could stamp an old cached fix as fresh.
- **Implementation / why it fixes the problem:** Remove heartbeat address lookup; validate cache/last-known age, fall back to bounded live GPS; share movement/heartbeat gate.
- **Tests / results:** GPS regression contracts and actual upload retry/heartbeat fixtures.
- **Measurements:** 30-second heartbeat retained; avoiding two address lookups/minute is policy arithmetic, not a field benchmark.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** No measured physical writes/minute or moving-device trace.

### F11 â€” GPS stream completion prevented restart

- **Exact functions/SQL:** LocationCacheService.startRiderLiveTracking/stopRiderLiveTracking.
- **Files and modified lines:** [lib/core/services/location/location_cache_service.dart](../../lib/core/services/location/location_cache_service.dart#L70) (70â€“73, 325â€“326, 345â€“347, 349â€“353, 356, 359, 372â€“376, 382â€“385, 402â€“404, 437, 480, 486â€“490, 492â€“494, 502, 517â€“521, 523â€“525, 527â€“528, 560â€“561, 569â€“576, 578â€“580, 582â€“583, 584 (deletion boundary), 588 (deletion boundary), 666â€“667, 678â€“680, 694, 709, 758â€“759, 766, 1043)
- **Previous behavior / actual root cause:** Normally completed stream retained its handle; stale callbacks could clear a newer generation.
- **Implementation / why it fixes the problem:** Clear the matching generation on completion/error; cancel stream/monitor/timer on stop.
- **Tests / results:** Actual normally completed platform stream can restart.
- **Measurements:** Before restart impossible; after replacement stream starts.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Real OS-level termination remains unverified.

### F12 â€” Duplicate/leaked Realtime owners and payment/order/chat channels

- **Exact functions/SQL:** RealtimeManager.subscribe/unsubscribe/_sameConfig/_subscribeToChannel/dispose; IncomingOrderCard subscriptions; PaymentService.listenPaymentStatus; order chat subscriptions.
- **Files and modified lines:** [lib/core/services/realtime/realtime_manager.dart](../../lib/core/services/realtime/realtime_manager.dart#L58) (58, 62â€“65, 80â€“90, 188, 239 (deletion boundary), 242, 245, 272â€“275, 294â€“299, 334, 348, 352, 363, 365, 380, 433); [lib/features/rider/orders/widgets/incoming_order_card.dart](../../lib/features/rider/orders/widgets/incoming_order_card.dart#L10) (10, 41â€“44, 59â€“62, 64â€“70, 174â€“184, 202â€“203, 207, 209â€“217, 226â€“227); [lib/modules/chat/screens/order_chat_screen.dart](../../lib/modules/chat/screens/order_chat_screen.dart#L71) (71â€“72, 83 (deletion boundary), 103â€“106, 1240, 1243â€“1253, 1274â€“1275, 2146); [lib/modules/payments/services/payment_service.dart](../../lib/modules/payments/services/payment_service.dart#L12) (12, 340â€“342, 344â€“347, 359, 361â€“362, 685)
- **Previous behavior / actual root cause:** Separate owners created channels independently; channel name/config collisions or late callbacks could affect the wrong owner.
- **Implementation / why it fixes the problem:** Pool by complete channel configuration, retain per-owner subscription ids, release only that owner, reject obsolete callbacks and isolate consumer exceptions. Payment/order/chat consumers use the shared manager.
- **Tests / results:** Actual manager lifetime/filter/exception tests plus payment/order/chat source contracts.
- **Measurements:** No measured production channel or WAL rate.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Managed reconnect/token rotation and event delivery require integration tests.

### F13 â€” Overlapping order-controller starts, refreshes and stale enrichment

- **Exact functions/SQL:** RealtimeOrderController.start/_start/fetchOrder/_queryOrder and refresh queue/lifecycle/dispose.
- **Files and modified lines:** [lib/core/services/realtime/realtime_order_controller.dart](../../lib/core/services/realtime/realtime_order_controller.dart#L3) (3, 11, 13â€“25, 53, 62â€“65, 68â€“76, 84, 88, 101â€“102, 109, 114, 132, 177â€“178, 194, 206â€“207, 209, 226, 252â€“273, 281, 297â€“313, 321â€“322, 389, 405â€“426, 433, 477â€“478, 547â€“548, 565, 569â€“575, 578, 587, 591, 598, 600, 611, 624, 633, 640, 646, 648, 655â€“663, 666, 668, 671, 675)
- **Previous behavior / actual root cause:** Repeated starts and live/poll requests overlapped; stale REST/rider/metadata responses overwrote newer events.
- **Implementation / why it fixes the problem:** Share start future, serialize reads with bounded follow-up, reuse pending username/rider fetches, reject stale identity/revision results, pause background enrichment and reconcile on resume.
- **Tests / results:** Actual SDK with controlled HTTP/realtime tests for concurrent starts, reassignment, KYC update, manual refresh and disposal.
- **Measurements:** Two overlapping starts: orders GET sends 2 to 1; eight pending events yield 1 initial order GET, 1 name GET and 2 total live sends.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Fake clocks/transports are not hosted latency measurements.

### F14 â€” Redundant map listener rebuild notifications

- **Exact functions/SQL:** RealtimeOrderController._setRiderLocation.
- **Files and modified lines:** [lib/core/services/realtime/realtime_order_controller.dart](../../lib/core/services/realtime/realtime_order_controller.dart#L3) (3, 11, 13â€“25, 53, 62â€“65, 68â€“76, 84, 88, 101â€“102, 109, 114, 132, 177â€“178, 194, 206â€“207, 209, 226, 252â€“273, 281, 297â€“313, 321â€“322, 389, 405â€“426, 433, 477â€“478, 547â€“548, 565, 569â€“575, 578, 587, 591, 598, 600, 611, 624, 633, 640, 646, 648, 655â€“663, 666, 668, 671, 675)
- **Previous behavior / actual root cause:** Identical latitude/longitude/heading payloads notified listeners repeatedly.
- **Implementation / why it fixes the problem:** Skip identical values while notifying real movement/heading changes immediately.
- **Tests / results:** Actual ValueNotifier regression.
- **Measurements:** Five identical events: 5 notifications to 1.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Notifier count is not rendered FPS.

### F15 â€” Hidden Passenger Home/Activity loading and concurrent refresh

- **Exact functions/SQL:** HomeTab._load and lifecycle/timer handlers; ActivityTab.loadOrders and isActive handlers; passenger navigation.
- **Files and modified lines:** [lib/features/user/activity/activity_tab.dart](../../lib/features/user/activity/activity_tab.dart#L25) (25â€“27, 88â€“90, 122, 125, 143â€“155, 158â€“165, 288â€“290, 328â€“329, 365â€“370, 476â€“477, 483); [lib/features/user/home/home_tab.dart](../../lib/features/user/home/home_tab.dart#L48) (48â€“49, 74â€“81, 91â€“93, 188â€“190, 218, 221, 250, 271â€“272, 275â€“278, 282â€“287, 688â€“690, 705â€“706, 712, 721â€“724, 771, 776, 843â€“848, 918); [lib/main_navigation_screen.dart](../../lib/main_navigation_screen.dart#L1) (1, 4, 30, 33 (deletion boundary), 42â€“43, 45, 70, 73, 75â€“80, 117, 119)
- **Previous behavior / actual root cause:** Passive hidden/background timers and overlapping refresh sources created unnecessary reads/UI work.
- **Implementation / why it fixes the problem:** Gate display timers/debounce by visibility/lifecycle; coalesce concurrent loads; reconcile once on return while retaining required realtime ownership.
- **Tests / results:** Actual Activity lifecycle/fake-clock tests and Home regressions.
- **Measurements:** Hidden Activity over 61 simulated seconds: 0 loads; return: one catch-up.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** No physical request rate or end-to-end reconnect result.

### F16 â€” Rider Home overlapping reads and hidden/background cosmetic refresh

- **Exact functions/SQL:** RiderHomeTab.loadRider/_fetchTodayEarnings/_startSilentRefreshTimer/didChangeAppLifecycleState.
- **Files and modified lines:** [lib/features/rider/home/rider_home_tab.dart](../../lib/features/rider/home/rider_home_tab.dart#L151) (151, 160â€“169, 177â€“178, 225, 230, 240â€“244, 258, 260, 309â€“312, 314, 353â€“354, 356â€“376, 406, 475â€“476, 698, 1634, 1652, 1670, 1688â€“1689, 2263, 2289, 2297â€“2298, 2340, 3221, 3235, 3257, 3267, 3278, 3322, 3331, 3334)
- **Previous behavior / actual root cause:** Repeated refresh callers and earnings reads overlapped; a cosmetic timer ran in background.
- **Implementation / why it fixes the problem:** Share completion and queued reconciliation, deduplicate earnings reads, pause cosmetic display timer; retain assignment listeners, off-tab reconciliation and GPS.
- **Tests / results:** Existing rider Home busy/free, assignment and earnings regression groups.
- **Measurements:** No production request-per-minute number claimed.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Essential notifications remain active; real rider dispatch session unverified.

### F17 â€” Earnings bursts and post-disposal dependent queries

- **Exact functions/SQL:** RiderEarningsTab.fetchData/_drainDataRequests/_fetchDataOnce.
- **Files and modified lines:** [lib/features/rider/earnings/rider_earnings_tab.dart](../../lib/features/rider/earnings/rider_earnings_tab.dart#L26) (26â€“30, 37â€“38, 70â€“71, 151, 162, 167, 187, 192, 201, 209, 213, 226, 262â€“281, 310, 314, 329, 1226)
- **Previous behavior / actual root cause:** Concurrent refresh/withdrawal events launched repeated batches; disposed widgets could continue dependent reads/listener attachment.
- **Implementation / why it fixes the problem:** Coalesce active batch with bounded follow-up, defer hidden display refreshes, check mounted state before dependent reads/listeners.
- **Tests / results:** Actual Earnings widget with controlled HTTP/realtime.
- **Measurements:** Three overlapping refreshes while blocked: 1 rider GET and 1 threshold GET; 0 dependent order reads after disposal.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Financial calculations unchanged; real withdrawals not executed.

### F18 â€” Unread notification body reads and account subscription leaks

- **Exact functions/SQL:** NotificationBadgeService.refresh/_drainRefreshQueue/_refreshOnce/startListening/stopListening.
- **Files and modified lines:** [lib/modules/notifications/services/notification_badge_service.dart](../../lib/modules/notifications/services/notification_badge_service.dart#L20) (20â€“22, 24â€“46, 53, 55, 59â€“66, 77, 106â€“128)
- **Previous behavior / actual root cause:** GET of notification ids transferred rows just to count; account listener id was not retained.
- **Implementation / why it fixes the problem:** Exact HEAD count with same owner/unread filters, refresh coalescing, shared account-scoped channel and explicit teardown.
- **Tests / results:** Actual HEAD request/filters/header/provider fixture plus subscription contracts.
- **Measurements:** No notification row JSON body returned; database count still executes.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** No physical notification delivery claim.

### F19 â€” Late unread count repainted a stopped badge (newly fixed)

- **Exact functions/SQL:** NotificationBadgeService._refreshOnce/startListening/stopListening.
- **Files and modified lines:** [lib/modules/notifications/services/notification_badge_service.dart](../../lib/modules/notifications/services/notification_badge_service.dart#L20) (20â€“22, 24â€“46, 53, 55, 59â€“66, 77, 106â€“128)
- **Previous behavior / actual root cause:** Only Auth identity was checked; stopListening could run before Auth identity disappeared, letting an old count restore cleared UI.
- **Implementation / why it fixes the problem:** Capture refresh generation; advance generation on start/scope change/stop and discard obsolete completions before provider writes. Preserve request coalescing.
- **Tests / results:** New actual deferred-HTTP regression: baseline FAIL expected 0/actual 9; fixed GPS/badge fixture 7 PASS; full Flutter 2065 PASS.
- **Measurements:** Stale post-stop badge writes: 1 to 0 in the reproduced case; not a network-latency benchmark.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** An already sent count request is ignored, not remotely canceled.

### F20 â€” No bounded request-count evidence for app slowness

- **Exact functions/SQL:** ApiMetricsClient.send/requestsLastMinute; main Supabase HTTP wiring.
- **Files and modified lines:** [lib/core/services/diagnostics/api_metrics_client.dart](../../lib/core/services/diagnostics/api_metrics_client.dart#L1) (1â€“43 (added)); [lib/main.dart](../../lib/main.dart#L3) (3â€“4, 28â€“29, 48, 92)
- **Previous behavior / actual root cause:** Total request impressions could not distinguish actual sends or operation bursts.
- **Implementation / why it fixes the problem:** Count actual HTTP sends per known operation in a rolling minute, including failures; prune storage and omit tokens/query values/bodies.
- **Tests / results:** Actual metrics clock/pruning/request tests.
- **Measurements:** Instrumentation only; no invented field request rate.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Socket frames and provider traffic outside the wrapper are not counted.

### F21 â€” Unauthorized admin UI initialization

- **Exact functions/SQL:** AccountGuard._check/build and admin dashboard guarded child.
- **Files and modified lines:** [lib/modules/admin/admin_dashboard_screen.dart](../../lib/modules/admin/admin_dashboard_screen.dart#L1) (1, 8, 10â€“16, 19, 22); [lib/shared/widgets/account_guard.dart](../../lib/shared/widgets/account_guard.dart#L1) (1â€“86 (added))
- **Previous behavior / actual root cause:** Privileged child could initialize before client access decision.
- **Implementation / why it fixes the problem:** Delay protected child creation until allowed role; show existing forbidden/login state otherwise.
- **Tests / results:** Actual ordinary-user widget proves protected child never mounts.
- **Measurements:** Avoids unauthorized child initialization; no latency benchmark.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** UI guard is not server-side authorization; backend security proposals remain separate.

### B01 â€” Non-atomic order acceptance

- **Exact functions/SQL:** accept-order; anonymous DO transaction; createAcceptanceExecutor/acceptOrderAtomically.
- **Files and modified lines:** [supabase/functions/accept-order/acceptance_sql.ts](../../supabase/functions/accept-order/acceptance_sql.ts#L1) (1â€“2 (added)); [supabase/functions/accept-order/atomic_acceptance.ts](../../supabase/functions/accept-order/atomic_acceptance.ts#L1) (1â€“58 (added)); [supabase/functions/accept-order/deno.json](../../supabase/functions/accept-order/deno.json#L1) (1â€“6 (added)); [supabase/functions/accept-order/index.ts](../../supabase/functions/accept-order/index.ts#L5) (5â€“6, 95â€“122, 126â€“133, 135â€“136, 139â€“140)
- **Previous behavior / actual root cause:** Assignment was marked accepted before guarded order claim; two riders could leave accepted assignment rows although loser returned 409.
- **Implementation / why it fixes the problem:** One Edge-bundled PostgreSQL READ COMMITTED transaction locks rider then order, checks Auth-bound actor/eligibility, preserves fare/promo helpers, updates winner/expiry/logs together and awaits COMMIT. Retry reads committed winner without duplicate writes/events.
- **Tests / results:** 16 native PG17 + 4 handler/recovery + 8 Auth/error tests PASS.
- **Measurements:** No latency claim: this fixes correctness under concurrency.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Local implementation; managed endpoint/Auth/Realtime/notification/recovery/drain gates remain. No global new unique index under Edge-only scope.

### B02 â€” Observed connection reset labeled non-retryable (newly fixed)

- **Exact functions/SQL:** accept-order transaction error classification.
- **Files and modified lines:** [supabase/functions/accept-order/index.ts](../../supabase/functions/accept-order/index.ts#L5) (5â€“6, 95â€“122, 126â€“133, 135â€“136, 139â€“140)
- **Previous behavior / actual root cause:** Terminated local database connection produced ECONNRESET, HTTP 500 and retryable=false despite safe idempotent retry support.
- **Implementation / why it fixes the problem:** Classify observed ECONNRESET as retryable 503; do not replay automatically inside the handler or change the transaction.
- **Tests / results:** 8 real SDK/PostgREST/direct-DB network checks and 8 Edge regression groups PASS; actual terminated connection leaves zero accepted rows and fresh retry succeeds.
- **Measurements:** Observed response 500/non-retryable to 503/retryable; not a millisecond improvement.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Local only; other unobserved driver codes not broadened speculatively. Unknown commit outcome remains resolved by idempotent retry.

### B03 â€” Excess nearby-rider/order distance calculations

- **Exact functions/SQL:** public.find_nearby_riders(uuid,double precision,double precision,double precision,integer,uuid[]); public.assign_nearby_searching_orders_core.
- **Files and modified lines:** See staged backend source ledger below.
- **Previous behavior / actual root cause:** Nearby CTE repeated expensive distance expressions and freed-rider matching visited far searching orders before distance rejection.
- **Implementation / why it fixes the problem:** Guarded latitude-band prefilter; MATERIALIZED nearby candidates evaluate distance once; retain exact final distance/order/eligibility/assignment semantics.
- **Tests / results:** Existing native PG17_RESULTS: 8 groups PASS including matching/assignment/GPS regressions; handler race compares original/proposed matching locally.
- **Measurements:** Synthetic 560 riders: median 2.156 to 1.832 ms; 1000 distant searching orders: 1.677 to 0.679 ms. Small fresh-backend cohort regressed 15.588 to 16.573 ms; production gain unproven.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Implemented guarded SQL locally, default ROLLBACK; no production migration/deployment and excluded from Wave A.

### B04 â€” Sequential push reads and concurrent OAuth cache misses

- **Exact functions/SQL:** send-push-notification; getAccessToken/mintAccessToken; preference/token lookup.
- **Files and modified lines:** See staged backend source ledger below.
- **Previous behavior / actual root cause:** Preferences then token lookup were serial; simultaneous expired-cache callers minted multiple OAuth tokens.
- **Implementation / why it fixes the problem:** Prepared staged source adds safe timing observations, OAuth single-flight with failure cleanup and overlapping internal token/preference reads; retain Auth/global/preferences gates, retries and FCM send decisions.
- **Tests / results:** 17 complete-handler mocked Deno tests PASS again; actual crypto/timeout paths exercised, external services mocked.
- **Measurements:** Concurrent cache misses share mint; no measured hosted before/after duration or real delivery. Historical mean 2265.48 ms is a lead, not a matched benchmark.
- **Status:** Local implementation/candidate only; no production deployment or mobile build installation verified.
- **Remaining risk:** Candidate source only, not the production function file. Real delivery destination unavailable; push deployment stays excluded/gated.

## Database/Edge candidates, exact object changes and rollback

| Problem | Exact implementation file | Current lines | Object/table | SQL/code change | Migration/deployment/index status | Recovery reference |
|---|---|---|---|---|---|---|
| B03 | [docs/production-performance/waves/01_find_nearby_riders.sql](../../docs/production-performance/waves/01_find_nearby_riders.sql#L1) | 1â€“157 | find_nearby_riders six-argument overload; riders eligibility/candidate SELECT | Latitude band + MATERIALIZED distance candidates | Local candidate only; NOT executed/deployed; no index change | 01_find_nearby_riders.rollback.sql |
| B03 | [docs/production-performance/waves/02_assign_nearby_searching_orders_core.sql](../../docs/production-performance/waves/02_assign_nearby_searching_orders_core.sql#L1) | 1â€“308 | assign_nearby_searching_orders_core; orders/rider_assignments/order_assignment_logs | Latitude-band filtering before exact distance; original matching/write rules retained | Local candidate only; NOT executed/deployed; no index change | 02_assign_nearby_searching_orders_core.rollback.sql |
| B04 | [docs/production-performance/waves/05_compat.index.ts](../../docs/production-performance/waves/05_compat.index.ts#L1) | 1â€“418 | send-push-notification compatibility stage | Type compatibility only; no claimed latency gain | Local candidate only; NOT executed/deployed; no index change | Captured v24 source; hosted rollback still unverified |
| B04 | [docs/production-performance/waves/05_push_timing.index.ts](../../docs/production-performance/waves/05_push_timing.index.ts#L1) | 1â€“430 | send-push-notification timing stage | Phase duration observation without secrets/user payloads | Local candidate only; NOT executed/deployed; no index change | Captured v24 source; isolated hosted rehearsal required |
| B04 | [docs/production-performance/waves/06_push_oauth.index.ts](../../docs/production-performance/waves/06_push_oauth.index.ts#L1) | 1â€“446 | send-push-notification OAuth stage | Single-flight cache refresh/failure cleanup | Local candidate only; NOT executed/deployed; no index change | Pre-change source or verified earlier stage |
| B04 | [docs/production-performance/waves/07_push_prefetch.index.ts](../../docs/production-performance/waves/07_push_prefetch.index.ts#L1) | 1â€“451 | send-push-notification prefetch stage | Overlap internal token/preferences reads; retain gating before send | Local candidate only; NOT executed/deployed; no index change | Verified earlier stage |

B01/B02 run an anonymous DO block inside an ordinary database transaction. They add **no persistent SQL function, table, index, trigger, grant or RLS policy**. Tables touched only by future authorized acceptance requests: orders, rider_assignments and order_assignment_logs; existing triggers may enqueue normal notification effects. Canonical calculate_fare_breakdown and eligibility helpers are preserved. No backfill/repair is included. **New migration filename: none required for Edge-only Wave A.** Earlier claim_order_assignment_atomic SQL/index drafts under docs/production-performance/acceptance are superseded and must not be applied for this wave.

B03 implementations are guarded source files ending ROLLBACK, outside automatic migrations; they are actual locally executable replacements tested against sanitized PG17, not production deployments. No new index is required. Promote to a separately reviewed migration only after managed equivalence/performance/recovery gates and exact approval; do not copy them blindly into an automatic deployment. B04 is explicitly staged under docs, not substituted into the live send-push-notification source before real delivery verification.

Existing indexes are retained: primary/ownership indexes, notifications(user_id,is_read), and current GPS/freshness/location indexes. Proposed removal of idx_riders_user_id and idx_riders_kyc_id is deferred despite duplicate identity-key coverage because the equal-work local experiment did not establish useful latency/WAL benefit. Optional orders(rider_id) partial proximity index is unproven and excluded. No publication/replica-identity changes were made.

### B05 â€” GPS database write amplification/index proposals (not counted as fixed)

- **Object/root cause:** riders -> bridge trigger -> rider_locations -> proximity check. Duplicate identity indexes cost maintenance, but measured local index removal did not improve heartbeat latency/WAL.
- **Action/status:** Keep indexes and tracking/proximity behavior unchanged; guarded removal drafts are not selected for release.
- **Measurements/tests/risk:** No demonstrated benefit: median 5.165 to 5.358 ms; median WAL 135 to 135 bytes in the recorded synthetic sample.

### B06 â€” Config origin latency not explained by SQL (not counted as fixed)

- **Object/root cause:** production_config API vs SELECT/RLS/gateway. Historical bounded sample mean origin 684.5 ms; single-row SQL execution 2.622 ms and 744-byte JSON. These are not a matched per-request subtraction.
- **Action/status:** No speculative index/cache/Edge endpoint change; retain existing Flutter coalescing and maintenance gates.
- **Measurements/tests/risk:** Exact gateway/queue/cold/request-start contribution still unknown.

### B07 â€” RLS repeated admin helper cost (not counted as fixed)

- **Object/root cause:** Four SELECT policies using public.is_admin(). Bare stable helper may execute repeatedly, but current material cost and complete audience equivalence are unproven.
- **Action/status:** Local proposal 04_admin_rls_initplan.sql only; no active policy rewritten.
- **Measurements/tests/risk:** Requires real authenticated positive/negative plan/equivalence testing; excluded from Wave A.

### B08 â€” Inherited legacy nearby-RPC overload removal migration (not counted as fixed)

- **Object/root cause:** find_nearby_riders five-argument overload; six-argument grant. Existing local migration proposes removing the legacy overload; current Flutter callers already provide explicit exclusions.
- **Action/status:** Retain as an inherited unexecuted draft, not as an approved performance fix; do not run blanket db push.
- **Measurements/tests/risk:** Current production necessity/dependency/consumer proof is insufficient for this release; no drop/grant executed.

## Verified measurements and limits

| Scenario | Before | After | Evidence/scope |
|---|---:|---:|---|
| Two concurrent tracking starts: orders GET sends | 2 | 1 | Saved-source baseline / actual controller with mocked HTTP |
| Five identical GPS events: location notifier updates | 5 | 1 | Actual notifier, synthetic events |
| Two hidden simulated frames: ticker callbacks | 2 | 0 | Actual widget ticker, simulated frames |
| Badge response after stop: stale provider writes | 1 (badge becomes 9) | 0 (badge stays 0) | Newly reproduced actual deferred HTTP/provider fixture |
| Actual interrupted database connection response | 500 / retryable=false | 503 / retryable=true | Real local postgres.js connection termination, no partial accepted rows; fresh retry succeeds |
| Nearby matching, 560 synthetic riders, median | 2.156 ms | 1.832 ms | PG17 scale/mechanism check, 12 measured calls / 3 warmups |
| Core matching, 1000 distant searching orders, median | 1.677 ms | 0.679 ms | Same synthetic scale check |
| Nearby small cohort/fresh backends, median | 15.588 ms | 16.573 ms | No gain established; do not extrapolate scale result |
| GPS duplicate-index removal, median / WAL | 5.165 ms / 135 bytes | 5.358 ms / 135 bytes | No gain established; index removal deferred |
| Physical cold/warm startup, first usable, API/GPS writes per minute, frame timings | Unmeasured | Unmeasured | No attached Android device in existing verified inventory |

Source-count claims (startup 5 to 2 blocking passenger reads, removed 500 ms splash floor, two potential heartbeat geocodes/minute) describe code paths/policy, not measured app wall-clock performance. Historical config mean 684.5 ms and push mean 2265.48 ms are audit leads, not current post-change timings.

Measurement artifacts: [Flutter controlled counts](../flutter-phase1/MEASUREMENTS.json), [native scale samples](../production-performance/local-tests/SCALED_PERFORMANCE.json), [small-cohort and GPS samples](../production-performance/local-tests/LOCAL_PERFORMANCE_RECOVERY.json). No expensive production benchmark or real financial transaction was run.

## Current verification and raw evidence

- Full Flutter: flutter test --no-pub --reporter expanded, **2065 PASS / 0 FAIL**; [raw local log](../../.dart_tool/waydrop-local-runtime/completion-flutter-full.log).
- New badge baseline: **expected failure**, 0 expected / 9 actual; [baseline](../../.dart_tool/waydrop-local-runtime/badge-stop-baseline.log). Corrected GPS/badge fixture: **7 PASS** (included in full suite); [fixed](../../.dart_tool/waydrop-local-runtime/badge-stop-fixed.log).
- PG17 atomic transactions: **16 PASS**, handler/recovery: **4 PASS**; [native](../../.dart_tool/waydrop-local-runtime/completion-native.log), [handler](../../.dart_tool/waydrop-local-runtime/completion-handler.log).
- Edge Auth/flags/errors: **8 PASS**, real SDK/PostgREST/direct DB: **8 PASS**; [unit](../../.dart_tool/waydrop-local-runtime/completion-edge-unit.log), [network](../../.dart_tool/waydrop-local-runtime/completion-network.log). Native Auth boundary in the network test is synthetic, not managed GoTrue.
- Full push handler mocks: **17 PASS**; [log](../../.dart_tool/waydrop-local-runtime/completion-push.log). Real delivery remains unavailable.
- Analyzer: flutter analyze wrapper stalled before output and was interrupted; installed Dart SDK analyze lib test completed with **0 errors, 73 warnings, 382 infos**, exit 2 for existing diagnostics. [Analyzer log](../../.dart_tool/waydrop-local-runtime/completion-analyze.log). No diagnostic names the changed badge service/test. No ignore rules or disabled tests added.
- Frozen Deno root candidate check PASS; updated deployment/recovery payload hash verifier PASS. No additional pub get was needed: package dependencies were unchanged this pass; previous verified pub get is retained.
- Earlier unchanged-code evidence retained separately: local TLS **3 PASS**, drain counter assertions **2 PASS**, PG17 matching/GPS **8 groups PASS**, offline Node **58 PASS**. These are not added to the current-run total. Most legacy Flutter regressions are source contracts; device/provider/managed integrations remain unverified.

## Production deployment and recovery boundary

Only the minimal atomic accept-order Edge candidate, now including the verified ECONNRESET response mapping, is prepared for Wave A. Exact revised files/hashes and commands: [release manifest](../production-performance/edge-only/RELEASE_MANIFEST.json), [deploy request](../production-performance/edge-only/DEPLOY_REQUEST.json), [exact Codex deployment call](../production-performance/edge-only/DEPLOY_REQUEST.codex.js), [emergency recovery call](../production-performance/edge-only/RECOVER_FAIL_CLOSED_REQUEST.codex.js). **Not executed.** Matching/push/GPS indexes/RLS/config/legacy overload changes are excluded. Do not run blanket migrations/db push. Any final GO must reference the revised manifest, not the prior acceptance payload.

The current [release checklist](../production-performance/edge-only/WAVE_A_PREFLIGHT.md) defines isolated managed Auth/Realtime/transactional notification tests, hosted candidate-to-503-to-candidate recovery rehearsal and the temporary 503 / confirmed v60 admission cutoff / bounded worker lifetime / zero old transactions and write locks procedure. Available connections expose only production, zero development branches and no browser/dashboard surface. No synthetic production accounts/data were created.

Rollback is availability-safe fail-closed accept-order (retryable 503, no DB access), followed by redeployment of a verified corrected candidate after drain. Captured v60 reconstructs/typechecks with identical emitted JavaScript, but retains the race and must never resume active acceptance traffic. An Edge rollback does not undo committed orders; no automatic data repair is approved. Database matching proposal recovery files restore captured definitions only after separate approval; none was needed/executed in production.

**Production execution ledger:** zero executions; execution time/production before-after/verification-after-deploy = not applicable. Production accept-order version last observed: **60**, source SHA256 **521fd8533d8a6d0fde15ccf9ceb211a8c631e3822f82c7f324b9e629736c9dfc**. Push version last captured: **24**, unchanged by this work. No production deployment is inferred from local source edits.

## Unresolved work and next required involvement

1. Existing isolated managed project + authorized synthetic accounts/safe notification sink; valid Auth/refresh/logout semantics, cross-user isolation, Realtime/reconnect, direct DB endpoint/TLS/role/connection budget and transactional notification effects. Local mocks/certificates do not prove these.
2. Hosted emergency recovery propagation and demonstrable v60 routing cutoff/drain; dashboard/operator evidence required. Do not create a paid environment or deploy production to obtain it.
3. Real-device Android profile cold/warm startup, first usable content, request deltas, GPS writes/minute and DevTools frame traces. Existing command: flutter run --profile -d <device-id> --dart-define-from-file=<approved-env-file>; compare at least ten process-cold launches and ten warm resumes under matched conditions. Provider/payment/KYC/FCM device journeys remain unverified.
4. Config latency attribution, small-cohort matching benefit, GPS/index experiment, RLS helper cost and legacy overload deployment necessity remain open B05â€“B08. Separate backend security proposals exist but are neither deployed nor silently included in performance Wave A.

Preserved UI layouts, payment/earnings/fare/promo calculations and dispatch eligibility were not redesigned or changed by the new fixes. Green local regression tests do not certify complete production readiness or prove all perceived slowness eliminated.

## November 3 — Choose Route / Select a Ride follow-up

User confirmed Build61 for 09:54–10:04 IST. [Detailed evidence and local changes](WAYDROP_CHOOSE_ROUTE_LOADING_FIX.md): calculate-order-pricing p95 **16,106 ms**, maximum **18,631 ms**; slow pricing_config/pricing_zones origin responses at **10:01:49 IST**. This is upstream API latency evidence, not raw SQL execution or proven CPU/I/O attribution.

Reproduced Flutter defects: all-vehicle publication barrier and skeletons persisting after terminal pricing failure. Corrected locally with opt-in progressive quote publication, current-route/account booking guards, explicit Retry states, route/geocode generation checks, exact overlapping directions coalescing, controller disposal and promo ownership. Removed 150 ms pre-pricing delay and map-paint prerequisite. Pricing/GST formulas, payment modes and dispatch remain unchanged. Controlled mocked-HTTP first Auto publication: **710 → 108 ms**, three requests in both cases; not an Android/production UI benchmark.

This task changed no production service or database object. Installed Build61 does not contain these source edits. Backend resource onset remains unresolved; broader SQL/Edge release restrictions and real-device validation gates remain unchanged. Final tests and exact source locations are recorded in the detailed report.

### Build62 — package corrections and remove prefilled-map wait

[Build62 follow-up](WAYDROP_BUILD62_SPEED_FIXES.md): reproduced an additional prefilled-coordinate path that waited for WebView page-finished before requesting directions/pricing. Start now runs independently; late map events only render existing geometry. Before regression:0 directions requests without map event; after:1 directions +3 vehicle pricing calls, with zero additional calls after two late map events. This is causal request-order evidence, not a measured Android duration.

User-supplied schema (61 tables/97 foreign keys) was reviewed as context and never executed. The export omits index/trigger/RLS definitions; lightweight read-only catalog counts confirm relevant production indexes already exist. Snapshot at10:54:15 IST:18 clients including inspection,0 other active clients,0 blocked sessions; not incident-onset evidence.

**Verified test APK** [waydrop-1.0.0-build62.apk](../../artifacts/waydrop-1.0.0-build62.apk), SHA256 `843ba7b998487aabb7a20ba57afb2b8b171305f9922c2e3604ebd287c81773f3`. Same signer as61, all three AOT libraries changed, source freeze unchanged. Full suite **2,233 passed / 10 existing live skips / 0 failed**; focused **30 passed**; analyzer **0 errors / 1 warning / 17 infos**. Not installed/published; actual phone speed remains unmeasured. Production SQL/Edge/config/cron unchanged; existing release/security gates remain open.

## Production authorization received — execution still incomplete

**Latest Supabase execution update:** [actual applied status](WAYDROP_SUPABASE_APPLIED_STATUS.md): pricing76/live-status55 remain live; four-SELECT-policy optimization applied as migration `20261103162805`, and legacy-compatible photo ownership/body-deadline fix deployed as photo19. Exact policy/source checks, local native/handler tests and bounded live denial/quote probes pass. No new Supabase project, AAB publication or admin rollout. Coordinated acceptance/dispatch/push/atomic-photo/Chat protocols remain unapplied; full combined rollout is not complete.

**Later app-only execution update:** [Waydrop app production rollout](WAYDROP_APP_PRODUCTION_ROLLOUT.md) now supersedes this earlier zero-deployment checkpoint for exactly two functions: pricing75→76 and live-status54→55 are ACTIVE, source/settings verified, public quote unchanged,31fresh local tests plus hosted5/5pre and5/5post checks pass. No SQL/cron/policy/admin changes; coordinated protocols remain blocked. Full rollout is still incomplete; Build62 must be installed separately for its Flutter changes.

[Current rollout ledger](WAYDROP_PRODUCTION_ROLLOUT_2026_11_03.md): user authorized completed work for production. No renewed approval requested. Admin Dashboard/Revenue error fan-out correction implemented in the confirmed sibling project; baseline14fail/7pass reproduction, final58admin tests pass, Vite production build and95-file ZIP verified. [Candidate ZIP](../../artifacts/waydrop-admin-20261103-production-candidate.zip). Hosting target and app distribution channel are missing; existing managed Auth/full-trigger/provider tests and old-writer drain gates remain unmet. No site publication, Edge deployment, migration, policy/cron/config change or production data write executed in this request. Production versions rechecked: pricing75, live-status54, acceptance60, push24. Full rollout must not be reported complete.
