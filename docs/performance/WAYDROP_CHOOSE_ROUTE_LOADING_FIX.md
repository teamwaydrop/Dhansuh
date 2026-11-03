# Choose Route loading investigation — November 3, 2026

Follow-up: [Build62 release and schema review](WAYDROP_BUILD62_SPEED_FIXES.md) packages this correction and an additional prefilled-route/map-readiness fix. Historical test counts and source locations below describe the preceding local candidate; current release results and artifact are in the follow-up.

Status: local Flutter correction; production unchanged. User confirmed **Build61**, tested **09:54–10:04 IST / 04:24–04:34 UTC**. These new changes are not in that installed APK. No new APK was built in this investigation.

## Finding

Two independent delays combine: production pricing/configuration APIs became slow, and Flutter withheld every vehicle until the slowest of three requests settled. Failure could then leave skeletons visible indefinitely. The latter two defects were reproduced and corrected locally. Neither screenshots nor aggregate logs establish this particular handset's exact loading duration.

Backend degradation is demonstrated; its initiating CPU, memory, disk or connection constraint is **not established**. The original November 1 initiating cause also remains unproven. No plan upgrade, production deployment, migration, configuration change or synthetic production booking was performed.

## Evidence and incident correlation

Only five bounded log queries used the ten-minute interval above: summary, metadata-key inventory, endpoint aggregate, pricing execution/vehicle minute join, and slow configuration records. A lightweight read-only role/catalog query and Edge source inspection supplemented them. No broad historical log scans or production EXPLAIN ANALYZE. Read-only inspection used the Supabase skill.

Safe exports are under [choose-route-20261103](choose-route-20261103/QUERY_PROVENANCE.md); each JSON records its window. Percentiles are request-sample percentiles, not device or SQL measurements.

| Endpoint | Requests/status | p50 | p95 | Maximum |
|---|---:|---:|---:|---:|
| calculate-order-pricing | 34 / 200 | 364 ms | 16,106 ms | 18,631 ms |
| pricing_config | 33 / 200 | 141 ms | 15,350 ms | 15,993 ms |
| pricing_zones | 36 / 200 | 109 ms | 13,763 ms | 13,925 ms |
| riders reads | 159 / 200 | 78 ms | 2,675 ms | 19,991 ms |
| riders writes | 17 / 204 | 219 ms | 16,117 ms | 16,117 ms |
| production_config | 88 / 200 | 31 ms | 2,242 ms | 13,889 ms |
| Auth user | 123 / 200 | 49 ms | 1,527 ms | 12,310 ms |
| dispatch_config | 76 / 200 | 29 ms | 1,518 ms | 3,884 ms |
| find_nearby_riders | 30 / 200 | 60 ms | 1,053 ms | 2,130 ms |

Source: [ENDPOINT_LATENCIES.json](choose-route-20261103/ENDPOINT_LATENCIES.json). Successful HTTP status does not mean a fast response. These counts cover the project, not exclusively this screen or this user.

At **04:31:49.441–.603 UTC / 10:01:49 IST**, configuration/zone records show 13,500–15,993 ms origin durations. At **04:32 UTC / 10:02 IST**, pricing execution maxima by vehicle were Auto **13,892 ms**, Bike **18,631 ms**, Cab **16,106 ms**. The execution-ID join identifies vehicle types, not one common booking batch. We cannot assign all three to this handset. Earlier/later calls include fast responses; this is not evidence that every request continuously took 19 seconds.

Sources: [SLOW_CONFIG_RECORDS.json](choose-route-20261103/SLOW_CONFIG_RECORDS.json), [PRICING_VEHICLE_TIMELINE.json](choose-route-20261103/PRICING_VEHICLE_TIMELINE.json).

The [window summary](choose-route-20261103/WINDOW_SUMMARY.json) has zero edge_logs HTTP 5xx and zero PostgreSQL 57014 matches. Five PostgREST and one Realtime timeout-keyword records were counted; their generic keyword counts do not prove pool exhaustion. The 20,643 ms maximum in that summary spans **all Edge functions**, not only pricing.

Deployed calculate-order-pricing was **v75**, bundle SHA256 `bb41c4a87d9a7e702bfb4b02b059464a9e0f114ded485e198bdb464ce34cdae3`. Captured deployed source differs from the broader local Edge candidate:

- Deployed `functions/calculate-order-pricing/index.ts:314` starts zone resolution; `:321` starts active configuration concurrently; `:329` awaits zone; `:413` resolves matching config; `:455` builds pricing response. Independent reads are already started together in production. Do not report them as a newly fixed sequential backend defect.
- Deployed `index.ts:27` reads pricing_zones. Shared config cache `functions/_shared/pricing_config_cache.ts:34` has isolate-local 30-second TTL/in-flight reuse. Separate cold isolates still read configuration. A local zone-cache candidate exists already; it was not deployed or rewritten here.
- Deployed `index.ts:300` creates a service-role client. Catalog snapshot at **10:14:51 IST** confirms service_role bypasses RLS. Attributing these slow service-client reads to authenticated RLS policy execution is unsupported. Planner row estimates were 18 configs and 2 zones; estimates are neither scan counts nor timings.
- Deployed `index.ts:453` reads configured GST and calls pure pricing arithmetic; `pricing-calculations.ts:276` returns GST and `:279` final_fare. No internal calculation spans exist for these incident calls; arithmetic time cannot be quantified from end-to-end durations.

## Source flow and confirmed local corrections

Main screen: `lib/features/local_rides/booking/screens/ride_location_screen.dart` (Choose Route). Controller: `lib/modules/payments/controllers/pricing_controller.dart`. Exact final source references are in the source-location list below; pre-change captures are retained as `.before` files in the evidence directory.

1. Address selection calls Ola place-details/geocoding, updates coordinates, obtains directions/distance, verifies serviceability, opens Select a Ride, and invokes calculate-order-pricing for Bike/Auto/Cab. Availability continues to depend on the backend returning a valid configured quote. Nearby rider reads remain independent map context; they are not a new fare eligibility rule. No extra profile/Auth prerequisite was added.
2. **All-vehicle publication barrier:** original controller awaited `Future.wait` before publishing any fare; the screen repainted after the whole batch. A valid Auto quote could be hidden behind unrelated Bike/Cab. Added opt-in `publishAsReady`; Choose Route subscribes to controller changes and publishes valid completed quotes immediately. Other controller callers retain default batch behavior. A later result retains the user's selected vehicle.
3. **Infinite failure skeleton:** original sheet used `!hasPricing` as loading, including after all requests failed/timed out. It now distinguishes pending, usable quote, and error. All failures end skeleton and expose explicit Retry pricing; invalid/failed directions expose Retry route. No automatic pricing retry loop was added.
4. **Stale route/quote race:** original directions/geocoding completion could overwrite newer selection. Selection/route generations now reject stale completion; exact-coordinate overlapping directions share raw work. New route selection immediately invalidates the old quote and distance. Failed directions cannot price a new destination using a previous distance. Quote visibility and booking depend on current exact route context and account.
5. **Map/artificial waiting:** removed the explicit 150 ms delay before pricing. Once route data is valid, pricing/serviceability can proceed without waiting for decorative WebView drawing/fit. Marker updates no longer block the two address-selection paths. JavaScript results cannot authorize a fare.
6. **Lifecycle and booking safety:** screen removes controller listener and disposes controller. Pending results cannot update a disposed owner. Booking requires a current finite nonnegative backend quote, both coordinates, positive route distance, and no route/order/payment operation in progress. The device-metadata await rechecks quote/vehicle/account before sending create-order. Existing booking idempotency and timeout reconciliation remain intact.
7. **Promo ownership:** pending promo validation is bound to route, account and selected vehicle. Changing vehicle invalidates the previous discount/validation owner. Fare/GST rounding and server promo calculation are unchanged. Cash/UPI chips only change payment mode and do not fetch pricing.
8. Compact three-column placeholders reserve the same minimum option area as the real cards. The existing bottom-sheet scroll remains. The long current-location label now wraps within its row; tests use a 430-pixel viewport. Native Android visual/layout confirmation remains outstanding.

No SQL, Edge implementation, KYC/payment policy, dispatch, GPS subscription or pricing formula was modified by this task. Three distinct vehicle requests remain three requests; this change improves first usable results, not their total normal count. Rebuilds and payment changes produce zero additional pricing requests. A timed-out retry shares still-running raw transports; after actual failed settlement a deliberate retry starts fresh requests.

### Source locations in the final candidate

| Responsibility | File and line |
|---|---|
| Current quote/account visibility, booking eligibility | `lib/features/local_rides/booking/screens/ride_location_screen.dart:106`, `:123` |
| Progressive state listener / stable selection | Same screen `:129` |
| Pickup / destination geocoding ownership | Same screen `:802`, `:865` |
| Directions coalescing and stale-response rejection | Same screen `:1093` |
| Serviceability / local-intercity branching | Same screen `:1181` |
| Pricing SDK batch / diagnostics scope | Same screen `:1726` |
| Promo validation ownership | Same screen `:1762` |
| Create-order ownership and existing idempotent payload | Same screen `:1864` |
| Sheet opening / removal of fixed wait | Same screen `:2021` |
| Vehicle fare/GST rendering | Same screen `:2070` |
| Cash / UPI local state | Same screen `:2461` |
| Skeleton/error/Retry and booking button | Same screen `:3394`, `:3770`, `:3837` |
| Opt-in publication / timeout and raw-work dedup | `lib/modules/payments/controllers/pricing_controller.dart:61`, `:182` |
| Existing serviceability cache / gate | `lib/core/services/location/serviceability_service.dart:26`, `:126` (unchanged) |
| Existing Ola details / directions provider | `lib/core/services/maps/ola_map_service.dart:689`, `:774` (unchanged) |
| New stage recording | `lib/core/services/diagnostics/choose_route_timing.dart:25` |
| Export privacy allowlist | `lib/core/services/diagnostics/performance_trace.dart:18` |

Modified implementation files are the screen, pricing controller, new timing helper and PerformanceTrace only. Modified/added tests: `test/choose_route_loading_test.dart`, `test/part5_safe_metrics_test.dart`. Other pre-existing dirty workspace changes are outside this task.

## Measurements and regression evidence

Before applying the correction, the two focused widget reproductions failed: Auto was absent while Bike/Cab remained pending; three skeleton cards persisted after all failures. Fixture-only issues (lazy-list visibility, fake-async Dio scheduling) were corrected separately and are not claimed as application performance findings.

[CONTROLLED_TIMING.json](choose-route-20261103/CONTROLLED_TIMING.json) records an actual wall-clock **controller** benchmark using real mocked HTTP completion delays: Auto 100 ms, Bike/Cab 700 ms. Default batch publication took **710 ms** to first Auto quote; progressive publication **108 ms** (602 ms / approximately 85% reduction for this controlled sample). Both made exactly three requests. Later runs vary by scheduler load; this is not a production, native-frame, map or Android startup benchmark.

Widget tests separately prove first Auto is selectable and Book Ride Now enabled while both unrelated requests remain unresolved. There is no measured numeric Android navigation-to-first-option or navigation-to-book-ready result. Screen-level timing should not be substituted with the controller number. Screenshot clocks at 10:01/10:02 establish neither a 60-second wait nor exact request boundaries.

Final verification:

| Check | Command / result |
|---|---|
| Focused | `flutter test --no-pub test/choose_route_loading_test.dart test/pricing_request_lifecycle_test.dart test/part5_safe_metrics_test.dart --reporter expanded` — **29 passed, 0 failed** |
| Full Flutter suite | `flutter test --no-pub --reporter expanded` — **2,232 passed, 0 failed, 10 existing live skips**; 2,242 total cases, 1 minute 41 seconds reported by runner |
| Difference from previous completed suite | Previous **2,216 passed / 10 skipped**; **15 new Choose Route cases + 1 new privacy case = 16 additional passes**. No existing pass removed. |
| Targeted analyzer | `flutter analyze --no-pub` with the four implementation files and two test files — **0 errors, 1 warning, 16 infos**, exit 1 because diagnostics remain. Not a clean analyzer run. The unused `finalFare` warning existed in the pre-change screen; remaining items are style/deprecation/import/documentation diagnostics. |
| SQL / Edge / managed integration | Not run for this Flutter-only correction; no SQL/Edge implementation changed. MockClient and mocked Dio responses exercise actual Flutter/controller/provider parsing paths, not managed Auth/RLS/native map/payment behavior. An isolated managed test environment was unavailable; project creation was previously declined. |

First full attempt had **2,227 passes, 1 failure, 10 skips** because an existing source test asserts the literal single-line dedup-map declaration. Formatting had split that unchanged declaration. Restored its original formatting; no expectation was weakened. The final full run above passes. Earlier focused failures during implementation are superseded by the completed final run, not counted as successful tests.

Local runner logs: `.dart_tool/waydrop-local-runtime/choose-baseline.log`, `choose-final-focused.log`, `choose-full-final.log`, `choose-final-analysis.log`. [VERIFICATION.json](choose-route-20261103/VERIFICATION.json) records commands, counts and final source hashes. Existing live-provider tests remain opt-in; no production test requests were made.

## Instrumentation and remaining attribution gaps

`lib/core/services/diagnostics/choose_route_timing.dart` adds debug/profile-only route stages: navigation start, first frame, coordinates ready, directions start/end, map start/end, serviceability start/end, pricing batch start/end, first quote readiness frame, book readiness frame and route failure. Numeric timestamp, elapsed offset and generation only; no addresses, coordinates, users, tokens, fares or messages. Export allowlisting is extended and privacy-tested in `test/part5_safe_metrics_test.dart`.

`PerformanceTrace.measure('choose_route', ...)` places pricing SDK transport metrics in the existing API diagnostics screen scope. The route stage called `optionRendered` means a scheduled post-frame after quote readiness; a lazy/offscreen option is not proven painted. Frame timings/visible-device capture are required for actual first-visible pixels. Navigation start means State initialization, not the earlier passenger-home tap. A new route generation has its own elapsed origin; use absolute timestamps/generation when correlating stages.

| Stage | Available evidence | Missing measurement |
|---|---|---|
| Coordinates/geocoding/directions | Source plus guarded route stages; mocked provider race tests | Actual handset/provider spans for this past interval |
| Vehicle pricing/config | Three SDK calls, deployed source, bounded API logs | Per-handset batch association and per-read Edge spans |
| Network/API | origin_time and Edge execution_time_ms; future API headers/body diagnostics | Client radio/DNS/TLS/queue split for incident |
| Fare/GST arithmetic | Captured deployed pure calculation source | Instrumented execution duration inside deployed function |
| PostgreSQL | Lightweight role/catalog metadata only | Incident SQL spans, execution/queue/lock/pool wait breakdown |
| CPU/RAM/swap/disk | No historical dashboard charts accessible | Per-minute resource onset, disk latency/IOPS/throughput, swap, active/waiting connection history and compute-size history |
| UI/device | Widget readiness and desktop controlled benchmark | Android profile first-visible quote/book times and frame/raster trace |

## Next validation and production requirements

Use a test phone with this local Flutter candidate in profile mode, approved environment file and `WAYDROP_PERF_EXPORT=true`. Compare at least ten matched cold/warm Choose Route journeys; record screen entry, route generation, first **visible** quote and first enabled Book frame, pricing SDK durations and provider spans. Include slow/failing network, fast address changes, Cash/UPI, promo validation and screen close. Native map drawing must be checked because the desktop harness intentionally uses the mock-map path. Do not upload private addresses, credentials or messages with diagnostics.

For backend attribution, obtain the Supabase dashboard CPU, memory/available RAM/swap, disk IOPS/latency/throughput, database active/waiting connections and compute-size exports covering **04:20–04:40 UTC November 3**; compare previous incident windows separately. Current charts or cumulative pg_stat_statements cannot reconstruct onset. If historical charts are unavailable, the initiating resource bottleneck remains unresolved.

Flutter candidate requires a reviewed app release and real-device validation; installed Build61 does not gain local source changes automatically. No production SQL/Edge changes are required for these Flutter corrections. Existing broader SQL/Edge bundles retain their prior NO-GO assessment and managed-concurrency/security validation requirements; no blanket deployment is authorized here.
