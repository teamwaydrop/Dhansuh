# Phase A — `rider_locations` split: read-only audit & implementation plan

**Date:** 2026-09-08 · **Mode:** READ-ONLY. Nothing modified/created/applied/committed. Phase 2B-lite is live and verified.
**Goal:** move the high-frequency rider GPS stream off the transactional `riders` row into a dedicated `rider_locations` table, MIRROR-KEPT variant (`riders.current_lat/lng` retained as a low-frequency compatibility mirror; dispatch/nearby SQL unchanged initially).

---

## 0. Current production facts (verified 2026-09-08, post-2B-lite)

| Fact | Value |
|---|---|
| PostgreSQL | **17.6** (so `CREATE OR REPLACE TRIGGER` is available) |
| `riders` rows | 23 (4 `online` now) |
| `riders` columns | 33 |
| `riders` lifetime `UPDATE`s | 30,559 · **HOT ratio 5.5%** → 94.5% of updates touch **all 13 indexes** + full-row WAL |
| `riders` size | 264 kB total, **208 kB (79%) is indexes** |
| `riders` `REPLICA IDENTITY` | **FULL** · RLS enabled |
| Indexes touched by a GPS write | `idx_riders_online_coords (current_lat,current_lng WHERE online)`, `idx_riders_location_updated (last_location_updated_at)`, `idx_riders_account_status_service_mode` (INCLUDEs current_lat/lng/last_location_updated_at) — plus, because the update is non-HOT, **every** index gets a new tuple |
| GPS `UPDATE riders` (`pg_stat_statements`) | 25,566 calls · **mean 77.6 ms · max 9,005 ms** |
| Realtime WAL-decode (`SELECT wal->>…`) | **2,462,239 calls · mean 11.5 ms · max 15,866 ms · total 7.87 h** — the #1 DB-time consumer, still growing |
| `UPDATE orders SET order_status` (arrive/OTP/etc.) | mean **270–514 ms · max 4,969–7,039 ms** |
| `find_nearby_riders` | mean 44.8 / 59.1 / 228.5 ms (plan variants) · max 7,613–12,090 ms |
| realtime publication `supabase_realtime` | 20 tables; `riders` = FULL |

---

## 1. Every GPS WRITE

### W1 — `LocationCacheService.updateRiderLocation()` — HIGH FREQUENCY (the target)
`lib/core/services/location/location_cache_service.dart:700-771`
```dart
supabase.from('riders').update({
  'current_lat', 'current_lng',
  'current_heading',                       // 0 when NaN
  'last_location_updated_at', 'last_active_at', 'updated_at'   // all = now() ISO
}).eq('user_id', user.id).eq('account_status', 'online');       // <-- online-only guard
```
- **Callers:** only two — `_handlePositionUpdate` (position stream, `:532-594`) and `_performHeartbeatUpdate` (30 s `Timer.periodic`, `:320-379`). Both gated by `_shouldUploadPosition` / the heartbeat, both guarded by `isUpdatingDb` (≤ 1 in-flight write per client).
- **Stream config** (`:430-462`): Android `AndroidSettings(distanceFilter: 5, intervalDuration: 10 s, accuracy bestForNavigation)` + a foreground service; iOS `AppleSettings(distanceFilter: 5)`.
- **Throttle rules** (`_shouldUploadPosition`, `:600-667`): upload if **first ever** OR **moved ≥ 10 m** (`movementThresholdMeters`) OR **≥ 30 s since last DB write** (`heartbeatSeconds`).
- **Effective write rate:** ~1 write / 10–30 s per **online** rider.
- **Offline behaviour:** the `.eq('account_status','online')` filter means an `UPDATE` from an offline rider matches 0 rows (no-op). `stopRiderLiveTracking()` cancels the stream + heartbeat timer on go-offline / GPS-off. `monitorGpsStatus()` (`:777-846`) writes `account_status='offline', updated_at=now()` (no GPS cols) when the OS GPS toggle turns off, then stops tracking.
- **Go-online:** `startRiderLiveTracking()` opens the stream + heartbeat and fires one immediate `_performHeartbeatUpdate()`.
- **Error/retry:** `updateRiderLocation` wraps the write in `try/catch` → `debugPrint` only, **no retry**. A dropped GPS write is simply superseded by the next tick. The stream `onError` nulls `riderLocationStream` so `startRiderLiveTracking` can restart it.
- **Columns written:** exactly `current_lat, current_lng, current_heading, last_location_updated_at, last_active_at, updated_at`.

### W2 — Go-online write — LOW FREQUENCY
`lib/features/rider/home/rider_home_tab.dart:1219-1225`
```dart
await supabase.from('riders').update({
  'account_status': 'online', 'updated_at': nowIso,
  'current_lat': freshLat, 'current_lng': freshLng, 'last_location_updated_at': nowIso,
}).eq('user_id', supabase.auth.currentUser!.id);
```
- Fires once per "Go Online" tap (~763 lifetime `account_status` updates). Writes `current_lat/lng/last_location_updated_at` **without** `current_heading` / `last_active_at`.

### W3 — `load-testing` edge function (test harness, not production traffic)
`supabase/functions/load-testing/index.ts:96-98` — `current_lat/lng/current_heading` insert. Update for consistency; not on the critical path.

### W4 — `delete_own_account()` (SQL, account deletion)
Nulls `current_lat/current_lng/current_heading` on the `riders` row (it does **not** `DELETE FROM riders` — verified). Rare.

### Is W1 the only high-frequency GPS write path?
**Yes.** Grep of `lib/` + `supabase/functions/` for `.update(`/`.upsert(`/`.insert(` combined with a rider-coord column returns only W1, W2, W3, W4. `updateRiderLocation` (the JS map-pin function invoked via `runJavaScript("updateRiderLocation(...)")` in the tracking screens & `transport_map_widget`) is a **name collision** — it renders a marker in the WebView, it does not touch the DB.

### Is `updated_at` relied on elsewhere?
**Yes, materially:** `check_dormant_riders()` (cron job 2, hourly) keys its "offline > 2 h" test on **`riders.updated_at`**, not `last_active_at`. It only ever inspects riders where `account_status != 'online'`, and going offline (W2's sibling / the toggle) still stamps `updated_at` — so if W1 stops touching `riders.updated_at`, dormancy is unaffected (an online rider is never a dormancy candidate). See §7.

---

## 2 & 3. Every GPS/LOCATION READ — full inventory

### Dart read sites

| # | File · line | Function / widget | Kind | Fields | Why | Move to `rider_locations`? |
|---|---|---|---|---|---|---|
| **R1** | `core/services/realtime/realtime_order_controller.dart:526-554` | `_subscribeRider()` — Realtime `subscribe(table:'riders', filterColumn:'id', filterValue:riderId, event:update)` | realtime | `payload.newRecord['current_lat'/'current_lng'/'current_heading']` (`:537-539`) | **passenger live tracking** — feeds `riderLocationNotifier` | **MOVE** — subscribe `rider_locations` filter `rider_id`. Uses `newRecord` only, **never `oldRecord`** |
| **R2** | `realtime_order_controller.dart:338-366` | `_fetchRider()` — `.from('riders').select('id,user_id,rating,…,current_lat,current_lng,current_heading, rider_kyc(…), users(…)')` | one-shot query | `current_lat/lng/current_heading` (`:348-350`) | initial pin + rider card | **MOVE the 3 coord fields** to a `rider_locations` read (separate keyed query; the rest of the select stays on `riders`) |
| **R3** | `realtime_order_controller.dart:465-477` | `_updateRiderLocation(riderData)` | in-memory parse | `current_lat/lng/current_heading` from the map produced by R2 | sets `riderLocationNotifier` | follows R2 |
| **R4** | `features/local_rides/booking/screens/ride_location_screen.dart:1662-1695` | `_fetchNearbyRiders()` — `.from('riders').eq('account_status','online').not(current_lat is null).gte/lte('current_lat'/'current_lng', box)` (polled every 5 s while booking) | query | `current_lat/lng/current_heading` | "nearby bikes on the map" during booking | **KEEP on `riders` mirror** (plan #4). Optional later move. |
| **R5** | `features/local_parcels/booking/screens/parcel_booking_screen.dart:296-328` | same bounding-box nearby query | query | `current_lat/lng/current_heading` | nearby-parcel-rider map | **KEEP on `riders` mirror** |
| **R6** | `features/intercity/parcels/booking/intercity_booking_screen.dart:241-270` | `.from('riders').select('id,current_lat,current_lng,current_heading').not(current_lat is null)` | query | `current_lat/lng/current_heading` | intercity "available riders" map | **KEEP on `riders` mirror** |
| **R7** | `features/intercity/shared/screens/intercity_searching_screen.dart:393, 478-479, 624-626, 1233-1234` | `.from('rider_assignments').select('… riders(user_id,account_status,rating,current_lat,current_lng)')` **embedded join** | query | `current_lat/lng` (+ `current_heading` mapped) | matched-rider positions on the intercity searching screen | **KEEP on `riders` mirror** — PostgREST embed needs the `rider_assignments.rider_id → riders.id` FK; there is no FK path to `rider_locations`. A later phase would switch to a keyed query. |
| **R8** | `shared/widgets/maps/transport_map_widget.dart:559` | reads `rider['current_heading']` from props | prop read | `current_heading` | marker rotation | **no change** — consumes whatever R1/R2/E1 supply; auto-fixed |
| **R9** | `rider_home_tab.dart:112-116`, `rider_orders_screen.dart:336-340`, `user/home/home_tab.dart:858-862` | `_locationHeartbeatFields` sets | **allow-list to IGNORE** | `current_lat/lng/current_heading/last_location_updated_at/last_active_at/updated_at` | let those screens' `riders` realtime subs SKIP a GPS-only update | **no change** — after the split, `riders` emits location-only events only on the rare mirror write; the gates keep working and rarely fire |

**Passenger-tracking screens (`ride_tracking_screen`, `parcel_tracking_screen`, `intercity_tracking_screen`, the searching screens, `payment_processing_screen`)** — verified: **none of them subscribe to `riders` directly.** They all consume `RealtimeOrderController.riderLocationNotifier` / `liveStateNotifier`. **Fixing R1 + R2 + E1 fixes every passenger-tracking screen at once.** (G1 scope for the tracking path = 2 files: `realtime_order_controller.dart` + `get-live-order-status/index.ts`.)

### Edge Function reads

| # | File · line | What | Move? |
|---|---|---|---|
| **E1** | `supabase/functions/get-live-order-status/index.ts:143-146` (embedded select `rider.current_lat/current_lng/current_heading/last_location_updated_at`), `:325-326` (rider→pickup distance), `:503-514` (`live_location` response object) | **authoritative passenger-side live rider position** — polled fallback for `RealtimeOrderController` | **MOVE** — add a `.from('rider_locations').eq('rider_id', order.rider_id)` fetch inside the existing `Promise.all`, source `live_location` from it, **fall back to `rider.current_lat/lng` when the `rider_locations` row is missing or stale** (rollout safety) |
| **E2** | `load-testing/index.ts:96-98` | writes GPS to `riders` in the load harness | update for consistency; low priority |
| **E3** | `start-dispatch/index.ts:513` | calls `find_nearby_riders` RPC | **no change** — the RPC reads the `riders` mirror |

### `newRecord` / `oldRecord` usage on `riders` subscriptions (see also §5)

| Subscription | file:line | filter | `newRecord`? | `oldRecord`? | Post-split |
|---|---|---|---|---|---|
| R1 passenger tracking | `realtime_order_controller.dart:527` | `id` | yes (coords) | **no** | MOVE → `rider_locations`, `newRecord` only |
| rider home tab | `rider_home_tab.dart:572` | `id` | yes | **yes** — `isLocationOnlyUpdate` gate (`:592`) | stays on `riders`; gate unaffected (no RI change) |
| rider orders screen | `rider_orders_screen.dart:374` | `id` | yes | **yes** — `isLocationOnlyUpdate` gate (`:389`) | stays on `riders` |
| rider earnings tab | `rider_earnings_tab.dart:220` | `user_id` | yes | **yes** — `isEarningsUiRelevantUpdate` gate (`:228`) | stays on `riders` |
| rider profile tab | `rider_profile_tab.dart:224` | `user_id` | yes | **yes** — `isProfileRelevantUpdate` gate (`:232`) | stays on `riders` |
| rider main navigation (service_mode) | `rider_main_navigation_screen.dart:123` | `user_id`/`id` | yes | needs spot-check, same gate pattern | stays on `riders` |
| passenger home tab | `user/home/home_tab.dart:939` (`event: .all`) | `user_id` | yes | **yes** — `isLocationOnlyUpdate` gate (`:955`) | stays on `riders` |

**Only R1 reads GPS from a realtime payload.** The other six subscribe to `riders` for *non-GPS* reasons (online toggle, earnings, subscription, profile, service_mode) and use `payload.oldRecord` **purely to discard** the GPS-write fan-out. Because Phase A **does not change `riders` REPLICA IDENTITY**, those `oldRecord` gates are untouched — and after the split they simply receive far fewer events.

---

## 4. SQL dependency audit

| # | Object | Type | GPS fields | Purpose · frequency | Move / Keep |
|---|---|---|---|---|---|
| S1 | `find_nearby_riders(p_order_id,…)` | fn | `riders.current_lat/lng`, `last_location_updated_at` | **dispatch matcher** — per `start-dispatch` round | **KEEP** — reads the `riders` mirror. Staleness gate is `last_location_updated_at ≥ now()-stale_sec` **OR `≥ now()-24h` OR IS NULL** → tolerates a 60 s mirror trivially. |
| S2 | `assign_nearby_searching_orders_core(p_rider_id,…,p_current_lat,p_current_lng,…)` | fn | lat/lng are **parameters** | rematch core | **no change** — callers pass the coords |
| S3 | `assign_nearby_searching_orders_on_rider_freed()` | trigger fn (on `orders`) | `SELECT current_lat,current_lng FROM riders WHERE id=NEW.rider_id` | on rider freed | **KEEP** — reads the mirror |
| S4 | `assign_nearby_searching_orders_to_rider()` | trigger fn (on `riders` `account_status`→online) | `NEW.current_lat/lng` | on go-online — uses W2's coords | **no change** (fires on the `riders` row, W2 populated it) |
| S5 | `assign_new_order_to_nearby_online_riders_core()` | fn | `riders.current_lat/lng` | new-order async match | **KEEP** — reads the mirror |
| S6 | `redispatch_freed_riders()` | cron fn (45 s) | `SELECT r.current_lat,r.current_lng FROM riders r WHERE account_status='online'…` | backstop rematch | **KEEP** — reads the mirror |
| S7 | `rider_self_rematch()` | fn | `riders.current_lat/lng` | rider-initiated rematch | **KEEP** — reads the mirror |
| **S8** | `on_rider_location_near_destination()` behind **`trigger_near_destination_check` `AFTER UPDATE OF current_lat, current_lng ON riders`** | trigger fn | `NEW.current_lat`, `NEW.current_lng`, `NEW.id` | intercity "almost there" push — **fires on EVERY GPS write** today | **MOVE the trigger to `rider_locations`**; the body's single `NEW.id` (used as `WHERE rider_id = NEW.id`) becomes `NEW.rider_id`. Keep the old function for rollback; add a sibling `on_rider_locations_near_destination()`. |
| S9 | `delete_own_account()` | fn | `UPDATE riders SET current_lat=NULL, current_lng=NULL, current_heading=NULL` | account deletion (soft — does **not** delete the `riders` row) | **add** a `DELETE FROM public.rider_locations WHERE rider_id = <rider>` (or null it) so a soft-deleted account doesn't leave a stale `rider_locations` row. Minor; Stage A4. |

**Triggers on `riders` that fire on a GPS write today:** `protect_rider_financial_columns_trigger` (BEFORE UPDATE, all columns — in-memory compare + `auth.role()`, cheap but per-write) and `trigger_near_destination_check` (S8). After the split, **neither fires on the GPS stream** (writes go to `rider_locations`; `rider_locations` has **no** triggers except the moved near-destination one and needs **no** financial-protection trigger — it has no financial columns).

**No SQL function references `last_active_at`.** `check_dormant_riders()` uses `riders.updated_at`.

---

## 5. Realtime audit (CRITICAL)

**A. Publication `supabase_realtime` — 20 tables:** intercity_requests(FULL), notifications(FULL), order_assignment_logs(DEFAULT), order_chat_messages(FULL), order_status_history(DEFAULT), order_verifications(FULL), orders(FULL), payments(FULL), pricing_zones(DEFAULT), rider_assignments(FULL), rider_kyc(FULL), rider_payout_accounts(DEFAULT), rider_payout_updates_log(DEFAULT), rider_reviews(DEFAULT), rider_subscription_history(DEFAULT), rider_travel_plans(FULL), rider_withdrawal_events(DEFAULT), rider_withdrawals(FULL), **riders(FULL)**, users(FULL). → `rider_locations` must be **ADDED**.

**B. Dart `riders` subscribers — 7** (table in §2/§3). Only **R1** consumes GPS.

**C. Which `riders` columns cause a UI refresh** — per the six non-tracking subscribers' gates: `account_status`, `service_mode`, `total_orders/total_completed_orders/total_earnings/today_earnings/wallet_balance/cod_pending_amount/cod_limit/government_tax_due_balance`, `subscription_active/subscription_expires_at`, `commission_waiver_active`, `is_verified`, `rating/rating_sum/total_ratings`, `kyc_id`, `free_trial_*`. **The six GPS/heartbeat columns never do** (they are the `_locationHeartbeatFields` allow-list).

**D. Subscribers using `oldRecord`:** the six non-tracking subscribers (to diff and skip GPS-only updates). **Not R1.**
**E. Subscribers using `newRecord`:** all 7 (for the changed row); **only R1 reads a GPS value from it.**

**F. `REPLICA IDENTITY` for `rider_locations` → DEFAULT is sufficient. FULL is NOT needed.**
- The single realtime consumer (R1) reads `payload.newRecord['current_lat'/'current_lng'/'current_heading']` and compares against its own cached `riderNotifier.value` — **it never touches `payload.oldRecord`** (verified `realtime_order_controller.dart:532-554`).
- No consumer branches on a `rider_locations` DELETE's old row (deletes are account-deletion only, rider offline, not tracked).
- `DEFAULT` → the WAL old-record for an UPDATE is the PK only → **minimal WAL bytes and minimal `list_changes` decode payload for the high-frequency stream** — which is the entire purpose of Phase A.
- FULL would re-introduce the full-old-tuple decode cost on every GPS ping, i.e. it would defeat the optimization.

| Realtime consumer | current payload dep | new payload dep | `oldRecord` required? | DEFAULT sufficient? | FULL necessary? |
|---|---|---|---|---|---|
| R1 (`_subscribeRider`) | `riders` UPDATE, `newRecord.current_lat/lng/heading` | `rider_locations` UPDATE, `newRecord.current_lat/lng/heading` | **no** | **yes** | no |
| the six non-tracking `riders` subs | `riders` UPDATE, `newRecord` + `oldRecord` diff | **unchanged** (still subscribe `riders`) | yes (unchanged) | n/a — `riders` RI not changed by Phase A | n/a |

---

## 6. RLS design for `rider_locations`

**Who must read `rider_locations` as a client role (`authenticated`)?** Only **one** case: a passenger whose active order is assigned to that rider (R1 realtime). `get-live-order-status` (E1) reads it as **`service_role`** → bypasses RLS. Rider screens read the `riders` mirror or device GPS, not `rider_locations` (in the mirror-kept variant). Nearby-search stays on `riders`.

| Option | Security | Query cost | Realtime-compatible | Passenger sees only their rider? | Malicious read of arbitrary coords? |
|---|---|---|---|---|---|
| **A** — `USING (EXISTS(SELECT 1 FROM riders r WHERE r.id=rider_locations.rider_id AND (r.account_status='online' OR r.user_id=(SELECT auth.uid()))))` | replicates today's over-broad `riders` "view online riders" exposure | 1 indexed subquery / row | yes | **no** — any authed user sees every online rider's exact coords | **yes** — same leak `riders` has today |
| **B** — denormalized `is_online bool` on `rider_locations`, `USING (is_online OR owner)` | still broad; needs the go-online/offline path to also write `rider_locations.is_online` (extra coupling) | cheap (no subquery) | yes | no | yes |
| **C** — no client policy; all reads via a `SECURITY DEFINER` RPC | tightest; but the passenger then **polls** instead of receiving realtime → worse pin latency; that RPC already exists (`get-live-order-status`) | n/a | **no** (kills the realtime push) | yes | no |
| **D** — **scoped passenger policy + owner policy** (recommended) | tightest that keeps realtime | 1 indexed `EXISTS(orders)` per event **per subscribed passenger** (not a fan-out — the sub filters `rider_id`, so exactly one row, one eval) | **yes** | **yes** | **no** |

### Recommended — Option D
```sql
ALTER TABLE public.rider_locations ENABLE ROW LEVEL SECURITY;   -- no FORCE

-- passenger: the location of the rider on an order they own that is still active
CREATE POLICY "passenger tracks assigned rider location" ON public.rider_locations
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.rider_id = rider_locations.rider_id
      AND o.user_id  = (SELECT auth.uid())
      AND o.order_status IN ('accepted','rider_arrived','picked_up','ongoing','rider_at_drop','payment_pending')
  ));

-- rider owner (defensive; the rider app does not currently read this table)
CREATE POLICY "rider views own location row" ON public.rider_locations
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.riders r
                 WHERE r.id = rider_locations.rider_id AND r.user_id = (SELECT auth.uid())));

-- NO INSERT/UPDATE/DELETE policy for authenticated  -> writes are service_role / SECURITY-DEFINER only.
```
- `orders(rider_id)` is indexed (`idx_orders_rider_id`); `orders(user_id)` too. The `EXISTS` is one bounded index probe.
- **This is stricter than `riders` today** — a passenger can see a rider's coordinates **only** while genuinely matched on an active order, versus `riders`' current "any authenticated user can see any `online` rider's exact position". Phase A therefore *improves* location privacy for the tracking path.
- Realtime evaluates this once per GPS event for the one subscribed passenger (subscription filter `rider_id=<id>` → single row). Not O(subscribers).

---

## 7. `last_active_at` / availability audit

**Every consumer of `riders.last_active_at`:**
- **Written by:** only **W1** (`updateRiderLocation`).
- **Read by SQL:** **none** — no function, no trigger, no RPC references it (verified against every `pg_proc` body).
- **Read by Dart:** **none for logic or display** — it appears only inside the `_locationHeartbeatFields` allow-lists (i.e. code that explicitly *ignores* it).
- **Read by edge functions:** none.

**What considers a rider "online":** `riders.account_status = 'online'` (an enum), full stop. Set by the go-online write (W2) and cleared by go-offline / `monitorGpsStatus` / the toggle.
**Dormancy** (`check_dormant_riders`, cron job 2, hourly): candidates are riders with `account_status != 'online'` **AND `riders.updated_at < now() - INTERVAL '2 hours'`** (plus per-notification cooldowns). It never looks at `last_active_at`.
**Dispatch staleness** (`find_nearby_riders`): uses **`last_location_updated_at`**, not `last_active_at`.
**Heartbeat updates it:** yes (W1), every 10–30 s while online — but nothing reads that.

**Recommendation:** `last_active_at` is **effectively vestigial**.
- **Keep the column on `riders`** (do not drop — plan #9) but it is acceptable for the high-frequency stream to **stop writing it** (nothing observes the value).
- **Do NOT rely on it for anything in Phase A.** Optionally also store `last_active_at` in `rider_locations` for symmetry, but there is no functional need.
- `riders.updated_at` (which dormancy *does* use) must keep being stamped by **go-offline** paths — verified W2's sibling / `monitorGpsStatus` do stamp it; the app's manual offline toggle path (`rider_home_tab.dart:1047` region) must be confirmed to stamp `updated_at` (spot-check in Stage A3). An *online* rider is never a dormancy candidate, so W1 no longer touching `riders.updated_at` is safe.

---

## 8. Mirror strategy

**Proposed:** `rider_locations` = high-frequency source (client writes every ping); `riders.current_lat/lng/current_heading/last_location_updated_at[/last_active_at]` = low-frequency mirror.

| Question | Finding |
|---|---|
| How often should the mirror update `riders`? | **Every ~60 s, or on ≥ ~150 m movement** — whichever first. |
| Does every GPS update still write `riders` (defeating the purpose)? | **No, by design.** The client writes `riders` only when its own throttle (60 s / 150 m) trips → ~1 `riders` write / minute per online rider instead of ~4–6 → **~75–85 % fewer `riders` GPS-driven writes**, each of which was the 77 ms / 13-index / full-row-WAL cost. |
| Is a time/threshold-based mirror sufficient for dispatch? | **Yes.** `find_nearby_riders` and the redispatch functions all accept `last_location_updated_at ≥ now()-60s` **OR `≥ now()-24h` OR IS NULL**. 60 s ≈ 0.5–1 km of city movement — well inside a 3–5 km dispatch radius, and the redispatch cron re-runs every 20–60 s. |
| Is a stale mirror acceptable for current `find_nearby_riders` behaviour? | **Yes** — its staleness tolerance is already effectively 24 h; a 60 s mirror is strictly fresher than what it tolerates today for a stationary rider. |
| Do NULL / 24 h staleness semantics remain correct? | **Yes.** Stage A1 backfills `rider_locations` from `riders`, and the mirror only ever *narrows* the `riders` freshness gap (60 s vs today's 10–30 s). A brand-new rider with no GPS: both `riders.current_lat` and `rider_locations` are NULL → `find_nearby_riders`' `IS NULL` branch still matches (rider stays dispatchable), unchanged. |

**Two ways to produce the mirror:**
1. **Client-side throttle (recommended end state).** `updateRiderLocation()` writes `rider_locations` every ping + `riders` only when its 60 s / 150 m throttle trips. Pros: server does zero extra work; the `riders` write rate genuinely drops. Cons: needs the Flutter release; **old app versions keep writing `riders` every ping** until they update (G10) — but that is *current* behaviour, so no regression, just delayed benefit for slow updaters.
2. **DB bridge trigger** `AFTER UPDATE OF current_lat, current_lng ON riders` → `INSERT INTO rider_locations … ON CONFLICT (rider_id) DO UPDATE`. Purpose: keep `rider_locations` fresh for **every** rider (any app version) during the rollout window, so R1 realtime tracking works even when the tracked rider is on an old app. Cost: one cheap upsert per `riders` GPS write **during the transition only**; drop it once client adoption is high.

**Recommended combination:** ship **both** — bridge trigger in A1 (guarantees `rider_locations` freshness for all riders immediately, so passenger tracking is fully functional), then client throttle in A3 (starts actually reducing `riders` write load), then drop the bridge in A6 once old-app riders are negligible. The load-reduction payoff of Phase A therefore lands at A3+A6, not A1.

---

## 9. Migration / rollout design (additive, staged, reversible)

### Stage A1 — create `rider_locations` (DB migration; zero behaviour change)
- **SQL objects:** `CREATE TABLE public.rider_locations` (§D below) · PK `rider_id` · FK `→ riders(id) ON DELETE CASCADE` · `CREATE INDEX idx_rider_locations_updated ON rider_locations(last_location_updated_at DESC)` · `ALTER TABLE … REPLICA IDENTITY DEFAULT` · `ENABLE ROW LEVEL SECURITY` + the 2 Option-D SELECT policies · `ALTER PUBLICATION supabase_realtime ADD TABLE public.rider_locations` · **backfill** `INSERT INTO rider_locations (rider_id, current_lat, current_lng, current_heading, last_location_updated_at, updated_at) SELECT id, current_lat, current_lng, current_heading, last_location_updated_at, now() FROM public.riders ON CONFLICT DO NOTHING` · **bridge trigger** `enqueue_rider_location_mirror()` `AFTER UPDATE OF current_lat, current_lng ON public.riders` → upsert into `rider_locations` (thin, SECURITY DEFINER, `ON CONFLICT DO UPDATE`).
- **Files:** 1 new migration only. No Dart, no edge fn.
- **Risk:** LOW. The only added runtime cost is the bridge upsert per `riders` GPS write (a 1-index-table upsert, ~sub-ms). Realtime gains a 20th published table.
- **Rollback:** `ALTER PUBLICATION … DROP TABLE public.rider_locations; DROP TRIGGER … ON public.riders; DROP FUNCTION enqueue_rider_location_mirror(); DROP TABLE public.rider_locations;` — nothing depends on it yet.

### Stage A2 — `get-live-order-status` reads `rider_locations` (edge fn deploy; no client release)
- **Files:** `supabase/functions/get-live-order-status/index.ts` only. Add a `.from('rider_locations').select('current_lat,current_lng,current_heading,last_location_updated_at').eq('rider_id', order.rider_id).maybeSingle()` inside the existing `Promise.all`; source `live_location` + the rider→pickup distance from it; **fall back to the embedded `rider.current_lat/lng/current_heading`** when the `rider_locations` row is absent or `last_location_updated_at` is older than the embedded `riders` value.
- **Risk:** LOW-MED. Behaviour-neutral because the fallback preserves exactly today's data when `rider_locations` is not yet fresher. `deno check` parity, a new regression guard.
- **Rollback:** redeploy the prior `get-live-order-status`.

### Stage A3 — passenger live-tracking readers + client GPS writer (Flutter release)
- **Files:** `lib/core/services/realtime/realtime_order_controller.dart` (R1 `_subscribeRider` → `rider_locations` filter `rider_id`; R2 `_fetchRider` reads coords from a `rider_locations` keyed query with a `riders.*` fallback; R3 follows) · `lib/core/services/location/location_cache_service.dart` (`updateRiderLocation()` → upsert `rider_locations` every ping **and** the throttled `riders` write).
- **Risk:** MED — this is the G1 "readers move together" cut; must ship the R1/R2 change and the writer change in the **same build**. Passenger-tracking screens auto-follow (they only consume `riderLocationNotifier`).
- **Rollback:** ship the previous build (writes `riders` every ping, reads `riders`); server-side A1/A2 keep working.
- **Rollout-window degradation (document):** if the tracked rider is on a pre-A3 app, R1's `rider_locations` subscription gets no events **from the client** — but the A1 bridge trigger still upserts `rider_locations` from that rider's `riders` GPS writes, so realtime tracking still works. Without the bridge, that pair falls back to the 15–45 s `get-live-order-status` poll until both apps update.

### Stage A4 — near-destination trigger → `rider_locations` (DB migration)
- **SQL objects:** `CREATE FUNCTION public.on_rider_locations_near_destination()` (copy of `on_rider_location_near_destination`, `NEW.id` → `NEW.rider_id`) · `CREATE TRIGGER trigger_near_destination_check_v2 AFTER UPDATE OF current_lat, current_lng ON public.rider_locations …` · `DROP TRIGGER trigger_near_destination_check ON public.riders` · keep `on_rider_location_near_destination()` for rollback · add `DELETE FROM public.rider_locations WHERE rider_id = <rider>` to `delete_own_account()` (or null it).
- **Risk:** LOW. The function logic is identical; only the row-identity column and the attach point change.
- **Rollback:** recreate `trigger_near_destination_check` on `riders`; drop the v2 trigger + function.

### Stage A5 — validate dispatch/nearby still work from the `riders` mirror (measurement, no code)
- Confirm `find_nearby_riders` returns online riders whose `riders.last_location_updated_at` is now ≤ 60 s stale (post-throttle) — still within its `≤ 24 h` gate. Confirm the booking-screen nearby map still renders pins. Capture `find_nearby_riders` `pg_stat_statements` before/after.

### Stage A6 — much later, NOT this phase
- Drop the A1 bridge trigger once pre-A3 app share is negligible · consider pointing S1/S3/S5/S6/S7 + R4/R5/R6/R7 at `rider_locations` and dropping `idx_riders_online_coords` / `idx_riders_location_updated` · only after all that, consider `ALTER TABLE riders DROP COLUMN current_lat/current_lng/current_heading/last_location_updated_at/last_active_at`.

---

## 10. Performance proof plan

**Capture the same query set immediately BEFORE Stage A3 and again ~24 h after Stage A3 adoption is meaningful, plus a live "3-ride" reproduction each time.**

```sql
-- 1. riders vs rider_locations write volume + HOT ratio
select relname, n_tup_upd, n_tup_hot_upd,
       round(100.0*n_tup_hot_upd/nullif(n_tup_upd,0),1) as hot_pct,
       pg_size_pretty(pg_indexes_size(('public.'||relname)::regclass)) as idx_size
from pg_stat_user_tables where relname in ('riders','rider_locations');

-- 2. the GPS write statement (riders) + the new rider_locations upsert
select calls, round(mean_exec_time::numeric,1) mean_ms, round(max_exec_time::numeric,0) max_ms,
       round(total_exec_time::numeric,0) total_ms, left(regexp_replace(query,'\s+',' ','g'),90) q
from extensions.pg_stat_statements
where query ilike '%UPDATE%"public"."riders"%current_%'
   or query ilike '%rider_locations%'
order by total_exec_time desc;

-- 3. order status-transition timing (arrive / OTP / completion)
select calls, round(mean_exec_time::numeric,1) mean_ms, round(max_exec_time::numeric,0) max_ms, left(query,80) q
from extensions.pg_stat_statements
where query ilike '%UPDATE%"public"."orders"%order_status%' or query ilike '%complete_order_and_settle%'
order by total_exec_time desc limit 10;

-- 4. find_nearby_riders
select calls, round(mean_exec_time::numeric,1) mean_ms, round(max_exec_time::numeric,0) max_ms
from extensions.pg_stat_statements where query ilike '%find_nearby_riders%' or query ilike '%p_pickup_lat%';

-- 5. realtime WAL-decode cost (the #1 consumer)
select calls, round(mean_exec_time::numeric,1) mean_ms, round(max_exec_time::numeric,0) max_ms, round(total_exec_time::numeric,0) total_ms
from extensions.pg_stat_statements where query ilike '%SELECT wal->>%';

-- 6. realtime health (query_logs, realtime_logs source): count of
--    "IncreaseSubscriptionConnectionPool: Too many database timeouts" and
--    "Tenant ... has been terminated" over the test window (before vs after)

-- 7. live contention during the 3-ride reproduction (sample every ~5s while testing)
select now(), state, wait_event_type, wait_event, count(*)
from pg_stat_activity where datname=current_database() group by 2,3,4;
select count(*) filter (where wait_event_type='Lock') as lock_waiters,
       count(*) filter (where state='idle in transaction') as idle_in_txn,
       max(extract(epoch from now()-query_start)) filter (where state='active') as longest_active_s
from pg_stat_activity where datname=current_database();

-- 8. transaction commit-lag proxy for "Swipe to Arrive": for each test ride compare
--    orders.rider_arrived_at (stamped) vs min(order_status_history.created_at where new_status='rider_arrived') (committed)
--    -- Phase A target: shrink that gap toward < 1 s.

-- 9. dead-tuple / autovacuum pressure on riders
select relname, n_dead_tup, last_autovacuum, autovacuum_count from pg_stat_user_tables where relname in ('riders','rider_locations');
```

**Success = after A3:** `riders` `n_tup_upd` growth rate drops ~75%+ and HOT ratio rises; `UPDATE riders SET current_*` mean/max falls; `SELECT wal->>…` mean/total growth rate falls; realtime "too many database timeouts" / tenant-restart events drop; the `rider_arrived` stamped-vs-committed gap shrinks; `find_nearby_riders` unchanged; a 6-ride back-to-back test stays responsive.

---

## 11. Safety / regression matrix

| Behaviour | Verdict | Note |
|---|---|---|
| rider go-online | **SAFE** | W2 still writes `riders` (account_status + coords); `trigger_assign_nearby_orders` + `handle_rider_status_change` unchanged. Spot-check the toggle path stamps `updated_at`. |
| rider go-offline | **SAFE** | `monitorGpsStatus` / toggle write `account_status='offline', updated_at=now()`; `stopRiderLiveTracking` unchanged. Dormancy keys on `updated_at`. |
| rider GPS write | **NEEDS CHANGE** | A3: client writes `rider_locations` every ping + `riders` throttled. |
| rider heading | **NEEDS CHANGE** | moves with lat/lng into `rider_locations`; go-online (W2) does not set heading today (unchanged). |
| passenger live tracking | **NEEDS CHANGE** (G1) | A2 (get-live-order-status) + A3 (R1/R2) must ship together; tracking screens auto-follow. |
| dispatch (`find_nearby_riders`, redispatch, rematch) | **SAFE** | reads the `riders` mirror; staleness tolerance ≫ 60 s. Validate in A5. |
| nearby-rider search (booking maps R4/R5/R6/R7) | **SAFE** | unchanged, reads the `riders` mirror. |
| stale-rider handling | **SAFE** | `last_location_updated_at` in the mirror stays ≤ 60 s fresh; NULL semantics preserved via backfill. |
| dormancy (`check_dormant_riders`) | **SAFE** | keys on `riders.updated_at` + `account_status`, never `last_active_at`; online riders excluded. |
| near-destination notification (S8) | **NEEDS CHANGE** | A4: move trigger to `rider_locations`, `NEW.id`→`NEW.rider_id`. |
| accept order | **SAFE** | no GPS dependency. |
| arrive (`rider_arrived`) | **SAFE** (improves) | Phase A removes the near-destination + financial-protect trigger firing from the GPS stream and cuts `riders` WAL/index churn → less contention on the `UPDATE orders SET order_status='rider_arrived'` transaction. |
| OTP / `ongoing` | **SAFE** (improves) | same. |
| completion (`complete_order_and_settle`) | **SAFE** | no GPS dependency; unchanged (2B-lite already verified byte-identical). |
| earnings / profile UI | **SAFE** | those `riders` subscriptions are unchanged; after the split they get fewer (not more) events. |
| realtime UI (all `riders` subscribers) | **SAFE** | `riders` REPLICA IDENTITY unchanged → `oldRecord` gates intact; `rider_locations` DEFAULT is sufficient for R1. |
| RLS / security | **SAFE** (improves) | Option D scopes location visibility to the matched passenger — *stricter* than `riders`' current "any online rider" policy. No `riders` RLS change. |
| `load-testing` edge fn | **NEEDS CHANGE** (low priority) | update W3 to write `rider_locations` for realistic load tests. |
| `delete_own_account` | **NEEDS CHANGE** (minor, A4) | also clear the `rider_locations` row on soft account deletion. |

**No row is HIGH RISK.**

---

## 12. FINAL OUTPUT

### A. Complete location dependency map
```
WRITE
  W1 location_cache_service.dart::updateRiderLocation()  [HIGH FREQ, online-only]  ─┐
  W2 rider_home_tab.dart go-online update                [LOW FREQ]                 │→ public.riders
  W3 load-testing/index.ts                                [test only]              │   current_lat/lng/heading
  W4 delete_own_account() nulls coords                    [rare]                   ─┘   last_location_updated_at
                                                                                       last_active_at, updated_at
                                                            │
                       ┌────────────────────────────────────┴───────────────────────────────┐
                       ▼ (stays on riders mirror)                                            ▼ (moves to rider_locations)
   DISPATCH / NEARBY (KEEP)                                              PASSENGER LIVE TRACKING (MOVE)
     S1 find_nearby_riders            R4 ride_location_screen box          R1 realtime_order_controller._subscribeRider
     S3 assign…_on_rider_freed        R5 parcel_booking_screen box         R2 realtime_order_controller._fetchRider (coords)
     S4 assign…_to_rider              R6 intercity_booking_screen          R3 realtime_order_controller._updateRiderLocation
     S5 assign_new_order…core         R7 intercity_searching embed         E1 get-live-order-status (live_location)
     S6 redispatch_freed_riders                                           S8 near-destination trigger  ── (Stage A4)
     S7 rider_self_rematch                                                (all passenger tracking screens auto-follow R1)
   NON-GPS riders realtime subs (6): rider_home/orders/earnings/profile/nav + passenger home — unchanged, quieter
   DORMANCY: check_dormant_riders → riders.updated_at (NOT last_active_at) — unaffected
```

### B. Exact files that will change
| Stage | File | Change |
|---|---|---|
| A2 | `supabase/functions/get-live-order-status/index.ts` | fetch `rider_locations` (Promise.all) + `riders.*` fallback for `live_location` |
| A3 | `lib/core/services/realtime/realtime_order_controller.dart` | `_subscribeRider` → `rider_locations` (filter `rider_id`); `_fetchRider` coord read → `rider_locations` keyed query + fallback; `_updateRiderLocation` unchanged (still parses a map) |
| A3 | `lib/core/services/location/location_cache_service.dart` | `updateRiderLocation()` → upsert `rider_locations` every ping + throttled `riders` write (60 s / 150 m) |
| A6 (later) | `supabase/functions/load-testing/index.ts` | write `rider_locations` |
| — | *no other Dart file* | passenger tracking screens & the six non-tracking `riders` subs are untouched |

### C. Exact SQL functions/triggers that will change
| Stage | Object | Change |
|---|---|---|
| A1 | **NEW** `public.rider_locations` table + `idx_rider_locations_updated` + 2 RLS policies + publication add + backfill | additive |
| A1 | **NEW** `public.enqueue_rider_location_mirror()` + trigger `AFTER UPDATE OF current_lat,current_lng ON public.riders` | bridge (drop in A6) |
| A4 | **NEW** `public.on_rider_locations_near_destination()` (copy, `NEW.id`→`NEW.rider_id`) + **NEW** trigger on `rider_locations`; **DROP** `trigger_near_destination_check` on `riders` (keep the old function) | move |
| A4 | `public.delete_own_account()` | add `DELETE FROM public.rider_locations WHERE rider_id = <rider>` |
| — | `find_nearby_riders`, `assign_nearby_searching_orders_*`, `redispatch_freed_riders`, `rider_self_rematch`, `check_dormant_riders`, `handle_rider_status_change`, `complete_order_and_settle` | **NO CHANGE** |
| — | `riders` RLS, `riders` REPLICA IDENTITY, cron jobs | **NO CHANGE** |

### D. Recommended `rider_locations` schema
```sql
CREATE TABLE public.rider_locations (
    rider_id                 uuid PRIMARY KEY REFERENCES public.riders(id) ON DELETE CASCADE,
    current_lat              double precision,
    current_lng              double precision,
    current_heading          double precision,
    last_location_updated_at timestamptz NOT NULL DEFAULT now(),
    last_active_at            timestamptz,          -- carried for symmetry; nothing reads it (see §7)
    updated_at               timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.rider_locations REPLICA IDENTITY DEFAULT;         -- §5F: DEFAULT is sufficient
CREATE INDEX idx_rider_locations_updated ON public.rider_locations (last_location_updated_at DESC);
ALTER PUBLICATION supabase_realtime ADD TABLE public.rider_locations;
-- + Option-D RLS (§6)
```
- One row per rider (`rider_id` PK). No history — every reader wants "now" (R1–R9, S1–S8, E1).
- `ON DELETE CASCADE` cleans up on a hard `riders` delete; soft delete handled in A4.
- Column names identical to `riders.*` so the moved near-destination function needs only the `NEW.id`→`NEW.rider_id` change.

### E. Recommended RLS — **Option D** (§6): scoped passenger `EXISTS(orders …active…)` + owner policy; no client write policy. Stricter than `riders` today; one bounded index probe per event per subscribed passenger; realtime-compatible.

### F. Recommended realtime / REPLICA IDENTITY — **`rider_locations` REPLICA IDENTITY DEFAULT**, added to `supabase_realtime`. R1 uses `newRecord` only → DEFAULT is sufficient; FULL would defeat the WAL-reduction goal. **`riders` REPLICA IDENTITY stays FULL** (unchanged this phase — the six `oldRecord` gates depend on it).

### G. Recommended mirror strategy — **client-side throttle (60 s / 150 m) writing `riders`, from A3**, plus a **DB bridge trigger from A1** (`riders`→`rider_locations` upsert) so tracking works for all app versions during rollout; drop the bridge in A6. `riders` GPS-driven write rate → ~1/min per online rider (~75–85% cut). Dispatch tolerates it (staleness gate ≤ 24 h). NULL semantics preserved by the A1 backfill.

### H. Migration / rollout plan — A1 (table + backfill + RLS + publication + bridge) → A2 (get-live-order-status + fallback) → A3 (Flutter: R1/R2 readers + throttled writer, same build) → A4 (near-destination trigger move) → A5 (validate dispatch/nearby) → A6 (later: drop bridge, move dispatch reads, drop columns). Every stage independently reversible (§9).

### I. Performance measurement plan — §10: capture the 9 query groups before A3 and ~24 h after, plus a monitored 6-ride reproduction each time; success = `riders` write-rate −75%+, GPS `UPDATE` mean/max down, WAL-decode growth down, realtime timeout events down, `rider_arrived` stamped-vs-committed gap → < 1 s, `find_nearby_riders` unchanged.

### J. Root risks / blockers
| id | Risk | Severity | Mitigation |
|---|---|---|---|
| G1 | R1 + E1 must migrate together, else the passenger pin freezes | HIGH if mis-sequenced | A2 ships the server fallback first; A3 ships R1+R2+writer in one build; tracking screens auto-follow |
| G2 | RLS subquery cost on the GPS stream | resolved | Option D = one bounded `EXISTS(orders)` per event per subscribed passenger (not a fan-out) |
| G8 | `last_active_at` / dormancy | resolved | nothing reads `last_active_at`; dormancy uses `riders.updated_at`; online riders excluded |
| G10 | old app versions keep writing `riders` every ping | MED | that is *current* behaviour (no regression); the A1 bridge keeps their `rider_locations` fresh; benefit is just delayed for slow updaters |
| A-1 | rollout window: tracking a pre-A3 rider from a post-A3 passenger | MED | A1 bridge trigger keeps `rider_locations` fresh from that rider's `riders` writes → realtime still works; without the bridge, falls back to the 15–45 s poll |
| A-2 | `get-live-order-status` reading a stale/absent `rider_locations` row | LOW | explicit `riders.*` fallback in A2 (behaviour-neutral until `rider_locations` is genuinely fresher) |
| A-3 | Realtime restart needed after `ALTER PUBLICATION … ADD TABLE` | LOW | toggle the table in Dashboard → Replication after A1 |
| A-4 | Free-tier compute ceiling | unchanged | Phase A reduces per-write cost; it does not raise the CPU/connection limit |
| A-5 | `intercity_searching_screen` embed (R7) can't embed `rider_locations` (no FK path) | LOW | stays on the `riders` mirror this phase; keyed-query switch is an A6 item |

### K. Safest implementation order
**A1 → A2 → A3 → A4 → A5**, then A6 much later. A1 and A2 are server-only and fully reversible with zero client impact. A3 is the one coordinated Flutter release (G1). A4 is a small trigger relocation. Do **not** reorder A2 after A3, and do **not** ship A3's reader change without A3's writer change in the same build.

### L. Recommendation on proceeding with A1
**PROCEED with A1.** It is purely additive (new table + backfill + RLS + publication + one thin bridge trigger), changes no existing behaviour, adds only a sub-millisecond upsert per `riders` GPS write, and is reversible by dropping the new objects. It unblocks A2/A3 and lets the passenger-tracking cutover happen without a data gap. The measurable slowdown relief lands at A3 (client throttle) — A1 is the safe, reversible foundation. Author the A1 migration for review next; do not apply until approved.
