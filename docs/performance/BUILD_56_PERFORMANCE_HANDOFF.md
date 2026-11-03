# Build 56: verified app corrections and remaining bottlenecks

Date: 2 November 2026, IST. User requested concrete improvements across app/API/upload flows. This follow-up changes local Flutter implementation and prepares a signed APK; **production remains unchanged**. No new project, spending, SQL migration, cron edit, Edge deployment or resource resize.

## What Build 56 changes

| Defect | Exact correction | Evidence |
|---|---|---|
| Passenger Home could keep a full-screen skeleton after data finished if GPS never initialized | `lib/features/user/home/home_tab.dart:1332–1340`: the skeleton now also requires `loading`. Existing GPS readiness/permission/service-area checks and location setup prompt remain. | Two actual widget counterexamples fail before: completed Home data and failed API both leave a skeleton with GPS unavailable. Both pass after. |
| Zone prefetch claimed completion to overlapping callers before data/resolver was ready | `lib/core/services/location/serviceability_service.dart:14,26–51`: callers join one actual in-flight future, including normal calls during a forced refresh; ownership clears on completion/failure. | Three actual-service/SDK tests: initial concurrent waiter, forced refresh with TTL cache, failure preservation and explicit retry. First two fail before; all three pass after. |
| Rider Home awaited display-only earnings before hiding skeleton and starting order reconciliation | Previously corrected `_refreshHomeEarnings` / `_loadRiderOnceMeasured` in `lib/features/rider/home/rider_home_tab.dart:195,450–460`; included in this APK | Five actual widget cases remain passing: no critical-path wait, late disposal/account response guards, failure retains prior value and single-flight query sharing. |
| Completed failed config attempt fetched again on each routine init | Previously corrected `lib/core/services/config/production_config_service.dart:74–89`; included in this APK | Reproduction 9 HTTP reads → 1, cached gates preserved, explicit refresh retained. Three config tests remain passing in full suite. |

The new Passenger Home condition is a minimum correction: `loading && initialData == null && !LocationCacheService.isInitialized`. It does not wait for GPS forever once data has succeeded or failed, while preserving the existing seeded/GPS-ready display behavior. It does not force `LocationCacheService.isInitialized = true`, fabricate coordinates, waive KYC or authorize booking. The actual location setup modal still exists when permission/service is unavailable. Tests check the underlying skeleton even when a modal is above it.

The zone fix changes synchronization, not the zone rules: same 15-minute cache TTL, same query/columns, same resolver/parser, same explicit forced refresh and previous-cache fallback. Startup prefetch, LocationCache initialization and Home can call concurrently in actual source. Returning immediately under the old busy flag allowed consumers to use an empty/stale resolver; no incident-wide causal claim is attached. A shared wait may take as long as the underlying request: correctness is not achieved by declaring unfinished work complete.

## Reproduction and regression results

New tests:

- `test/passenger_home_location_loading_test.dart`: **2 pass**, originally **2 expected failures**, with GPS denied/unavailable and no startup seed. API completion/failure is controlled by a completer using actual Home/SDK code.
- `test/serviceability_shared_load_test.dart`: **3 pass**, originally **1 pass / 2 expected failures**. One query serves overlapping waiters; TTL reuse adds zero reads; forced failure retains the cached synthetic zone and a subsequent explicit retry works.
- Existing `test/rider_home_critical_path_test.dart`: **5 pass**, retained.

Combined focused suite: **10 passed / 0 failed**. Full Flutter: **2,133 passed / 0 failed**, previous 2,128 plus five new cases. Analyzer of the two newly changed implementation files and two new tests: **no issues**, exit 0. Previous config/Rider Home corrections are covered by the full run; this is not a full-project analyzer claim.

Logs under `.dart_tool/waydrop-local-runtime/`: `passenger-loader-before.log`, `zones-singleflight-before.log`, `build56-focused.log`, `build56-full-flutter.log`, `build56-analyze.log`. Initial Passenger test fixture needed a phone-shaped viewport and completed async response processing; the retained baseline failures are the intended skeleton assertion, not those setup errors. No managed SQL/Edge integration suite was rerun because no SQL/Edge implementation changed.

Controlled before/after measurements are **dependency/state measurements**, not handset speed claims:

- Passenger data finished + GPS unavailable: permanent skeleton before → core Home/location setup UI after.
- Rider read finished + earnings withheld: skeleton/assignment setup held before → core Home and assignment reconciliation proceed after.
- Overlapping zone caller: returned before the result before → waits for the same single query after.
- Failed config + eight later init calls: 9 → 1 requests.

## API and upload delays: still open

The user's earlier November 2 **15:51–16:00 IST** interval contained project-wide REST tail latency (orders maximum 7.996 seconds, riders 5.050 seconds) and Storage POST durations **8.635, 19.148 and 22.676 seconds**. A request of only 19,751 bytes took 19.148 seconds. Those remain observed delays, not repaired server benchmarks. See [bounded evidence and source analysis](WAYDROP_FREE_PLAN_BOTTLENECK_ANALYSIS.md).

Normal parcel details uploads once and passes URLs to booking; booking reuses URLs rather than retransmitting them. Rider proof upload must finish before server-side checksum/verification. No image-quality reduction, proof bypass, blind retry or global timeout was introduced to make a spinner disappear. `process-verification-photo` fetches the uploaded image and computes its checksum server-side; changing that is a security/protocol change, not a cosmetic speed fix.

Current official upload documentation describes a newer default retry policy, but the **pinned local storage_client 2.4.1 implementation defaults to zero retries** (`storage_client.dart:38`). Thus a presumed SDK ten-retry storm is not a verified explanation in this source. No SDK version upgrade or retry policy change was made. [Official upload reference](https://supabase.com/docs/reference/dart/storage-from-upload); inspect the installed implementation rather than applying a newer default to the pinned build.

Historical memory commitment, occupied swap and IOWait do not establish the initiating mechanism. Active paging, per-device disk latency/queue, I/O budget and admission waits at onset are missing. No new production log scans were run. Free-plan resource insufficiency and the original November 1 initiating database-wide cause remain **unproven**; there is no evidence-backed guarantee that paying for compute repairs Storage or phone-network delay.

## APK, rollout and rollback

Release version: **1.0.0 (56)**, built with the existing local configuration and release signing setup. Artifact, SHA-256, package/version and comparison against Build 55 signer are recorded in [verification](build56-20261102/VERIFICATION.json). Build output is redacted before persistence. The existing Build 55 APK is preserved. No install, publication or production activation is performed automatically.

Flutter status: **candidate for same-device verification**, not a certified 100%-fast release. Backend combined SQL and Edge bundles remain **NO-GO** under their existing managed-integration, business-rule and old-writer/fencing gates; this APK does not activate them. Existing KYC, payments, atomic acceptance, tracking, chat/outbox and push safeguards remain.

No Android phone is attached: device inventory reports Windows/Chrome/Edge only. Phone opening time, first usable frame, frame jank, network path and end-to-end booking/proof speed cannot be measured here. The next decisive check is to update the same phone to this APK, repeat the same journey/connection and timestamp profile/core-Home readiness separately from parcel upload and verification completion. Existing profile instrumentation can support a controlled device run; release diagnostic export remains disabled.

For a release regression, retain Build 55 as the reference. Android normally disallows installing a lower version code over a newer version; do not uninstall and erase user state just to downgrade. A signed forward build restoring the prior Flutter changes is the safe app rollback route. No database rollback is needed for this Flutter-only batch. Production migrations/Edge rollout, compute resizing and resource purchases remain separate pending decisions, not implied by this artifact.
