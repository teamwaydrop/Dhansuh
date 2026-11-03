# Build62 — make verified route fixes available on the phone

November 3, 2026. User reports continued slowness and supplies a schema export. Previous Choose Route fixes existed locally, while the tested phone ran Build61. A local source correction does not update an installed APK.

## New confirmed defect and correction

For prefilled pickup and destination, the screen started directions from the WebView `onPageFinished` callback. `_loadCurrentLocation()` returned early for a prefilled pickup. Consequently a valid prefilled journey still waited for map asset/page initialization before requesting directions or fares. This path is used by repeat-booking entry points, including `lib/features/user/activity/activity_tab.dart`, `lib/shared/screens/completed_order_details_screen.dart` and `lib/features/user/home/home_tab.dart`.

Reproduction in `test/choose_route_loading_test.dart`: open the actual screen with both coordinates and valid mocked directions, with no WebView page-finished event. **Before: 0 directions requests, expected 1; test failed.** After: **1 directions request and 3 distinct vehicle-pricing requests**, without that event. No route distance is seeded in this test.

Local correction in `lib/features/local_rides/booking/screens/ride_location_screen.dart`:

- `:305` / `:333`: start directions after the first frame when coordinates are present, independently of map loading. If initial location discovery supplies missing coordinates, start after those become available.
- `:539` `handleMapReady`: a late map event injects the map and paints current geometry; it no longer recalculates directions or resets/restarts pricing.
- `:1176` `_paintCurrentRoute`: replay validated geometry when a late map becomes available; skip invalidated distance and stale owners. The quote and backend validation remain prerequisites for booking.

The test also invokes two late map-ready callbacks and verifies no additional provider/pricing calls. Desktop tests use the existing mock-map path; native WebView rendering still requires phone validation. This is a demonstrated ordering defect, not a measured number of Android seconds saved.

Build62 includes the preceding [Choose Route corrections](WAYDROP_CHOOSE_ROUTE_LOADING_FIX.md): progressive first-valid vehicle quotes, finite-fare/current-route/account guards, explicit Retry states, stale geocode/directions protection, overlapping raw-request sharing, removal of the fixed 150 ms wait, map-paint independence, controller cleanup and promo ownership. Cash/UPI state, backend fare/GST calculations, order idempotency, security and dispatch rules are preserved.

## What the supplied schema does and does not establish

[Schema review evidence](build62-20261103/SCHEMA_REVIEW.json) records **61 table definitions and 97 foreign keys**. The attachment contains no explicit index definitions, trigger bodies or RLS policies. It is context DDL and was **not executed**.

Important paths remain:

| Flow | Relationship |
|---|---|
| Identity | `auth.users.id → public.users.id` |
| Rider identity/KYC | `riders.user_id → users.id`; `riders.kyc_id → rider_kyc.id` |
| Fare configuration | `pricing_config.pricing_zone_id → pricing_zones.id`; `orders.pricing_config_id → pricing_config.id` |
| Booking/assignment | `orders.user_id → users.id`; `orders.rider_id → riders.id`; `rider_assignments → orders/riders` |
| Chat | `order_chat_messages → orders/users/riders`; sender references Auth identity |

Rider row IDs and user/Auth IDs are distinct; flattening or removing these links is not a latency correction. Table count alone does not establish expensive requests. No foreign keys, security checks or critical triggers were removed.

One lightweight production **read-only** catalog/activity transaction, with a 2-second statement timeout, observed at **10:54:15 IST**: 18 client connections including inspection, 0 other active clients and 0 blocked sessions. Catalog index counts: orders19, riders13, pricing_config12, rider_assignments8, rider_kyc6, users3, pricing_zones2. Therefore missing explicit indexes in the pasted export must not be interpreted as missing indexes in production. Counts do not prove those indexes are ideal or justify dropping/adding them.

The activity snapshot is not peak-time or incident-onset evidence. No broad logs, business-table scans, production EXPLAIN ANALYZE or writes were performed. Existing evidence still shows pricing/config API outliers of approximately **13–19 seconds** in the user's earlier 09:54–10:04 IST window. Flutter corrections cannot eliminate backend queue/network time. Historical CPU/available RAM/swap/disk latency/IOPS/waiting-connection/compute-size evidence remains unavailable; Free plan as the initiating cause remains unproven.

## Verification and artifact

Focused Flutter/controller/privacy tests: **30 passed, 0 failed** (`build62-focused.log`). Full `flutter test --no-pub --reporter expanded`: **2,233 passed, 0 failed, 10 existing live-provider skips**, 2,243 total cases; runner duration 3m21s (`build62-full.log`). Previous completed suite was 2,232 passes; one actual-screen prefilled-navigation regression was added. Existing quote fixtures now explicitly start after route resolution; the new case exercises initial coordinates without seeding distance. No assertion was weakened.

Targeted analyzer over the four implementation files and two test files: **0 errors, 1 warning, 17 infos**, exit1; not a lint-clean run. The existing unused `finalFare` warning remains, with style/import/documentation/deprecation infos (`build62-analyzer.log`). Local logs are under `.dart_tool/waydrop-local-runtime/`. No managed-provider, native WebView or physical-phone performance pass is claimed.

The source freeze is [SOURCE_SHA256.json](build62-20261103/SOURCE_SHA256.json), and the build request is [BUILD_REQUEST.json](build62-20261103/BUILD_REQUEST.json). [Regression verification](build62-20261103/TEST_VERIFICATION.json). No production SQL/Edge/configuration/cron deployment is included. Prior combined SQL/Edge NO-GO requirements remain unchanged.

Verified local APK: [waydrop-1.0.0-build62.apk](../../artifacts/waydrop-1.0.0-build62.apk), **1.0.0(62)**, package `com.waydrop.app`. SHA256 `843ba7b998487aabb7a20ba57afb2b8b171305f9922c2e3604ebd287c81773f3`. Release build exit0, 513.36 seconds. Signature verifies and matches Build61; all three architecture AOT libraries differ from61; plaintext `.env` asset absent; all183 frozen source/config files unchanged during build. [APK verification](build62-20261103/APK_VERIFICATION.json). Build61 is retained. No installation or publishing was performed.

[Release scope](build62-20261103/RELEASE_SCOPE.json): 178 frozen files unchanged from61; changed screen, controller, diagnostics exporter and version; added the route timing helper. No other earlier frontend candidate silently joined this release. Flutter assessment: **conditional test release**, pending native phone/provider validation; SQL/Edge assessment remains **NO-GO for the combined candidate bundles**. Reverting the APK is the local rollback; no database rollback is necessary. Do not delete app data or queues just to benchmark.

Phone validation is required for real speed: install the verified Build62 artifact, confirm 1.0.0(62), exercise normal and repeat booking, observe first fare/Book readiness, rapid address changes, Cash/UPI and failure/Retry. No Android device was attached to ADB during this task. Installation, native frame timings, backend resource onset and zero end-to-end latency are not claimed.
