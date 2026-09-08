# WayDrop — Full Codebase Audit Report

**Scope:** ~120 Dart files under `lib/`, `test/`, plus Android/iOS platform config, `pubspec.yaml`, and `schema.sql`.
**Method:** `flutter analyze` (full static-analysis pass, 520 raw diagnostics), manual read-through of every `core/` service, `main.dart`/app bootstrap, payment/pricing/upload services, platform manifests, and a structural diff of the three near-duplicate booking verticals (local rides / local parcels / intercity). No code was modified.
**Severity key:** 🔴 High — crash, data loss, secret exposure, or broken store-submission blocker. 🟠 Medium — real bug or risk under realistic conditions, not guaranteed to trigger. 🟡 Low — cosmetic, maintainability, or lint-level.

---

## 1. Compile-Time Errors

`flutter analyze` reports **0 errors** — the project currently compiles cleanly. The items below are things that will only surface as failures under specific build/runtime conditions, not `flutter analyze` errors.

| File | Line | Explanation | Severity |
|---|---|---|---|
| `lib/main.dart` | 47–48 | `dotenv.env['SUPABASE_URL']!` and `dotenv.env['SUPABASE_ANON_KEY']!` use the null-assertion operator. If `.env` fails to load (missing file in a fresh clone, packaging error, or a key renamed/typo'd) this throws an uncaught `TypeError` before `runApp`, killing the app with a blank/native crash screen instead of a readable error. | 🟠 Medium |
| `ios/Runner/Info.plist` | whole file | Missing `NSLocationWhenInUseUsageDescription` / `NSLocationAlwaysAndWhenInUseUsageDescription`. The app calls `Geolocator` (incl. background tracking via `AppleSettings` in `location_cache_service.dart`) and iOS **terminates the process immediately** the first time location permission is requested if these keys are absent — this is not a soft failure, it's a hard crash and an App Store submission blocker. | 🔴 High |
| `ios/Runner/Info.plist` | whole file | Missing `NSCameraUsageDescription` / `NSPhotoLibraryUsageDescription`. `image_picker` is used for KYC uploads (`rider_kyc_upload_service.dart`) and parcel photos (`parcel_upload_service.dart`); invoking the picker without these keys crashes iOS the same way. | 🔴 High |

---

## 2. Runtime Bugs

Confirmed via `flutter analyze` warnings (dead/unreachable code, impossible comparisons) plus manual tracing.

| File | Line | Explanation | Severity |
|---|---|---|---|
| `lib/features/rider/intercity/intercity_bookings_screen.dart` | 105 | `dead_code` + `dead_null_aware_expression`: the right-hand side of a `??`/`?.` can never execute because the left operand can't be null in this branch — the intended fallback logic never runs. | 🟠 Medium |
| `lib/features/rider/intercity/intercity_bookings_screen.dart` | 107 | Same class of dead null-aware expression; a fallback branch is unreachable. | 🟠 Medium |
| `lib/features/intercity/shared/screens/intercity_tracking_screen.dart` | 111 | `unnecessary_null_comparison`: comparing a non-nullable value to `null`; the `if` always evaluates `true`, so whatever guard was intended (e.g. "no rider assigned yet") never fires. | 🟠 Medium |
| `lib/features/intercity/shared/screens/intercity_tracking_screen.dart` | 2462 | Same pattern — a null-guard that can never be false, meaning that code path is effectively unconditional. | 🟠 Medium |
| `lib/features/rider/orders/screens/rider_active_order_screen.dart` | 175 | `unnecessary_null_comparison` — guard condition always true, likely masking a state check that was supposed to gate UI/logic. | 🟠 Medium |
| `lib/features/intercity/parcels/booking/intercity_details_screen.dart` | 389 | `unnecessary_type_check` — a runtime `is` check always evaluates to `true`, so the `else` branch handling the "wrong type" case is unreachable dead code. | 🟡 Low |
| `lib/shared/screens/connection_error_screen.dart` | 44 | `unreachable_switch_default` — the `default:` case in a `switch` is provably unreachable because all enum values are already handled explicitly; harmless today but signals the switch is not exhaustive-safe against future enum additions (adding a new enum value would silently hit no branch instead of the intended default). | 🟡 Low |
| `lib/app_start_screen.dart` | 44–46, 48–247 | `listenAuthChanges()` subscribes to `supabase.auth.onAuthStateChange` and calls `checkUserFlow()` on every event, but `checkUserFlow` sets `_isChecking = false` *before* awaiting the (up to 800 ms) `changeScreen` transition. A second auth event arriving in that window re-enters `checkUserFlow` and can race two navigation flows against each other (e.g. double-push or a stale screen assignment). | 🟠 Medium |
| `lib/core/services/location/location_cache_service.dart` | 894–896, 900–932 | `_updateServiceableNotifier()` fires `updateServiceability()` without awaiting it, from multiple call sites (`_cachePosition`, `loadMockLocationFromPrefs`, `saveMockLocationToPrefs`, `clearCache`). Overlapping calls are not sequenced, so a slower in-flight network response can overwrite `serviceabilityStatus`/`isServiceableNotifier` with stale data after a newer call already resolved (last-response-wins instead of last-call-wins). | 🟠 Medium |
| `lib/shared/screens/connection_error_screen.dart` (interacting with `app_start_screen.dart`) | n/a | `checkUserFlow()` special-cases `if (currentScreen is ConnectionErrorScreen)` to force a splash replay, but the auth-listener re-entry path above can call `checkUserFlow` again while still mid-flight, so the "retry" button and the auth-state listener can both trigger overlapping fetches of the same profile data. | 🟡 Low |

---

## 3. UI / UX Issues

| File | Line | Explanation | Severity |
|---|---|---|---|
| `lib/features/rider/earnings/rider_earnings_tab.dart` | 1017–1018 | Uses `Radio`'s deprecated `groupValue`/`onChanged` (removed pattern post-3.32) instead of `RadioGroup`. Still works today but is flagged for removal; on a future Flutter upgrade this selector will silently stop responding to taps. | 🟡 Low |
| `lib/features/rider/settings/rider_settings_screen.dart` | 199 | `activeColor` on `Switch` is deprecated in favor of `activeThumbColor`; cosmetic today, breaks on Flutter's eventual removal. | 🟡 Low |
| `lib/features/user/profile/profile_tab.dart` | 1126 | Same deprecated `activeColor` usage on a `Switch`. | 🟡 Low |
| `lib/main.dart` | 138, 165 / `rider_earnings_tab.dart:1304` / `post_travel_plan_screen.dart:619,686` | `dialogBackgroundColor` on `ThemeData` is deprecated (use `DialogThemeData.backgroundColor`); dialogs across the app rely on a field that will stop being read in a future SDK bump, silently reverting all dialogs to the default background color. | 🟡 Low |
| Nearly every screen (≈150 occurrences across ~45 files, full list in `scratch/analyze_full.txt`) | various | `Color.withOpacity()` is deprecated app-wide in favor of `.withValues(alpha:)`. Beyond the deprecation itself, `withOpacity` on already-transformed colors causes the "precision loss" the lint warns about, which can produce visibly-off translucent overlays on some color spaces (Android 13+ wide-gamut displays). This is the single most repeated lint in the project. | 🟡 Low |
| `lib/features/intercity/parcels/booking/intercity_booking_screen.dart` | 970–977 | `screenBg`, `cardBg`, `circleBtnIcon` are computed (presumably for dark/light theming) but never used in the `build()` below — strongly suggests the screen doesn't actually adapt those elements to the current theme even though it looks like it's trying to. | 🟠 Medium |
| `lib/features/rider/orders/rider_orders_screen.dart` | 1442 | `boostPercentVal` is computed but unused — a "boost %" badge that was likely intended to show on the incoming-order card is missing from the render tree. | 🟠 Medium |
| `lib/main_navigation_screen.dart` | 51, 65 | `navBarBgColor` and `bottomPadding` are computed every build but never applied — the custom nav bar's background/safe-area padding doesn't actually track the values computed for it (dark/light theme or notch/gesture-bar insets may render incorrectly). | 🟠 Medium |
| `lib/features/local_parcels/booking/screens/parcel_details_screen.dart` | 87–88 | `_estimatedFare` / `_loadingFare` fields are set but never read by the widget tree — a fare/loading indicator likely doesn't actually appear on this screen despite the state existing for it. | 🟠 Medium |
| `lib/shared/helpers/location_display_service.dart`, `lib/core/location/utils/city_normalizer.dart` | n/a | Not wired into a visible "your city couldn't be detected" empty-state on several screens; `ServiceabilityStatus.unknown` is a modeled state (`serviceability_status.dart`) but several booking screens only branch on `serviceable` vs `notServiceable`, so users in the "unknown" state get default (serviceable) treatment rather than a clear message. | 🟡 Low |
| Rider tracking/searching screens (`ride_tracking_screen.dart`, `parcel_tracking_screen.dart`, `intercity_tracking_screen.dart`) | see §6 | Because these are near-duplicated files (see Duplicate Code), copy/paste drift means UX text and behavior have already diverged in small ways between verticals (e.g. background-tracking banner text differs, one has an extra `gradientPart` helper the other doesn't) — users bounce between a ride and a parcel flow that look almost, but not quite, consistent. | 🟡 Low |

---

## 4. Performance Problems

| File | Line | Explanation | Severity |
|---|---|---|---|
| `lib/core/services/maps/ola_map_service.dart` | 93–97, 147–156 | `_autocompleteCache`, `_reverseGeocodeCache`, `_geocodeCache`, `_routeCache`, `_placeDetailsCache` are static `Map`s that grow for the lifetime of the process with **no size cap, no LRU eviction, and no TTL**. A rider running the app for a full shift doing many searches will accumulate unbounded memory in these maps. | 🟠 Medium |
| `lib/core/services/location/location_cache_service.dart` | 411–422 | `AndroidSettings` for live rider tracking uses `LocationAccuracy.bestForNavigation`, a 5 m distance filter, a 10 s interval, **and** `enableWakeLock: true`. This is appropriately aggressive for active-trip tracking, but it is started for the whole time a rider is "online" (not just mid-trip), which will noticeably drain battery over a full shift — worth gating the highest accuracy tier to "on an active order" and falling back to a coarser mode while idle-online. | 🟠 Medium |
| `lib/main.dart` | 86, 100–105 | `debugPrint` is globally replaced with a no-op and the `print` zone is silenced *unconditionally* (not gated behind `kReleaseMode`), and `FlutterError.onError` / the `runZonedGuarded` error handler both only contain comments about wiring up Crashlytics/Sentry — nothing actually records fatal errors. In production this means **crashes and errors are invisible with no telemetry**, and in debug builds developers lose all `print`/`debugPrint` output for diagnosing issues, which will slow down every future debugging session on this codebase. | 🟠 Medium |
| Tracking/searching screens (`ride_tracking_screen.dart` 1900+ lines, `intercity_searching_screen.dart` 4144 lines, etc.) | whole files | Screens in the 2,000–4,000 line range are single giant `StatefulWidget`s building large widget trees inline (no `const` extraction for a lot of repeated card/row builders based on the analyzer's large "unused private builder method" counts, e.g. `_buildTimelineNode`, `_buildTimelineConnector`). Combined with `withOpacity` recomputing colors every rebuild, these screens do more rebuild work than necessary; splitting into smaller `const`-friendly widgets would meaningfully cut rebuild cost on such large trees. | 🟡 Low |
| `lib/core/services/cache/cache_service.dart` | whole file | Every `get`/`put` JSON-encodes/decodes through a Hive box on every call, with no in-memory front cache — fine for infrequent config reads, but if any hot path (e.g. per-frame or per-scroll-event) starts using this cache, it will show up as jank since Hive I/O + JSON (de)serialization happens synchronously on the calling isolate/thread for `get`. Not currently misused anywhere I found, flagged as a latent risk. | 🟡 Low |

---

## 5. Security Issues

This is the highest-impact section of the audit — several items are 🔴 High and should be treated as immediate action items regardless of how the rest of the report is prioritized.

| File | Line | Explanation | Severity |
|---|---|---|---|
| `android/app/build.gradle.kts` | 70–74 | A **live Ola Maps API key is hardcoded as a string literal** in a `buildConfigField`. This file is normal source-controlled Gradle config (unlike `.env`), so this key is committed to git the moment this file is committed/pushed anywhere. It is also dead code — no Dart file reads `BuildConfig.OLA_MAPS_API_KEY`; every call site reads `dotenv.env['OLA_MAPS_API_KEY']` instead — so it serves no purpose except exposure. **Rotate this key and delete the field.** | 🔴 High |
| `pubspec.yaml` | 95 | `.env` is declared under `flutter: assets:`, which packages the raw `.env` file **verbatim into the app bundle** (extractable from any release APK/IPA with `unzip`/`apktool` — no reverse-engineering skill required). This currently ships `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `OLA_MAPS_API_KEY`, `CASHFREE_APP_ID`, and **`CASHFREE_SECRET_KEY`** to every installed copy of the app. `CASHFREE_SECRET_KEY` in particular should never leave the server — Cashfree secret keys can create/refund payments and are meant to stay in the payment-service backend only. | 🔴 High |
| `.gitignore` | whole file | `.env` is **not listed**, so nothing currently stops it from being swept up by a future `git add .` / `git add -A`. The repo currently has no commits, so it hasn't happened yet, but there is no guard rail preventing it. | 🔴 High |
| `lib/core/services/maps/ola_map_service.dart` + 10 screen files (grep list in review notes) | multiple | `OLA_MAPS_API_KEY` is sent directly from the client to `api.olamaps.io` as a query parameter in ~12 call sites, with no backend proxy. Combined with the two findings above, this key is fully extractable and usable by anyone who downloads the app, enabling quota theft/billing abuse against the project's Ola Maps account. | 🟠 Medium |
| `test/network_chaos_verifier.dart` | 13–16 | The real Supabase project URL **and a live anon-key JWT** are hardcoded directly in a test file (rather than read from `.env`/a test fixture). Unlike `.env`, test files are ordinarily committed to git without a second thought, so this is actually the more likely of the two Supabase-credential leaks to end up in version control history. Anon keys are designed to be semi-public (protected by RLS), but hardcoding real production credentials in test source is still bad practice and should pull from environment/config instead. | 🟠 Medium |
| `android/app/src/main/AndroidManifest.xml` | 19 | `android:usesCleartextTraffic="true"` is set at the application level, disabling Android's default block on unencrypted HTTP traffic for the *entire app* (all domains), not just a specific dev endpoint. If every backend call is actually HTTPS today this has no live exploit, but it removes a platform-level safety net against any future accidental `http://` call or a misconfigured dependency, and is commonly flagged by mobile security scanners / enterprise MDM policies. | 🟠 Medium |
| `lib/core/services/cache/cache_service.dart` | 21–29 | The Hive "secure cache" encryption key is generated once and then stored in **plaintext `SharedPreferences`** (`hive_encryption_key`). `SharedPreferences` on Android is an unencrypted XML file and on iOS an unencrypted plist; storing the encryption key next to (functionally) the data it protects means the "encryption" only stops casual inspection of the Hive file itself, not anyone with file-system/backup access to the device. Should use `flutter_secure_storage` (Keystore/Keychain-backed) for the key. | 🟠 Medium |
| `lib/core/services/database/supabase_service.dart` | 52, 54 | Uses raw `print()` (not `debugPrint`) for `'USER SAVED'` / `'DATABASE ERROR: $e'`. Low severity on its own, but note this whole file appears to be dead code (see §7) reachable only if re-wired in later. | 🟡 Low |

---

## 6. Duplicate Code

This is the largest structural issue in the codebase. Three verticals — **local rides**, **local parcels**, and **intercity** — each ship their own copy of what is functionally the same tracking screen and searching screen, rather than one parameterized screen.

| Files | Lines | Explanation | Severity |
|---|---|---|---|
| `lib/features/local_rides/tracking/screens/ride_tracking_screen.dart` (1,961 lines) vs. `lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart` (1,875 lines) | whole files | A line-by-line diff shows these are ~95%+ identical: same class structure, same private helper methods (`_textGray`, `_openExternalGoogleMaps`, `_formatDate`, `_getCityName`, `_buildTimelineNode`, `_buildTimelineConnector` — all four flagged as *separately* unused by the analyzer in **both** files, at nearly the same line numbers), same map/webview rendering logic, differing only in class names, a couple of order-type branches, and one extracted `gradientPart` helper present in the parcel copy but not the ride copy. Any bug fix or feature change to trip tracking has to be manually applied 2–3× (a 3rd near-copy exists for intercity, 2,970 lines), and the drift already visible between them (e.g. the ride copy is missing the `gradientPart` extraction) shows fixes are *already* not being applied consistently. | 🔴 High |
| `lib/features/local_rides/searching/screens/ride_searching_screen.dart` (2,209 lines) vs. `lib/features/local_parcels/searching/screens/parcel_searching_screen.dart` (2,194 lines) vs. `lib/features/intercity/shared/screens/intercity_searching_screen.dart` (4,144 lines) | whole files | Diffing the two local-mode files produces only ~108 differing lines out of ~2,200 (roughly 95% identical). The intercity version is a further-diverged superset (double the size) covering the same "searching for a match" concept plus intercity-only concerns. This is the same pattern as the tracking screens: one concept, three maintained copies. | 🔴 High |
| `lib/core/services/location/location_permission_helper.dart` | 25–102 vs. 138–216 | The "GPS disabled" dialog and the "permission permanently denied" dialog are two near-identical ~80-line `AlertDialog` blocks (same styling, spacing, color logic, button layout) differing only in icon, title, body text, and the settings-opening call. Easily extracted into one shared `_buildInfoDialog({icon, title, body, actionLabel, onAction})` helper. | 🟡 Low |
| `lib/features/local_rides/tracking/screens/ride_tracking_screen.dart`, `lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart`, `lib/shared/screens/completed_order_details_screen.dart` | `_openExternalGoogleMaps` (each file, own copy) | The same "open this lat/lng in the external Google Maps app" helper is duplicated verbatim (and unused — see §7) in at least 3 files instead of living once in `shared/helpers`. | 🟡 Low |

---

## 7. Unused Code and Files

### Entirely unused files (no import references found anywhere in `lib/`)

| File | Explanation | Severity |
|---|---|---|
| `lib/shared/widgets/tilt_3d_container.dart` (`Tilt3DContainer`) | Zero references anywhere in `lib/`. Dead file. | 🟡 Low |
| `lib/models/map_search_result.dart` (`MapSearchResult`) | Zero references anywhere in `lib/`. Dead file. | 🟡 Low |
| `lib/core/services/database/supabase_service.dart` (`SupabaseService`) | Zero references anywhere in `lib/`; `main.dart` and the auth screens call Supabase directly instead. Also still contains the `print()` calls noted in §5. | 🟡 Low |

### Unused declarations flagged by the analyzer (representative — full list of ~40 in `scratch/analyze_full.txt`)

| File | Line | Explanation | Severity |
|---|---|---|---|
| `lib/features/local_rides/tracking/screens/ride_tracking_screen.dart` | 42, 347, 930, 935, 1150, 1181 | `_textGray`, `_openExternalGoogleMaps`, `_formatDate`, `_getCityName`, `_buildTimelineNode`, `_buildTimelineConnector` declared but never called. | 🟡 Low |
| `lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart` | 43, 355, 944, 949, 1137, 1168 | Same six unused declarations, duplicated (see §6). | 🟡 Low |
| `lib/features/intercity/shared/screens/intercity_tracking_screen.dart` | 380, 1482, 1513 | `_openExternalGoogleMaps`, `_buildTimelineNode`, `_buildTimelineConnector` unused here too. | 🟡 Low |
| `lib/features/intercity/parcels/dashboard/intercity_parcels_screen.dart` and `lib/features/intercity/rides/dashboard/intercity_rides_screen.dart` | 5–9 | Both files import `app_mode_provider.dart`, `mode_switch_overlay.dart`, `rider_status_service.dart`, `rider_main_navigation_screen.dart`, `rider_payout_details_screen.dart` and use none of them — five unused imports each, identically, in both files (further duplication evidence). | 🟡 Low |
| `lib/features/rider/profile/rider_profile_tab.dart` | 14 | Unused import of `order_chat_screen.dart`. | 🟡 Low |
| `lib/modules/support/screens/customer_support_screen.dart` | 3, 35 | Unused import of `order_chat_screen.dart`; unused local `primaryLime`. | 🟡 Low |
| `lib/modules/chat/screens/order_chat_screen.dart` | 659, 837, 1188 | `_buildIntercityHeader`, `_buildOrderPanel`, `_showAttachmentMenu` declared but never called — looks like an intercity-chat variant and an attachment menu that were built but never wired to a button. | 🟠 Medium |
| `lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart` | 145, 1214, 1251 | `_buildSpecTile`, `_buildSpecItem`, `_buildBottomStatTile` unused — likely leftovers from a UI iteration where a spec/stat section was replaced but the old builders weren't deleted. | 🟡 Low |
| `lib/core/services/session/feature_flag_service.dart` | 4, 38 | Unused import of `cache_service.dart`; `_isVersionCompatible` is a fully-implemented version-comparison method that is never called — remote flag fetching itself is also stubbed out as a no-op (`fetchFlags()`), so the whole remote feature-flag system is currently inert and running on hardcoded defaults only. | 🟠 Medium |
| `lib/core/services/session/user_session_service.dart` | 1 | Unused `dart:async` import. | 🟡 Low |
| `android/app/build.gradle.kts` | 70–74 | Entire `buildConfigField` for `OLA_MAPS_API_KEY` is unused dead code (also a security issue, see §5). | 🟡 Low |

---

## 8. Flutter / Dart Best-Practice Violations

| File | Line | Explanation | Severity |
|---|---|---|---|
| `lib/main.dart` | 85–105 | Silencing `debugPrint` and the zone `print` globally and unconditionally (not `if (kReleaseMode)`) removes a core debugging tool for the whole team in every build variant, and the "delegate to Sentry/Crashlytics" comments in `FlutterError.onError` / `runZonedGuarded` were never implemented — there is currently **no crash reporting at all** in this app. | 🟠 Medium |
| Multiple screens (`login_screen.dart`, `permissions_screen.dart`, `profile_setup_screen.dart`, `intercity_bookings_screen.dart`, `parcel_location_screen.dart`, `ride_location_screen.dart`, `rider_home_tab.dart`, `rider_active_order_screen.dart`, `travel_plan_details_screen.dart`, `profile_tab.dart`, `not_serviceable_screen.dart`, `order_chat_screen.dart`, `payment_service.dart`, `rider_profile_tab.dart`, `rider_earnings_tab.dart`, `home_location_screen.dart`) | ~35 call sites total (full list in `scratch/analyze_full.txt`) | `use_build_context_synchronously`: `BuildContext` used after an `await` without confirming the context is still valid via `context.mounted` immediately before use (some are "guarded by an unrelated `mounted` check" per the analyzer, meaning the check exists but doesn't actually guard the context use it's associated with). Can throw `'!_element!.mounted': is not true.` or silently operate on a disposed context if the user navigates away during the await. | 🟠 Medium |
| `lib/core/services/database/supabase_service.dart` | 52, 54 | `print()` instead of `debugPrint()` — bypasses the app's own log silencing/format and is flagged by `avoid_print`. | 🟡 Low |
| `lib/core/services/location/location_cache_service.dart`, `lib/core/services/maps/ola_map_service.dart`, `lib/modules/payments/services/payment_service.dart`, `lib/modules/payments/controllers/pricing_controller.dart` | whole files | Extremely fragmented line-wrapping (single tokens/short expressions broken across many lines, e.g. `static Position?\n cachedPosition;`) makes these core service files far harder to read/review/diff than the rest of the codebase — looks like an artifact of an aggressive auto-formatter or manual reformatting that wasn't run through `dart format`. Running `dart format lib/` would fix this mechanically. | 🟡 Low |
| `lib/core/services/location/location_cache_service.dart` | whole file | Entire service is a bag of `static` mutable fields/methods (global mutable state) rather than an instantiable, testable class — makes unit testing impossible without hitting real platform channels/singletons, and there's no way to have two independent instances (e.g. for testing or multi-account scenarios). | 🟡 Low |
| `lib/features/intercity/parcels/booking/intercity_details_screen.dart:136`, `lib/features/local_parcels/booking/screens/parcel_details_screen.dart:93`, `intercity_bookings_screen.dart:39-42`, `intercity_searching_screen.dart:79` | as listed | `prefer_final_fields`: several private fields (`_uploadedUrls`, `_negotiations`, `_upcomingTrips`, `_activeTrips`, `_history`, `_selectedDateFilter`) are never reassigned after construction and should be `final` — purely a maintainability/intent-clarity issue today. | 🟡 Low |
| `lib/shared/screens/connection_error_screen.dart` (dangling doc comments across ~15 files, e.g. `supabase_service.dart:1`, `ola_map_service.dart:1`, `ride_tracking_screen.dart:1`) | 1 | `dangling_library_doc_comments`: the `///` file-header doc blocks used throughout the codebase (a nice convention) aren't attached to a `library;` directive, so the analyzer treats them as dangling rather than actual library docs — a one-line `library;` per file would make them "count" as intended documentation. | 🟡 Low |
| `lib/features/rider/onboarding/services/rider_kyc_upload_service.dart` | 5 | Imports `path_provider`, which isn't declared as a direct dependency in `pubspec.yaml` (it's only present transitively). Works today by luck of a transitive dependency graph; a future dependency bump that drops that transitive path would break this file's imports with no warning until then. | 🟠 Medium |
| `lib/modules/payments/services/payment_service.dart` | 298 | Uses `CFDropCheckoutPaymentBuilder`, which the Cashfree SDK itself flags as deprecated/no-longer-supported in favor of `CFWebCheckoutPayment`. Continuing to build on a checkout API the vendor says isn't supported is a forward-compatibility risk for the app's entire payment flow. | 🟠 Medium |
| Project-wide | n/a | No `.gitignore` entry for `.env`, no CI/lint gate enforcing `dart format --set-exit-if-changed`, and no crash-reporting SDK wired up despite comments anticipating one — these are process/tooling gaps rather than single-file bugs, but they're the root cause behind several other findings in this report (secret exposure, inconsistent formatting, invisible production crashes). | 🟠 Medium |

---

## Priority Action List

If only a handful of items get fixed first, address these in order:

1. **Rotate the Ola Maps key hardcoded in `android/app/build.gradle.kts:70-74`** and delete the unused field.
2. **Remove `CASHFREE_SECRET_KEY` from the client `.env`** (and anything else server-only) — it should exist only in the Supabase Edge Function environment, never in an asset shipped to devices.
3. **Add `.env` to `.gitignore`** before this repo's first commit.
4. **Add the missing iOS `Info.plist` usage-description keys** (location, camera, photo library) — the app cannot ship to the App Store and will crash on first permission prompt without them.
5. Plan a consolidation of the ride/parcel/intercity tracking and searching screens into shared, parameterized widgets — the current 3× duplication is the biggest ongoing maintenance cost in the codebase.
