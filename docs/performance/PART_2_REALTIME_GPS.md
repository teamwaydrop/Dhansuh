# Part 2 — Realtime and GPS investigation

Project `yvwpchffctiagevpqgwy`. Incident inspected: **1 November 2026, 21:52–22:04 IST / 16:22–16:34 UTC**. Catalog and source review: 2 November IST. **Production remained read-only.**

## Verdict

**Realtime/GPS is a verified workload amplifier in the current architecture, not a proven initiating cause of the original slowdown. Its marginal contribution to that incident is unquantified. It cannot be classified as unrelated.**

One GPS PATCH can produce two table changes, trigger work, index maintenance and downstream subscriber work. However, the incident has only **13 Dart PATCH records to `riders`**, zero HTTP >=500 for those PATCHes, and no increase around 22:02 IST. Realtime's 13.8-second operation is evidence of slow processing, not proof that replication initiated database pressure. Historical call totals do not change this conclusion.

Two reproducible local defects were fixed: a fallback reconnect can tear down an already recovered channel, and three GPS-only filters incorrectly treat absent old business fields as unchanged. Neither defect is demonstrated to have fired in the production incident. No publication, identity, trigger, index, policy or production setting was changed.

Evidence: [catalog, SQL definitions, incident traffic](realtime-gps-20261102/EVIDENCE.json), [39 literal Flutter table bindings](realtime-gps-20261102/CLIENT_BINDINGS.json), [Part 1 incident logs](root-cause-20261101/INCIDENT_LOGS.json). Source coordinates below refer to the final working tree, not an asserted production build.

## 1. GPS source → request → database → passenger map

| Step | Exact source / behavior |
| --- | --- |
| Online/start ownership | [rider_home_tab.dart](../../lib/features/rider/home/rider_home_tab.dart), `_goOnlineWithFreshLocation` around 1170–1290, calls tracking start at 1266 and writes online status with fresh coordinates. Home load also starts/stops tracking at 478–480. Logout/restriction stops tracking in `app_start_screen.dart:70` and `user_session_service.dart:130`. |
| Single upload stream | [location_cache_service.dart](../../lib/core/services/location/location_cache_service.dart), `startRiderLiveTracking:399`, guarded by `_startingTracking` and the stream handle. Android settings at 448–451: best navigation accuracy, 5 m OS distance filter, requested 10-second interval. Apple settings at 465: navigation accuracy, 5 m filter, background updates enabled. |
| Stream delivery | `_handlePositionUpdate:569` caches each delivered fix, then uses `_shouldUploadPosition:589` and `isUpdatingDb`. Successful completion updates dedup state; skipped events never release another request's lock. Generation checks prevent stopped tracking from accepting an old request as the new generation's upload. |
| Heartbeat | `_performHeartbeatUpdate:324`; timer at 541–547 every 30 seconds plus an immediate attempt. Fresh cache / last-known / current-position fallback; an aged fix or GPS acquisition failure is not stamped fresh. After its asynchronous read, heartbeat rechecks tracking generation, upload gate and lock. |
| One REST PATCH | `updateRiderLocation:695` sends `current_lat`, `current_lng`, `current_heading`, `last_location_updated_at`, `last_active_at`, `updated_at` to **`riders`**, filtered by current `user_id` AND `account_status='online'`. No Flutter direct `rider_locations` write or subscription was found. |
| Additional database write | Live trigger `trg_riders_gps_bridge_to_rider_locations` invokes `sync_riders_gps_to_rider_locations`: UPSERT the same coordinates/heading/freshness into `rider_locations` on `rider_id`. Definitions are retained in evidence. |
| Near-destination work | Existing-row UPSERT updates coordinates, firing `trg_rider_locations_near_destination_check`. Function `check_rider_near_destination_from_rider_locations` looks up an ongoing, not-yet-notified intercity order by rider; if within 3 km, updates the order and enqueues the notification chain. |
| Passenger live coordinates | [realtime_order_controller.dart](../../lib/core/services/realtime/realtime_order_controller.dart), `_subscribeRider:607`, binds **`riders`, UPDATE, id=riderId**, applies lat/lng/heading at 633–641. Rider profile enrichment is only re-fetched for rating/KYC changes. Ride, parcel and intercity tracking screens consume this controller and update map JS. Removing `riders` publication would break this live path. |

There are **two location streams with different purposes**, not two database upload loops. [rider_active_order_screen.dart](../../lib/features/rider/orders/screens/rider_active_order_screen.dart), `_startLocalLocationTracking:4832`, requests 1-second Android / 3 m fixes for the rider's own WebView. Its callbacks coalesce local JS updates; they do not PATCH Supabase. `RiderOrdersScreen`'s 10-second location timer (`rider_orders_screen.dart:432`) can refresh searching orders; it is not a second coordinate writer.

### Exact frequency and repeated-write findings

- Upload gate is **distance >=10 m OR >=30 seconds since last successful upload**, not an unconditional ten-second timer and not a mandatory minimum interval between movement writes. On Android the OS interval is requested at ten seconds (nominally up to six movement callbacks/minute); it is not a strict cross-platform rate limit. Apple/fallback settings have no time interval. No new throttling was added that could reduce location accuracy.
- A stationary rider is eligible after 30 seconds, and the 30-second heartbeat checks that eligibility. Timer phase after a movement upload can delay the next stationary attempt to just under 60 seconds; network/GPS acquisition adds delay. The source does not promise exactly two successful writes/minute.
- Identical fixes within the gate window produce no second upload. Heartbeat shares the movement gate and lock, so it does not immediately repeat a just-completed stream write. While HTTP is outstanding, new fixes are cached but do not create overlapping PATCHes. There is no growing position-write queue. The next eligible callback/heartbeat uses a current fix; immediate trailing upload of the latest movement is not implemented.
- Stationary heartbeat writes are intentionally **not SQL no-ops**: freshness timestamps change. The bridge's `WHEN` includes those timestamps, so it UPSERTs `rider_locations` even if coordinates are identical. The UPSERT includes lat/lng in its SET list, so the coordinate UPDATE trigger runs again. This is verified repeated downstream work, but freshness is used by dispatch and cannot simply be removed.
- The first `rider_locations` INSERT does not run its UPDATE-only near-destination trigger; a later UPSERT UPDATE does. Skipping all unchanged-coordinate UPDATEs could miss the first near-destination evaluation after an order becomes ongoing while the rider is stationary. No such trigger optimization was implemented.
- Go-online explicitly writes status and a fresh fix in one request. Tracking starts just before it; an immediate tracking PATCH may see zero online rows. Existing `successfulLocationUploads` counts successful HTTP completions, **not proven changed rows** (the PATCH requests no representation/count). Do not use that counter alone as a database row-write measurement or remove the go-online fresh-location write.

Actual per-device/per-rider repeated coordinates cannot be reconstructed: retained gateway logs do not contain PATCH bodies or device/build identity. The 13 PATCHes include possible status or service-mode writes. Calling all 13 “GPS writes” would overstate the evidence.

## 2. Realtime creation, reconnection and disposal

| Path | Finding |
| --- | --- |
| Shared rider listeners | Home, Orders, Earnings, Profile and navigation use `rider-home-$riderId`, matching schema/table/event/id filter. `RealtimeManager.subscribe:96` pools listeners by name **and** configuration; release-safe mismatch isolation remains. Five logical listeners can share one Realtime channel object. Channels multiplex on the SDK socket; one channel does not necessarily mean another WebSocket. |
| Tracking scope | `RealtimeOrderController._subscribeRider:607` returns when already bound to the same rider; switches unsubscribe the prior ID. `dispose:665` cancels polling and both order/rider subscriptions. Distinct order-ID and rider-ID filters serve different data and were retained. |
| Passenger Home | `home_tab.dart:933` keeps one raw channel with users/KYC/rider bindings, checks user/rider/KYC identity before replacing it, and handles removal futures. Its separate order binding remains. Raw multiplexing is intentional, not proof of duplication. |
| Disposal races | Manager checks managed-object ownership after awaited reconnect steps and checks channel identity on delivery/status callbacks. Last-owner unsubscribe removes managed state before asynchronous SDK removal. Existing stale-callback/disposal tests pass. No production duplicate subscription leak was established. |
| Recovery defect — fixed | `_reconnectChannel:328` schedules 2/5/10/30-second jittered backoff and a connectivity probe. SDK `realtime_client-2.5.3` independently rejoins after errors/timeouts. Previously the manager still removed/recreated the channel if SDK recovery happened during its delay or probe. Added subscribed-status checks after both waits (`realtime_manager.dart:357,362`). Ownership checks remain. Still-failed channels reconnect; disposed channels do not return. |
| Metrics interpretation | `RealtimeObservability.subscriptionCreateCount` increments on every logical `subscribe`, including pooled attachments; dispose count increments on unsubscribe attempts. They are not physical-channel/WebSocket counts. `reconnectAttemptsCount` is recorded upon successful reconnect callback. High creation/deletion counters alone cannot establish duplicate channels or server subscription SQL cost. |

Installed SDK evidence: `C:/Users/karth/AppData/Local/Pub/Cache/hosted/pub.dev/realtime_client-2.5.3/lib/src/realtime_channel.dart:55–103` owns `_rejoinTimer`, scheduling retry on error/timeout; `realtime_client.dart:261` removes a channel by unsubscribing. The manager test factory now accepts an optional connectivity callback so tests use no live project or network.

### GPS-only event classification — fixed without weakening eligibility

Previous predicates in Rider Home, Rider Orders and Passenger Home accepted a key whenever `!oldRecord.containsKey(key)`. For example, old `{id: ...}` plus new `{id: ..., account_status: 'offline', ...}` was incorrectly “GPS-only” and skipped normal processing. A newly visible `cod_limit` field was also incorrectly ignored even with other old business fields present.

New [rider_update_filter.dart](../../lib/core/services/realtime/rider_update_filter.dart) skips only when every returned field is either an explicit GPS/freshness field or has a known equal previous value. Empty/unknown business data follows the original refresh/update path. Applied at `rider_home_tab.dart:645`, `rider_orders_screen.dart:392`, `home_tab.dart:1023`. Existing field allowlists are unchanged. Full known GPS-only rows still skip; availability, service mode, COD/eligibility changes do not.

**Important distinction:** current live `realtime.apply_rls` was inspected. For UPDATE it includes selectable old columns; the primary-key-only RLS restriction in that definition applies to DELETE. FULL on `riders` therefore can support update diffs today. We did not assume all RLS UPDATEs are key-only. The bug is a verified unsafe fallback for incomplete/changed column shapes, not a proven explanation for incident payloads. Full function definition is saved in evidence.

## 3. Trigger and index costs

The bridge runs AFTER `UPDATE OF current_lat,current_lng` with a changed-coordinate/heading/freshness `WHEN`. The Flutter PATCH always names both coordinate columns and fresh timestamps. For an actually matched rider row, the normal path can create **one riders row version + one rider_locations row version**, with changes for both published tables. Trigger SQL is synchronous within the PATCH transaction; replication delivery is downstream. Gateway logs cannot see the trigger UPSERT as a separate REST call.

The near-destination function performs one orders lookup per existing-row location update. It uses `rider_id` plus status/type/notified/destination predicates and `LIMIT 1`; live `idx_orders_rider_id` supports the rider restriction. It computes distance only after finding a candidate. Per-trigger timing is unavailable (`track_functions=none`); no production `EXPLAIN ANALYZE`, speculative index or trigger change was run. Its own cost cannot be separated from total GPS statement latency using current evidence.

`riders` has **13 indexes**. GPS touches indexed attributes:

| Index | GPS dependency |
| --- | --- |
| `idx_riders_account_status_service_mode` | INCLUDE contains `current_lat`, `current_lng`, `last_location_updated_at`; included columns still matter for HOT eligibility. |
| `idx_riders_location_updated` | Indexes `last_location_updated_at`; timestamp changes even for stationary heartbeat. |
| `idx_riders_online_coords` | Indexes lat/lng, partial predicate online; online movement affects coordinate keys. |

Other indexes include account/status/service-mode, financial balance, IDs, subscription and creation time. Non-HOT row updates can require index work beyond the directly changed key; no exact per-index microsecond or WAL-byte cost was measured. `idx_riders_user_id`/`idx_riders_kyc_id` overlap unique-key indexes, but they were not dropped without usage/plan validation.

Later cumulative table snapshot: `riders` **32,331 updates / 2,951 HOT (~9.13%)**, versus `rider_locations` **395 updates / 395 HOT (100%)**, with only its rider-ID primary-key index. These counters are not GPS-only or incident-window samples and their reset epochs were not independently established. They support the physical-design concern; they do not prove the November 1 bottleneck or that all historical GPS executions ran through today's bridge. FULL identity itself is not the indexed-column reason for losing HOT. [PostgreSQL HOT conditions](https://www.postgresql.org/docs/17/storage-hot.html).

Moving GPS exclusively to `rider_locations` would require migrating passenger tracking, dispatch readers, freshness predicates and rollout compatibility. Today’s code still needs coordinates/freshness on `riders`; removing that write would be unsafe. An architecture migration is a separate proposal, not this local fix.

## 4. Publication and replica identity: all 13 tables

Current `supabase_realtime` publishes INSERT/UPDATE/DELETE/TRUNCATE. All 13 tables have primary keys; seven are FULL. A table can remain published with DEFAULT and still deliver ordinary new-row UPDATEs. Old-row comparisons and filtered DELETE behavior need separate review. [Supabase documents per-subscriber authorization, ordered processing and replica identity/delete requirements](https://supabase.com/docs/guides/realtime/postgres-changes).

| Public table | Current identity | Verified consumer / decision |
| --- | --- | --- |
| `users` | DEFAULT, PK id | Suspension listener (`user_session_service.dart:52`) and Home users update (`home_tab.dart:957`). Keep publication and identity. |
| `rider_kyc` | FULL | Home all-events binding (`home_tab.dart:978`) handles DELETE. No old-value diff found, but filtered-delete behavior must be preserved/tested before considering DEFAULT. Keep now. |
| `riders` | FULL | Live passenger map plus rider availability/COD/service-mode listeners. Old business diffs are used. **Retain publication and FULL.** |
| `payments` | FULL | `payment_service.dart:343` binds UPDATE by payment ID and emits `newRecord`; no old-row consumer found locally. **Candidate for DEFAULT only after external-consumer audit and managed payment-status tests.** Keep now; no payment security change. |
| `orders` | FULL | Controllers/Home/active-order listeners; old status, verification and OTP comparisons (`rider_active_order_screen.dart:1293–1295`, `intercity_bookings_screen.dart:199`). Retain. |
| `rider_assignments` | DEFAULT | Incoming assignment cards/searching/travel-plan listeners (`incoming_order_card.dart:212`, `intercity_searching_screen.dart:662`, `travel_plan_details_screen.dart:416`). Keep; no new FULL requirement established. Validate any expected filtered DELETE separately. |
| `rider_withdrawals` | FULL | Earnings/Payouts all-events, filtered `user_id` (`rider_earnings_tab.dart:194`, `rider_payouts_screen.dart:100`). Old values not directly consumed, but filtered deletion refreshes matter. Retain pending payment/payout tests. |
| `rider_travel_plans` | FULL | Home all-events filtered `rider_id` (`rider_home_tab.dart:903`) reloads plans including deletion/completion. Retain filtered-delete semantics. |
| `order_chat_messages` | DEFAULT | Chat INSERT-only (`order_chat_screen.dart:1213`) and support list. Keep; no FULL needed for insert delivery. |
| `intercity_requests` | FULL | Searching all-events filtered `parcel_id` (`intercity_searching_screen.dart:723`), travel-plan/chat/bookings lifecycle callbacks. Retain pending filtered-delete/cancel flow tests. |
| `notifications` | DEFAULT | Badge all-events filtered `user_id` (`notification_badge_service.dart:99`); read state observer uses newRecord and known state. Keep; unknown/deletion events reconcile conservatively. |
| `order_verifications` | DEFAULT | No literal Flutter subscriber found. Candidate publication removal after external/admin consumer audit; keep now. |
| `rider_locations` | DEFAULT, PK rider_id | No Flutter subscriber found. Incident has **58 Deno GET records**, which require table/API access, **not publication**. Candidate publication removal after external/other-build audit. **Keep table, writes, trigger and publication now.** |

Thus both GPS tables are not proven necessary in the publication for this Flutter build: **riders is necessary; rider_locations has no demonstrated subscribing client**. No active rows were present in `realtime.subscription` at the later 00:04 IST inspection. That idle snapshot does not establish incident subscriber counts or rule out other deployed/admin builds. Removing only `rider_locations` publication would not by itself remove its UPSERT/near-destination SQL costs. No removal SQL was generated or applied.

## 5. Incident-specific GPS/Realtime contribution

The following is new, narrow incident inspection, not May statistics repackaged as causation. Explicit log query bounds were 16:22–16:34 UTC. Results are saved in `EVIDENCE.json.traffic`.

| Recorded gateway minute UTC (IST) | Riders PATCH records | Max PATCH origin ms | WebSocket GET records |
| --- | ---: | ---: | ---: |
| 16:22 (21:52) | 0 | — | 4 |
| 16:23 (21:53) | 0 | — | 1 |
| 16:24 (21:54) | 2 | 80 | 4 |
| 16:25 (21:55) | 2 | 87 | 0 |
| 16:26 (21:56) | 2 | 153 | 2 |
| 16:27 (21:57) | 1 | 107 | 1 |
| 16:28 (21:58) | 1 | 36 | 0 |
| 16:29 (21:59) | 1 | 81 | 0 |
| 16:30 (22:00) | 1 | 5,091 | 0 |
| 16:31 (22:01) | 1 | 8,845 | 0 |
| 16:32 (22:02) | 1 | 775 | 0 |
| 16:33 (22:03) | 1 | 100 | 0 |

All 13 PATCHes are Dart, none HTTP >=500. No direct REST write to `rider_locations` appears; the bridge's SQL writes remain invisible to this REST count. Its 58 GETs are Deno and do not identify the specific calling Edge Function. There are 12 WebSocket GET records, all before 16:28. These are transport requests, not counts of `phx_join`, SDK rejoin, channels, callbacks or rows in `realtime.subscription`; channel churn can occur on an existing socket. No incident subscription leak/storm was proven.

The `realtime.list_changes` event at **16:32:33.663 UTC / 22:02:33.663 IST** took **13,798.532 ms**, after unrelated reads had already slowed. Its outer Function Scan lacks per-table changes, subscription fanout, RLS timing and waits. It is consistent with a congested consumer and/or an amplifier, not a demonstrated initiator.

Later `pg_stat_statements`: dominant `list_changes` shape **2,605,255 calls, mean 11.571 ms**; another shape **479,595 calls, mean 6.376 ms**. Polling calls need not equal delivered events, subscribers or useful changes. GPS-shaped PATCH SQL matches the six Flutter fields: **25,957 calls, mean 79.535 ms, total 2,064,482.307 ms**. Reset is May 7, not November 1. These costs include execution/waits in their aggregate scope, not isolated trigger/index/CPU costs, and cannot supply incident execution rates. No claim that “2.6 million calls caused 22:02” is justified.

## 6. Local fixes, measured comparisons and tests

New application changes are limited to `realtime_manager.dart`, new `rider_update_filter.dart`, and the three filter call sites above. GPS acquisition settings, movement/heartbeat gates, uploaded fields, online filter, location stream, passenger tracking bindings, assignment and atomic acceptance were unchanged. KYC/payment authorization and production backend were unchanged.

Before/after was measured by running the same six new behavior tests with the previous two reconnect checks removed and the previous filter predicate reproduced, then restoring final files byte-for-byte in a `finally` block. Baseline: **2 pass / 4 fail**, expected. Fixed: **6/6 pass**.

| Deterministic scenario | Before | After |
| --- | --- | --- |
| SDK recovers during fallback delay | One unnecessary connectivity probe, removal and new channel | Zero probes/removals/replacements; original channel retained |
| SDK recovers during pending connectivity probe | One unnecessary removal/new channel | One already-started probe, zero removals/replacements |
| Channel still failed | One replacement | One replacement; fallback preserved |
| Last owner unsubscribes during backoff | No replacement | No replacement; disposal preserved |
| Full old row plus newly present business field | Incorrectly skipped | Normal processing |
| Partial old row plus offline status | Incorrectly skipped | Normal processing |

These are request/channel-object counts in fakes, **not production latency or WAL benchmarks**. The safe missing-field fallback may do more work when information is incomplete; suppressing eligibility updates is not a valid performance optimization.

Commands/results:

- `flutter test --no-pub test/part2_realtime_gps_test.dart test/waydrop_realtime_lifecycle_test.dart test/waydrop_gps_and_badge_test.dart test/phase1_gps_completion_test.dart test/phase1_tracking_controller_test.dart test/realtime_lifecycle_cleanup_regression_test.dart test/phase1_realtime_workload_regression_test.dart --reporter expanded`: **39 passed, 0 failed**.
- Final new tests plus `test/realtime_manager_release_safe_collision_guard_regression_test.dart`: **18 passed**, including six already counted new tests and **12 additional pooling guards**. Total distinct focused tests: **51**.
- Targeted analyzer across six changed source/test files: **0 errors, 1 existing warning**, unused `boostPercentVal` in `rider_orders_screen.dart:2023`; analyzer itself exits nonzero for that warning. New helper/test/manager diagnostics were corrected. Whole-project analyzer/full-suite history was not re-counted.
- Existing GPS tests verify concurrent starts open one stream, skipped fixes do not release an in-flight lock, repeated identical fixes do not add a PATCH, failures do not advance dedup state, a >=30-second stationary fix remains eligible, and a completed stream can restart. Tracking tests verify same-rider reuse, event coalescing and disposal. These are mocked HTTP/platform measurements, not physical-device accuracy measurements.

An initial test harness used widget fake time with default Auth refresh and left an Auth timer pending. It was corrected to regular asynchronous tests with Auth auto-refresh disabled and injected connectivity. It did not establish an application timer leak. Logs: `.dart_tool/part2-tests.log`, `part2-final-tests.log`, `part2-baseline-tests.log`, `part2-analyze.log`. [Verification/source hashes](realtime-gps-20261102/VERIFICATION.json).

## 7. Outstanding verification and production decisions

1. Rebuild on physical Android and iOS against an authorized test destination. Measure delivered fixes, GPS PATCH attempts/completions/affected rows, timestamp age, stationary/turn/movement accuracy, background recovery and passenger-map freshness. Nominal OS settings are not observed device rates.
2. Capture interval deltas of table updates/HOT, WAL bytes, subscriber rows per entity, changes processed versus delivered, RLS/trigger timing, lock waits and connection occupancy. The incident lacks those measurements; no per-table WAL or trigger-time improvement is claimed.
3. Audit deployed admin/web/other-build subscribers before changing either candidate publication or the payment identity. Managed tests must exercise filtered DELETE, status/COD/KYC transitions, payouts, passenger maps and intercity completion. Any production change needs explicit approval; none was requested or performed here.
4. Rehearse any future GPS-table split/index change with dispatch/freshness readers and supported old app builds. An unconditional stationary-trigger suppression or removal of `riders` events is unsafe with current dependencies.

**Final classification: verified architectural/code-level amplifier; incident-specific amplification is plausible but unmeasured; initiating cause remains unproven.** The small observed PATCH rate and lack of a gateway WebSocket burst at 22:02 weigh against the proposed GPS-write/reconnect storm, while not excluding unlogged channel/RLS work on existing sockets.
