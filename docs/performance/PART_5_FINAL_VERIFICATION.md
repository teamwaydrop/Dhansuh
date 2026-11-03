# Part 5 — Final verification and deployment assessment

Project `yvwpchffctiagevpqgwy`. Original incident: **2026-11-01 16:22–16:34 UTC**, especially 16:32. Parts 1–4 and the consolidated report were read first. **No production writes, deployments, migrations, cron/configuration edits, paid upgrades or user-data changes occurred. Zero new log queries.** This completes the local final phase; it does not authorize deployment.

## Decision and answers

| Question | Evidence-based answer |
| --- | --- |
| Actual defects across the five parts? | Uncancelled chat replay and queue loss, repeated Home/unread reads, SDK/manager reconnect races, unsafe incomplete GPS diffs, duplicate dispatch audit errors, unrecoverable worker flags, empty matching sweeps, unused rejection reads, history/outbox display loss and reconnect gaps, failed-count retry amplification, push cleanup/status/partial-success defects, and sender/support INSERT authorization gaps. Part 5 additionally verifies a rejection/acceptance race and an anonymously executable internal dispatch RPC. These are distinct from the still-unproven initiating database cause. |
| Which have local fixes? | The preceding reports document the preserved client fixes, Part 3 audit/empty-sweep/dead-read candidates and Part 4 push/RLS candidates. New here: rejection compare-and-set, restricted internal-dispatch EXECUTE candidate, CRLF-portable test readers and opt-in sanitized device capture. Nothing was applied to production. |
| All sixteen broad-suite failures addressed? | **Yes: all sixteen reproduced and classified as deterministic CRLF-sensitive fixtures.** Five reader changes retain every original assertion. Targeted **105 pass/16 fail → 121 pass/0 fail**. Exact names, original errors and comparison with the Part 4 failures are in [VERIFICATION.json](final-verification-20261102/VERIFICATION.json). |
| Stale-worker recovery safe? | **No. BLOCKED FOR DEPLOYMENT.** Exact-token release is safe in the tested race; later offer and dispatch-state writes are not fenced by that token. A native counterexample reopens an accepted offer while the replacement lease remains valid. |
| Chat RLS and FCM fixes complete? | **No, as an end-to-end claim.** Local INSERT policies pass participant/agent/foreign-user tests and additional anonymous-role denial. Push cleanup, authorization and partial successes pass. Concurrent delivery and acceptance/status-write ambiguity remain reproducible; durable recovery and managed JWT/RLS/device validation remain open. |
| Measured improvements? | Controlled counts and synthetic scale results below; **no device or post-deployment latency gain measured**. |
| November 1 initiating cause proven? | **No.** Timeouts, pool pressure and amplifiers are established; incident CPU/memory/I/O/wait evidence remains inaccessible. |
| Exact production changes? | Reviewable file/function inventory, ordering, exclusions and rollback gates are in [WAYDROP_PRODUCTION_DEPLOYMENT_CHECKLIST.md](WAYDROP_PRODUCTION_DEPLOYMENT_CHECKLIST.md). **No blanket migration or whole-working-tree release is approved.** |
| What blocks GO? | Unfenced dispatch writers, eligibility parity, push claims/recovery, managed Auth/RLS/async tests, acceptance admission/drain rehearsal, Android measurements and release-scope freeze. Existing analyzer warnings remain visible. |

| Release category | Assessment now |
| --- | --- |
| Flutter reviewed fix subset | **CONDITIONAL GO** for release preparation: local suite is green. Device/profile, managed session/KYC/tracking/chat checks and an exact manifest are required before shipping. This is not approval of every unrelated dirty-tree change. |
| SQL migrations as a combined bundle | **NO-GO**. Stale recovery/cross-writer matching remains unsafe. INSERT policies and the new internal-RPC ACL are separately testable security candidates, pending managed role/compatibility tests and individual approval. Index/publication changes remain deferred. |
| Edge Functions as a combined bundle | **NO-GO**. `start-dispatch` is unfenced and push has no durable claim/recovery. Isolated atomic acceptance and targeted rejection/push safety corrections are conditional candidates after their managed/drain gates; passing local tests is not production readiness. |

## Sixteen failures: classification and correction

The unmodified-reader run reproduces **the same sixteen exact test names** as Part 4. In five files, LF-only multiline assertions run against CRLF source. Method-end searches for `\n  }\n` also fail, causing fallback slices to omit the sound/guard code. The real implementation contains the required behavior. Part 5 snapshots show those Home/Orders implementations unchanged. Normalizing only `\r\n` to `\n` makes all original assertions pass.

| Test file | Original failures | Exact failure surface / independent check |
| --- | ---: | --- |
| `incoming_order_minimize_and_intercity_accept_regression_test.dart:38` | 3 | Busy guard precedes sound, sound/haptic/announced state, and multi-offer reconciliation. First error: expected sound position greater than 648, actual -1; subsequent expected true/actual false. Full methods at Rider Home `954–994` and reconciliation `564` retain the guards/calls. |
| `production_control_system_regression_test.dart:23` | 1 | Serviceability early return: expected true/actual false for a multiline literal. Passenger Home `1560/1600` still returns before booking. |
| `rider_orders_screen_duplicate_active_order_work_suppressed_regression_test.dart:37` | 6 | Subscription body, initial poll, covered-screen callback gate, busy location poll, order-event gate and rider-status read. Expected true/actual false because multiline/end delimiters missed. Current Orders retains all predicates and subscription setup. |
| `ride_b_missed_after_ride_a_completion_regression_test.dart:67` | 3 | First-poll flag ordering, in-flight/queued guard and assignment projection. Expected true/actual false for LF literals; current source retains the exact statements in the expected order. |
| `subscription_trial_banner_and_vehicle_selection_regression_test.dart:42` | 3 | Subscription entitlement expression, unverified-vehicle label and verified plan subset. Expected true/actual false for multiline literals; entitlement/vehicle predicates remain at Rider Home `1308/1900/2072`. |

**All sixteen: outdated platform-sensitive fixture, deterministic, not flaky, not a newly found app defect.** No test was deleted, skipped or assertion weakened. [Machine evidence](final-verification-20261102/VERIFICATION.json) retains every full group/test name and original stack/error. An older retained 2,065-pass log exists, but there is no complete source-matched pre-Part-4 baseline to date when each fixture became sensitive. It is not silently treated as this baseline. The current before/after is controlled against a preserved Part 5 source snapshot.

## New actual fixes and safety counterexamples

### Rejection can race acceptance — fixed locally

`supabase/functions/reject-order/index.ts:218/298` previously validated an assignment snapshot, then updated by ID alone. An acceptance between those operations could turn sent/expired into accepted; the subsequent rejection overwrote it. The already-rejected branch could also apply stale cooldown timestamps after acceptance or a fresh re-offer.

Both PATCHes now match **ID + the observed status**, return only the ID, and inspect the returned row. No match returns **409 before any audit write** (`246/327`). This is one conditional PATCH with a returned representation, not an additional SELECT round trip. Existing rider ownership, order validation, four-minute cooldown, recovery ownership and Part 3 unused-read removal remain.

[Actual handler race probes](final-verification-20261102/reject_race_test.ts): **pre-Part-5 source 1 pass/4 expected failures; candidate 5/5 pass**. The retained three Part 3 handler checks also pass. Its HTTP mock now supplies the returned update ID, matching the new representation rather than fabricating a successful empty PATCH. A real PostgreSQL accept transaction holds the assignment lock, commits accepted, then the waiting conditional rejection rechecks and changes **zero** rows. This does not fence other dispatch writers or certify the missing-assignment rejection branch under every managed race.

### Anonymous internal matching RPC — local ACL candidate

Current read-only privileges admit both `anon` and `authenticated` to SECURITY DEFINER `assign_new_order_to_nearby_online_riders_core(uuid)`. [Captured body](final-verification-20261102/new_order_core.production.sql) selects a supplied order and loops riders without `auth.uid()` ownership validation. The inner rider core itself is service-only, but this outer function can invoke it with its definer privileges. An outsider can trigger matching work for a known searching order, even without table access. No incident exploitation is inferred.

[INTERNAL_DISPATCH_ACL.candidate.sql](final-verification-20261102/INTERNAL_DISPATCH_ACL.candidate.sql:3) revokes EXECUTE from PUBLIC/anon/authenticated and explicitly retains service_role. Existing new-order trigger pg_net calls use the service role; no Flutter direct caller was found. Native tests execute the captured body as anon before the candidate, deny both untrusted roles after it, and retain service-role execution. **Candidate only; production ACL unchanged.** Managed consumer validation and exact pre-change ACL capture are required before applying or preparing rollback.

### Resumed owners, eligibility and enqueue coalescing — not fixed or approved

[SAFETY_RESULTS.json](final-verification-20261102/SAFETY_RESULTS.json) records **10 diagnostic assertions**, including four intentionally reproduced unsafe/amplifying behaviors. These are not ten claims of production safety.

- Worker lease acquisition/replacement uses a timestamp CAS, and old release changes **0 rows**. But `start-dispatch/index.ts:560` updates dispatch state by order ID, and **652** blindly upserts offers. Native equivalents of these exact predicates overwrite a newer state, change accepted→sent and clear `accepted_at` while retaining the replacement lease. Captured table constraints/triggers do not prevent this fixture counterexample. It is not a complete hosted Edge-process rehearsal; it is sufficient to reject the assumption that release fencing protects writes.
- The captured rider core checks tax/COD, mode/vehicle and search age but does not independently recheck online status. A service call after setting the fixture rider offline still creates **one** sent offer. Caller filters help but do not make every subsequent writer equivalent. KYC/freshness/active-trip eligibility must be reconciled centrally, without silently changing existing permissive business rules.
- Two recovery selections before an async worker claims its flag enqueue the same order **twice** in the native queue capture. Advisory transaction locks do not cover queue/worker lifetime. Disabling fallbacks is not a fix; require durable per-order enqueue coalescing plus crash recovery.
- Atomic acceptance tests retain one winner, one synthetic acceptance event, idempotency, financial rollback and actor/tax/COD/service checks **within that transaction**. They do not make unfenced later offer writers safe or prove payment-provider exactly-once behavior.

**Do not deploy automatic stale-true/NULL recovery as a complete safety fix.** A correct replacement needs server-side lease fencing on every write, shared order/offer locking and eligibility checks across writers, defined lock order, and crash/timeout/replay tests. A JS preflight read or an extra expiry predicate alone cannot close the check/write race.

## Push, chat and API reliability handoff

Part 4 was rerun: full push handler **16 pass**, native chat/policy tests **14 pass**, plus new anonymous RLS denial. Structured UNREGISTERED cleanup still matches registration version and recipient; unrelated 404/410 or payload errors do not remove tokens. Partial device success remains sent. Stable UUIDs, ordering/merge, offline persistence and disposal/reconnect regressions pass in the full Flutter suite.

Remaining issues are explicit:

- **Concurrent push replay still sends twice**; provider acceptance followed by a failed status write remains ambiguous. Sequential `push_sent` suppression is not an atomic claim. No durable per-notification/per-device claim, retry ledger or crash recovery was introduced.
- Ordinary enqueue or notification INSERT exceptions can leave committed chat/inbox with missing downstream delivery. Failure capture is best-effort; no pg_net response reconciliation consumer was proven. Re-inserting chat to repair delivery would be wrong.
- Edge provider fetches have bounded aborts; Chat text retries have bounded backoff and account serialization. Supabase read requests can still remain pending without native cancellation or bounded loading UX. Chat full-history reads, offset inbox pagination, notification-tap account transitions, attachment/auto-info idempotency and complete UPDATE/DELETE authorization remain open. INSERT policy tests are not a complete chat authorization certification.
- Full-suite payment/KYC/auth coverage includes many source contracts and mocks. No managed OTP, payment-provider charge, real KYC submission, FCM handset delivery or live Realtime recovery was performed.

## Targeted database findings, not another incident attribution

[Read-only evidence](final-verification-20261102/READ_ONLY_EVIDENCE.json) contains five small SQL inspections: current health, eight retained spill statements, five function privileges, one unread-count EXPLAIN and the internal matching body. Project metadata was read once. No production EXPLAIN ANALYZE, table scan benchmark, stats reset or log query was used.

- Database cumulative counters at **2026-11-02 09:14:16.698469 IST**: `temp_files=373285`, `temp_bytes=1528766901753`; database stats reset is **May 1**, while statement stats have the separate May 7 reset documented in Part 1. This is historical aggregate temp traffic, not November 1 spill timing or current disk occupancy. Read/write timing counters are zero and cannot supply latency evidence.
- **Seven of eight** top retained temp-block writers are dashboard/catalog/statistics introspection shapes. One is an application PostgREST intercity request join, **18 historical calls / mean 500.766 ms / max 4423.782 ms / 13148 temp blocks written**. Queries/comments were sanitized before persistence. Do not attribute the full database temp-byte total to those retained entries or claim an introspection query initiated this incident. Eviction/reset/time attribution and concurrent resource samples are missing.
- Current estimates: orders **258 dead / 1205 live**, assignments **205 / 1013**, notifications **257 / 5690**. Last autovacuum timestamps are old for some tables; these are estimates and thresholds, not a bloat or autovacuum-failure diagnosis. No VACUUM, ANALYZE or maintenance settings were changed. Review settings and interval deltas if growth continues.
- Unread-count [EXPLAIN without ANALYZE](final-verification-20261102/UNREAD_PLAN.json) selects an existing user-ID index with estimated total cost **2.51**, for a synthetic nonexistent UUID under the inspection role. It is not an authenticated-RLS/real-user runtime plan and does not explain incident p95. No speculative unread index was added.
- GPS/Realtime architecture and all publications/identities remain as in Part 2. HOT and duplicate-index experiments did not establish safe removal benefit. Matching bounding proposals retain their existing scale evidence and drift/eligibility gates; no new function/index rewrite was justified here.

Application leads retained from earlier captures include nearby matching **228.459 ms mean / 12,089.528 ms max**, GPS-shaped SQL **~79.5 ms mean**, and unread counts **~97 ms mean**. Realtime `list_changes` is Supabase-managed work; catalog/function discovery and dashboard statistics are administrative work. These are cumulative samples with different populations, not an incident ranking. Saved matching plans/scale tests and the new unread plan support targeted access paths, not a reason to remove security checks or add speculative indexes.

**Initiating cause still unproven.** The connector has no historical host-metrics tool, and browser inventory returned **zero apps/browsers**, so there was no authenticated chart surface. Current project metadata exposes region/version/healthy status, not incident compute size. Missing: incident CPU saturation/throttle, available RAM/swap/page pressure, disk IOPS/throughput/latency/queue, active/waiting connection history, wait/lock chains, compute tier and sample interval. A current snapshot of one active inspection plus idle/extension sessions cannot reconstruct the incident. Operator export of **16:20–16:36 UTC** remains required. [Supabase Reports documentation](https://supabase.com/docs/guides/observability/reports) confirms time-filtered charts; no retention upgrade was purchased and no chart values were fabricated.

## Measured benefits and limits across parts

| Controlled scenario | Before → local candidate | Scope |
| --- | --- | --- |
| Original sixteen fixtures | 105 pass/16 fail → **121 pass/0 fail** | Same source behavior; newline portability, not app speed |
| Concurrent tracking starts | **2 → 1 GET** | Existing controller/mock HTTP measurement |
| Duplicate GPS notifier events | **5 → 1 notifier updates** | Existing synthetic event fixture; not GPS accuracy |
| Badge write arriving after stop | **1 → 0 stale writes** | Existing deferred HTTP/provider test |
| Valid dispatch re-offers | **6 → 0 audit exceptions** | Native controlled replay |
| Empty freed-rider sweeps | **3 → 0 core calls** | Native controlled calls; fallback retained |
| Ordinary rejection | **2 → 1 assignment SELECTs** | Part 3; new conditional PATCH adds no SELECT |
| Stale rejection after concurrent accept/re-offer | Unconditional mutation/audit → **409, 0 stale writes/audits** | Four actual-handler probes; native lock-wait predicate check |
| Arbitrary FCM404 cleanup / pre-auth failure status writes | **1 → 0 / 1 → 0** | Part 4 actual-handler mocks |
| Sequential successful push replay | **2 → 1 provider sends** | Concurrent replay remains unsafe |
| Matching 560-rider cohort / 1000 distant searches | Median **2.156→1.832 ms / 1.677→0.679 ms** | Earlier PG17 scale test, not new production/device timing; small-cohort gain unproven |
| GPS duplicate-index removal experiment | **5.165→5.358 ms**, no WAL gain | No benefit established; removal deferred |

Earlier measurements retain their original artifacts and test populations; they are not recast as new production results. No Passenger/Rider first-usable time, API device p50/p95, complete frame/jank profile or post-deployment latency was obtained. Android inventory lists Windows/Chrome/Edge only. The [deployment checklist's Android procedure](WAYDROP_PRODUCTION_DEPLOYMENT_CHECKLIST.md#android-profile-procedure) supplies exact commands and safe capture steps.

## Final verification matrix

| Suite | Final outcome | Limit |
| --- | --- | --- |
| Complete Flutter | **2,118 pass / 0 fail** | Includes payment, KYC, authorization, GPS, Realtime, chat, lifecycle and 3 new export/privacy/chunk checks; many are contracts/mocks |
| Sixteen-failure target files | **121 pass / 0 fail** | Same assertions, normalized readers |
| Dart analyzer `lib test` | **0 errors / 73 warnings / 384 infos**, exit 2 | Existing diagnostics retained, not a clean analyzer exit |
| Native matching/GPS | **8 groups pass** | Synthetic PostgreSQL/pg_net capture |
| Native dispatch | **5 groups pass** | Does not prove resumed-owner safety |
| Native atomic acceptance | **16 pass** | Actual local executor, emulated managed boundaries |
| Actual acceptance handler/recovery | **4 pass** | Auth/PostgREST boundary mocked, local transaction real |
| Worker/audit source blocks | **5 pass** | PostgREST model plus independent native CAS |
| Rejection handlers | **8 pass** | 3 retained + 5 new race probes |
| Push handler | **16 pass** | Includes two documented remaining replay/ambiguity cases |
| Edge authorization/flags | **8 pass** | Transport/executor mocks |
| Chat RLS/trigger chain | **14 pass**, plus new anonymous denial | Managed JWT/Realtime/FCM absent |
| Adversarial diagnostics | **10 assertions hold** | **4 expose defects/unsafe behavior**, not safety passes |
| Existing acceptance/recovery manifest checks | **Pass** | Five frozen release files/three request hashes; no deployment |

[VERIFICATION.json](final-verification-20261102/VERIFICATION.json) contains raw-log paths, exact errors, final counters, phase-specific source hashes and preserved-source comparisons. Initial harness failures were missing Deno local-read/write permissions, selecting the real SDK instead of the intended Auth mock (401), and an ambiguous test SELECT column; corrected and rerun, not hidden. Analyzer attempts concurrent with full compilation crashed with a closed pipe; the serial direct-SDK run completed. No suppressions or skipped tests were added.

Part 5 source edits: the five reader helpers, `reject-order/index.ts`, its existing HTTP response mock, `performance_trace.dart`, and the new export tests. Device export is opt-in with `WAYDROP_PERF_EXPORT=true`, disabled in release, emits allowlisted labels/numbers, chunks log lines and drains batches to prevent double-counting. It adds no Supabase requests. Bounded buffers can lose samples during stalls; complete jank/first-usable evidence still requires device traces/video. Earlier working-tree code was snapshotted and preserved; the exact prior-part fixes were not rewritten.

**Production execution ledger: zero. Local final verification is complete; the combined production bundle remains NO-GO.**
