# WayDrop — What Flutter DevTools Will Reveal (Predicted)

**Purpose:** Predict what each Flutter DevTools view would show when profiling this codebase, based on static analysis of `lib/` (143 files, 90,509 lines).
**Constraint honored:** No code was modified — analysis and prediction only.
**Companion doc:** `PERFORMANCE_AUDIT_REPORT.md` (issue registry with line numbers, severities, fixes).

**How to capture (recommended workflow):**
```bash
flutter run --profile --dart-define-from-file=.env   # profile mode: real timings, fewer assertions
# Then: DevTools → Performance / CPU Profiler / Memory / Network / Widget Inspector
```
Use the QA bypass credentials in `docs/15_Testing.md` (phone `+919999999901`, OTP `123456`) to walk through Home → Book Ride → Searching → Tracking, and the rider flow (Orders Nearby → Active Order), since those are the highest-risk screens below.

---

## 1. Performance View — Frame Analysis

**Predicted result: sustained red frames (jank) on 4 screens, intermittent jank everywhere else.**

| Screen | Predicted frame pattern | Evidence |
|---|---|---|
| Rider Orders Nearby | **Red bar every 1 s** (the 1 s `setState(() {})` expiry tick), plus bursts on 10 s order refresh | `rider_orders_screen.dart:235` `Timer.periodic(1s)` → `setState(() {})`; `startLocationTimer()` 10 s → `fetchSearchingOrders()` |
| Incoming order cards | Red bars every 1 s while a card is on screen (countdown tick rebuilds a 1,272-line card) | `incoming_order_card.dart:86` `_countdownTimer` 1 s |
| Home (user & rider) | Recurring green/orange frames every 5 s (nearby-riders poll → `setState`), every 30 s (silent refresh), on every realtime order event | `home_tab.dart:1018` 5 s timer; `:187` 30 s timer; `_load()` 4 queries |
| Tracking screens | Continuous yellow/orange (WebView JS bridge per rider position + 5 s poll + realtime) | `realtime_order_controller.dart:38` 5 s poll; `transport_map_widget.dart` `runJavaScript` per update |
| Admin dashboard | Red bar every 4 s (7-query stats refresh) | `admin_dashboard_screen.dart:45` 4 s timer |
| Splash | Long frame (~200–500 ms) while route-motif `CustomPaint` + logo asset decode run | `app_start_screen.dart:431` CustomPaint per animation frame |

**Timeline event hotspots DevTools will flag:**
- `build` events taking 10–30 ms on Home/Rider Orders because the `build` methods are 2,000–5,100 lines tall with hundreds of widgets each (e.g., `home_tab.dart` build ≈ 400 lines of widget construction).
- `Timer.periodic` callbacks appearing as recurring UI-thread tasks — DevTools will show them as the *most frequent* event type at idle, which is abnormal for a realtime-first app.
- Long `jsonDecode`/`decodePolyline` tasks whenever route geometry or match payloads arrive (main-thread decoding, zero `compute()`/isolates in the project).

**What jank detection will report:** "64 frames janky in 120 frames" style counts on: Rider Orders Nearby, all Searching screens (5 s poll + map marker re-plot), Tracking screens, Home during a rider poll, and the splash.

---

## 2. UI Thread vs Raster Thread

**Predicted split:** UI-thread-bound on data screens; **raster-thread-bound on tracking/map screens and anywhere heavy shadows/gradients exist**.

- **UI thread (high):** JSON decode, Haversine distance loops (`home_tab.dart:1056` per rider × full table), `rawOrders.sort()` in `_load`, string interpolation for `debugPrint('...${response.data}')` (payload stringification still runs in release — e.g., `intercity_searching_screen.dart:311`, `payment_service.dart:214`), `GoogleFonts` theme construction on root rebuilds (`main.dart:182`).
- **Raster thread (high):**
  - **173+ `blurRadius` shadows** across the app, many `blurRadius: 20–32` (e.g., `intercity_searching_screen.dart:1366` blur 32, `travel_plan_details_screen.dart:2374` blur 24, tracking screens blur 24). Every blurred box-shadow costs a blur pass per repaint — and these repaint whenever their parent rebuilds (which is constantly per §1).
  - **`ImageFilter.blur(sigmaX: 10)`** in `intercity_searching_screen.dart:1346` — a live background blur over the map/markers, re-blurred on every frame it's visible. This is the single most raster-expensive effect in the app.
  - **~56 gradient usages** (`LinearGradient`/`RadialGradient`) — moderate, but combined with shadows they multiply paint cost.
  - **Continuously animating `CustomPaint`s:** `waydrop_bike_animation.dart` (5 custom painters, incl. gradient shaders, `..repeat()` controller), `RouteMotifPainter` (`path.computeMetrics()` + `extractPath` loop every frame on splash), `_ModeSwitchPainter` (`shouldRepaint => true` — always repaints), `_MapGridPainter` on every map screen.
  - **WebView (Maplibre GL) compositing** on every map screen — WebView content is composited as a texture; animated markers inside JS cause full-surface compositing each frame.

**DevTools symptom:** In the Performance view, hover a red frame on a tracking screen → the raster thread bar will be full while the UI thread bar is short.

---

## 3. CPU Profiler

**Predicted sample hotspots (most common self-time):**
1. **Timer callback stack:** `Timer._handleMessage` → `_performHeartbeatUpdate` / `_fetchNearbyRiders` / `_load` / `setState` → rebuild. Profiler will show the same 5–10 frames recurring at steady intervals — the signature of polling-based architecture.
2. **`_fetchNearbyRiders`:** full-table select + `cos/sqrt/asin` Haversine math per rider on the UI thread, every 5 s (`home_tab.dart:1025–1098`).
3. **`decodePolyline`/`jsonDecode`:** route geometry decode on UI thread (`ola_map_service.dart:527+`, `transport_map_widget.dart:127` inside `didUpdateWidget` — decodes *on every parent rebuild*).
4. **`fetchSearchingOrders`:** nested `rider_assignments.select('*, orders(*, users(...))')` merge/filter/sort loops (`rider_orders_screen.dart:340–400`).
5. **String building for debug logs** — `debugPrint` is a no-op in release but argument evaluation (payload `toString()`) is not.
6. **Garbage collection** between bursts — see §5.

**What to compare:** CPU profile in a 30-second idle window on Home should be near-zero; expect 5–15% sustained CPU from timers alone.

---

## 4. Widget Rebuild Stats (Performance → Widget Rebuild Counts)

**Predicted top rebuilders (counts per 60 s):**

| Widget | Predicted rebuilds/min | Cause |
|---|---|---|
| `RiderOrdersScreenState` | **~62** (1/s + 10 s refresh + events) | unconditional 1 s `setState` |
| `IncomingOrderCardState` | **~60** while visible | 1 s countdown tick |
| `HomeTabState` | **~20–25** (12 from 5 s poll + 2 from 30 s + realtime events + location) | 3 timer chains + realtime `_load()` |
| `RiderHomeTabState` | **~15–20** | 5 s + 30 s timers + realtime |
| Searching screens | **~15** (5 s poll + match events) | rider refresh timer |
| `AdminDashboardScreenState` | **~15** | 4 s refresh |
| Activity tabs | **~2–3** | 30 s refresh + realtime |
| Profile tabs | **variable, potentially looped** | FutureBuilder re-created future in `build` (`profile_tab.dart:895`, `rider_profile_tab.dart:642`) → new DB query per rebuild |

**What the "const-less" column will show:** thousands of widgets recreated per rebuild — 7,664 `const` usages exist but the *massive* build methods create hundreds of non-const widgets per call, and entire subtrees (nav bar, cards, map overlays) are rebuilt because there is **no `RepaintBoundary` anywhere in the codebase** and screens keep state at the root instead of in leaf widgets.

**DevTools detail worth checking:** profile tab rebuild counts will grow *linearly while idle* if the FutureBuilder loop is real — a telltale "rebuilding forever" signal.

---

## 5. Memory View — Heap, GC, Allocations

**Predicted observations:**
1. **Image decode spikes:** Open Home → profile photos, parcel images, chat images. Expect sawtooth heap growth: each `Image.network` without `cacheWidth/cacheHeight` allocates a full-resolution bitmap (8–32 MB per photo). Only ONE call site in the app passes cache dimensions (`rider_earnings_tab.dart:2127`). Expect DevTools "Large image" warnings in the image inspector.
2. **~4–6 MB bundled PNG assets decoded at full size:** `LOGO.png` 1.5 MB, `ride.png` 1.2 MB, `logowaydrop.png` 1.2 MB, `LOGO1.png` 1 MB, `waydrop_logo_transparent.png` 376 KB (splash logo, animated). Each decodes to width×height×4 bytes.
3. **Multiple WebView surfaces:** navigating Home → Location → Booking → Tracking keeps 2–3 Maplibre WebViews alive in the stack (`AutomaticKeepAliveClientMixin` in `transport_map_widget.dart:61` keeps tab maps alive). Each WebView is a separate process/isolate on Android — DevTools memory will show large native heaps not fully explained by Dart objects.
4. **GC pauses correlated with timer bursts:** expect GC events immediately after 5 s/30 s poll `setState` bursts (short-lived object churn from rebuilds + JSON maps). DevTools GC histogram will show frequent young-gen collections.
5. **Hive cache growth:** route geometry cached as JSON strings (full polyline arrays) in the encrypted Hive box (`cache_service.dart`, `ride_tracking_screen.dart:328` etc.) — every route fetch adds a large string entry; box size grows unbounded (no eviction policy visible).
6. **Static caches that never shrink:** `OlaMapService` in-memory maps (`_routeCache`, `_geocodeCache`, `_autocompleteCache`, `_reverseGeocodeCache`, `_placeDetailsCache`) grow for the app lifetime — bounded in practice by distinct places, but no cap.
7. **`_announcedOrders` Set** in rider orders — it IS pruned (`rider_orders_screen.dart:478`), good.

**Leak checklist (predicted clean, worth verifying):**
- `LocationCacheService.addListener` — `home_tab.dart` removes its listener in `dispose` ✓
- Realtime channels — screens unsubscribe in `dispose` (mostly) ✓; but verify no screen forgets `RealtimeManager.instance.unsubscribe` (e.g., check searching screens' dispose)
- `Geolocator.getPositionStream` subscriptions — cancelled in `dispose` paths ✓ (verify `rider_active_order_screen.dart:4433` subscription cancel)
- **Suspect:** `NotificationService` Firebase listeners are global/singleton (fine); `RealtimeOrderController` polling timer — verify it's cancelled when the last tracking screen pops (if not, it keeps polling forever → DevTools shows a permanent 5 s network cadence after leaving tracking).

**DevTools allocation summary prediction:** top allocating frames will be rebuilds (`_WidgetsAppState`/`Element` re-creation), `jsonDecode` maps, and `Color.withOpacity` results (136+ deprecated `withOpacity` calls allocating new Color objects per build).

---

## 6. Network View

**Predicted request pattern — a heartbeat chart with recurring spikes, not event-driven:**

| Interval | Request | Source |
|---|---|---|
| 5 s | `riders` full-table select (+KYC join) — Home | `home_tab.dart:1018` |
| 5 s | nearby riders / matches — all 3 Searching screens | `ride_searching_screen.dart:256`, `parcel_searching_screen.dart:240`, `intercity_searching_screen.dart:1148` |
| 5 s | edge function + `orders` select — Tracking | `realtime_order_controller.dart:38` |
| 8 s | HTTP GET to Supabase REST (connectivity ping, app-wide, always on) | `connectivity_wrapper.dart:32` |
| 10 s | `dispatch_config` + `rider_assignments(*)` nested — Rider Orders | `rider_orders_screen.dart:222,340` |
| 30 s | 4-query batch (users, riders, kyc, orders) — Home | `home_tab.dart:187` |
| 30 s | activity/earnings refreshes — Activity tabs | `activity_tab.dart:62`, `rider_activity_tab.dart:40` |
| 4 s | 7-query admin stats | `admin_dashboard_screen.dart:45` |
| 8 s | full chat history re-fetch + offline-queue sync | `order_chat_screen.dart:133` |

**What DevTools Network will additionally show:**
- **Startup waterfall:** 6–10 parallel requests fired at once when `MainNavigationScreen`'s `IndexedStack` eagerly builds all 4 tabs (Home `_load` 4 queries + Activity `loadOrders` + Profile queries + badge + zones). The waterfall will show a wide "wall" of concurrent requests at t≈0–2 s.
- **Large response bodies:** full-table rider selects (unbounded rows), nested `orders/riders/users` joins, unprojected `select()`s (~30 sites) — payload sizes in the KB–MB range per response.
- **Realtime WS + HTTP polling coexisting:** the WebSocket (Supabase Realtime) stays connected while identical data is re-fetched over HTTP — Network view will show this redundancy clearly.
- **Long-running requests:** Ola Maps geocode/directions (external, 15 s timeouts, throttled 200 ms) during location search; each keystroke debounced 400 ms.

---

## 7. Timeline Events / Shader Compilation

- **Shader compile jank:** first paint of every screen with gradients + shadows + rounded clips will compile SkSL shaders. With 173 shadows and 56 gradients, expect **dozens of "Compiling shader" timeline events** on first navigation — a burst of dropped frames the first time each screen renders. Impeller (if enabled on Android) mitigates this; the app sets `useMaterial3: true` but no explicit Impeller config seen in `main.dart` — verify `android/app/build.gradle.kts` for Impeller settings.
- **Persistent shader cache:** ensure `flutter build` uses the persistent cache; in debug/profile runs, every hot-restart recompiles.
- **`ImageFilter.blur` (sigma 10)** — shader-heavy; visible as a repeating "ImageFilter.blur" raster event on the Intercity Searching bottom sheet.
- **Expected long task events:** `Future.wait` bursts at startup, `Future.delayed` artificial gaps (`app_start_screen.dart:260` 800 ms min-splash, `pricing_controller.dart:83` 500 ms min-pricing) will appear as deliberate idle gaps in the timeline — DevTools will show these as *empty* frames (nothing rendered) which is wasted startup/booking time.

---

## 8. What DevTools Will NOT Directly Show (but confirms our audit)

- **Battery cost of `LocationAccuracy.bestForNavigation` + 5 m distance filter + 30 s DB heartbeat writes** (`location_cache_service.dart:444–492, 1000+`) — not visible in DevTools; needs device power profiling. But the 30 s `riders.update` network spikes will show in Network view.
- **Background/global cost** — timers keep running when app is backgrounded (iOS/Android may suspend them, but `foregroundNotificationConfig` + wake lock keeps the rider location stream alive; battery drain measurable via OS battery stats).

---

## 9. Predicted DevTools Scorecard (what you'll see)

| DevTools view | Prediction | Confidence |
|---|---|---|
| Frame Analysis | Red frames: Rider Orders (1/s), Searching, Tracking, Home (every 5 s), Admin (4 s), Splash | 90% |
| Jank detection | Sustained jank on 4+ screens; 10–20% frames janky during 5 s polls | 85% |
| Widget rebuild stats | RiderOrdersScreen ~62/min; Home ~20–25/min; Profile potential infinite loop | 85% |
| CPU Profiler | Timer callbacks + Haversine loops + jsonDecode as top self-time | 85% |
| Raster thread | Tracking/map screens raster-bound (WebView + blur-32 + shadows) | 80% |
| Memory heap | Image decode sawtooth; 2–3 live WebViews; GC bursts after polls | 85% |
| Network | 5 s/8 s/10 s/30 s periodic spike chart; startup request wall; large bodies | 90% |
| Timeline | Shader-compile bursts on first paint; artificial 800 ms/500 ms idle gaps | 85% |

---

## 10. What to Capture & Compare After Fixes (validation plan)

1. **Baseline capture** (before any fix): 60 s Performance recording on Home + Rider Orders + one Tracking session; CPU profile on Home idle; Memory snapshot after opening 5 screens with images; Network log of 60 s Home idle.
2. Fix in priority order from `PERFORMANCE_AUDIT_REPORT.md` §16 (start with: remove 1 s root `setState`, replace 5 s polls with realtime, add `cacheWidth/cacheHeight`, add `RepaintBoundary`).
3. **Re-capture the identical scenarios** and diff: expected results — rebuild counts −90%+, frame bar green on Rider Orders, Network spike chart collapses to near-zero at idle, GC frequency drops, memory peak falls >50%.
4. Use **Timeline → "Profile in timeline"** with a 2-second sweep on the tracking map to quantify raster vs UI thread split before/after the map consolidation.

*Validation caveat: static predictions are directional; exact numbers depend on device (mid-range Android), network latency, and rider/order density in the staging DB. Use DevTools as the measuring stick for each fix.*
