# Local ride diagnostics — candidate for independent review

Actual-app instrumentation is implemented locally; actual-app diagnostic build/install/capture requires separate approval. The operator reports successful synthetic export/retrieval using the separate isolated host on P1 (V2338, Android 16) and P2 (CPH2381, Android 14). That is not evidence of actual-app ride timing. No backend/function/configuration changes, telemetry uploader, polling or new backend requests are introduced by the recorder. Earlier validation entries below are historical records, not current capture authorization.

## Enablement and privacy boundary

The singleton is disabled unless the compile-time boolean `WAYDROP_LOCAL_RIDE_DIAGNOSTICS=true` and a valid `WAYDROP_DIAGNOSTIC_RUN_KEY` (base64 encoding of 32 operator-generated random bytes) are explicitly supplied. Missing/malformed key fails disabled. Use the same approved capture key on both phones for same-run correlation; never reuse an authentication key, print/share the key in chat, or supply it remotely. No key/configuration file was generated in this task. Ordinary builds omit it and remain disabled. This is not a remotely supplied flag, profile privilege or authorization bypass. Future build/install/use requires separate approval; do not run a diagnostic build command yet. Tests use explicitly enabled isolated recorder instances with synthetic data.

`RideDiagnostics.instance.exportJson()` returns sanitized text in memory. The separately approved settings export action writes only that output, under the limits below. No console printing, telemetry or sharing UI was added. Isolated-host retrieval is operator-reported successful; retrieval under the actual app package remains unverified. Do not assume release/profile VM evaluation can retrieve it. Never substitute raw logcat, Crashlytics payloads or request bodies for this export. Existing application logging/Crashlytics behavior is untouched and is not certified by this recorder.

Identifiers become keyed SHA-256 pseudonyms using the private capture key (isolated test instances without a supplied key use a random session key); no raw-ID lookup map, key, identity, coordinates, OTP, token, notification/request body, fare, payment reference or exception message enters the buffer/export. The existing cached crypto 3.0.7 package is now a pinned direct dependency without a version change. Fixed enums and numeric fields define the schema. Status is whitelisted; server version candidates require a valid timezone-aware calendar timestamp. No arbitrary tags/strings may be exported.

At most 64 SDK waits retain diagnostic completion observers. Overflow emits `observationSkipped` and passes through the same SDK future; it never suppresses or retries the request. `client_observed_waits` counts local waits, not network/server requests. Capacity is 2,048 events (hard constructor maximum 8,192), dropping oldest entries and reporting `dropped`; numeric endpoint/counter maps have fixed enum keys. Render deduplication stores at most 64 pseudonymous ride entries per owner. Missing/evicted/duplicate pairing endpoints return unavailable, never interpolation. Account replacement (including A→B→A) retires that diagnostic owner; old callbacks/attempts cannot record into a replacement identity. This stops diagnostics on a retained old widget, not its application behavior. Fresh diagnostic ownership requires a newly constructed owner; capture should stay on the approved fixed test identities.

## Events and honest timing interpretation

- `action`: command-handler entry for an accepted operation, not hardware touch time. Booking records before device metadata awaits and keeps the same operation/correlation through its existing retry.
- `requestStart`: immediately before invoking the existing SDK future; not socket-send/server-receive time. Every retry has a distinct attempt number within the logical operation.
- `response`: SDK future resolved; HTTP code is included only when the pinned client exposes it. SDK exceptions retain only available numeric HTTP status. The pinned `FunctionResponse` has data/status, no response headers; gateway request IDs therefore remain unavailable. Existing booking idempotency correlation is pseudonymized, not exposed.
- `confirmed`: successful server acknowledgement for a mutation. `requested_status` is distinct from `observed_status`, which exists only if returned by the server. Alternate RPC success without a returned status/version remains acknowledgement evidence only. Read/live-snapshot success is not a mutation confirmation. Malformed booking success without an order identity cannot confirm booking.
- `timeoutUnknown`/`exceptionUnknown`: client wait failed; server/transport may still be running. These do not prove rollback, absence or failure-before-commit. Do not calculate actual network outstanding requests by decrementing on timeout.
- `realtimeReceipt`: beginning of the existing callback, before existing application logic. `applied`: existing row assignment/accepted controller application. Duplicate deliveries remain observable; rejected controller rows have no applied event. Shared controller receipt/application use the same diagnostic operation.
- `rendered`: the post-frame boundary following the builder containing the selected status, provided route, identity, lifetime and current status still match. Rebuilds of that same status are deduplicated. This is Flutter UI-frame evidence, not GPU presentation/human perception; clipped/occluded content and actual device delivery still require visual/profile validation. Rider PiP map-only frames are excluded. A terminal route that closes without rendering has no render event.

`mono_us` comes from one session Stopwatch. A device UTC wall-clock anchor is recorded solely for later alignment, explicitly marked unverified; it cannot establish server clock offset or justify cross-phone subtraction by itself. Duration pairing uses matching operation/attempt on the same recorder only. `server_version_candidate` is ordering evidence, never transaction commit time or a basis for cross-clock subtraction. No cross-device clock alignment is inferred. Independent keys intentionally yield different pseudonyms; the shared approved capture key produces matching ride labels across phones without raw IDs. The capture key is embedded in the diagnostic binary, so this is pseudonymization, not a promise of anonymization against a person holding the APK/key and candidate IDs. Compare the exported `capture_namespace` fingerprints locally before joining captures; they identify the key namespace without disclosing the key. Review secure key provisioning, verify the implemented local export retrieval on both phones, and establish clock alignment before any six-ride comparison. Do not compare independent monotonic origins.

## Coverage and boundaries

Hooks cover all four existing create-order booking callers; Home, Orders and Incoming Order Card acceptance; Travel Plan intercity acceptance/start; Rider Active Order generic status, intercity start/arrival/delivery/payment-confirmation branches; Intercity Bookings alternate arrival/completion/status calls; existing verification/fallback reads and assignment-feed receipts; shared order/live-status reads and Realtime application; passenger searching/tracking builders for ride, parcel and intercity, and rider active/completion builders. Original payloads, selected columns, filters, timeout windows and retries remain inside unchanged SDK expressions. No dispatch, payment, authorization, business rule or blocked Travel Plan lifecycle redesign is included.

Request totals count these instrumented SDK attempts only, not every app request or hidden SDK retry. Stream callback (including ignored old/failed callbacks, counted separately)/heartbeat and actual location-write start/response/unknown counters are aggregate, location-free observations; no GPS subscription or heartbeat was added. Existing Realtime observability methods feed numeric create/dispose/reconnect/error counters, whose instrumentation coverage is not assumed exhaustive. Counter snapshots accompany timeline events, and final totals survive timeline eviction. Frames/raster jank, memory, wire timing and database/pool/Edge execution durations remain external capture requirements, not measurements supplied by this recorder.

## Local validation and future six-ride report

Controlled futures/clocks and widget frames test pairing, overlapping/reversed attempts, retries, missing events, uncertain outcomes, duplicate evidence, redaction, malformed versions/booking evidence, account replacement/logout/disposal, listener cleanup, bounded eviction, unchanged request/result behavior and frame fencing. Tests execute the production recorder/owner logic; they do not exercise actual Android/GPS/Supabase behavior or certify every screen integration.

After independent review and separate capture approval, the report should include R1–R6, phone role/build/session age, event ledger and evidence source, action→SDK receipt, receipt→first matching frame and Realtime receipt→application/frame for each phase. Ambiguous correlations, unknown server versions, missing frame evidence, clock misalignment and buffer eviction must be marked NOT AVAILABLE/NOT CALCULABLE. Client acknowledgements cannot be renamed backend commit times. API/read response-to-render pairing requires a unique matching ride/status sequence; repeated/ambiguous revisions cannot be paired by assumption. RPC acknowledgements without returned version/status remain distinct from observed authoritative row evidence. No timings or performance improvements have been measured by implementing these hooks.

## Exact files changed by this candidate

New: `lib/core/services/diagnostics/ride_diagnostics.dart`, `lib/core/services/diagnostics/ride_diagnostics_owner.dart`, `test/ride_diagnostics_test.dart`, this document. Dependency declaration only: `pubspec.yaml`, `pubspec.lock` (crypto version unchanged; prior app version change preserved).

Existing Dart files receive diagnostic hooks only; earlier uncommitted work remains:

- `lib/core/services/location/location_cache_service.dart`
- `lib/core/services/realtime/realtime_order_controller.dart`
- `lib/core/services/realtime/realtime_observability.dart`
- `lib/features/local_rides/booking/screens/ride_location_screen.dart`
- `lib/features/local_rides/searching/screens/ride_searching_screen.dart`
- `lib/features/local_rides/tracking/screens/ride_tracking_screen.dart`
- `lib/features/local_parcels/booking/screens/parcel_booking_screen.dart`
- `lib/features/local_parcels/searching/screens/parcel_searching_screen.dart`
- `lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart`
- `lib/features/intercity/rides/booking/intercity_ride_booking_screen.dart`
- `lib/features/intercity/parcels/booking/intercity_booking_screen.dart`
- `lib/features/intercity/shared/screens/intercity_searching_screen.dart`
- `lib/features/intercity/shared/screens/intercity_tracking_screen.dart`
- `lib/features/rider/home/rider_home_tab.dart`
- `lib/features/rider/orders/rider_orders_screen.dart`
- `lib/features/rider/orders/screens/rider_active_order_screen.dart`
- `lib/features/rider/orders/widgets/incoming_order_card.dart`
- `lib/features/rider/intercity/intercity_bookings_screen.dart`
- `lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart`

External memory capture must be an aggregate trend only: do not export heap/object dumps, raw HTTP profiler bodies/headers or unsanitized device logs. Render markers are frame candidates, not verified pixels or raster timings.

## Actual local validation

`flutter test --no-pub test/ride_diagnostics_test.dart test/completion_status_poll_test.dart test/completion_responsiveness_regression_test.dart test/rider_pending_ride_after_completion_regression_test.dart test/location_cache_service_guard_ownership_test.dart test/rider_gps_webview_perf_regression_test.dart test/realtime_order_controller_stale_status_regression_test.dart --reporter compact --timeout 30s`: **97 passed, exit 0** (29 diagnostic tests and 68 related regressions). Two intermediate failures were unchanged GPS source assertions sensitive to CRLF; restoring the touched source's LF convention fixed them without changing assertions. Introduced annotation/property errors were corrected before final validation.

`flutter analyze --no-pub` on the two new recorder files/directory, the diagnostic test and every existing Dart path in the manifest: **0 errors, 42 warnings, 242 informational findings, exit 1**. No findings remain in the new recorder/tests. Remaining warnings concern existing imports, variables, methods and optional parameters outside the hooks; informational findings in existing code were left untouched. The corrected recorder/test/incoming-card subset also passed with 0 findings, exit 0. Full output is retained locally in `%TEMP%/waydrop-ride-diagnostics-release-review-analysis.txt`.

`git diff --check`: **exit 0**. The diagnostic observer issued one fake request with diagnostics disabled and one with it enabled; the 65-pending-attempt test issued all 65 fake requests, retaining only 64 diagnostic completion observers. These are local correctness counts, not backend/device latency, traffic savings or capacity measurements. Status: ready for independent local review; no build, phone enablement, installation, app launch, production access or six-ride capture authorized/executed by this pass.


## Approved local export candidate (not approved for phone use)

Passenger and Rider Settings expose **Save diagnostic capture** only when the existing recorder singleton is explicitly enabled. Ordinary builds omit `WAYDROP_LOCAL_RIDE_DIAGNOSTICS` and `WAYDROP_DIAGNOSTIC_RUN_KEY`, leaving the action hidden and the writer disabled. Explicit enablement requires the compile-time boolean plus a valid base64-encoded 32-byte capture key; malformed/missing keys fail disabled. Deliberate enabled release/profile builds are possible: this is not a release-mode prohibition. No build/launch configuration or production `.env` was modified.

The writer's only content source is `RideDiagnostics.instance.exportJson()`. It captures that sanitized JSON once before filesystem awaits; subsequent events remain in memory for the next explicit export. A capture with no timeline events is reported empty (counters alone do not produce a saved capture). UTF-8 bytes above **4,194,304 (4 MiB)** are rejected without truncation or replacement. Exactly the limit is accepted. One export can run at a time across both settings actions; duplicate clicks do not queue more writes. Failures and unavailable storage return fixed categories, never JSON, keys, paths or exception details. No uploads, clipboard, sharing sheet, backend calls, permissions or telemetry were added.

On Android, the already-cached `path_provider` **2.1.5** supplies the app-specific external files directory. It is now a pinned direct dependency; all package versions/hashes remain unchanged. The exporter creates only its `ride-diagnostics` child directory and owns only `capture.json` and `capture.json.tmp` beneath it. It flushes the temporary file, then renames it to the fixed file in the same directory. It never deletes the last valid capture before replacement. Errors clean up only an ordinary file at the fixed temporary filename, never recursively and never the capture/unrelated files. Non-file/symlink collisions are rejected, not removed. Cleanup errors report failure; interrupted processes may leave the exporter-owned temporary file until the next explicit export. A successful export replaces the previous capture; retrieve it first if it must be preserved. This is a same-filesystem replacement protocol, not a power-loss durability guarantee. It assumes the app-specific directory is not concurrently manipulated by another process; it does not claim adversarial filesystem race protection.

The expected primary-storage path is `/sdcard/Android/data/com.waydrop.app/files/ride-diagnostics/capture.json`; storage layout and authorized ADB readability on these phones remain **UNVERIFIED**. After separate build/install/capture approval, confirm the real app-specific directory on each phone and retrieve using `adb -s <approved-device> pull <verified-capture-path> <protected-local-phone-label>.json`. Do not run this now, fall back to raw logs, grant broad storage permissions, or print the capture/key. Keep both phone exports distinct and compare their pseudonymous capture namespaces before joining them. These files remain sensitive pseudonymous evidence in external app-specific storage; authorized ADB/host access must be protected. No device export, retrieval or ride test was performed.

### Files in this export-only change

New: `lib/core/services/diagnostics/ride_diagnostic_export.dart`, `lib/shared/widgets/ride_diagnostic_export_tile.dart`, `test/ride_diagnostic_export_test.dart`.
Integration only: `lib/features/user/settings/user_settings_screen.dart`, `lib/features/rider/settings/rider_settings_screen.dart` (one import and one action each). Dependency metadata: `pubspec.yaml`, `pubspec.lock` (`path_provider` declaration/classification only). Documentation: this file. Existing recorder/owner, ride hooks and recorder tests were not modified by this export task; all earlier work is preserved.

Tests use the actual writer with unique disposable local directories, controlled futures and fault injection; UI feedback tests use immutable debug-only dependencies. Test seams cannot enable the production singleton and are runtime-rejected outside debug mode. No JSON/data sink can be supplied to the production writer.

### Local validation for the export candidate

- `flutter test --no-pub test/ride_diagnostic_export_test.dart test/ride_diagnostics_test.dart --reporter expanded --timeout 30s`: **55 passed, 1 skipped, exit 0** (22 export tests plus 33 recorder tests; enabled-build-only settings test skipped in the ordinary build).
- With `--dart-define-from-file=<temporary synthetic invalid-key fixture>` and `--name 'default or malformed|ordinary passenger'`, the export test file: **2 passed, exit 0**. The fixture explicitly enables diagnostics but supplies a base64 key decoding to 31 bytes; the real singleton stays disabled and both settings hide export.
- With `--dart-define-from-file=<temporary synthetic valid-key fixture>` and `--plain-name 'enabled diagnostic build exposes both settings actions'`, the export test file: **1 passed, exit 0**. A temporary random 32-byte test key enables the real singleton and both settings expose the action. Neither fixture/key was printed; both temporary files were removed. These were local Flutter tests, not APK/device builds or backend tests.
- Targeted `flutter analyze --no-pub` on the writer, tile, export test and both settings: **0 errors, 0 warnings, 1 pre-existing informational deprecation, exit 1**. `activeColor` in Rider Settings already exists in Git HEAD; it was left unchanged. No new analyzer findings remain.
- `git diff --check`: **exit 0**; existing line-ending notices remain informational.
- An intermediate test failure came from completing the test fixture's one-shot signal twice on a second export; the fixture was corrected without weakening concurrency or last-valid-file assertions.

Phone retrieval, Android filesystem replacement behavior and actual capture timings still require separately approved device validation. No latency/performance gain is claimed.

## Actual-app capture review: coverage and collection contract (2026-10-15)

This section documents reviewed source boundaries, not measured ride timings. No actual-app build, installation or ride capture is authorized by this documentation update.

| Stage | Production hook / caller (paths relative to `lib/`) | Evidence and missing boundary |
|---|---|---|
| Booking | `features/local_rides/booking/screens/ride_location_screen.dart`: `_createOrder`, `_submitOrderToBackend`; equivalent parcel/intercity booking screens | Handler action before metadata await, existing SDK attempts/responses, returned order linkage. Not hardware touch, socket send or server receive. Local ride retry keeps its operation/correlation. |
| Assignment | `features/rider/home/rider_home_tab.dart` and `features/rider/orders/rider_orders_screen.dart`: assignment subscription callbacks | Assignment-feed callback receipt only; no dispatch-start, push delivery, sound or human notification timestamp. |
| Offer frame / acceptance | `features/rider/orders/widgets/incoming_order_card.dart`: `build`, `acceptOrder`; Home/Orders acceptance handlers; Travel Plan Details acceptance | Card post-frame candidate and acceptance SDK evidence. Card action is near SDK invocation; other offer surfaces lack an explicit first-offer frame marker. |
| Arrival / status | `features/rider/orders/screens/rider_active_order_screen.dart`: `updateStatus`, `_markIntercityParcelAtDropoff`; Intercity Bookings `_markRideArrived` | Generic action includes existing location/device preflight; alternate RPC action is near invocation. Initial gesture/dialog time is not uniformly covered. |
| Completion / settlement | Active Order `updateStatus`, `_completeIntercityParcelDelivery`; Intercity Bookings completion/status calls | Generic status, delivery and settlement RPC acknowledgements. Success without returned status/version is not terminal-row or commit-time proof; OTP/payment-sheet interaction before invocation is outside this interval. |
| Plan start | Active Order `_startIntercityTrip`, Travel Plan Details start handler | Existing plan-start RPC. Plan labels are separate from order labels; no inferred plan-to-order mapping. |
| Reads / Realtime | `core/services/realtime/realtime_order_controller.dart`: order/live-status reads, subscription callback, `_applyOrderData`; Active Order Realtime and fallback/verification reads | Selected SDK waits, callback receipt and accepted state application. Not all HTTP traffic, hidden SDK retries, server processing or network transit. |
| Frames | Ride/parcel/intercity searching and tracking builders; Active Order normal/completion builders | Current-route/status post-frame candidate, not proof of pixels, raster completion or user perception. A closed terminal route can legitimately have no marker. |
| Background counters | `core/services/location/location_cache_service.dart`, `core/services/realtime/realtime_observability.dart` | Location-free aggregate callback/write/channel counters. Coverage is not exhaustive; no frame-time, memory, pool/lock or server-execution measurement. |

### Correlation and privacy limits

Two independent recorders with the same valid 32-byte fixture key must produce matching order pseudonyms and `capture_namespace`; a different key must produce different values. Operation/attempt/sequence numbers remain recorder-local. Plan labels use a different prefix and cannot be substituted for ride labels. Verify namespaces before any cross-phone join; retain phone/role association in a separate redacted acquisition record.

Each recorder owns its monotonic origin. Even matching namespaces do not permit subtraction of P1 and P2 `mono_us`. Wall anchors have `clock_alignment=unverified`; a cross-phone booking-to-assignment duration is NOT CALCULABLE without independently justified alignment and its uncertainty. `updated_at`/`server_version_candidate` is ordering evidence, never transaction commit time. Missing, evicted, repeated or ambiguous endpoints remain NOT AVAILABLE/NOT CALCULABLE.

Pseudonyms are not anonymous against an APK/key holder with candidate IDs. The capture also reveals status/activity timing and a wall anchor. Keep APKs, captures and acquisition records access-restricted; do not upload them or ordinary logs. Existing Firebase/Crashlytics and application logs are outside this recorder's guarantee. Launching the actual app initializes its normal SDKs and can make production requests; the isolated host's zero-backend behavior does not transfer to the app.

### Enablement and local export

Ordinary builds omit BOTH `WAYDROP_LOCAL_RIDE_DIAGNOSTICS` and `WAYDROP_DIAGNOSTIC_RUN_KEY`. Missing/malformed enablement fails disabled. An explicitly enabled release is supported; release mode itself is not a prohibition. Only after separate build approval, provide an ignored, protected local defines file with explicit enablement and an operator-generated synthetic 32-byte Base64 key. Never put the key in source, reports, commands printed to logs, or authentication configuration. Use the same approved run key on both phones for that capture run. Do not modify `.env` or production configuration.

Both actual Passenger and Rider Settings already contain the gated Save diagnostic capture tile. It exports only `exportJson()`, with fixed feedback, no JSON/path/exception display. Export is manual, single-operation, at most 4 MiB UTF-8 without truncation. The writer replaces only its fixed file through its own temporary file. Event storage defaults to 2,048 entries; retained SDK observers and each owner's pending frame observations are limited to 64. Oldest events/overflow observations may be lost, explicitly limiting available evidence.

Expected actual-app Android path (verify package/storage root after separate device approval): `/sdcard/Android/data/com.waydrop.app/files/ride-diagnostics/capture.json`; temporary filename `capture.json.tmp`. Do not retrieve the isolated host's directory as actual-app evidence. On ADB access denial stop: no root, new permissions, raw logs, clipboard or network fallback.

### Next six rides: procedure requiring separate approval

1. Review local tests and build configuration first. Separately authorize the actual-app APK, installation/replacement, production-connected startup, named synthetic test accounts and exactly six controlled rides. No capture begins through this documentation work.
2. Verify APK hash/package/signing and unchanged permissions; maintain separate P1/P2 labels, model/OS, role, build hash and app-session age locally. Do not export raw account/device/order identities.
3. Confirm enabled Settings action and matching capture namespaces. Keep fixed test identities; an account replacement retires an existing diagnostic owner, so a retained screen may stop recording. Do not interpret missing markers as no work.
4. Perform only authorized normal booking/acceptance/arrival/completion actions. Do not add retries, polling, artificial payments or extra backend reads for diagnostics. Record interruptions, route changes and human observations separately without personal/location/payment data.
5. After each ride, save on each phone and retrieve only the sanitized fixed capture through approved serial-targeted ADB. Preserve a separate immutable local copy per phone/ride before the next export overwrites the fixed file. Exports are cumulative per process, not per-ride resets; do not double-count overlapping captures. Restart resets monotonic session/operation IDs, so record sessions separately.
6. Validate JSON allowlist/types/enums, namespace, size, dropped/skipped evidence and temporary-file cleanup locally without printing contents or keys. Stop on export/access/schema failure. Never infer completeness from a valid JSON file alone.
7. Build R1-R6 ledgers of action, SDK start/response, acknowledgement, Realtime receipt/application and frame candidate with evidence source. Calculate only uniquely paired same-session durations; keep server status/version evidence separate. Rank only measured phases. Push delivery/server processing, cross-phone intervals, jank and memory remain unavailable unless separately measured safely.

### Settings test boundary

Default tests mount the actual Passenger/Rider Settings and verify the production singleton hides the action. The enabled harness reads each real Settings ListView's child configuration, verifies exactly one production export tile, and mounts those same children with only that tile replaced through its existing debug-only test factory. This is necessary because a lazy ListView can evict the disabled zero-height tile. It then invokes the real exporter into a disposable directory and compares bytes with recorder output, checking fixed feedback and absence of raw fixture data/paths. Filesystem invocation and assertions run outside Flutter's fake clock. This exercises the actual Settings child configuration and the enabled action/writer, not an untouched compile-time-enabled Settings route. No keys/defines or backend startup are created. Compile-time enabled singleton wiring and actual-app Android filesystem access remain unverified; the existing enabled-build test stays conditional.
