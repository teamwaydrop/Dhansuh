# Build 57: completion transition and parcel upload investigation

Date: November 2, 2026. Window **20:50–21:05 IST / 15:20–15:35 UTC**, ending at 21:05:00 IST. User confirms **Build 57**, with loader → white page → Rider Home after tapping **Back to Home**, plus slow parcel photo flow. Project-wide logs do not identify that handset or prove its installed artifact hash.

## Two different demonstrated problems

1. **Client transition:** Back to Home creates a fresh guarded rider shell. Its access-check placeholder is explicitly white; after the fresh access response is published, process-lifetime seed flags prevent dashboard/Home from reusing it and cause duplicate rider reads. Both behaviors reproduce in actual widgets and are corrected locally.
2. **Photo failure:** the pickup upload failed with **Storage DatabaseTimeout / HTTP544 / PostgreSQL57014**, with **33.2 seconds measured by Storage itself**. This is direct backend failure evidence, not merely a large-image or Flutter spinner hypothesis. The initiating database resource/wait is still unidentified. The client transition correction does not claim to repair this service failure.

Production remained read-only throughout: five bounded log queries within the supplied window, one lightweight role/settings snapshot, no production DML/DDL, deployments, restarts, configuration changes, broad historical scans or paid resources.

## Exact upload and database evidence

| Gateway timestamp UTC / IST | Flow | Request bytes | Origin duration | Result |
|---|---|---:|---:|---|
| 15:27:50.842 / 20:57:50.842 | parcel booking image | 52,852 | **16.111 s** | 200 |
| 15:28:44.503 / 20:58:44.503 | pickup proof | 566,848 | **33.209 s** | **544** |
| 15:30:41.115 / 21:00:41.115 | dropoff proof | 437,821 | **15.094 s** | 200 |

Storage's own error at **15:29:17.721 UTC / 20:59:17.721 IST** reports:

- Operation: `storage.object.upload`.
- Error code: **DatabaseTimeout**, error status **544**.
- Execution time **33,200 ms**, response time **33,200.283 ms**.
- Raw database error code **57014**.

PostgreSQL application **Supabase Storage API** recorded a statement timeout at **15:29:17.636 UTC**, 85 ms before the Storage error record. Its parsed SQL text is absent. A unique gateway544 upload and the Storage error have tightly matching timing/status; no shared request ID was collected. Gateway timestamp + duration is within about 9 ms of the Storage error timestamp, consistent with a start-time gateway record for this request. This correlation is not generalized into exact start timestamps for every REST request.

[DETAIL.json](completion-2050-20261102/DETAIL.json), [SQL_FEATURES.json](completion-2050-20261102/SQL_FEATURES.json), [STORAGE_ERRORS.json](completion-2050-20261102/STORAGE_ERRORS.json), [STORAGE_ERROR_CODE.json](completion-2050-20261102/STORAGE_ERROR_CODE.json). Object names, image data and private identifiers were not returned or included.

Supabase documents legacy Storage544 as a database timeout and general544 as a gateway request timeout. Here the actual service code and PostgreSQL cancellation establish the backend failure mechanism. They do **not** establish a specific exhausted pool, max_connections ceiling, blocking transaction or initiating CPU/disk/RAM cause. Do not blindly increase pool size or timeouts. [Storage error codes](https://supabase.com/docs/guides/storage/debugging/error-codes), [HTTP status codes](https://supabase.com/kb/troubleshooting/http-status-codes).

A roughly 53 KB request also took 16 seconds; compressing photos alone is not an adequate evidence-backed solution. The successful uploads' transfer/authorization/SQL/object-write portions remain unseparated. A failed response does not establish whether object data or metadata committed; no automatic retry, object deletion, proof bypass or verification-row repair was added.

## Backend read delays in the same interval

[AGGREGATE.json](completion-2050-20261102/AGGREGATE.json) returned **81 groups**, below its 110-group cap:

| Dart API group | Requests | Median ms | p95 ms | Maximum ms |
|---|---:|---:|---:|---:|
| orders GET | 323 | 93 | 4,310 | 11,740 |
| riders GET | 177 | 110 | 6,063 | 10,310 |
| users GET | 58 | 178 | 4,948 | 7,832 |
| rider KYC GET | 49 | 164 | 5,865 | 7,217 |
| assignments GET | 187 | 84 | 2,615 | 7,666 |
| notifications HEAD | 62 | 75 | 3,761 | 8,078 |

These counts are project-wide, not one phone's duplicates. Two Realtime subscription-manager statement timeouts occurred at **20:58:55.316 and 20:58:55.417 IST**; the third PostgreSQL57014 belongs to Storage. Nineteen PostgREST timeout-text records are not asserted to be nineteen independently failed SQL requests. There was one gateway5XX group failure: the upload544. This is another observed shared-backend degradation, without proving the same initiating mechanism as earlier incidents.

At the later **21:23:13 IST** metadata snapshot, max_connections was60; 13 client backends were idle, and none was blocked. This does not reconstruct the test peak. Roles report no individual connection cap (`rolconnlimit=-1`). Authenticator's configured timeout is8s; authenticated's is20s. Storage role settings list search_path/log_statement but no statement_timeout; effective per-service/session/pool limits were not obtained. [ROLE_LIMITS.json](completion-2050-20261102/ROLE_LIMITS.json). No historical resource charts/wait graph were obtained, and no instantaneous snapshot is used to rule out the earlier stall.

## Why Back to Home showed white and loaded again

Source chain:

`rider_active_order_screen.dart:Back to Home → returnToLocalRideHome → new RiderMainNavigationScreen → RiderEntryHandler.resolve → guarded dashboard → RiderHomeTab`.

This direct helper is the **local-order** branch. The intercity branch first opens RiderRatingScreen; the user's exact order type was not independently identified. The common guarded shell/seed behavior is reproduced, but a full intercity completion/rating journey is not certified by these tests.

- `lib/features/rider/orders/screens/rider_active_order_screen.dart:4733` calls the helper for local completion.
- `lib/features/local_rides/shared/navigation/local_ride_home_navigator.dart:15–29` creates a fresh shell using pushAndRemoveUntil and retains the first route. That stack policy was not changed or replaced with a bare pop.
- `lib/features/rider/onboarding/screens/rider_entry_handler.dart:load/build` revalidates KYC/rider/payout. Previously its pending scaffold used **Colors.white**.
- The guard publishes a **new InitialRiderData** after a successful ready decision. Dashboard and Home previously used `_hasConsumedColdStartSeed` flags that stay true for the process. On a later entry those flags rejected even the newly published response, causing two additional rider reads after the required guarded read.

Real widget baseline: **1 passed / 3 expected failures**—white placeholder; a new response caused one unnecessary Home read; recreated guarded dashboard caused **3 rider reads where1 is required**. This does not prove every white frame on the phone came from this scaffold: no handset frame trace or crash log was captured. It does identify a direct reproducible matching transition.

## Local fixes and preservation

1. **Per-response, per-consumer reuse** in `lib/core/providers/initial_data_provider.dart`: `InitialRiderData.consumeFor` permits each screen to use a fresh response once, rejecting repeated use of that same response, wrong/missing account, expired data and future timestamps. The five-second freshness boundary remains. It is display-read reuse, not permission caching.
2. `lib/features/rider/navigation/rider_main_navigation_screen.dart` and `lib/features/rider/home/rider_home_tab.dart` consume the new guarded response independently. A genuinely new validation response can be used after completion; a recreated screen cannot keep reusing an old response. Neither consumer skips its subscription/order-reconciliation/GPS setup.
3. `lib/features/rider/onboarding/screens/rider_entry_handler.dart` uses the Rider dark theme and explicit **Checking partner access…** while validation is pending. KYC, suspension, payout, service-mode and Auth checks still gate readiness. No navigation removal or permission bypass was introduced.

Actual widget reproduction changes **3 rider reads → 1** on a recreated guarded dashboard. Required account validation remains; this is not zero-read or cached authorization. The two duplicate reads could be concurrent, so no fabricated sum of their durations is claimed as handset speed improvement. Pending KYC cannot reach a supplied ready screen.

The existing root-retention policy and guard timeout/cancellation ownership were not redesigned. No claim that native WebView/graphics issues, all offscreen work or every possible white-screen cause is resolved. The backend tail can still delay the legitimate access check.

## Regression results

- `test/rider_completion_transition_test.dart`: **4 actual widget tests pass**—nonwhite pending validation, fresh response reuse after Home recreation, one authoritative read on guarded dashboard recreation, pending-KYC denial.
- `test/rider_seed_consumption_test.dart`: **5 tests pass**—independent consumers, new responses, wrong/missing identity, expiry/future rejection and old-response republication.
- Updated the existing Orders-tab source guard to assert per-response consumption instead of a process-lifetime flag; its other service-mode/realtime assertions remain.
- Focused access/navigation suite: **18 passed / 0 failed**.
- Full Flutter: **2,147 passed / 0 failed**, previous2,138 plus nine new tests.
- Analyzer on the changed implementation/tests: **no issues**, exit0. This is not a new full-project analyzer result.

Logs: `.dart_tool/waydrop-local-runtime/completion-before.log`, `completion-after.log`, `completion-focused.log`, `completion-full-flutter.log`, `completion-analyze.log`. Previous completed fixes and the pending RLS/dispatch/push review gates remain.

## Production actions and client handoff

**Build58 contains the client transition/seed fixes only** and preserves the earlier fixes. Signature/artifact result and exact hashes: [VERIFICATION.json](completion-2050-20261102/VERIFICATION.json). No installation, publication or measured on-device frame improvement is claimed. Existing APKs are preserved; no production SQL/Edge changes are bundled or activated.

Release build **PASS**, version **1.0.0 (58)**, signature verified with the same signer as Build57. [APK artifact](../../artifacts/waydrop-1.0.0-build58.apk). This is a candidate for testing the corrected transition; Storage backend timeout is not claimed fixed by this APK.

For the photo backend, the next decisive work is a Storage-specific SQL/wait/pool trace plus CPU modes, MemAvailable/paging, system/data-device latency/IOPS/queue and minimum I/O budget during **20:58:44–20:59:18 IST**, with the full test interval as context. The failing SQL is missing, so an index/RLS/pool change cannot be selected responsibly from these records. A later idle connection count does not establish the historical peak.

A privacy-safe [support investigation draft](completion-2050-20261102/STORAGE_SUPPORT_DRAFT.md) is prepared with exact timestamps/codes and the missing measurements; it was **not submitted**. No credentials, object paths or user content are included. If historical service traces are unavailable, a controlled next reproduction needs per-stage numeric timings and safe correlation IDs; no production test upload was created by this agent.

The independently tested public-table RLS candidate remains unapplied and is **not** presented as the fix for the unidentified Storage statement. All production changes still require explicit approval. The original database-wide initiating resource cause remains unproven; the current pickup failure's **DatabaseTimeout mechanism is confirmed**.
