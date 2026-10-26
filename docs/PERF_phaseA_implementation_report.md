# PERF — Phase A: rider GPS split into `rider_locations` — implementation report

**Date:** 2026-09-08
**Status:** A1 LIVE in production. A2 / A3 / A4 **authored and verified, NOT deployed, NOT committed.**
**Scope guard honoured:** no change to `complete_order_and_settle`, wallet/tax/earnings/fare/Cashfree
logic, the Phase B-lite completion side-effect architecture, dispatch business logic, `find_nearby_riders`,
or any unrelated table / cron / UI. `riders` GPS columns and the A1 bridge trigger are retained (their
removal is a later stage, A6).

---

## A. Goal

Cut the dominant contributor to the "app gets slow after ~3 rides" symptom: the high-frequency
`riders` GPS `UPDATE` stream feeding the Realtime WAL-decode pipeline on the Free-tier (60-connection)
instance. `riders` carries `REPLICA IDENTITY FULL` + 13 indexes + 2 GPS triggers, so every GPS ping is
a full-row WAL record fanned out to every logical-decode subscriber.

Phase A introduces `public.rider_locations` (one row per rider, `rider_id` PK, `REPLICA IDENTITY
DEFAULT`, single index) as the lean high-frequency GPS surface, and:

1. widens the Flutter writer's `riders` GPS cadence so `riders` is written ~1/min instead of ~3/min;
2. keeps `rider_locations` fresh via the A1 DB **bridge trigger** (`riders` GPS `UPDATE` → upsert
   `rider_locations`);
3. points passenger live-tracking reads (`get-live-order-status`, `RealtimeOrderController`) and the
   intercity near-destination trigger at `rider_locations`;
4. leaves dispatch / nearby-rider search reading the `riders` mirror, unchanged.

---

## B. Stage A1 — foundation (LIVE in production since 2026-09-08, migration `20260908000005`)

Already applied and verified in a prior turn. Unchanged by this work. Recap:

- `public.rider_locations` — `rider_id uuid PK → riders(id) ON DELETE CASCADE`, `current_lat/lng/heading
  double precision`, `last_location_updated_at/last_active_at/created_at/updated_at timestamptz`, all
  nullable, `REPLICA IDENTITY DEFAULT`, no secondary index.
- RLS: deny-by-default + one `SELECT` policy backed by `STABLE SECURITY DEFINER
  can_read_rider_location(rider_id)` — the rider themselves, OR a passenger with an **active** order
  assigned to that rider (`accepted / rider_arrived / picked_up / rider_at_drop / ongoing /
  payment_pending`). Grants: `authenticated` SELECT only, `service_role` ALL.
- Added to the `supabase_realtime` publication (21 tables total, 20 originals intact).
- Backfilled 1:1 from `riders` (23/23 rows).
- Bridge trigger `trg_riders_gps_bridge_to_rider_locations` `AFTER UPDATE OF current_lat, current_lng
  ON riders` → `sync_riders_gps_to_rider_locations()` (one upsert, no `riders` write, no recursion,
  no HTTP/vault).

**A5 re-check of A1 (read-only, prod):** `rider_locations` 23 rows, in publication, bridge trigger
armed, `coord_mismatch` vs `riders` = 0. **The bridge has fired 0 UPDATEs so far** (`n_tup_upd = 0`)
— no rider has been online since A1 was applied. Its correctness is verified structurally (trigger
definition + function body) but **not yet observed under live GPS traffic** → see section J.

---

## C. Stage A2 — `get-live-order-status` edge function (authored, NOT deployed)

**File:** `supabase/functions/get-live-order-status/index.ts` (+40 / −6 lines)

The passenger-side authoritative live rider position (polled fallback for
`RealtimeOrderController.fetchLiveOrderState`) now reads **`rider_locations` first, `riders.current_*`
as fallback**:

- One isolated `supabaseAdmin.from("rider_locations").select("current_lat, current_lng,
  current_heading, last_location_updated_at").eq("rider_id", order.rider_id).maybeSingle()` — placed
  after the rider-resolution guards, **not** folded into the embedded `orders` select.
  *Rationale:* a broken PostgREST embed would fail the whole order query → 404 on every 5 s poll; an
  isolated point-read that errors just returns `data: null` and every consumer falls back to the
  `riders.*` values already fetched — i.e. exactly pre-A2 behaviour.
- `hasUsableRiderLocation = row != null && current_lat != null && current_lng != null`.
- Four `effectiveRider{Lat,Lng,Heading,LocationUpdatedAt}` consts feed the **two** GPS consumers:
  the OLA ETA closure and the `live_location` response block.
- **Response JSON shape, keys, types, and null-handling are identical.** `rider_locations` exposes
  the same 4 GPS fields `riders` already did — no new data surface.

**Verification:**
- `deno check`: 14 → **12** errors (baseline captured via `git stash`). All 12 are pre-existing
  classes (11 × PostgREST array-vs-object embed inference on `order.riders`; 1 × `Timeout` type).
  No new error class; the new `rider_locations` read type-infers cleanly.
- `deno lint`: clean.
- Structural guard `test/phase2e_get_live_order_status_auth_fetch_parallel_regression_test.dart`
  still passes — no forbidden string introduced (`current_lat:`, `REPLICA IDENTITY`,
  `ALTER PUBLICATION`, `updateRiderLocation`, `complete_order_and_settle` all still absent;
  `.from("orders")` count still 1).

---

## D. Stage A3 — Flutter writer + passenger reader (authored, NOT built/shipped)

**User decision (asked mid-implementation):** write path = **bridge-only, throttle `riders`** — the
client keeps writing **only** `public.riders`; `rider_locations` stays fresh via the A1 bridge
trigger. No new client write surface, no new RLS write policy, no rider-id lookup.

### D.1 Writer — `lib/core/services/location/location_cache_service.dart` (+24 / −6)

| constant | before | after | effect |
|---|---|---|---|
| `movementThresholdMeters` | 10 | **150** | stream-driven write only after ~150 m of movement |
| `heartbeatSeconds` | 30 | **60** | heartbeat / max-interval write cadence → ~1/min |
| stale-cache tolerance | `heartbeatSeconds * 4` (would become 240 s) | new const `_heartbeatStaleCacheToleranceSeconds = 120` | unchanged ~2 min |

`updateRiderLocation()` body is **unchanged** — still
`.from('riders').update({current_lat, current_lng, current_heading, last_location_updated_at,
last_active_at, updated_at}).eq('user_id', …).eq('account_status', 'online')`.

Net: steady-state `riders` GPS write rate drops from ~3/min to **~1/min per online rider**
(~65–80 % fewer writes) — each write being a `REPLICA IDENTITY FULL` full-row WAL record touching
13 indexes and firing the bridge + near-destination triggers.

### D.2 Passenger reader — `lib/core/services/realtime/realtime_order_controller.dart` (+66 / −8)

`_subscribeRider()` now opens **two** pooled Realtime channels for the assigned rider:

1. **`realtime-rider-loc-<id>`** on `public.rider_locations` (`filterColumn: 'rider_id'`, event
   `update`) — the fresh live-GPS feed → `riderLocationNotifier`. **New.**
2. **`realtime-rider-<id>`** on `public.riders` (`filterColumn: 'id'`) — **kept**, but its callback
   no longer reads coordinates; it only detects a mid-ride `rating` / `rider_kyc_id` change and
   re-runs `_fetchRider`. (Those fields do not change during a ride; the channel is retained purely
   to preserve existing behaviour — candidate for removal in A6.)

`_fetchRider()` (the one-shot profile + initial-position load) gains an isolated
`from('rider_locations').select('current_lat, current_lng, current_heading').eq('rider_id', id)
.maybeSingle()` read, overlaid onto the rider map before it is published; on miss / null / error it
keeps the `riders` embed values it already selected (pre-A3 behaviour). The `riders` embed still
selects `current_lat/lng/heading` as the fallback source.

New field `_riderLocationSubId`; unsubscribed in the re-subscribe guard and `dispose()` alongside
`_riderSubId`.

All three passenger tracking screens (`ride_tracking_screen`, `parcel_tracking_screen`,
`intercity_tracking_screen`) consume `riderLocationNotifier` and are unaffected — they gain the new
source automatically.

**Known gap (covered twice):** the `rider_locations` subscription is `event: update` only. A
brand-new rider's *first* bridge write is an `INSERT` (no backfill row yet) and is not delivered by
that subscription — but it is caught by `_fetchRider`'s direct read and by the A2 `get-live-order-status`
read, and the next bridge write (~60 s later) is an `UPDATE`. Not worth widening to `event: all`.

**Verification:**
- `flutter analyze` (full project): **0 new issues** in either file. The one `info` on
  `location_cache_service.dart:364` (`prefer_conditional_assignment`) is a pre-existing lint on the
  untouched `if (position == null)` block — confirmed identical on a `git stash` baseline.
- `flutter test`: 14 GPS / tracking / realtime / vehicle-source regression files run explicitly
  (incl. `rider_gps_webview_perf`, `realtime_manager_release_safe_collision_guard`,
  `payment_processing_realtime_health_gate`, `traveller_tracking_vehicle_source`,
  `tracking_engine_animation_stop`, `phase2f_e_passenger_tracking_renderer_recovery`) → all pass.

---

## E. Stage A4 — near-destination trigger + `delete_own_account` (authored, NOT applied)

**File:** `supabase/migrations/20260908000006_phaseA4_near_destination_gps_source_to_rider_locations.sql`

7 executable statements, all idempotent / re-runnable:

1. `CREATE OR REPLACE FUNCTION public.check_rider_near_destination_from_rider_locations()` — a
   **byte-for-byte copy** of the production `on_rider_location_near_destination()` body, the **only**
   change being the order lookup key: `WHERE rider_id = NEW.rider_id` (the `rider_locations` PK)
   instead of `NEW.id`. Verified by normalized diff against `pg_get_functiondef` — that single token
   is the sole difference. Same 3.0 km radius, same `near_destination_notified` guard, same
   intercity-only filter, same `send_push_notification_fnc('Almost There', …)` call.
2. `CREATE TRIGGER trg_rider_locations_near_destination_check AFTER UPDATE OF current_lat, current_lng
   ON public.rider_locations` → the new function (parity with the old `riders` trigger: `FOR EACH
   ROW`, no `WHEN` clause).
3. `DROP TRIGGER trigger_near_destination_check ON public.riders` — the check now runs once, from the
   `rider_locations` write. The old function `on_rider_location_near_destination()` is **left in
   place** (unused) so rollback is a one-line `CREATE TRIGGER`.
4. `REVOKE ALL ON FUNCTION public.sync_riders_gps_to_rider_locations() FROM PUBLIC;` and the same for
   the new function — folds in the A1 non-blocking security-advisor follow-up. Both are inert
   (`RETURNS trigger`); no `GRANT` is issued (trigger functions need none to fire).
5. `CREATE OR REPLACE FUNCTION public.delete_own_account()` — the **entire** production body,
   re-declared verbatim (**md5-verified normalized-identical** to prod), plus **one** added
   statement in the `IF FOUND` rider block, immediately after the existing `DELETE FROM
   public.rider_vehicles …`:

   ```sql
   DELETE FROM public.rider_locations WHERE rider_id = v_rider.id;
   ```

   Consistent with how the function already hard-deletes the rider's other pure-operational rows
   (`rider_payout_accounts`, `rider_vehicles`). The `riders` `UPDATE` earlier in the same function
   already fires the bridge and leaves a NULL-coordinate `rider_locations` row; this line drops it
   outright. (Data hygiene, not a leak fix — the bridge already removes usable coordinates.)

**Kept on the `riders` mirror, unchanged:** `find_nearby_riders` and every dispatch / rematch /
nearby-search function (their staleness gate tolerates `>= now()-24h OR NULL`, so a ~1/min mirror is
fine).

**Verification:**
- `$function$` dollar-quotes balanced (4 = 2 functions). Both function bodies diffed against
  `pg_get_functiondef` — only the intended one-token / one-line change each.
- No `GRANT … (push fn | financial fn) … TO (PUBLIC | authenticated | anon)` anywhere.
- `test/phase1_privileged_function_lockdown_regression_test.dart` +
  `test/phase2_push_notification_function_lockdown_regression_test.dart` (both scan
  `supabase/migrations/` for later re-grants) → pass.

---

## F. Files changed

```
 M lib/core/services/location/location_cache_service.dart      | +24 -6
 M lib/core/services/realtime/realtime_order_controller.dart   | +66 -8
 M supabase/functions/get-live-order-status/index.ts           | +40 -6
?? supabase/migrations/20260908000006_phaseA4_near_destination_gps_source_to_rider_locations.sql   (new)
```

Pre-existing untracked from earlier phases (not part of A3/A4, left as-is): `docs/PERF_*.md` ×4,
`supabase/migrations/20260908000004_*` (B-lite, already applied), `supabase/migrations/20260908000005_*`
(A1, already applied).

**No unrelated file touched.** `git diff` on `main` = exactly the 3 files above.

---

## G. Regression audit (A5)

| check | result |
|---|---|
| `flutter analyze` (full project) | 0 new issues from Phase A (494 pre-existing repo-wide `info`/deprecation lines unchanged) |
| `flutter test --exclude-tags=live` | **1985 pass / 17 fail** — the identical 17 fail on a clean `git stash` baseline (`intercity_parcel_fixes`, `rider_kyc_submission_reliability`, `rider_orders_busy_to_free_refetch`, `rider_self_rematch`, `nearby_partner_count`, `local_order_delivery`, `production_fix_2026_07_29`, `rider_home_active_order_duplicate_work_suppressed`, `rider_pending_ride_after_completion`, `rider_orders_screen_duplicate_active_order_work_suppressed`). **None reference any Phase A file.** Phase A adds **zero** new failures. |
| `deno check` `get-live-order-status` | 14 → 12, all pre-existing classes |
| migration-dir structural guards (phase1 + phase2 lockdown, redispatch advisory-lock, government-tax) | pass |
| GPS / tracking / realtime regression files (14) | pass |
| prod read-only: A1 objects | healthy; `coord_mismatch` = 0; A4 objects absent (as expected) |

**Recommend the user run and re-run** `flutter test` for the 17 pre-existing failures separately —
they are unrelated to this work but should be triaged.

---

## H. Performance impact (expected)

| metric | before Phase A | after A3 (bridge-only) | after A6 (later) |
|---|---|---|---|
| `riders` GPS `UPDATE` / min / online rider | ~3 | **~1** (−65–80 %) | ~0 |
| WAL full-row records from GPS (`REPLICA IDENTITY FULL`, 13 indexes) | ~3/min | ~1/min | ~0 |
| `rider_locations` `UPDATE` / min / online rider | 0 | ~1 (lean row, `DEFAULT` RI, 1 index) | ~10 (direct writer) |
| passenger live-GPS Realtime channel | fat `riders` row (33 cols, FULL) | lean `rider_locations` row | lean |
| passenger map refresh cadence | ~10 s / 5 m | **~60 s / 150 m** | back to ~5 s |
| near-destination trigger fires | every `riders` GPS write | every `rider_locations` write (same ~1/min) | every direct write |

**Trade-off accepted by the user:** with the bridge-only path, passenger map tracking refreshes about
every 60 s / 150 m instead of ~10 s / 5 m. This is a deliberate Free-tier survival choice — a reliable
60 s update is far better than a ~10 s update that stalls entirely when the Realtime tenant restarts
under WAL load (the actual "app goes slow" symptom). A6 restores fine-grained tracking by moving the
writer directly to `rider_locations` (needs an owner-scoped RLS write policy — out of scope here).

The larger, already-applied wins remain the dominant fixes: the `rider_assignments.accepted_at/
rejected_at` schema-drift fix (`82aa827`, restored the fast dispatch path) and Phase 1 + B-lite.

---

## I. Rollback

| stage | rollback |
|---|---|
| A2 | redeploy the previous `get-live-order-status` build (or `git checkout` the file). The fallback logic already degrades to pre-A2 behaviour if `rider_locations` reads fail. |
| A3 | ship a build with the two Dart files reverted. Writer revert restores 30 s / 10 m cadence; reader revert restores the single `riders` subscription. |
| A4 | `DROP TRIGGER trg_rider_locations_near_destination_check ON rider_locations;` + `CREATE TRIGGER trigger_near_destination_check AFTER UPDATE OF current_lat, current_lng ON riders … EXECUTE FUNCTION on_rider_location_near_destination();` (old function was never dropped). `delete_own_account`: the extra `DELETE` is harmless; re-run the pre-A4 body to fully revert. Full rollback block is in the migration file. |
| A1 | unchanged — its own rollback block still applies, but only after A2/A3/A4 are reverted. |

---

## J. What is NOT done / open items

1. **Nothing is deployed or committed.** A2 (edge fn), A3 (Flutter build), A4 (migration) are all
   authored and verified only.
2. **The A1 bridge trigger has never fired under live traffic** (`rider_locations.n_tup_upd = 0`).
   Before or during the A3 deploy, run **one controlled test**: put a QA rider online, confirm
   `rider_locations` gets updated rows (`SELECT * FROM rider_locations WHERE rider_id = …`), then run
   one ride and confirm the passenger map tracks and the intercity "Almost There" push still fires.
   *This needs your approval — it is a live rider/data action.*
3. **A6 (later phase, not started):** drop `riders.current_lat/lng/heading` + the bridge trigger,
   move the Flutter writer directly to `rider_locations` at full cadence (requires a new migration
   adding `GRANT UPDATE` + an owner-scoped RLS `UPDATE` policy on `rider_locations`, plus a
   client-side rider-id cache). This is what restores ~5 s passenger tracking.
4. The 17 pre-existing `flutter test` failures on `main` are unrelated but should be triaged.
5. Phase B (waiver-branch `complete_order_and_settle` UPDATE consolidation) — **not started**, per
   instruction.

---

## K. Deploy order (when approved)

1. **Apply A4 migration** `20260908000006` (additive: near-dest trigger move + 2 REVOKEs +
   `delete_own_account` +1 line).
2. **Deploy** `get-live-order-status` (A2) — passengers on the current app build immediately benefit
   from the `rider_locations`-first read with `riders` fallback.
3. **Ship one Flutter build** with A3 (writer throttle **and** reader dual-subscribe together — they
   are a coherent pair). A2 shipping first means even an un-updated client still receives GPS via the
   edge-function fallback while the `riders` cadence widens.
4. Monitor one controlled ride (section J.2), then **commit** the 3 Dart/TS files + the A1 and A4
   migration files with a `perf:` message, and **push**.

Do **not** start Phase B.

---

## L. Approval checklist

- [ ] A2: deploy `get-live-order-status`
- [ ] A4: apply migration `20260908000006` to production (`yvwpchffctiagevpqgwy`)
- [ ] A3: build + release the Flutter client with the writer + reader changes
- [ ] controlled live-rider test (J.2) — **explicit approval required**
- [ ] commit + push once verified
