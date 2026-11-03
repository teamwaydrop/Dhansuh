# Waydrop Phase 1 — Flutter performance completion report

Date: 1 November 2026 (Asia/Calcutta). Scope: Flutter only, continuing the modified project. No Supabase provisioning, remote SQL, database/Edge Function changes, backend configuration changes or charges. Every existing supabase/ file was checked against the Phase 1-start hash manifest and remains unchanged. Phase 2 has not started.

## Result

The remaining verified Flutter performance defects are fixed. The final complete offline selection passes **2,054 tests**, including **16 new behavioral tests**. Analyzer: **0 errors, 73 existing warnings, 382 existing information diagnostics; zero new findings**. flutter pub get succeeds, with no package version changes. git diff --check passes. Physical-device performance remains unmeasured because adb lists no attached Android device.

## Problems fixed in this pass

| Area | Exact implementation | Evidence |
|---|---|---|
| Hidden-tab animation work | LazyIndexedStack retains visited State but uses TickerMode to mute hidden tickers. Wrapper keys are distinct from child GlobalKeys, preserving Activity's externally addressable State and rider tab identity across list changes. | Real ticker, State-retention and GlobalKey tests. Before: hidden ticker still ran twice over two pumped frames; after: zero hidden ticks. |
| Hidden Activity polling | ActivityTab receives isActive from passenger navigation. Its passive timer and debounced display refresh stop while hidden/backgrounded, then reconcile on activation/resume. Realtime ownership remains intact. | Actual Activity lifecycle/timer code tested with an overridden loadOrders counter: zero loads during 61 seconds of hidden fake-clock time; one catch-up on return. |
| Tracking-controller duplicate starts | start() shares its initialization future; repeated calls cannot add another channel/timer or duplicate the initial REST/live request. | Controlled baseline: two orders GET sends for concurrent starts; fixed: one, with one order channel. |
| Overlapping tracking refreshes | Initial live enrichment uses the same coalescing path as realtime/polling. Queued payload-only events no longer force an unnecessary orders read. Public manual fetchOrder calls serialize and preserve one fresh queued read after an action. Username and rider lookups share pending requests; valid empty names are not fetched on every order event. | Actual Supabase client with mocked HTTP/channel delivery. Eight events during pending enrichment leave one initial orders read, one username request and two total live requests after the queued follow-up. Manual refresh test checks sequential reads. |
| Stale tracking responses | A REST result cannot overwrite an order changed by realtime while the read was pending. Old rider metadata cannot overwrite a newly assigned rider, or initiate further enrichment after disposal/reassignment. Rider KYC changes use the actual kyc_id field and queue a fresh lookup if a metadata update arrives during an existing lookup. | Cancellation race, reassignment and in-flight KYC-change tests. |
| Background tracking display work | Controller skips background fallback/ETA enrichment, continues applying order realtime rows, and reconciles on resume. Disposal cancels its timer, removes lifecycle observation and releases channels; repeated dispose is safe. | Thirty seconds of paused fake-clock time adds zero fallback requests; resume performs one orders/live refresh pair. Disposal during startup creates no channels or live requests. |
| Redundant map notifications | Shared location setter suppresses identical latitude/longitude/heading values. Real movement and heading changes still notify immediately. | Five identical events: **5 → 1** notifier updates in an executed baseline/fixed comparison; separate heading and position changes each notify. This measures notifier work, not physical rendered frames. |
| GPS stream recovery | Normal stream completion releases its handle. Completion/error callbacks from old tracking generations cannot clear current-generation ownership. Existing upload lock, movement gate, success-only dedup state, offline retry behavior and 30-second heartbeat remain. | Pre-change completed stream left a non-null handle; fixed test can start the replacement stream. Existing GPS stream/HTTP concurrency, failure and heartbeat tests still pass. |
| Earnings request bursts | Three overlapping refresh calls share the current batch and queue bounded follow-up work. Hidden withdrawal display events do not launch a full batch; re-entry refreshes. A disposed widget cannot start dependent order queries or attach a new rider listener. Optional injected dependencies allow testing the actual widget offline. | Actual Earnings widget with mocked HTTP/realtime: one rider GET and one threshold GET while blocked; no subsequent order reads after disposal. Financial calculations and authoritative sources are unchanged. |
| Rider Home background UI refresh | Pause only the cosmetic silent-refresh timer in background. Resume still reconciles assignments even off-tab, and restarts the timer only when Home is selected. Rider assignment listeners and live GPS owners remain active. | Existing assignment, busy/free, covered-screen and Home regression groups pass; source review confirms essential subscriptions were retained. |

## Existing fixes retained and verified

- main.dart still initializes independent Firebase, Supabase and cache work concurrently. Notifications, location and unused legacy flag initialization remain outside the blocking startup path.
- app_start_screen.dart still starts public configuration/profile work in parallel, resolves maintenance/version gates without waiting for a stalled profile, observes errors, checks current identity before applying results and preserves Auth/KYC decisions. There is no artificial splash floor. Passenger Home receives the startup profile instead of blocking navigation on all secondary data.
- production_config_service.dart retains its concurrent package/config fetch, request coalescing, explicit timeout and existing cache/failure policy. No maintenance policy was weakened to improve a timing number.
- Rider navigation retains lazy selected-tab mounting, account-scoped/expiring startup seeds and the eagerly retained Home service owner. Rider Orders keeps its visibility-gated display polling and the essential active-order/reconnect fallback. No matching condition or dispatch RPC contract changed.
- Notification badge still uses a shared account-scoped listener, coalesced exact HEAD counts and account-change cleanup. Existing Auth/session, KYC, GPS upload and notification behavior tests remain green.

No new changes were needed in those already-fixed startup, rider-navigation, Rider Orders or notification files. They were verified, not rewritten.

## Exact Flutter files modified in this pass

1. lib/core/services/location/location_cache_service.dart — startRiderLiveTracking stream completion/error ownership.
2. lib/core/services/realtime/realtime_order_controller.dart — start/_start, refresh queue, fetchOrder/_queryOrder, username/rider fetch coalescing, metadata identity checks, location setter, lifecycle and disposal.
3. lib/features/rider/earnings/rider_earnings_tab.dart — fetchData/_drainDataRequests/_fetchDataOnce, hidden refresh gate, mounted check and test dependencies.
4. lib/features/rider/home/rider_home_tab.dart — passive timer and lifecycle handling.
5. lib/features/user/activity/activity_tab.dart — isActive, visibility/background timer/debounce gates and reconciliation.
6. lib/main_navigation_screen.dart — pass Activity visibility while preserving its GlobalKey.
7. lib/shared/widgets/lazy_indexed_stack.dart — hidden TickerMode and stable wrapper keys.

[Complete Phase 1-only diff](CHANGES.patch) and [SHA256 changed-file manifest](CHANGED_FILES.json) compare against the working tree at this phase's start, rather than mixing earlier edits into the change list. Seven test files changed: four new behavioral test files and three existing source-contract files. No payment calculation, order matching, UI layout/design or backend implementation was edited.

## Regression results

| Command/check | Result |
|---|---|
| flutter pub get | Success; existing locked package versions retained |
| flutter analyze --no-pub | 0 errors, 73 warnings, 382 infos; 455 total; no new diagnostic fingerprints |
| Complete offline Flutter selection | **2,054 passed, 0 failed** |
| New behavior tests | **16 passed**, included in the complete run |
| Original 20 failure groups | Pass within the complete run; earlier resolutions preserved |
| git diff --check | Pass |
| Backend source integrity | Zero changed supabase/ files |
| Android device inventory | Empty |

Analyzer exits nonzero because existing warnings/information diagnostics remain. The remaining warnings concern existing unused code/imports/parameters and redundant assertions; the information diagnostics are mostly existing API deprecations and style preferences. No new ignore rules or skipped tests were added, and unrelated cosmetic cleanup was avoided.

The first wider run found four new structural mismatches after refactoring. They expected the old direct live call, an arbitrary 3,000-character rider-method slice, and two direct singleton-call spellings. The assertions now require the same terminal-state gate, authoritative intercity vehicle lookup and pooled subscribe/unsubscribe behavior through the injected manager. Behavioral tests independently verify these paths. No failure was hidden or deleted.

The original 20-case investigation is preserved in ../WAYDROP_FAILURE_TRIAGE_CONTINUATION.json. Its historical create-order fixture caveat still applies: the reproducible tracked baseline is not proof of equality to the unavailable deployed v76 artifact. That is not used as a Flutter performance claim.

Two pre-existing live-backend files were intentionally not executed: pricing_dedup_regression_test.dart and intercity_parcel_pricing_regression_test.dart. They would access configured services and are outside this Flutter-only offline run. This exclusion is explicit; it is not a claim those connected tests passed.

Full logs: [tests](evidence/flutter_phase1_full_tests_final.txt), [analyzer](evidence/flutter_phase1_analyze_final.txt), [dependency resolution](evidence/flutter_phase1_pub_get.txt), [device inventory](evidence/flutter_phase1_devices.txt). Expected failing before-fix reproductions are separately named baseline logs in the evidence directory. [Structured final verification](VERIFICATION.json).

## Performance measurements and limits

[Machine-readable measurements](MEASUREMENTS.json) contain actual controlled-test counts. Controller baselines use saved pre-change source with HTTP/realtime/clock dependency seams only; ticker/GPS baselines use the saved source unchanged. A fake clock/frame pump is not an Android performance measurement.

| Metric | Before | After | Measurement scope |
|---|---:|---:|---|
| Orders GETs for two overlapping controller starts | 2 | 1 | Mocked HTTP sends through the real client |
| Hidden ticker callbacks over two pumped frames | 2 | 0 | Real Flutter ticker lifecycle; simulated frames |
| Location notifications for five identical GPS events | 5 | 1 | Real production controller/notifier; synthetic payloads |
| GPS can restart after normal stream completion | No | Yes | Mocked platform stream, real service lifecycle |
| Physical cold/warm startup and first usable p50/p95 | Not measured | Not measured | No attached Android phone |
| Actual startup/steady API requests per minute | Not measured | Not measured | No comparable device session capture |
| Physical GPS writes/minute | Not measured | Not measured | Offline tests verify upload contracts, not field movement |
| Profile build/raster durations and missed frames | Not measured | Not measured | No physical profile-mode trace |

When a phone is attached, use flutter run --profile -d <device-id> --dart-define-from-file=<authorized-env-file>. Record at least ten process-cold starts and ten warm resumes under identical device/account/network/cache conditions. Use existing PERF_PROCESS/PERF_STARTUP/PERF_HOME markers plus first rendered usable content, not splash display, as the navigation timing evidence. Capture API counter deltas, successfulLocationUploads deltas over a measured minute, and DevTools Performance build/raster traces. Android am start -W is a process-launch metric, not first usable Flutter content. Do not introduce a new backend environment or run real financial transactions merely to obtain timings in this phase.

## Remaining Flutter limitations and Phase 2 boundary

No known failing offline regression remains for this pass. Device startup/frame/GPS/notification behavior and real provider workflows remain unverified; unit/source-contract success does not certify every real-world business transaction or prove all perceived slowness is gone. Existing analyzer cleanup remains deferred. No mobile latency, FPS or requests/minute improvement is invented.

For Phase 2, investigate backend latency in startup/profile reads, order/assignment and earnings queries, dispatch/reconnect RPCs, the GPS write/trigger bridge, notification delivery and provider/Edge Function response times. Compare authenticated query plans and end-to-end latency in a separately approved environment. Backend security proposals, staging provisioning and production deployment are all outside this completed Flutter code pass and remain untouched.

Stop here. Wait for the user's Phase 2 instructions.
