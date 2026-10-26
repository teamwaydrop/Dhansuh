# Phase 2 implementation / dependency audit (READ-ONLY)

**Date:** 2026-09-08 · **Mode:** READ-ONLY — nothing implemented, no migration, no code change, no commit, no RLS / replica-identity / cron change.
**Covers:** (A) moving live rider GPS off `riders` into a dedicated table; (B) reducing synchronous work in the completion transaction.

---

## 0. Executive answer

- **Do B-lite first, then A, then B-full.** See §10.
- GPS has **no location-history requirement** anywhere — every consumer wants "where is this rider *now*". → `rider_locations` is **one row per rider** (`rider_id` PK, upsert).
- The safest version of A keeps `riders.current_lat/lng` alive as a **low-frequency mirror** so **zero** dispatch SQL and **zero** nearby-search queries have to change; only the *passenger live-tracking* path and the *write* path move.
- In the completion transaction, the push-notification work is **already asynchronous** (the triggers only `net.http_post`-enqueue; the real FCM send happens later in the pg_net worker). The real synchronous weight is: multiple full-row `orders`+`riders` writes, a rider-row lock held for the whole settlement, and 3 non-financial AFTER-triggers (reward cycle, daily-activity stats, trip-token expiry). Those 3 can move out.

---

## 1. Exact current GPS architecture

### 1.1 Columns (on `public.riders`)
| Column | Type | Notes |
|---|---|---|
| `current_lat` | double precision, null | live position |
| `current_lng` | double precision, null | live position |
| `current_heading` | double precision, null | bearing, `0` when NaN |
| `last_location_updated_at` | timestamptz, null | freshness stamp (dispatch staleness gate reads this) |
| `last_active_at` | timestamptz, null | presence stamp — **also** bumped by the GPS write; read by dormancy logic |
| `updated_at` | timestamptz, null | generic row stamp, bumped every GPS write |

No `current_location` (PostGIS), no `speed`, no `accuracy` column exists.

### 1.2 The write path (single source)
`lib/core/services/location/location_cache_service.dart`
- `startRiderLiveTracking()` opens a `Geolocator.getPositionStream` (`distanceFilter: 5 m`, `intervalDuration: 10 s`, `bestForNavigation`) **and** a `Timer.periodic(30 s)` heartbeat.
- `_handlePositionUpdate` → `_shouldUploadPosition` (upload if: first ever / moved ≥ 10 m / ≥ 30 s since last) → `updateRiderLocation()`.
- `_performHeartbeatUpdate` (every 30 s) → `updateRiderLocation()`.
- `updateRiderLocation()` (**the only writer**, `:700`):
  ```dart
  supabase.from('riders').update({
    'current_lat', 'current_lng', 'current_heading',
    'last_location_updated_at', 'last_active_at', 'updated_at'
  }).eq('user_id', user.id).eq('account_status', 'online');
  ```
- In-flight guard: `isUpdatingDb` (≤ 1 concurrent write per client).
- `monitorGpsStatus()` writes `account_status='offline'` (no GPS columns) when the OS GPS toggle goes off.
- Effective rate ≈ **1 write / 10–30 s per online rider**. Lifetime `riders.n_tup_upd ≈ 30,500`, of which **≈ 13** changed `account_status` — i.e. **> 99.9 % of `riders` writes are GPS**.

### 1.3 Every current reader of rider GPS

**Dart — reads that matter:**
| # | File / line | What it does | Class |
|---|---|---|---|
| R1 | `core/services/realtime/realtime_order_controller.dart:527` | **Passenger live tracking** — Realtime subscribe `riders` filtered `id=<riderId>`, reads `newRecord.current_lat/lng/current_heading` → `riderLocationNotifier` | CONFIRMED critical |
| R2 | `realtime_order_controller.dart:340-366` (`_fetchRider`) | one-shot `.from('riders').select('… current_lat, current_lng, current_heading …')` for the initial pin | CONFIRMED |
| R3 | `realtime_order_controller.dart:465` (`_updateRiderLocation`) | parses `current_lat/lng/current_heading` out of a rider map | CONFIRMED |
| R4 | `features/local_rides/booking/screens/ride_location_screen.dart:1662` | "nearby bikes on the map" — `.from('riders').eq('account_status','online').gte/lte('current_lat'/'current_lng', …)` bounding box, polled every 5 s while booking | CONFIRMED |
| R5 | `features/local_parcels/booking/screens/parcel_booking_screen.dart:296` | same bounding-box nearby-rider query | CONFIRMED |
| R6 | `features/intercity/parcels/booking/intercity_booking_screen.dart:241` | `.from('riders').select('id, current_lat, current_lng, current_heading').not('current_lat','is',null)` (no box) | CONFIRMED |
| R7 | `features/intercity/shared/screens/intercity_searching_screen.dart:393` | `.from('rider_assignments').select('… riders(user_id, account_status, rating, current_lat, current_lng)')` — **embedded join** to rider GPS via the `rider_assignments→riders` FK | CONFIRMED (join — see §5) |
| R8 | `intercity_searching_screen.dart:478,543,624,1233` | consumes `current_lat/lng` out of the R7 result / a second `.from('riders')` map | CONFIRMED |
| R9 | `shared/widgets/maps/transport_map_widget.dart:559` | reads `rider['current_heading']` from data handed in by its parent (does **not** query) | POSSIBLE (prop-only; fixed automatically if its callers are fixed) |

**Dart — the 5 "isLocationOnlyUpdate / heartbeat" gates** (`rider_home_tab.dart:111/592`, `rider_orders_screen.dart:335/389`, `rider_profile_tab.dart`, `rider_earnings_tab.dart`, `user/home/home_tab.dart:857/955`): these **do not read GPS for display** — they exist purely to *ignore* the GPS-write realtime fan-out on `riders`. `_locationHeartbeatFields = {current_lat, current_lng, current_heading, last_location_updated_at, last_active_at, updated_at}`.

**Edge Functions:**
| # | File | What |
|---|---|---|
| E1 | `supabase/functions/get-live-order-status/index.ts:143-146, 325-326, 503-514` | Embedded select of `rider.current_lat/lng/current_heading/last_location_updated_at` on the order→rider relation; builds the `live_location` object in the response; also computes rider→pickup distance. **This is the authoritative passenger-side live position** (polled fallback by `realtime_order_controller.fetchLiveOrderState`). | CONFIRMED critical |
| E2 | `supabase/functions/load-testing/index.ts` | test harness only | DISPROVEN as production dependency |

**SQL functions that READ `riders.current_lat/lng`:**
| # | Function | Use | Reads from |
|---|---|---|---|
| S1 | `find_nearby_riders(p_order_id, …)` | **dispatch matcher** (`start-dispatch` calls it) | `riders r … r.current_lat, r.current_lng, r.last_location_updated_at`; staleness gate is *very* lenient: `last_location_updated_at >= now()-stale_sec` **OR** `>= now()-24h` **OR** `IS NULL` |
| S2 | `assign_nearby_searching_orders_core(p_rider_id, p_rider_user_id, p_current_lat, p_current_lng, …)` | rematch core | lat/lng arrive as **parameters** — the *callers* read them |
| S3 | `assign_nearby_searching_orders_on_rider_freed()` (trigger fn on `orders`) | on rider freed | `SELECT … current_lat, current_lng FROM riders WHERE id = NEW.rider_id` then passes to S2 |
| S4 | `assign_nearby_searching_orders_to_rider()` (trigger fn, `riders` `account_status`→online) | on go-online | reads `NEW.current_lat/lng` |
| S5 | `assign_new_order_to_nearby_online_riders_core()` | new-order async match | reads `riders.current_lat/lng` |
| S6 | `redispatch_freed_riders()` (cron) | backstop rematch | `SELECT r.current_lat, r.current_lng FROM riders r WHERE account_status='online' …` |
| S7 | `rider_self_rematch()` | rider-initiated rematch | reads `riders.current_lat/lng` |
| S8 | `on_rider_location_near_destination()` | trigger fn behind `trigger_near_destination_check` | reads `NEW.current_lat/lng` |

**Triggers involving GPS columns on `riders`:**
| # | Trigger | Event | Effect |
|---|---|---|---|
| T1 | `trigger_near_destination_check` → `on_rider_location_near_destination()` | `AFTER UPDATE OF current_lat, current_lng ON riders` | fires **on every GPS write**; 1 indexed `SELECT orders` (usually 0 rows), early-returns for local rides; only acts for intercity `ongoing` orders |
| T2 | `protect_rider_financial_columns` | `BEFORE UPDATE ON riders` (all cols) | fires on every GPS write; in-memory column compare + `auth.role()`; cheap but non-zero |
| T3 | `trigger_assign_nearby_orders` | `AFTER UPDATE OF account_status` | **not** GPS (already narrowed) |

**Realtime:**
- `riders` is in publication `supabase_realtime` (INSERT+UPDATE+DELETE+TRUNCATE, **all 33 columns**, no row filter), `REPLICA IDENTITY FULL`.
- Every GPS write is decoded by Realtime `list_changes`, RLS-checked per subscriber, JSON-encoded — for **6 distinct client subscriptions** to `riders` (1 passenger tracking that needs it + 5 that discard it).

**Background service:** `LocationCacheService` static singleton; Android foreground service (`ForegroundNotificationConfig`) keeps the stream alive when backgrounded; `stopRiderLiveTracking()` on go-offline / GPS-off.

---

## 2. Exact completion-transaction architecture

`update-order-status/index.ts:631` → for `new_status ∈ {completed, delivered}` calls **`rpc('complete_order_and_settle', …)`** (one `plpgsql` `SECURITY DEFINER` function = **one transaction T1**). Every other transition is a plain `.from('orders').update().eq('order_status', currentStatus)`.

### T1 step-by-step (`complete_order_and_settle`)

| Step | Statement | Locks / writes | Fires |
|---|---|---|---|
| 1 | `UPDATE orders SET order_status=completed, completed_at, +5 cols WHERE id=? AND order_status=?` (optimistic) | row lock on `orders(id)`; full-row WAL (RI FULL) | **7 order-status triggers** ↓ |
| 1a | trg `protect_order_state_columns` (BEFORE) | — | `auth.role()` check (service_role passes) |
| 1b | trg `set_compliance_retention` (BEFORE) | sets 1 NEW col | — |
| 1c | trg `handle_order_activity_tracking` (AFTER) | **UPSERT `rider_daily_activity`** | analytics only |
| 1d | trg `trg_reward_cycle_on_order_completion` (AFTER) | `evaluate_reward_cycle('user',…)` + `('rider',…)` → each: `SELECT reward_config` + `qualifying_completed_ride_count()` (a COUNT) + conditional `INSERT reward_cycles` | loyalty only; cheap now (≈33 ms lifetime), **grows with order volume** |
| 1e | trg `assign_nearby_searching_orders_on_rider_freed` (AFTER) | `SELECT riders` + vault decrypt (1 secret) + **`net.http_post` ENQUEUE** | rematch — enqueue only, real work is out-of-txn |
| 1f | trg `expire_trip_sharing_tokens` (AFTER) | `UPDATE trip_share_tokens WHERE order_id=?` | share-link revocation |
| 1g | trg `on_order_status_update` (AFTER) | vault decrypt + **`net.http_post` ENQUEUE** → `send_order_status_notifications_core` | **notification composition + FCM send both happen in a LATER transaction** (pg_net worker) |
| 2 | `UPDATE rider_assignments SET assignment_status='expired' WHERE order_id=? AND rider_id=? AND status='accepted'` | row lock | — |
| 3 | `SELECT subscription_active,… FROM riders WHERE id=?` | shared lock | — |
| 4 | 0–2 × `UPDATE orders SET commission_amount, gst_amount, rider_earning,…` (waiver branches) | full-row WAL each; does **not** re-fire `OF order_status` triggers | — |
| 5 | `apply_order_government_tax(…)` | INSERT govt-tax ledger + **`UPDATE riders.government_tax_due_balance`** (full-row WAL, RI FULL; `protect_rider_financial_columns` BEFORE) | — |
| 6 | `credit_rider_for_completed_order(…)` | **`UPDATE riders` SET wallet_balance, total_earnings, today_earnings, total_orders, cod_pending_amount, updated_at** (full-row WAL; `protect_rider_financial_columns` BEFORE; `trigger_rider_wallet_balance_update` AFTER → `on_rider_wallet_balance_update` → push only if wallet < −₹500, else no-op) | — |
| 7 | `INSERT order_status_history` | — | (no trigger on that table) |

**Transaction boundary:** all of steps 1–7 commit or roll back together. **`riders(id)` is write-locked from step 5 or 6 until T1 commits** — the same row that rider's GPS stream `UPDATE`s every 10–30 s.

**Vault / decryption:** 2 calls, each `SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='supabase_service_role_key'`. `vault.secrets` count = **1** → O(1) decrypt, not a measurable cost.

**Push-notification HTTP:** **none synchronous.** 1e + 1g only `net.http_post`-enqueue (a fast local INSERT into `net.http_request_queue`). Actual composition (`send_order_status_notifications_core`) and FCM delivery (`notifications` INSERT → `on_notification_insert` → `net.http_post`) run in later, separate transactions driven by the pg_net background worker.

**Measured:** `complete_order_and_settle` / `update-order-status` RPC path ≈ **mean 400 ms, max 4.2 s**; the code comment at `update-order-status/index.ts:621` records this chain *"proven live to take upwards of 80 seconds under contention"* pre-consolidation.

---

## 3. Complete dependency map — "if GPS moves to `rider_locations`"

```
                         ┌─────────────────────────────────────────┐
  WRITE (1 site)          │  LocationCacheService.updateRiderLocation │  ← MUST change
                         └───────────────┬─────────────────────────┘
                                         │ writes lat/lng/heading/ts
                          ┌──────────────┴───────────────┐
                          ▼                              ▼
                 riders.current_lat/lng          rider_locations (NEW)
                 (KEEP as low-freq mirror,        rider_id PK, RI DEFAULT,
                  or drop — see options)          in realtime publication
                          │                              │
   ┌──────────────────────┼───────────────┐              │
   ▼ (unchanged if mirror kept)           ▼              ▼
 DISPATCH / NEARBY-SEARCH SQL        NEARBY-MAP        PASSENGER LIVE TRACKING
 S1 find_nearby_riders               R4 ride_location   R1/R2/R3 realtime_order_controller  ← MUST repoint
 S3 assign…_on_rider_freed           R5 parcel_booking  E1 get-live-order-status            ← MUST repoint
 S4 assign…_to_rider                 R6 intercity_book  (T1 near-destination trigger)       ← MUST move
 S5 assign_new_order…core            R7/R8 intercity_searching join
 S6 redispatch_freed_riders          ── all KEEP reading riders.* IF mirror kept,
 S7 rider_self_rematch                  else all repoint to rider_locations
 S8 on_rider_location_near_destination (T1)
```

### 3.1 Must change regardless of approach
| Item | Change |
|---|---|
| `location_cache_service.dart` `updateRiderLocation()` | write to `rider_locations` (upsert on `rider_id`); decide whether to *also* keep a throttled `riders` write |
| `realtime_order_controller.dart` `_subscribeRider` (R1) | subscribe to `rider_locations` filtered `rider_id=<id>` instead of `riders` `id=<id>` |
| `realtime_order_controller.dart` `_fetchRider` (R2), `_updateRiderLocation` (R3) | read lat/lng/heading from `rider_locations` (separate query, or embed) |
| `get-live-order-status/index.ts` (E1) | fetch `current_lat/lng/heading/last_location_updated_at` from `rider_locations` (separate query — PostgREST cannot embed `orders→rider_locations` without an FK path through `riders`; simplest is a second `.from('rider_locations').eq('rider_id', order.rider_id)` call, run in the existing `Promise.all`) |
| Realtime publication | `ALTER PUBLICATION supabase_realtime ADD TABLE public.rider_locations` |
| `on_rider_location_near_destination` / `trigger_near_destination_check` (S8/T1) | move the trigger from `riders (current_lat,current_lng)` to `rider_locations`; the function reads `NEW.current_lat/current_lng` — works unchanged if `rider_locations` has those column names |
| `delete_own_account` | also delete/After: `ON DELETE CASCADE` from `rider_locations.rider_id → riders.id` handles it automatically |
| RLS on `rider_locations` (NEW) | mirror the intent of `riders`' *"Allow authenticated users to view online riders"* + own-row |

### 3.2 Changes ONLY if the `riders.current_lat/lng` mirror is dropped
| Item | Change |
|---|---|
| S1 `find_nearby_riders` | `JOIN rider_locations rl ON rl.rider_id = r.id`; use `rl.current_lat/lng`, `rl.updated_at` for the staleness gate |
| S3–S7 dispatch/rematch fns | same join / read swap |
| R4 `ride_location_screen.dart`, R5 `parcel_booking_screen.dart`, R6 `intercity_booking_screen.dart` | `.from('rider_locations')` bounding box; account_status filter now needs a join or a `rider_ids` pre-filter |
| R7 `intercity_searching_screen.dart` join | `rider_assignments.select('… riders(user_id, account_status, rating), rider_locations(current_lat, current_lng)')` — requires an FK `rider_assignments.rider_id → rider_locations.rider_id` OR a separate query keyed by `rider_id` |
| `idx_riders_online_coords` (added 2026-09-08) | move to `rider_locations` |
| The 5 `_locationHeartbeatFields` gates | become dead code (harmless to leave; `riders` no longer emits location-only updates) |

---

## 4. Proposed `rider_locations` schema

```sql
CREATE TABLE public.rider_locations (
    rider_id                  uuid PRIMARY KEY
                              REFERENCES public.riders(id) ON DELETE CASCADE,
    current_lat               double precision,
    current_lng               double precision,
    current_heading           double precision,
    last_location_updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_at                timestamptz NOT NULL DEFAULT now()
);
-- column names kept identical to riders.* so on_rider_location_near_destination() needs no body change

ALTER TABLE public.rider_locations REPLICA IDENTITY DEFAULT;   -- PK only; no oldRecord consumer exists

-- bounding-box nearby-rider search (partial not possible without account_status here;
--  keep it plain, or add a denormalised is_online bool updated by the go-online/offline path)
CREATE INDEX idx_rider_locations_coords ON public.rider_locations (current_lat, current_lng);

ALTER PUBLICATION supabase_realtime ADD TABLE public.rider_locations;

ALTER TABLE public.rider_locations ENABLE ROW LEVEL SECURITY;

-- READ: any authenticated user may see the position of an ONLINE rider, or their own row.
CREATE POLICY "view online rider locations" ON public.rider_locations
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.riders r
      WHERE r.id = rider_locations.rider_id
        AND (r.account_status = 'online' OR (SELECT auth.uid()) = r.user_id)
    )
  );

-- WRITE: a rider may upsert only their own row.
CREATE POLICY "rider upserts own location" ON public.rider_locations
  FOR ALL TO authenticated
  USING     (EXISTS (SELECT 1 FROM public.riders r WHERE r.id = rider_locations.rider_id AND r.user_id = (SELECT auth.uid())))
  WITH CHECK(EXISTS (SELECT 1 FROM public.riders r WHERE r.id = rider_locations.rider_id AND r.user_id = (SELECT auth.uid())));
-- service_role bypasses RLS for get-live-order-status.
```

**Design decisions (all CONFIRMED by the audit):**
| Question | Answer | Evidence |
|---|---|---|
| One row per rider, or history? | **One row per rider**, upsert | no consumer reads a track/breadcrumb/history; every reader wants "now" (R1–R9, S1–S8, E1) |
| Primary key | `rider_id` (FK → `riders.id`, `ON DELETE CASCADE`) | 1:1 with riders; cascade replaces the manual null-out in `delete_own_account` |
| Columns | `current_lat, current_lng, current_heading, last_location_updated_at, updated_at` | exact set the writer sends; names matched to `riders.*` so `on_rider_location_near_destination` body is unchanged |
| `last_active_at` | **stays on `riders`** — it is a *presence* signal (dormancy checks), not a map coordinate; keep the go-online path / a light heartbeat writing it, OR write it from the same client call | it is read by `check_dormant_riders` cron logic, not by tracking |
| Indexes | PK + `(current_lat, current_lng)` for the map box | mirrors `idx_riders_online_coords` |
| RLS | online-rider-visible + own-row-write, via `EXISTS` on `riders` | mirrors `riders` "view online riders" policy intent |
| Realtime | must be **added** to `supabase_realtime`; `REPLICA IDENTITY DEFAULT` is fine | only consumer (R1) reads `newRecord`, never `oldRecord` |
| Retention / cleanup | none needed (1 row/rider, overwritten); `ON DELETE CASCADE` cleans up on account deletion | — |
| Historical locations needed? | **No** | exhaustive consumer trace |

---

## 5. Required code / database changes (full list)

### A — GPS move (recommended "mirror-kept" variant)

**Database (1 migration):**
1. `CREATE TABLE rider_locations` + index + RLS + `ALTER PUBLICATION … ADD TABLE` (§4).
2. Move `trigger_near_destination_check` from `riders` → `rider_locations` (`DROP TRIGGER` on riders, `CREATE TRIGGER … AFTER UPDATE OF current_lat, current_lng ON public.rider_locations`). Function body unchanged.
3. (optional) drop `idx_riders_online_coords` once R4/R5/R6 are repointed — **not** in the same migration; do it last.

**Edge functions (1):**
4. `get-live-order-status/index.ts` — add a `rider_locations` fetch (`.eq('rider_id', order.rider_id)`) inside the existing `Promise.all`; source `live_location` + the rider→pickup distance from it; fall back to `riders.*` if the row is missing (during rollout).

**Dart (2 files minimum, mirror-kept):**
5. `location_cache_service.dart::updateRiderLocation` — `upsert` into `rider_locations` every ping; **keep** the existing `riders` update but gate it to the 30 s heartbeat only (≈ ⅓ the current `riders` write rate) — or keep it fully as-is for phase-1 of A and drop it in phase-2 of A.
6. `realtime_order_controller.dart` — `_subscribeRider` → subscribe `rider_locations` (`rider_id=<id>`); `_fetchRider` / `_updateRiderLocation` read coords from `rider_locations`.

**Dart (only if the mirror is later dropped — "full" variant):**
7. `ride_location_screen.dart`, `parcel_booking_screen.dart`, `intercity_booking_screen.dart` — nearby-box query → `rider_locations` (+ join/pre-filter for `account_status='online'`).
8. `intercity_searching_screen.dart` — the `rider_assignments → riders(current_lat,current_lng)` embed → separate `rider_locations` query keyed by `rider_id`.
9. SQL `find_nearby_riders`, `assign_nearby_searching_orders_on_rider_freed`, `assign_nearby_searching_orders_to_rider`, `assign_new_order_to_nearby_online_riders_core`, `redispatch_freed_riders`, `rider_self_rematch` — join `rider_locations`.

### B — completion-transaction slimming

**B-lite (low risk, no business-logic change): move the 3 non-financial AFTER-triggers off the synchronous path.**
- `handle_order_activity_tracking` (rider_daily_activity stats), `trg_reward_cycle_on_order_completion` (loyalty), `expire_trip_sharing_tokens` (share-link revoke) → convert each to a `net.http_post`-enqueue to a small `/rpc/*_core` (same pattern already used by `on_order_status_update`), **or** have `complete_order_and_settle` stop relying on triggers and instead `net.http_post`-enqueue one "post-completion side-effects" job after `COMMIT`.
- Keeps in T1: the `orders` UPDATE, `rider_assignments` settle, `apply_order_government_tax`, `credit_rider_for_completed_order`, `order_status_history` — the financial/audit core.
- Expected: fewer statements + shorter rider-row-lock window per completion.

**B-full (larger): consolidate the 0–2 waiver-branch `UPDATE orders` into step 1's single UPDATE**, so a completion writes `orders` once, not 2–3×. Careful — touches fare/commission/GST math; needs its own review.

**Not needed:** there is no synchronous push HTTP, no multi-secret vault decrypt, no explicit `FOR UPDATE`/advisory lock to remove.

---

## 6. Risks / regressions

| # | Risk | Severity | Mitigation | Class |
|---|---|---|---|---|
| G1 | Passenger map pin stops moving if `realtime_order_controller` / `get-live-order-status` aren't both repointed together | HIGH | ship both in the same release; keep a `riders.*` fallback read in E1 during rollout | CONFIRMED |
| G2 | `rider_locations` RLS `EXISTS(riders …)` sub-query runs per row in Realtime's RLS check on every GPS event → adds cost back | MED | denormalise an `is_online boolean` onto `rider_locations` (written by the go-online/offline path) and make the SELECT policy `USING (is_online OR own-row)` — no subquery | STRONGLY SUSPECTED |
| G3 | If the mirror is dropped, `find_nearby_riders` join to a possibly-empty `rider_locations` row for a brand-new rider → rider excluded from dispatch until first GPS write | MED | `LEFT JOIN` + keep the existing lenient `IS NULL` staleness branch; or backfill `rider_locations` from `riders` in the create migration | STRONGLY SUSPECTED |
| G4 | Intercity searching-screen embed (R7) has no FK to `rider_locations` → PostgREST embed fails silently | MED | use a separate keyed query, not an embed | CONFIRMED |
| G5 | `on_rider_location_near_destination` moved to `rider_locations`: it reads `NEW.id` today (`riders.id`); on the new table the row key is `rider_id` → **body change needed** (`NEW.rider_id`) | LOW | one-word edit in the function body when the trigger moves | CONFIRMED |
| G6 | B-lite: reward/stats/share-token side-effects become eventually-consistent (a few seconds late) | LOW | acceptable for loyalty/analytics/'@post-ride' revoke; document it | POSSIBLE |
| G7 | B-full waiver-branch consolidation math error → wrong commission/GST | HIGH | separate PR, its own regression test, do **not** bundle with A | STRONGLY SUSPECTED |
| G8 | `last_active_at` left on `riders` but GPS heartbeat no longer bumps it → dormancy logic mis-fires | MED | keep one write path bumping `last_active_at` (30 s heartbeat still writes `riders`, or a tiny separate update) | CONFIRMED |
| G9 | Realtime publication change requires a Realtime restart / re-subscribe to take effect | LOW | toggle the table in Dashboard → Replication after the migration | CONFIRMED |
| G10 | Old app versions still writing GPS to `riders` after the server moves on | MED | keep `riders` GPS columns + the mirror until forced-update adoption is high; never DROP the columns in the same release | CONFIRMED |

**Explicitly NOT at risk:** ride acceptance (`accept-order` — no GPS dep), ride completion financial path (no GPS dep), rider availability toggle (`account_status`, separate column), `book→accept` (already fixed).

---

## 7. Safe migration order

1. **B-lite** — move the 3 non-financial completion triggers async. *(no new table, no client release; smallest blast radius; measurable on its own)*
2. **A-migration (additive only)** — `CREATE TABLE rider_locations` + index + RLS + add to publication + **backfill from `riders`** + add `trigger_near_destination_check` on `rider_locations` **in addition to** the one on `riders` (idempotent: both fire, function is safe to run twice — it flips `near_destination_notified` once).
3. **A-server** — deploy `get-live-order-status` reading `rider_locations` with `riders` fallback.
4. **A-client r1** — `location_cache_service` **dual-writes** (`rider_locations` always + `riders` unchanged); `realtime_order_controller` reads `rider_locations`. Release + wait for adoption.
5. **A-cleanup** — once adoption is high: drop the `riders` GPS trigger, reduce/stop the `riders` GPS write (keep `last_active_at`), repoint R4/R5/R6/R7 + the dispatch SQL (or keep the throttled mirror), drop `idx_riders_online_coords`.
6. **B-full** — waiver-branch UPDATE consolidation, as its own reviewed change.
7. Only much later, if ever: `ALTER TABLE riders DROP COLUMN current_lat/current_lng/current_heading`.

Each step is independently deployable and independently revertible.

---

## 8. Rollback plan

| Step | Rollback |
|---|---|
| B-lite | restore the 3 triggers to their current synchronous bodies (`CREATE OR REPLACE`) — instant |
| A-migration | `ALTER PUBLICATION supabase_realtime DROP TABLE public.rider_locations;` `DROP TRIGGER … ON rider_locations;` `DROP TABLE public.rider_locations;` — safe because nothing depends on it yet |
| A-server | redeploy previous `get-live-order-status` (reads `riders`) — the column data is still there |
| A-client | previous build still writes `riders` and reads `riders`; server fallback in E1 keeps working; no data migration to undo |
| A-cleanup | re-add the `riders` trigger; re-enable the full `riders` GPS write; recreate `idx_riders_online_coords`; revert the repointed SQL/queries |
| B-full | `CREATE OR REPLACE` the prior `complete_order_and_settle` |

No destructive step (no `DROP COLUMN`, no data deletion) until the very end and only after long bake.

---

## 9. How to test after migration

**B-lite:**
1. Complete a ride. Confirm: order → `completed`; wallet credited (`riders.wallet_balance` / `wallet_transactions`); `order_status_history` row; govt-tax ledger row — **all present immediately**.
2. Confirm within ~10 s: `rider_daily_activity` incremented; `reward_cycles` evaluated; `trip_share_tokens.is_revoked=true`.
3. `pg_stat_statements`: `complete_order_and_settle` mean/max exec time before vs after.
4. Regression suite: any `test/*complete*`, `*settlement*`, `*reward*` structural guards.

**A:**
5. Passenger tracking: during an active ride, rider pin moves smoothly on the map; `get-live-order-status` `live_location` matches `rider_locations`.
6. Dispatch: create an order, confirm a rider is offered within seconds; `find_nearby_riders` still returns the online rider (check the `EXPLAIN` uses `rider_locations` if repointed).
7. Nearby-map (booking screens): online riders still appear on the pre-booking map.
8. Intercity searching screen still shows matched-rider positions.
9. Near-destination: an intercity `ongoing` order still gets the "almost there" push when the rider is < 3 km from the drop.
10. `account_status` go-online/offline still reflected on rider tabs (unchanged — `riders` still emits those).
11. Delete a test rider account → `rider_locations` row gone (CASCADE).
12. Load: 6-ride back-to-back test; compare `accept→arrive` / `OTP→complete` and `realtime_logs` (`list_changes` cancellations, tenant restarts) to the current baseline.
13. `pg_stat_statements`: `riders` `UPDATE` call count should drop sharply; Realtime `list_changes` total exec time should drop.

---

## 10. Which change FIRST, and why

**Order: B-lite → A → B-full.**

1. **B-lite first.** It is the smallest change (3 `CREATE OR REPLACE FUNCTION`, no new table, no client release, no RLS/replica-identity/cron change), it is trivially reversible, and it directly attacks the measured symptom — `complete_order_and_settle` holding a long transaction (and the rider-row lock) while doing loyalty/stats/token work that has no reason to be synchronous. You get a measurable `OTP→complete` improvement within one deploy, with almost no risk.
2. **A second.** Bigger (new table + edge fn + client release + realtime publication change) and needs staged rollout, but it is the structural fix for the *intermittent realtime-delivery* lag (`list_changes` drowning in full-row GPS updates) and it also *shrinks* the rider-row-lock contention that B-lite starts on (fewer/lighter `riders` writes competing with the settlement transaction). Do it additively (dual-write, fallback reads) so every step is reversible.
3. **B-full last.** The waiver-branch `UPDATE orders` consolidation touches fare/commission/GST math — highest regression cost, lowest marginal benefit once B-lite + A are in. Separate PR, separate review, separate regression test.

**Independent of all of the above:** the Free-tier instance remains the ceiling — B-lite + A reduce the load per operation, they do not raise the CPU/connection limit.
