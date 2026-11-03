# Build 56: November 2, 17:43–17:55 IST investigation

Project `yvwpchffctiagevpqgwy`. Exact inspected interval: **2026-11-02 12:13:00–12:25:00 UTC**, ending at 17:55:00 IST. User confirms Build 56 was used and Passenger/Rider Home, booking and photo flow felt delayed. This is user-reported build attribution; project logs do not identify that handset or its APK hash.

## Finding

**Confirmed shared backend stall during this test**, affecting Flutter REST, server-side Edge-to-REST calls, PostgreSQL and Realtime. It is not adequately explained by the Flutter loader defects corrected in Build 56. **The resource/operation that initiated the stall remains unproven.** No claim that Free compute, CPU, active swapping, a lock holder or one RLS function initiated it.

An additional **verified application workload amplifier** was found on the exact booking-map query path: nearby-rider polling admitted new requests while the previous request was unfinished. A minimum local correction now shares that work. A safe authenticated query plan also shows a substantial cross-table RLS expansion on this path; that is a concrete SQL optimization target, not a measured root-cause verdict.

## Exact production evidence

[AGGREGATE.json](evening-1743-20261102/AGGREGATE.json) contains 91 groups below the 120-group cap. It covers 4,943 gateway records, including 2,357 Dart-family requests, across the project. Counts are **not per user** and not proof of redundant requests. [TIMELINE_COMPLETE.json](evening-1743-20261102/TIMELINE_COMPLETE.json) contains 77 selected slow/error events below its 100-row cap, including 41 gateway requests taking at least five seconds. This later corrected selection supersedes the capped initial timeline, which included ordinary signed-URL calls.

| Operation | Count in interval | Median ms | p95 ms | Maximum ms |
|---|---:|---:|---:|---:|
| Dart riders GET | 388 | 139 | 2,605 | **47,939**, one HTTP500 |
| Dart orders GET | 649 | 65 | 1,804 | **35,849** |
| Dart users GET | 127 | 118 | 2,444 | **28,482** |
| Edge orders GET | 403 | 61 | 772 | **43,435** |
| Edge production_config GET | 181 | 28 | 968 | **42,994** |
| Edge dispatch-round-status RPC | 9 | 270 | 47,330 | **47,330** |
| Dart nearby-riders RPC | 54 | 64 | 1,284 | **14,750** |
| Edge Auth user GET | 291 | 27 | 917 | **13,030** |

Fast medians do not cancel the severe foreground tail. These gateway origin durations do not include all handset rendering or pre-request work. Gateway timestamp semantics have not been independently established as request-start versus completion; no exact SQL start or concurrency count is inferred by subtracting duration.

Timeline, using recorded timestamps:

| UTC / IST | Evidence | Causal interpretation |
|---|---|---|
| 12:17:45 / 17:47:45 | Notification-side RPC, Edge rider_locations and config reads each about 6.2–6.3 s | Earliest selected >5 s records already cross unrelated backend paths. Not necessarily the first degradation. |
| 12:19:48–52 / 17:49:48–52 | Orders/riders take >6 s; first Warp timeout-manager record | Degradation visible before the main PostgreSQL cancel cluster. |
| 12:20:02–17 / 17:50:02–17 | 28–48 s Dart and Edge requests across orders, riders, config and dispatch status | Shared backend delay; changing only Home presentation cannot eliminate it. |
| 12:20:08.801, 10.050, 14.266 / 17:50:08–14 | Three Realtime subscription-manager statement timeouts | Subscription setup is affected. No evidence it initiated the earlier stall. |
| 12:20:24.781 / 17:50:24.781 | realtime.list_changes cancelled **due to user request** | SQLSTATE57014 alone is not proof of statement_timeout. |
| 12:20:26.236 / 17:50:26.236 | PostgREST nearby-map riders/KYC query statement timeout, context `SQL function is_admin` | Identifies an actual failed SQL path and authorization dependency. |
| 12:20:34.830 / 17:50:34.830 | Another PostgREST statement timeout; query text absent | Cannot assign its table or request with certainty. |

There are **five explicit statement timeouts and one user-request cancellation**, not six statement timeouts. PostgREST has 22 Warp timeout-manager records but only **six distinct timestamp/message pairs**, plus one other statement-timeout record. Do not treat all 22 as independently failed SQL requests. No explicit `PGRST003` was found in this selected window; earlier incidents' pool-timeout evidence is not silently carried over.

Dashboard/management logs also show long queries, including pg_stat_statements diagnostics, after the cross-path slowdown was already visible. Four records selected by the word “timeout” are **not four cron startup failures**: three are duration statements and the remaining record is not classified as a statement timeout. SQL text can itself contain the word timeout. The initial heuristic error labels are not authoritative; [SQL_CLASSIFICATION.json](evening-1743-20261102/SQL_CLASSIFICATION.json) provides the corrected classifications. A later dashboard null-constraint error is not evidence of the initiating cause.

## Booking query and RLS: specific SQL target

The captured failed query selects rider ID/coordinates/heading, joins `rider_kyc.vehicle_type`, filters online accounts and latitude/longitude bounds. It matches the shared implementation shape in:

- `lib/features/local_rides/booking/screens/ride_location_screen.dart`, nearby-rider path around **1647–1735**.
- `lib/features/local_parcels/booking/screens/parcel_booking_screen.dart`, nearby-rider path around **279–360**.

No trace-ID join proves which screen generated the particular HTTP500. The PostgreSQL statement itself identifies the booking-map query shape.

Live metadata shows `public.is_admin()` is STABLE SQL, querying active `admins` by `auth.email()`. Bare admin helper predicates remain in riders/KYC/users policies. The KYC support/admin policy reads users; users policies refer to orders and intercity requests, whose policies can in turn read riders and other authorization paths.

A **single non-ANALYZE EXPLAIN**, inside a rolled-back read-only transaction with a synthetic authenticated identity and illustrative public coordinates, confirms:

- **53 plan nodes**, including 33 InitPlan nodes and seven SubPlan nodes, maximum depth eight.
- Relations include **riders, rider_kyc, users, orders and intercity_requests**, despite the small requested display payload.
- Eleven filter nodes reference `is_admin()`.
- Existing `idx_riders_online_coords` and `rider_kyc_pkey` are used. An obvious missing coordinate index is not established.

These are **plan structure counts, not 53 SQL round trips, measured helper executions or milliseconds**. No target SELECT was executed; no production EXPLAIN ANALYZE. The identity/coordinates and projection are illustrative, so this is not a historical plan capture for the user's precise location. [AUTHENTICATED_PLAN.json](evening-1743-20261102/AUTHENTICATED_PLAN.json).

The current statistics estimate only 25 riders, 35 KYC rows and 128 users; they are estimates, not historical row counts. The snapshot's last rider autovacuum timestamp is **17:47:48.121 IST**, near the first selected slow records, and last autoanalyze is 17:44:46.990. This is a useful correlation to investigate, **not proof that autovacuum began then, saturated I/O or caused the stall**. No duration/I/O series or historical blocker graph was obtained. At the later 19:34 snapshot only three idle client connections and no blocker were observed; that does not clear the incident. [DATABASE_METADATA.json](evening-1743-20261102/DATABASE_METADATA.json).

## Verified local correction: stop overlapping nearby-map reads

Both screens retain adaptive 5/10/20-second polling. Previously those timers called an unguarded async fetch: a roughly 48-second unfinished request permits repeated five-second ticks to start additional SQL reads. Request duration does not cancel the next timer tick. This is a demonstrated code mechanism; the exact overlap count on the user's phone is not inferred from project-wide counts.

Implementation:

- `lib/core/services/network/single_flight_refresh.dart`: shares one unfinished refresh, releases ownership on success/failure, adds no retry or timeout.
- Both booking screens wrap their actual nearby fetch through this helper. The pickup coordinates are captured once; disposed/obsolete responses cannot update the map. Existing coordinate bounds, five-kilometre distance calculation, online filter, vehicle-type read and normal timer fallback remain.

Controlled actual Supabase SDK transport test: ten refreshes against a held response produce **10 concurrent requests without the guard → 1 with it (90% reduction in this reproduction)**. A later refresh still executes after completion; synchronous failure releases ownership without an automatic retry. This does not claim a 90% reduction in live project traffic or solve the initiating database stall.

This guard concerns nearby preview markers, not the assigned rider's live tracking, dispatch eligibility or acceptance. If pickup changes during a stalled request, the obsolete result is discarded and the next normal refresh after settlement reads the current pickup. No immediate extra request is queued. A transport that never settles still holds the slot: real cancellation/deadline recovery is not claimed implemented by a non-cancelling Future.timeout.

`test/nearby_rider_single_flight_test.dart`: **five pass** (two actual SDK/control cases, one failure-release case and two source wiring/guard checks). The latter two are not WebView end-to-end tests. Full Flutter: **2,138 passed / 0 failed**, previous 2,133 plus five. Analyzer on the touched screens/helper/test: **0 errors, 2 warnings, 28 infos**, exit 1; all reported locations are in unchanged existing screen code, with none in the new helper/test. This is **not a clean analyzer run**. Log: `.dart_tool/waydrop-local-runtime/evening-nearby-analyze.log`.

The new correction is **local, after Build 56**. The existing APK and its hash are preserved; no replacement APK was built under the same version. It needs a separately versioned reviewed candidate and device verification. This report does not claim the already-installed Build 56 contains this later fix.

## Photo flow: what this window actually contains

No gateway object-upload POST/PUT/PATCH was found in the inspected interval. Storage traffic consists of **107 Edge signed-URL generation POSTs** (maximum 1.767 s) and **85 Dart signed-image GET/downloads** (maximum 0.685 s). A signed-path GET is a download, **not URL generation or a photo upload**. The raw path-only classification in STORAGE_ADMISSION_ADMIN labels both as signed_URL_generation; this report corrects it using the method from AGGREGATE.

The prior afternoon window's 8–23-second uploads are **not evidence of upload duration in this new interval**. The user's photo-flow delay may occur before upload, during verification/order loading, in a request logged outside the boundary or on another transport; it is not yet isolated. Order-verification GET took up to **20.687 s** here, a concrete slow read in that journey. No proof this record belongs to the user's precise photo attempt.

Function mapping identifies 171 get-live-order-status, 154 push, 80 pricing, 20 create-order and 20 start-dispatch records across the project. No process-verification-photo function group was present. These counts do not identify unique orders, duplicates or the user's device. Missing function duration/status fields were not interpreted as zero latency or success. [EDGE_MAPPING.json](evening-1743-20261102/EDGE_MAPPING.json).

## What to do next, in order

1. **Client load amplifier:** include the tested single-flight correction in the next separately versioned APK. Run booking with a deliberately held response; verify one active read, current pickup markers, disposal and normal later refresh on a phone. No server deployment is required for this correction.
2. **RLS hot path:** compare the existing guarded local proposal `docs/supabase-phase2/proposals/04_admin_rls_initplan.sql` using authenticated admin/non-admin/support/owner/unrelated-user differential tests and plans in isolation. It already exists; it was not rewritten or applied. Statement-stable helper wrapping may reduce repeated checks, but does not remove the cross-table policy graph. A minimal authorized rider-map projection that avoids private KYC policy expansion is another design candidate, requiring explicit access-contract and security tests. Do not open KYC rows or add an unguarded SECURITY DEFINER endpoint to improve speed. Supabase documents statement-independent helper caching and RLS performance considerations in its [RLS guide](https://supabase.com/docs/guides/database/postgres/row-level-security).
3. **Initiating resource:** export existing Reports for **17:45–17:52 IST / 12:15–12:22 UTC**, preferably the full requested interval plus pre-onset context. Required: CPU modes/IOWait, MemAvailable, swap-in/out and major faults, system/data-device latency/IOPS/queue/utilization, minimum I/O budget balance, active/idle/waiting connections and pool admission. Correlate the 17:47:48 maintenance timestamp. Browser inventory is empty; these charts were not accessed. Connector tools expose no historical host-metric series. No new scraper can reconstruct the past.
4. **Photo stage:** capture camera completion, upload start/completion, verification Edge call and order-verification reload separately, using numeric timings and a safe request ID without object URLs, coordinates or tokens. Do not blindly compress the earlier tiny image or bypass proof/security.
5. **Production:** maintain existing independent deployed fixes. Combined SQL/Edge dispatch fencing/eligibility/coalescing and durable push remain behind their existing managed verification/approval gates. User declined a new test project; none was created. No production write or paid upgrade is justified automatically by this report.

Scope this follow-up: five bounded log queries in the same twelve-minute window (one initial timeline hit its cap, then a stricter replacement), one metadata SELECT, one capped non-ANALYZE authenticated EXPLAIN/read-only rollback and one Edge-version mapping read. No broad historical scan, production data mutation, migration, policy change, deployment, cron change or resource purchase. Evidence checks and exact hashes are in [VERIFICATION.json](evening-1743-20261102/VERIFICATION.json).
