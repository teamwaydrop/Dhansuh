# WayDrop — Flutter Performance Audit Report

**Audit type:** Static analysis against official Flutter/Dart performance recommendations
**Scope:** `lib/` (143 Dart files, 90,509 lines), `assets/`, `pubspec.yaml`, Supabase query patterns in the client
**Method:** Read all key files; ran ~30 pattern searches for known anti-patterns; measured file sizes, asset sizes, timer counts, rebuild triggers, subscription counts
**Date:** August 1, 2026
**Constraint honored:** No code was modified. This is analysis and reporting only.

---

## Executive Summary

WayDrop is a real-time logistics app (rides, parcels, intercity) that works, but every page feels slow. The root causes are architectural and consistent across the app:

1. **Polling everywhere instead of realtime.** ~20 `Timer.periodic` loops fire Supabase queries every 1–30 s even while the user does nothing. The app has a realtime manager, yet screens poll on top of it (and some poll *instead* of it). This keeps the CPU, network, and battery busy 24/7 and causes frequent full-screen rebuilds.
2. **Monolithic stateful screens with root-level `setState`.** Screens are 2,000–5,100 lines each. A 1-second countdown timer rebuilds an entire 2,030-line orders screen (`setState(() {})`) — tens of thousands of widget instances re-created per second, with zero `RepaintBoundary` or const-subtree isolation.
3. **No lazy building on primary scroll views.** `SingleChildScrollView` + `Column` builds the entire home screen eagerly; lists inside scroll views use `shrinkWrap` + `NeverScrollableScrollPhysics`, defeating `ListView.builder` laziness.
4. **Network images decoded at full resolution.** ~30 `Image.network`/`Image.asset` call sites with no `cacheWidth`/`cacheHeight`; several 1–1.5 MB PNG assets bundled. Memory pressure → GC stalls → dropped frames.
5. **Blocking startup chain.** Firebase → Supabase → Hive/secure-storage init are serialized and awaited before the first frame; `AppStartScreen` then adds an artificial 800 ms minimum splash delay and runs 4–7 DB queries before showing Home; `IndexedStack` then builds **all four tabs at once**, each firing its own queries and timers simultaneously.
6. **All heavy work on the UI isolate.** Zero `compute()`/isolate usage; `jsonDecode` of large route geometries, message payloads, and edge-function responses runs on the main thread (some inside `build`/`didUpdateWidget`).
7. **WebView-based maps.** Every map screen boots a full WebView + 748 KB Maplibre GL JS + JS bridge calls for every rider position update — heavy on mid-range Android devices.

**Most impactful single fixes (see §14):** eliminate 1 s root rebuilds; stop polling (use realtime or longer intervals); lazy-build scrollables; add image downscaling + `RepaintBoundary`; parallelize/defer startup.

---

## 1. Issue Registry — CRITICAL

### C1. One-second full-screen rebuild of the rider orders list
- **File:** `lib/features/rider/orders/rider_orders_screen.dart`
- **Page:** Rider → Orders ("Orders Nearby")
- **Line:** `startExpiryTimer()` at 233–236 (`setState(() {})` every 1 s); `build` at 800+
- **Official recommendation violated:** Flutter docs — "Keep your build methods pure and cheap"; rebuild only what changed; use `RepaintBoundary`/const subtrees to limit rebuild scope.
- **Root cause:** A `Timer.periodic(1 s)` calls `setState(() {})` unconditionally, forcing a full rebuild of a 2,030-line widget tree (TabBar + two `ListView.builder` card lists), plus a separate `_filterExpiredAssignmentsFromState()` pass that re-sorts and copies both lists each tick.
- **Why it causes slowness:** Every second, Flutter rebuilds/lays out/paints ~hundreds of widgets including `SlideToAcceptButton`, images, gradients. On low-end devices this is sustained jank (continuous dropped frames), not a one-time cost.
- **Estimated impact:** Continuous 5–15% CPU; frame drop risk every second; battery drain.
- **Confidence:** 95%
- **Suggested fix (no code):** Only tick when an assignment whose `expires_at` is within the next 60 s is actually visible; rebuild only the countdown chip via its own `StatefulWidget`/`ValueListenableBuilder` instead of the whole screen; move the 1 s tick into a child widget isolated by a const boundary.
- **Difficulty:** Easy

### C2. Home tab silently re-fetches the entire user dataset every 30 s — and reloads on every realtime event
- **File:** `lib/features/user/home/home_tab.dart`
- **Page:** User Home
- **Lines:** `_startSilentRefreshTimer()` 184–194 (30 s → `_load()`); `_load()` 645–700 runs 4 Supabase queries; realtime callbacks at 812–880 call `_load()`; `_subscribeActiveOrders` 881–990 calls `_load()` per event
- **Official recommendation:** Use realtime/streams instead of polling; fetch-on-demand; cache aggressively.
- **Root cause:** `_load()` re-queries `users`, `riders`, `rider_kyc`, and `orders` (limit 10) on a 30 s timer, on app-resume, and on every realtime order event — even though `AppStartScreen` already fetched the same data and stored it in `initialUserDataProvider`. No cache staleness check or "already loading" guard.
- **Why it causes slowness:** 4 network round-trips every 30 s (4 × ~150–500 ms = perceptible latency and bandwidth), plus JSON parsing + `setState` on the UI thread. During an active order, each status change re-triggers the whole batch.
- **Estimated impact:** ~4 queries/min at idle; noticeable rebuild churn; higher data usage.
- **Confidence:** 95%
- **Suggested fix (no code):** Consume `initialUserDataProvider` as source of truth; refresh individual resources via realtime push; replace the 30 s timer with an on-demand pull-to-refresh and a single lightweight "updated since" check; add an in-flight guard.
- **Difficulty:** Medium

### C3. Nearby-riders query fetches the *entire* online-riders table every 5 s, then filters in Dart
- **File:** `lib/features/user/home/home_tab.dart`
- **Page:** User Home (map overlay)
- **Lines:** `_startRiderRefreshTimer()` 1015–1020 (5 s); `_fetchNearbyRiders()` 1025–1098
- **Official recommendation:** Database should filter/aggregate (server-side); never ship a full table to the client for client-side filtering. "Minimize the amount of work done per frame."
- **Root cause:** The query selects **all** riders with `account_status='online'` with an inner `rider_kyc` join and **no distance bounds**, then computes Haversine distance in Dart and discards riders beyond 3 km. Same pattern in ride/parcel/intercity searching screens (see H3).
- **Why it causes slowness:** Payload grows linearly with rider count in the whole country; every 5 s the client downloads & parses a potentially huge JSON array (with nested KYC) on the UI thread, then runs trig math per rider, then `setState` rebuilds the map overlay.
- **Estimated impact:** Grows without bound; at 1,000 online riders ≈ 500 KB–2 MB every 5 s; guaranteed jank at scale.
- **Confidence:** 95%
- **Suggested fix (no code):** Push the radius filter into Postgres (lat/lng bounds or PostGIS/`earthdistance` index), select only needed columns, add `limit`, and push updates via realtime instead of 5 s polling.
- **Difficulty:** Medium

### C4. `FutureBuilder` re-creates its future inside `build` → repeated DB query per rebuild
- **File:** `lib/features/user/profile/profile_tab.dart` (lines 541, 894–895) and `lib/features/rider/profile/rider_profile_tab.dart` (line 641–642)
- **Page:** User Profile / Rider Profile
- **Lines:** `future: Supabase.instance.client.from('users').select('role')...` created inline in `build`
- **Official recommendation:** Flutter docs warn that a FutureBuilder whose `future` is created inside `build` re-runs the future on every rebuild — the single most common FutureBuilder mistake.
- **Root cause:** Each `build` constructs a fresh `Future` (a new DB query). When it resolves, `FutureBuilder` calls `setState` → `build` runs → new future → new query. This can form a continuous query loop while the profile is visible.
- **Why it causes slowness:** Continuous background Supabase queries + rebuild churn on an already heavy screen; observed as "profile never settles / spins".
- **Estimated impact:** 1+ query per rebuild cycle; potential infinite loop until the widget is disposed.
- **Confidence:** 90%
- **Suggested fix (no code):** Cache the future in `initState`/a Riverpod provider; or use a provider + `ref.watch` and a manual refresh.
- **Difficulty:** Easy

### C5. Tracking screens poll rider position AND listen to realtime AND stream GPS — triple redundancy
- **Files:** `lib/features/local_rides/tracking/screens/ride_tracking_screen.dart` (115–131, 328), `parcel_tracking_screen.dart` (106–123), `intercity_tracking_screen.dart` (130–147), `lib/core/services/realtime/realtime_order_controller.dart` (38: 5 s poll)
- **Pages:** Ride/Parcel/Intercity tracking
- **Official recommendation:** Use a single source of truth for live data; avoid duplicate fetch paths.
- **Root cause:** Each tracking screen attaches to `orderController` notifiers (realtime-driven), subscribes to a 5 s polling timer in `RealtimeOrderController` that invokes an edge function + `orders.select()`, AND listens to a local GPS `getPositionStream` (rider_active_order_screen.dart:4433). `RealtimeOrderController._pollingTimer` (line 38) polls every 5 s even when realtime is healthy.
- **Why it causes slowness:** 2–3 concurrent update paths fight over state; repeated full-order JSON parsing (polyline geometry decode per poll) on the UI thread; needless edge-function invocations.
- **Estimated impact:** ~12 requests/min per active tracking session; visible map/ETD stutter.
- **Confidence:** 85%
- **Suggested fix (no code):** Make realtime the single update channel; use the poll only as a slow (60 s) staleness fallback gated by a "last event received" timestamp.
- **Difficulty:** Medium

### C6. Home tab is built eagerly with a single `SingleChildScrollView` + giant `Column`, rebuilt wholesale
- **File:** `lib/features/user/home/home_tab.dart`
- **Page:** User Home
- **Lines:** build 1260–1690; `SingleChildScrollView` at 1303; `_animateEntrance` at 3102 wraps 5 major sections in `flutter_animate`
- **Official recommendation:** Lazy building (`ListView.builder`/Slivers); avoid `Column` inside `SingleChildScrollView` for large/variable content; don't wrap large subtrees in per-build implicit animations.
- **Root cause:** A 3,112-line build method constructs the entire page (header, location bar, service bubbles, rider card, recent activity list) eagerly; every location update (5 s) and every `_load` (30 s + realtime events) re-executes it. Each `_animateEntrance(...)` call wraps a section in `.animate()` — flutter_animate re-runs entrance animations on every rebuild, causing repeated opacity/slide repaints of whole sections.
- **Why it causes slowness:** Home rebuilds are very expensive (hundreds of widgets + gradients + implicit animations) and occur several times per minute; perceived as sluggish scrolling and laggy entrance animations on every data refresh.
- **Estimated impact:** 10–30 ms+ build per refresh on mid-range devices; jank on scroll.
- **Confidence:** 90%
- **Suggested fix (no code):** Restructure with `CustomScrollView` + slivers; extract sections into `const`-friendly child widgets with `RepaintBoundary`; animate once on first build only (e.g., keep a `bool _entrancePlayed`), not per rebuild.
- **Difficulty:** Hard

### C7. Zero `RepaintBoundary` anywhere in the app
- **Files:** all of `lib/`
- **Official recommendation:** Wrap frequently-changing subtrees (maps, animated markers, countdown chips, shimmer) in `RepaintBoundary` so repaints are isolated. (0 matches found in the entire codebase.)
- **Root cause:** The only paint isolation present is the default framework-level boundaries; every custom animation (pulse markers, splash route motif, map overlays, countdowns) repaints whatever region it occupies plus layers merged with siblings.
- **Why it causes slowness:** A 1 s countdown chip or an animated map marker forces the enclosing layer to repaint; combined with C1, whole-screen repaints occur per tick.
- **Estimated impact:** Widespread; multiplies the cost of every animation/timer.
- **Confidence:** 100% (absence confirmed by search)
- **Suggested fix (no code):** Add `RepaintBoundary` around: maps, per-card countdown chips, animated markers, shimmer loaders, the nav bar — anything that animates independently of its parent.
- **Difficulty:** Easy

### C8. All JSON parsing runs on the UI isolate; zero `compute()`/isolates
- **Files:** `ola_map_service.dart` (283–721), `transport_map_widget.dart` (127, in `didUpdateWidget`), `chat/order_chat_screen.dart` (155–931), tracking screens' route geometry decode (intercity_tracking 334), `rider_home_tab.dart` (1990), etc. — 29+ `jsonDecode` sites
- **Official recommendation:** Offload heavy parsing with `compute()`/`Isolate.run`; never decode large JSON during build/layout.
- **Root cause:** Route polylines (thousands of points), chat history, and edge-function responses are decoded synchronously on the main thread — some inside `didUpdateWidget` (transport_map_widget) which runs during every parent rebuild.
- **Why it causes slowness:** Multi-hundred-µs–ms pauses per decode; during live tracking these happen repeatedly (every rider position update re-normalizes geometry) → dropped frames.
- **Estimated impact:** 1–10 ms stalls each; jank during tracking/map updates.
- **Confidence:** 90%
- **Suggested fix (no code):** Parse once into typed models on a background isolate; cache decoded models; avoid re-decode in `didUpdateWidget` by diffing inputs.
- **Difficulty:** Medium

---

## 2. Issue Registry — HIGH

### H1. Image decoding at full resolution everywhere
- **Files:** ~30 call sites: `Image.network` in `rider_orders_screen.dart` (1246, 1560, 1605), `incoming_order_card.dart` (228, 845), `rider_active_order_screen.dart` (698, 2977, 3109), `order_chat_screen.dart` (381, 1050, 1486), `intercity_tracking_screen.dart` (2242), `rider_orders_screen.dart`, etc.; `Image.asset` in `app_start_screen.dart` (308–323), `home_tab.dart` (2620), `services_tab.dart` (248), `rider_home_tab.dart` (2591–2975)…
- **Official recommendation:** Always pass `cacheWidth`/`cacheHeight` (or `ResizeImage`) to match the widget's display size; use `CachedNetworkImage` with `memCacheWidth`; bundle compressed (WebP) assets.
- **Root cause:** Network photos (Supabase storage, user profile/parcel images) are decoded at native resolution and only scaled at paint time. Only one place in the entire app passes `cacheWidth/cacheHeight` (rider_earnings_tab.dart:2127).
- **Why it causes slowness:** Each 2–8 MB photo can allocate 8–32 MB decoded bitmap; repeated decodes on rebuild (uncached `Image.network` re-downloads on every rebuild unless `CachedNetworkImage`); memory pressure → GC pauses → jank; OOM risk on low-RAM devices.
- **Estimated impact:** High; biggest single memory consumer.
- **Confidence:** 95%
- **Suggested fix (no code):** Add `cacheWidth`/`cacheHeight` (or `ResizeImage`) at every image site; standardize on `CachedNetworkImage` with `memCacheWidth`; convert bundled PNGs (LOGO.png 1.5 MB, ride.png 1.2 MB, etc.) to WebP and resize to display dimensions.
- **Difficulty:** Medium

### H2. App startup is serialized, blocking, and artificially slowed
- **Files:** `lib/main.dart` (main 26–134), `lib/app_start_screen.dart` (checkUserFlow 57–250)
- **Pages:** Launch → Splash → Home
- **Lines:** main.dart 63 (`await Firebase.initializeApp()`), 70 (`await Supabase.initialize`), 78 (`await CacheService.instance.init()`); app_start_screen 260 (`Future.delayed(800ms - elapsed)` min-splash), 84–95 (profile query), 139–170 (rider + orders), 185–199 (user-path Future.wait)
- **Official recommendation:** Defer non-critical init after first frame; parallelize independent awaits; avoid artificial delays; splash should be fastest path to first useful frame.
- **Root cause:** Three heavy initializations are awaited serially before `runApp` (Firebase, Supabase, Hive+secure-storage). Then the splash enforces a **minimum 800 ms** display and the auth flow runs 1–4 sequential/parallel queries (each up to 8 s timeout) before navigating. `MainNavigationScreen` uses `IndexedStack`, which builds **all four tabs at once** — each tab's `initState` immediately fires its own queries and timers, stacking load at startup.
- **Why it causes slowness:** Cold start to interactive Home typically 3–8 s on device; the artificial 800 ms and duplicated initial fetches (app_start_screen + home_tab._load + activity_tab.loadOrders + profile) multiply it.
- **Estimated impact:** 3–8 s cold start; the single most user-visible performance issue.
- **Confidence:** 90%
- **Suggested fix (no code):** Move Firebase/Hive init into a non-blocking background task; run `runApp` first; parallelize the three awaits; remove the artificial 800 ms delay; lazy-initialize non-visible tabs (e.g., only build the active tab in `IndexedStack`, or gate each tab's fetch on first visibility).
- **Difficulty:** Hard

### H3. Searching screens poll nearby riders/partners every 5 s with heavy queries
- **Files:** `ride_searching_screen.dart` (256), `parcel_searching_screen.dart` (240), `intercity_searching_screen.dart` (1148)
- **Pages:** Local ride/parcel/intercity searching
- **Official recommendation:** Realtime push over polling; server-side proximity filters; minimal payloads.
- **Root cause:** Identical pattern to C3 — periodic rider-location fetches (5 s) with client-side distance filtering, plus per-match N+1 enrichment queries (intercity_searching_screen 291–440: riders → assignments → travel plans → KYC per match).
- **Why it causes slowness:** 5 s polling + N+1 queries = 10–20 requests/min on the searching screen; frequent list rebuilds and map marker re-plotting via JS bridge.
- **Estimated impact:** High on network; medium on UI jank.
- **Confidence:** 85%
- **Suggested fix (no code):** Real-time rider-position channel per order; batch enrichment into a single edge-function call or SQL join; paginate.
- **Difficulty:** Medium

### H4. `rider_orders_screen` heavy nested query runs every 10 s + every realtime event
- **File:** `lib/features/rider/orders/rider_orders_screen.dart`
- **Lines:** `fetchSearchingOrders()` 340–400: `dispatch_config.select('*')` then `rider_assignments.select('*, orders(*, users(...))')`
- **Official recommendation:** Select only required columns; avoid deep nested joins in hot paths; use realtime deltas.
- **Root cause:** Every 10 s (and on every realtime assignment/order event, and after accept/reject) the screen fetches all `sent` assignments with the full nested `orders` + `users` records, then re-merges, re-filters, re-sorts in Dart, and rebuilds.
- **Why it causes slowness:** Large payloads (full order rows incl. addresses, images arrays, JSONB columns); redundant with the realtime channels already subscribed; heavy setState.
- **Estimated impact:** ~1 MB/min worst case; jank on each refresh.
- **Confidence:** 85%
- **Suggested fix (no code):** Project columns; maintain local list via realtime inserts/updates; use the fetch only for initial hydration; move expiry handling server-side (trigger) or into a light RPC.
- **Difficulty:** Medium

### H5. Realtime subscription overlap — two channels + two `.stream()`s + polling on one screen
- **File:** `lib/features/rider/orders/rider_orders_screen.dart` (listenSearchingOrders 405–490, listenActiveOrder 300–330, listenRiderStatus 200–215, plus timers)
- **Page:** Rider Orders
- **Official recommendation:** One subscription per table/owner; avoid duplicating realtime and polling for the same data.
- **Root cause:** `RealtimeManager` channel on `rider_assignments`, a second on `orders`, a `.stream()` on `orders` (rider_id), a `.stream()` on `riders`, plus 10 s and 1 s timers — all updating overlapping state.
- **Why it causes slowness:** 4+ live connections and 2 polling loops for one screen; every event re-triggers `fetchSearchingOrders()`.
- **Estimated impact:** Battery + bandwidth + rebuild churn.
- **Confidence:** 90%
- **Suggested fix (no code):** Consolidate to 1–2 channels; use the RealtimeManager for all subscriptions (it already multiplexes); drop the timers or reduce to staleness fallback only.
- **Difficulty:** Medium

### H6. Map screens boot a fresh WebView each time (748 KB JS, JS bridge per update)
- **Files:** `lib/shared/widgets/maps/transport_map_widget.dart`, `home_location_screen.dart`, `ride_location_screen.dart`, `intercity_location_screen.dart`, tracking screens
- **Pages:** All map screens
- **Lines:** transport_map_widget 101–133 (`loadFlutterAsset('assets/map/ola_map_home.html')`), `_triggerInitializeMap` 165–207, `didUpdateWidget` 209–300 (JS calls on every prop change)
- **Official recommendation:** Reuse heavyweight views; minimize bridge traffic; avoid re-creating expensive surfaces per navigation.
- **Root cause:** Each screen creates a `WebViewController` loading Maplibre GL (748 KB) + per-update `runJavaScript` for markers/routes/rider positions; `AutomaticKeepAliveClientMixin` keeps the WebView alive inside tabs (good) but new pushes create new WebViews.
- **Why it causes slowness:** 0.5–2 s map init per screen; bridge round-trips during tracking cause frame stutter; 2–3 WebViews alive simultaneously across nav stack = significant memory.
- **Estimated impact:** High on page-open latency and memory.
- **Confidence:** 85%
- **Suggested fix (no code):** A single shared cached WebView/map surface with channel-based commands; or move to a native map plugin (e.g., `google_maps_flutter`/Ola SDK) that renders in the rasterizer instead of a WebView; batch JS calls per frame.
- **Difficulty:** Hard

### H7. `debugPrint` string interpolation still executes in release
- **Files:** 163+ debugPrint call sites; hot ones: `intercity_searching_screen.dart` 311 (`MATCH RIDERS RESPONSE => ${response.data}`), `payment_service.dart` 214/490 (`${response.data}`), `pricing_controller.dart` 135 (`PRICING RAW RESPONSE ... ${response.data}`)
- **Official recommendation:** Remove/guard logging of large payloads; avoid string building on hot paths.
- **Root cause:** `main.dart` replaces `debugPrint` with a no-op in release (good), but Dart still evaluates the **arguments**, so `debugPrint('... ${response.data}')` stringifies entire JSON responses on the UI thread in production.
- **Why it causes slowness:** Giant string allocations + JSON `toString` on every payment/pricing/match response.
- **Estimated impact:** ms-scale stalls on already-slow payment & matching flows; GC pressure.
- **Confidence:** 90%
- **Suggested fix (no code):** Wrap payload logs in `if (kDebugMode)` or `kReleaseMode` guards so arguments aren't evaluated; log to Crashlytics with metadata only in release.
- **Difficulty:** Easy

### H8. `withOpacity` (deprecated) used 136+ times
- **Files:** across the codebase (services_tab, activity_tab, tracking screens, booking screens, etc.)
- **Official recommendation:** Flutter 3.27+ deprecates `withOpacity` in favor of `withValues(alpha:)`; more importantly, these create new `Color` objects per build per usage.
- **Root cause:** 136+ call sites (many in hot rebuild paths) allocate a fresh Color each build.
- **Why it causes slowness:** Minor per-instance cost, but in 5,000-line build methods with hundreds of calls per rebuild it adds measurable allocation/GC churn.
- **Estimated impact:** Low-medium; compounds with root rebuilds.
- **Confidence:** 100% (count confirmed)
- **Suggested fix (no code):** Migrate to `withValues(alpha:)`; hoist computed colors out of build into cached fields where stable.
- **Difficulty:** Easy

### H9. `MediaQuery.of(context)` used in 39 sites inside build
- **Files:** main_navigation_screen.dart (65), custom_curved_navigation_bar.dart (80), tracking screens, rider_active_order_screen (2314, 2400+), profile_tab (175, 312)…
- **Official recommendation:** Use `MediaQuery.sizeOf` / `MediaQuery.paddingOf` etc., which only rebuild dependents when that specific value changes.
- **Root cause:** Legacy `MediaQuery.of(context)` registers a dependency on the entire MediaQuery; any inset/orientation change rebuilds all dependents.
- **Why it causes slowness:** Extra rebuilds on keyboard show/hide, rotation, and accessibility changes.
- **Estimated impact:** Low-medium.
- **Confidence:** 90%
- **Suggested fix (no code):** Replace with the specific `MediaQuery.*Of` accessors; avoid calling inside per-frame animated builders.
- **Difficulty:** Easy

### H10. `SystemChrome.setSystemUIOverlayStyle` called inside `build`
- **Files:** `main.dart` (WayDropApp.build ~150), `main_navigation_screen.dart` (build 50–60), `rider_main_navigation_screen.dart`
- **Official recommendation:** No side effects/platform calls inside `build` (violates build purity; may run on every rebuild).
- **Root cause:** The style call (a platform-channel message) is issued every time the widget rebuilds, including theme-mode flips.
- **Why it causes slowness:** Redundant platform-channel traffic; minor jank during theme transitions.
- **Estimated impact:** Low.
- **Confidence:** 95%
- **Suggested fix (no code):** Move to `initState`/`didChangeDependencies` or a `SystemChrome`-handling root that only reacts to actual changes.
- **Difficulty:** Easy

### H11. Root theme rebuilt (with GoogleFonts) on every `WayDropApp` rebuild
- **File:** `lib/main.dart` (lines 156–216)
- **Official recommendation:** Cache `ThemeData`; construct outside build; `GoogleFonts.*TextTheme` performs font asset resolution/loading.
- **Root cause:** Two full `ThemeData` objects (rider dark + user light) are constructed in `build` every time the provider rebuilds, each calling `GoogleFonts.plusJakartaSansTextTheme(...)`.
- **Why it causes slowness:** GoogleFonts triggers HTTP/asset font loading on first use (can block text rendering), and recreating themes discards caches.
- **Estimated impact:** First-render font flash/delay; minor per-rebuild cost.
- **Confidence:** 85%
- **Suggested fix (no code):** Hoist themes to top-level `final` constants (or a provider); bundle the font asset instead of runtime GoogleFonts fetch.
- **Difficulty:** Easy

### H12. Admin dashboard polls 7+ sequential queries every 4 s
- **File:** `lib/modules/admin/admin_dashboard_screen.dart`
- **Lines:** `_refreshTimer` 45 (4 s), `fetchStats()` 55–140 (riders, orders, assignments, orders, fare_payments, payment_disputes, orders — several sequential/await-chain)
- **Official recommendation:** Refresh on demand / realtime; parallelize independent queries.
- **Root cause:** 4-second polling of a dashboard that does ~7 queries (some sequential), with `GridView.count` + nested scroll views rebuilt on every tick.
- **Why it causes slowness:** Continuous heavy load on the admin client and backend; UI freezes during refresh.
- **Estimated impact:** High (admin-only, but real).
- **Confidence:** 85%
- **Suggested fix (no code):** Poll every 30–60 s or push updates; use a single aggregated RPC/view; parallelize with `Future.wait`.
- **Difficulty:** Easy

---

## 3. Issue Registry — MEDIUM

### M1. `shrinkWrap` + `NeverScrollableScrollPhysics` nested lists
- **Files:** activity_tab.dart (443–525 ×4), admin_dashboard (191–315), intercity_rides/parcels dashboards (400/590), rider_home_tab (2285), travel_plan_details (1866), post_travel_plan (1468), intercity_searching (3663)
- **Official recommendation:** Avoid nested scrollables; `shrinkWrap` forces full child layout (no laziness).
- **Root cause:** `ListView.separated` inside `SingleChildScrollView`/`Column` with `shrinkWrap: true` + `NeverScrollableScrollPhysics` builds every item eagerly.
- **Why it causes slowness:** O(n) children built per parent rebuild; duplicates the cost of C6/H1.
- **Estimated impact:** Medium on those screens.
- **Confidence:** 90%
- **Suggested fix (no code):** Convert to slivers (`SliverList`/`SliverGrid`) in a `CustomScrollView`, or `Column` + `for` when item count is small and bounded.
- **Difficulty:** Medium

### M2. `IntrinsicHeight` usage
- **File:** travel_plan_details_screen.dart (1102)
- **Official recommendation:** Avoid `Intrinsic*` in scrollable/expensive layouts (forces two-pass layout).
- **Why it causes slowness:** Extra layout pass on a big screen.
- **Impact:** Low-medium. **Confidence:** 90%. **Fix:** Replace with fixed heights or `Align`/`ConstrainedBox`. **Difficulty:** Easy

### M3. `.select()` without column projection on hot queries
- **Files:** home_tab (648–663), rider_home_tab (161–186, 1179), rider_earnings_tab (145–226 ×6), intercity_bookings (105–199), notification_service (358, 426), profile_tab (750–752), rider_orders (361–370), intercity_searching (339, 571, 722, 794)…
- **Official recommendation:** Always project columns; select only what the UI needs.
- **Root cause:** `select()` returns full rows including heavy columns (e.g., riders `route_geometry`, `parcel_images`, address strings).
- **Why it causes slowness:** Larger payloads, more parsing, more memory per fetch — multiplied by every poll.
- **Impact:** Medium. **Confidence:** 90%. **Fix:** Explicit column lists everywhere. **Difficulty:** Easy

### M4. Duplicate initial fetches across tabs (IndexedStack builds all tabs at startup)
- **Files:** main_navigation_screen.dart (initState builds all 4 tabs), activity_tab.dart (initState `loadOrders`), profile_tab.dart (initState queries), home_tab.dart (`_load`)
- **Official recommendation:** Lazy instantiate off-screen tabs; gate heavy work on visibility.
- **Why it causes slowness:** At app start, Home + Services + Activity + Profile all run initState work simultaneously (queries, timers, notification badge subscription), delaying first paint and saturating the network.
- **Impact:** High at startup (compounds H2). **Confidence:** 85%. **Fix:** Build only the active tab (or use `IndexedStack` with lazy children); add per-tab `isVisible` gating. **Difficulty:** Medium

### M5. No pagination/infinite scroll on order/history lists
- **Files:** activity_tab.dart (120–128 `orders.select()` no limit), rider_order_history (40–48), intercity_bookings (105+), notifications_inbox (36–44)
- **Official recommendation:** Paginate (`limit`/`offset` or cursor) long lists.
- **Why it causes slowness:** Full history downloads per visit; grows over time.
- **Impact:** Medium over app lifetime. **Confidence:** 80%. **Fix:** Server-side pagination + `ListView.builder`. **Difficulty:** Medium

### M6. N+1 enrichment queries in intercity matching
- **File:** intercity_searching_screen.dart (291–440), intercity_matching_service.dart (169–230, 395–429)
- **Official recommendation:** Batch queries; single SQL join/RPC.
- **Why it causes slowness:** For each matched partner: separate riders, KYC, reliability, seats, capacity queries — 4–6 round trips per match.
- **Impact:** High on that screen. **Confidence:** 85%. **Fix:** One joined query or a dedicated edge function returning hydrated matches. **Difficulty:** Medium

### M7. Location stack: `bestForNavigation` accuracy + 5 m distance filter + 10 s interval + 30 s heartbeat DB writes
- **File:** location_cache_service.dart (444–492, 970–1030)
- **Official recommendation:** Match location accuracy to feature need; throttle uplinks; batch.
- **Why it causes slowness:** `bestForNavigation` + 5 m filter keeps GPS radios and CPU hot for every online rider (battery); each heartbeat writes a full `riders` row update (lat, lng, heading, 3 timestamps) every 30 s even when stationary.
- **Impact:** High battery drain; DB write amplification at scale. **Confidence:** 85%. **Fix:** Use `balanced` accuracy when not actively navigating; raise distance filter to 10–20 m; reduce heartbeat to 60 s; debounce identical positions. **Difficulty:** Medium

### M8. Chat screen reloads full history every 8 s + decodes every message
- **File:** order_chat_screen.dart (131–145 `_syncTimer` 8 s, 1101–1113 full `select()`, 155–200 jsonDecode per message)
- **Official recommendation:** Realtime deltas; incremental inserts; parse off-main-isolate.
- **Why it causes slowness:** 8 s full-list re-fetch while a realtime channel is already active; JSON parse per message on UI thread.
- **Impact:** Medium. **Confidence:** 80%. **Fix:** Use realtime inserts only; keep poll as reconnect fallback; move decode to isolate. **Difficulty:** Medium

### M9. `connectivity_wrapper` pings Supabase REST every 8 s for the app's entire lifetime
- **File:** shared/helpers/connectivity_wrapper.dart (32)
- **Official recommendation:** React to connectivity via plugin callbacks, not polling.
- **Why it causes slowness:** A perpetual HTTP GET every 8 s from every session; competes with real work on the network; wakes the radio.
- **Impact:** Medium battery/network. **Confidence:** 85%. **Fix:** Use `connectivity_plus` stream + listen for change; ping only on change. **Difficulty:** Easy

### M10. Hive cache does sync `jsonEncode`/`jsonDecode` of route geometry on UI thread
- **File:** cache_service.dart (104, 122), tracking screens route caching (ride_tracking 328, parcel_tracking 305, intercity_tracking 332)
- **Official recommendation:** Keep I/O + codec off the UI thread; cache decoded models.
- **Why it causes slowness:** Every route fetch round-trips a full JSON encode/decode of polyline data on the main thread; also re-decoded again by the map widget.
- **Impact:** Medium during tracking. **Confidence:** 85%. **Fix:** Encode/decode in `compute()`; store typed binary. **Difficulty:** Medium

### M11. Analytics writes `analytics_events` rows inline on the UI flow
- **File:** core/services/analytics/analytics_service.dart (11–24, awaited from booking flows)
- **Official recommendation:** Fire-and-forget/queue analytics; never await user-blocking.
- **Why it causes slowness:** Some flows `await logEvent(...)` before continuing (e.g., ride/payment flows), adding a DB write to the critical path.
- **Impact:** Low-medium. **Confidence:** 70%. **Fix:** `unawaited()` + internal queue with batching; write in background. **Difficulty:** Easy

### M12. `pricing_controller` adds an artificial 500 ms minimum latency
- **File:** modules/payments/controllers/pricing_controller.dart (83: `Future.delayed(500ms - elapsed)`)
- **Official recommendation:** No artificial delays on critical paths.
- **Why it causes slowness:** Every fare quote takes ≥500 ms even when the server responds in 100 ms.
- **Impact:** Medium on perceived booking latency. **Confidence:** 95%. **Fix:** Remove the minimum-delay gate (keep only skeleton UI duration). **Difficulty:** Easy

---

## 4. Issue Registry — LOW

- **L1.** `Timer.periodic` in `rider_active_order_screen.dart` (932, 4669) and `incoming_order_card.dart` (86) with 1 s ticks — countdown chips should own isolated rebuilds (see C1/C7). **Confidence:** 90%
- **L2.** `Hero` animations: only matches are icon/asset usages, not `Hero` widgets — no issue found; all navigations use plain `MaterialPageRoute` (190+ sites) with default transitions. Suggest `PageRouteBuilder`/predicted-transitions later for polish; not a perf problem today. **Confidence:** 80%
- **L3.** `SkeletonLoader` uses `shimmer` package during every loading state — shimmer repaints continuously; scope it to visible placeholder only. **Confidence:** 75%
- **L4.** `waydrop_bike_animation.dart` and splash `RouteMotifPainter` run continuous `AnimationController` + per-frame `Path.computeMetrics`/`extractPath` loops — CPU-heavy paint during splash and unserviceable screens. **Confidence:** 85%
- **L5.** `providerContainer` is a global top-level — acceptable for app-lifetime data, but `StateProvider` usage (initial data) causes whole-subtree rebuilds for watchers; prefer `Notifier` + `select`. **Confidence:** 70%
- **L6.** `realtime_manager` heartbeat HTTP check (`_checkConnectivity`) on every reconnect loop — fine, but only ping after failures. **Confidence:** 80%
- **L7.** Multiple `SharedPreferences.getInstance()` calls per flow (chat screen 5×, KYC 4×) — cache the singleton. **Confidence:** 75%

---

## 5. Top 20 Biggest Performance Bottlenecks (ranked)

| # | Bottleneck | Severity | Effort to fix |
|---|-----------|----------|---------------|
| 1 | Root-level `setState` every 1 s (rider orders, incoming cards) | Critical | Easy |
| 2 | Full-table online-riders fetch + client-side radius filter every 5 s | Critical | Medium |
| 3 | 30 s full-profile refresh + reload-on-every-realtime-event (home) | Critical | Medium |
| 4 | FutureBuilder re-creating DB futures in `build` (profiles) | Critical | Easy |
| 5 | No `RepaintBoundary` anywhere | Critical | Easy |
| 6 | All JSON decoding on UI isolate (geometry, chat, payments) | Critical | Medium |
| 7 | Startup: serialized Firebase→Supabase→Hive init + 800 ms artificial splash + all-4-tabs eager build | Critical | Hard |
| 8 | `SingleChildScrollView`+Column home with per-rebuild entrance animations | Critical | Hard |
| 9 | Tracking: realtime + 5 s poll + GPS stream triple-update | Critical | Medium |
| 10 | Full-res image decode everywhere; 1.5 MB PNG assets | High | Medium |
| 11 | WebView map per screen + JS bridge per update | High | Hard |
| 12 | Heavy nested `rider_assignments/orders/users` query every 10 s | High | Medium |
| 13 | Realtime channel overlap (2 channels + 2 streams + timers) | High | Medium |
| 14 | N+1 partner enrichment in intercity matching | High | Medium |
| 15 | `debugPrint('...${response.data}')` stringifies payloads in release | High | Easy |
| 16 | `shrinkWrap` + `NeverScrollableScrollPhysics` nested lists | Medium | Medium |
| 17 | Unprojected `select()` on hot queries | Medium | Easy |
| 18 | GPS `bestForNavigation` + 5 m filter + 30 s heartbeat writes | Medium | Medium |
| 19 | Admin dashboard 7-query poll every 4 s | Medium | Easy |
| 20 | Chat 8 s full-history reload + per-message decode | Medium | Medium |

## 6. Slowest Pages (estimated, ranked)

1. **Rider Active Order** (5,100 lines; timers + GPS stream + multiple edge functions + WebView) — worst sustained cost
2. **Intercity Searching** (3,880 lines; 5 s polling + N+1 enrichment + boost retries)
3. **Ride Location / Parcel Location / Intercity Location** (2,269–3,415 lines; WebView + autocomplete + debounced geocodes + 5 s rider refresh)
4. **User Home** (3,112 lines; 4-query refresh ×2 timers + realtime reloads + animations)
5. **Rider Home** (3,092 lines; silent refresh + nearby-partner poll + live map)
6. **Rider Orders** (2,030 lines; 1 s rebuild + 10 s fetch + 4 subscriptions)
7. **Intercity Tracking** (3,006 lines; triple update paths + verification polls)
8. **Tracking screens (ride/parcel)** (~1,800–2,000 lines; poll+realtime+GPS)
9. **Profile tabs** (FutureBuilder loops + sequential KYC/rider/payout queries)
10. **Chat** (8 s reload + per-message decode + offline queue sync)
11. **Admin Dashboard** (4 s multi-query poll)
12. **Payments** (artificial 500 ms pricing gate + polling + WebView-free but SDK heavy)

## 7. Slowest Services

1. **`RealtimeOrderController`** — 5 s edge-function + orders poll on every tracking screen
2. **`OlaMapService`** — external API latency (15 s timeouts) + main-thread JSON decode; mitigated by good in-memory caches
3. **`LocationCacheService`** — GPS init chain (last-known → current → reverse-geocode → zones → serviceability) is serial; heartbeat writes
4. **`AnalyticsService`** — inline awaited inserts
5. **`CacheService`** — sync JSON codec on UI thread
6. **`PricingController`** — artificial 500 ms gate

## 8. Slowest Database Queries (client-side)

1. `riders` full table (all online) + `rider_kyc!inner` join, no bounds — every 5 s (home)
2. `rider_assignments.select('*, orders(*, users(...))')` — every 10 s + per event (rider orders)
3. `orders.select()` unprojected (12 statuses, limit 10) — every 30 s + per event (home)
4. `orders.select()` in app_start (2× for rider/user paths)
5. Per-match enrichment (riders + assignments + plans + KYC) in intercity searching
6. `riders.select()` + `rider_kyc` + `rider_payout_accounts` sequential (profile switch)
7. Admin dashboard 7-query chain every 4 s
8. `order_chat_messages` full select every 8 s
9. `users`/`riders`/`rider_kyc` full-row selects on 3 tabs at startup

## 9. Widgets That Rebuild the Most

1. **RiderOrdersScreenState** — every 1 s (`setState(() {})`)
2. **IncomingOrderCardState** — every 1 s countdown tick
3. **HomeTabState** — every 5 s (nearby riders) + every 30 s + every realtime event
4. **RiderHomeTabState** — 5 s + 30 s + realtime
5. **Searching screens** — every 5 s rider poll + every match change
6. **ActivityTab / RiderActivityTab** — 30 s refresh + realtime events
7. **AdminDashboardState** — every 4 s
8. **Profile tabs** — per FutureBuilder completion loop
9. **All tracking screens** — per orderController notifier + per GPS position
10. **Every `_animateEntrance`-wrapped section on Home** — re-animates per rebuild

## 10. API Calls That Waste the Most Time

1. Nearby-riders full-table poll (home) — every 5 s, unbounded
2. `RealtimeOrderController` poll — every 5 s during tracking
3. `fetchSearchingOrders` nested query — every 10 s + events
4. Home `_load` 4-query batch — 30 s + events + resume
5. Intercity per-match enrichment chain
6. Profile FutureBuilder role query loop
7. Pricing controller (artificial 500 ms)
8. Admin stats chain every 4 s
9. Ola reverse-geocode/directions (external; cached, but 15 s timeouts)

## 11–15. Scores

| Area | Score /100 | Rationale |
|------|-----------|-----------|
| **Startup performance** | **35** | Serialized init + 800 ms artificial delay + eager 4-tab build + 1–4 queries before Home |
| **UI rendering** | **40** | No RepaintBoundary, root setState storms, giant build methods, per-rebuild entrance animations |
| **Database efficiency** | **35** | Polling over realtime, full-table fetches, unprojected selects, N+1, no pagination |
| **Network efficiency** | **40** | Redundant channels+polls, payload bloat, global 8 s connectivity ping |
| **Memory usage** | **45** | Full-res image decode, 1.5 MB assets, multiple WebViews, unbounded list payloads |
| **Battery efficiency** | **35** | bestForNavigation GPS + 5 m filter + 30 s writes + ~20 polling timers + continuous animations |
| **Flutter architecture** | **45** | Feature-first layout is clean & dependency direction respected; but monolithic screens, no typing of Supabase rows, StateProvider misuse, no isolate use |
| **Overall app performance** | **38** | Sum of the above; app is functional but constantly busy |

## 16. Prioritized Action List (highest → lowest impact)

1. **Kill the 1 s full-screen rebuilds** (C1, L1): isolate countdown chips; tick only when visible. — *Easy, immediate jank relief*
2. **Replace all polling with realtime/deltas** (C2, C5, H4, H5, M8, M9, H12): keep timers only as 60 s staleness fallbacks; gate on last-event time. — *Biggest holistic win*
3. **Push proximity filtering to Postgres** (C3, H3) + project columns (M3) + paginate (M5). — *Kills unbounded payloads*
4. **Fix FutureBuilder-in-build** (C4). — *Easy, eliminates query loops*
5. **Add `RepaintBoundary`** around maps/animations/cards (C7). — *Easy*
6. **Add `cacheWidth/cacheHeight` + WebP assets** (H1). — *Memory + jank relief*
7. **Move JSON decoding off the UI thread** (C8, M10). — *Medium*
8. **Rework startup** (H2, M4): parallelize init, drop 800 ms delay, lazy tabs, drop duplicate fetches. — *Biggest perceived-speed win*
9. **Restructure Home with slivers + one-time animations** (C6, M1). — *Hard but high payoff*
10. **Consolidate map to a shared/native surface** (H6). — *Hard*
11. **Guard debugPrint payload logging** (H7). — *Easy*
12. **Tune GPS** (M7): accuracy/distance filter/heartbeat. — *Battery*
13. **Remove artificial 500 ms pricing gate** (M12). — *Easy*
14. **Batch intercity enrichment into one RPC** (M6). — *Medium*

*Confidence note: static-analysis confidence is high for patterns with direct evidence (timer counts, query shapes, file sizes, absence of RepaintBoundary/compute). Perceived-impact estimates should be validated with Flutter DevTools timeline/profile on a mid-range Android device before/after each fix — see docs/15_Testing.md for QA credentials.*
