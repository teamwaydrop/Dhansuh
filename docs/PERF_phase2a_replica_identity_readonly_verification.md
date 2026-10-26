# Phase 2a read-only verification — `riders` REPLICA IDENTITY FULL → DEFAULT

**Date:** 2026-09-08 · **Mode:** READ-ONLY (no production change, no migration, no code change, no commit)
**Question:** Is it safe to apply `ALTER TABLE public.riders REPLICA IDENTITY DEFAULT` right now?

---

## 1. Executive summary

**Recommendation: DO NOT apply the bare `FULL → DEFAULT` on `riders` yet.**

- It is **not** the fix for the two symptoms you care about (`accept→arrive` 25–39 s, `OTP→complete` 57 s). Those are driven by the **`orders` status-change write path** — `complete_order_and_settle` doing ~4–5 `orders` updates + 2–3 `riders` updates + 2 `net.http_post` + a 7-trigger fan-out **inside one transaction that holds a lock on the rider's row**, on a CPU-contended instance. `riders` replica identity has no effect on that.
- It **would** meaningfully reduce Realtime/WAL load from the rider GPS stream (which is real and is >99.9% of all `riders` realtime events), i.e. it helps the *intermittent realtime-delivery* lag — but only partially.
- It is **blocked by a client-side dependency**: 5 Flutter screens branch on `payload.oldRecord` for `riders` UPDATE events to decide whether to refresh the UI. Their logic is written assuming the old row is fully populated (which requires FULL). Under `DEFAULT` the old record is PK-only and those gates misfire. There is also an unresolved question of whether RLS already strips the old record to PK-only *today* — which must be confirmed with a real captured payload before touching anything.

**Correct next step:** do **Phase 2b instead** — move the GPS write stream to a dedicated `rider_locations` table. That removes ~99.9% of `riders` updates, makes `riders` replica identity irrelevant, sidesteps the client-gate problem entirely, and is purely additive. Details in §13.

---

## 2. Current `riders` REPLICA IDENTITY

| Property | Value | Source |
|---|---|---|
| `riders` replica identity | **FULL** (`relreplident = 'f'`) | `pg_class` |
| `orders` replica identity | FULL | `pg_class` |
| `rider_assignments` replica identity | FULL | `pg_class` |
| `riders` RLS | **enabled**, not forced, 7 policies | `pg_class.relrowsecurity`, `pg_policies` |
| `riders` primary key | `riders_pkey (id)` present | `pg_index` |
| Also unique | `riders_user_id_key (user_id)`, `riders_kyc_id_key (kyc_id)` | `pg_indexes` |

`DEFAULT` would use `riders_pkey (id)` as the row identity — valid (PK exists, `id` is immutable).

---

## 3. Actual Realtime usage of `riders`

**Publication:** `riders` is in `supabase_realtime`.
- Operations published: **INSERT + UPDATE + DELETE + TRUNCATE** (`pg_publication`).
- Columns published: **all 33** (`pg_publication_tables.attnames`), no column list.
- Row filter: **none** (`rowfilter = null`).

**Client subscribers to `table: 'riders'`** (from `lib/`):

| File | Filter | Purpose | Reads `oldRecord`? |
|---|---|---|---|
| `core/services/realtime/realtime_order_controller.dart:527` | `id = <riderId>` | **Passenger live rider tracking** — reads `newRecord.current_lat/lng/current_heading` for the map | **No** — diffs against its own cached `riderNotifier.value` |
| `features/rider/home/rider_home_tab.dart:572` | `id = <riderId>` | Rider home tab (online toggle, today's earnings, badges) | **Yes** — `isLocationOnlyUpdate` gate (`:592`) |
| `features/rider/orders/rider_orders_screen.dart:374` | `id = <riderId>` | Rider orders screen | **Yes** — `isLocationOnlyUpdate` gate (`:389`) |
| `features/rider/profile/rider_profile_tab.dart:224` | `user_id = …` | Rider profile | **Yes** — `isProfileRelevantUpdate` gate (`:232`) |
| `features/rider/earnings/rider_earnings_tab.dart:220` | `user_id = …` | Rider earnings | **Yes** — `isEarningsUiRelevantUpdate` gate (`:228`) |
| `features/rider/navigation/rider_main_navigation_screen.dart:123` | (service_mode watch) | service-mode guard | needs spot check, same pattern |
| `features/user/home/home_tab.dart:939` | `user_id = …` | Passenger home | **Yes** — `isLocationOnlyUpdate` gate (`:955`) |

**Event volume:** lifetime `riders` `n_tup_upd ≈ 30,500`. The GPS-shaped update (`current_lat/lng/heading/last_location_updated_at/last_active_at/updated_at`) dominates; `account_status`-changing updates ≈ **13** total. So **>99.9 % of `riders` realtime UPDATE events are GPS pings.**

---

## 4. OLD-row dependency analysis

### 4a. Who depends on `payload.oldRecord` for `riders`

Five screens compute a boolean like `isLocationOnlyUpdate` by diffing `payload.oldRecord` against `payload.newRecord`, and **`return;` (skip the UI refresh)** when the only changed columns are GPS/heartbeat fields. Representative code — `rider_home_tab.dart:592`:

```dart
final oldData = payload.oldRecord;
final isLocationOnlyUpdate = oldData.isNotEmpty &&
    data.keys.every((key) =>
        !oldData.containsKey(key) ||          // key absent  -> treated as "not a real change"
        oldData[key] == data[key] ||          // value equal -> not a change
        _locationHeartbeatFields.contains(key));
if (isLocationOnlyUpdate) { rider = {...rider!, ...data}; return; }   // skip reload
```

The code comment states: *"`oldRecord` is populated because `riders` has REPLICA IDENTITY FULL (confirmed live)"*.

### 4b. What happens to these gates under `DEFAULT`

Under `REPLICA IDENTITY DEFAULT`, Supabase Realtime delivers `payload.oldRecord` as **`{id: <riderId>}` (primary key only)**.

Walk the gate with `oldData = {id: …}`:
- `oldData.isNotEmpty` → **true**
- for every non-`id` key: `!oldData.containsKey(key)` → **true** → the `.every()` short-circuits to true for that key
- for `id`: `oldData['id'] == data['id']` → **true**
- ⇒ `isLocationOnlyUpdate` → **true for *every* `riders` UPDATE**, including go-online/offline, earnings credit after completion, subscription changes, wallet changes, KYC changes.
- ⇒ those screens **stop refreshing from Realtime** on any real `riders` change → stale until a manual pull-to-refresh / screen re-focus.

The "conservative fallback" in the comments only triggers when `oldRecord` is **completely empty `{}`**, not when it is `{id}`. So it does **not** protect against this.

### 4c. The RLS complication (must be resolved before any change)

Supabase docs (Realtime — *Receiving `old` records*, and the Realtime troubleshooting guide) state explicitly:

> *"When RLS is enabled and `replica identity` is set to `full` on a table, the `old` record contains **only the primary key(s)**. … There's no way around this while RLS is on — don't rely on other `payload.old` fields for a policy-protected table."*

`riders` **has RLS enabled**. If this documented behavior applies to the Realtime version serving this project, then **`payload.oldRecord` for `riders` is already `{id}` today**, the five client gates are *already* misfiring (classifying everything as location-only), and `FULL → DEFAULT` would change **nothing** on the client — making it safe *and* a pure win.

The client comment ("oldRecord is populated … confirmed live") contradicts that. **Only one of these is true, and they lead to opposite conclusions.** This must be settled by capturing one real `riders` UPDATE payload (see §12 pre-req) before the change is applied.

### 4d. DELETE events

`riders` DELETE is published. Lifetime `n_tup_del = 54` (rider account deletions). No client subscription filters/branches on a `riders` DELETE old row in a way that a PK-only old record would break (deletes are rare and handled by full reload paths). **Low risk.**

---

## 5. GPS → `riders` → Realtime analysis

| Question | Finding | Class |
|---|---|---|
| Do GPS updates generate Realtime events? | **Yes.** Every `LocationCacheService` write is an `UPDATE public.riders` and `riders` is in the publication with UPDATE enabled, all columns, no filter. Mean 76 ms/update, **max 9,005 ms**, ~25k lifetime. | CONFIRMED |
| Are those events *needed*? | **Yes, by exactly one consumer:** `realtime_order_controller._subscribeRider` uses `newRecord.current_lat/lng/heading` to move the rider pin on the passenger's tracking map. It does **not** use `oldRecord`. | CONFIRMED |
| Does anyone *not* want them? | **Yes — the 5 rider/passenger screens in §3** subscribe to the whole `riders` row and then explicitly filter GPS events out with the `oldRecord` gate. They receive ~25k events to discard ~25k. | CONFIRMED (waste) |
| WAL / decode cost of publishing full old row on every GPS ping | `riders` has 33 columns + 14 indexes. FULL logs the entire old tuple per update; DEFAULT logs ~PK only. Estimated **~30–45 % less WAL bytes per GPS update**, and **~45–50 % smaller logical-decode payload** for each `riders` UPDATE that Realtime's `list_changes` has to decode + RLS-check + JSON-encode per subscriber. `list_changes` is the #1 DB time consumer overall (≈ 27.9 M ms lifetime). | ESTIMATE |

---

## 6. `orders` status-change trigger chain analysis

**Triggers on `orders` for `UPDATE OF order_status`** (`pg_trigger`), in fire order:

| # | Trigger / function | When | Work done | Cost |
|---|---|---|---|---|
| B1 | `protect_order_state_columns` (BEFORE) | every status change | `auth.role()` + in-memory compare; raises if not service_role | cheap |
| B2 | `set_compliance_retention` (BEFORE) | on completion | sets one column on NEW | cheap |
| A1 | `handle_order_activity_tracking` (AFTER) | on completion/cancel | UPSERT `rider_daily_activity` | 1 write |
| A2 | `trg_reward_cycle_on_order_completion` (AFTER) | on completion | `evaluate_reward_cycle('user', …)` **and** `evaluate_reward_cycle('rider', …)` | 2 sub-calls (rewards barely exercised in prod: `evaluate_reward_cycle` internals ≈ 4 calls / 33 ms lifetime — currently cheap) |
| A3 | `assign_nearby_searching_orders_on_rider_freed` (AFTER) | on leaving active set + rider_id not null | `SELECT riders` + `vault.decrypted_secrets` decrypt + **`net.http_post`** to `assign_nearby_searching_orders_core` | 1 decrypt + 1 http enqueue |
| A4 | `expire_trip_sharing_tokens` (AFTER) | on completed/delivered/cancelled | `UPDATE trip_share_tokens WHERE order_id = …` | 1 write |
| A5 | `on_order_status_update` (AFTER) | **every** status change | `vault.decrypted_secrets` decrypt + **`net.http_post`** to `send_order_status_notifications_core` | 1 decrypt + 1 http enqueue |

**`complete_order_and_settle` (the `OTP→complete` RPC)** — one `plpgsql` transaction:

1. `UPDATE orders SET order_status='completed' + 6 cols` → **fires B1,B2,A1,A2,A3,A4,A5 synchronously in-transaction**
2. `UPDATE rider_assignments` (settle accepted assignment)
3. `SELECT riders` (subscription lookup)
4. 0–2 further `UPDATE orders` (commission-waiver branches) — full-row WAL each (REPLICA IDENTITY FULL), but don't re-fire the `OF order_status` triggers
5. `apply_order_government_tax(...)` → writes ledger + **`UPDATE riders.government_tax_due_balance`** (full-row WAL + `protect_rider_financial_columns` BEFORE trigger)
6. `credit_rider_for_completed_order(...)` → **`UPDATE riders` wallet_balance/total_earnings/today_earnings** (full-row WAL + `protect_rider_financial_columns` + `trigger_rider_wallet_balance_update` AFTER) + INSERT `wallet_transactions`
7. `INSERT order_status_history`

Net per completion: **~4–5 `orders` writes + ~2–3 `riders` writes + ~5 other-table writes + 2 `net.http_post` + 7 trigger functions, all in one transaction that holds a row lock on `orders(id)` and `riders(id)`.**

The `riders(id)` row it locks in steps 5–6 is **the same row the rider's GPS stream updates every ~10 s.** Under Free-tier CPU where a lone `riders` update already spikes to 9 s, this is a genuine serialization point.

**Direct measurement (`pg_stat_statements`, lifetime):**
- `WITH pgrst_source AS (UPDATE "public"."orders" SET "order_status" …)` — several entries, **mean 190–580 ms, max 5,062–7,836 ms**.
- `complete_order_and_settle` chain and `update-order-status` RPC path — **mean ~400 ms, max ~4,200 ms** (and the edge-function code comment itself says this settlement chain was *"proven live to take upwards of 80 seconds under contention"* before it was consolidated into the RPC — migration `20260813000000`).
- `net` worker draining `net.http_request_queue` — **mean 6–10 ms, max 2,432 ms** — competes for the same CPU.
- `vault.decrypted_secrets` — **1 secret only** in the vault → decrypt is O(1), not in the top statements → **not a significant cost.**

---

## 7. Correlation with the 8-ride timeline

| Step | Observed (rides 7–8) | Mechanism | Affected by `riders` replica identity? |
|---|---|---|---|
| `book→accept` | 3–10 s (was 37 s pre-fix) | **already fixed** (`rider_assignments.accepted_at/rejected_at`) | no |
| `accept→arrive` | **25 s / 39 s** | rider taps Arrived → `update-order-status` → **direct `UPDATE orders`** → A5 (`on_order_status_update` decrypt + `net.http_post`) + B1 + full-row WAL (`orders` FULL) + 2 permissive UPDATE RLS policies; **plus** the rider's app only shows the "Arrived" button after it receives the `accepted` Realtime event, which is delayed when `list_changes` is behind | **indirectly** — `riders` FULL adds WAL that slows `list_changes`, delaying the rider's own screen; the `orders` UPDATE itself is unaffected by `riders` replica identity |
| `arrive→OTP` | 6–40 s | partly human (rider enters OTP) + `log_otp_attempt` RPCs + realtime delivery of the OTP prompt to the passenger | indirectly (realtime delivery) |
| `OTP→complete` | **57 s** | `complete_order_and_settle` transaction weight (§6) + `riders(id)` row-lock vs GPS stream + 7-trigger fan-out + Free-tier CPU | **no** — this is `orders`/RPC/lock/CPU, not `riders` replica identity |

**Conclusion:** `riders` FULL → DEFAULT would shave the *realtime-delivery* component (button/state appearing late on the other party's screen) but leaves the dominant `OTP→complete` cost (the settlement transaction) untouched.

---

## 8. CONFIRMED

| # | Finding | Evidence | Impact |
|---|---|---|---|
| C1 | `riders` replica identity is **FULL**; RLS enabled; PK on `id` exists | `pg_class`, `pg_policies`, `pg_index` | prerequisite facts |
| C2 | `riders` publishes UPDATE with **all 33 columns, no row filter**; >99.9 % of its realtime UPDATE events are GPS pings | `pg_publication_tables`, `pg_stat_user_tables` (`n_tup_upd≈30.5k`, account_status updates ≈13) | GPS is the realtime load on this table |
| C3 | **5 Flutter screens branch on `payload.oldRecord` for `riders` UPDATEs** to skip UI refresh; logic assumes a fully-populated old row | `rider_home_tab.dart:592`, `rider_orders_screen.dart:389`, `rider_profile_tab.dart:232`, `rider_earnings_tab.dart:228`, `home_tab.dart:955` | changing replica identity changes what these receive |
| C4 | Under `DEFAULT`, `oldRecord = {id}` → those gates classify **every** `riders` update as location-only → **skip refresh** for online/offline, earnings, subscription, wallet, KYC | gate logic walk (§4b) + Supabase Realtime docs (old record = PK only) | UI staleness regression on rider + passenger home screens |
| C5 | `complete_order_and_settle` = one transaction doing ~4–5 `orders` writes + ~2–3 `riders` writes + 5 other writes + 2 `net.http_post` + 7 trigger functions, holding a lock on `riders(id)` | `pg_get_functiondef`, `pg_trigger` | root of `OTP→complete` latency; unaffected by `riders` replica identity |
| C6 | `orders` `UPDATE SET order_status` spikes to **5–8 s**; settlement chain historically **up to 80 s** | `pg_stat_statements`, edge fn comment `update-order-status/index.ts:621` | the `accept→arrive` / `OTP→complete` symptom source |
| C7 | Passenger live-tracking (`realtime_order_controller._subscribeRider`) needs `riders` GPS realtime events but uses `newRecord` only, **not** `oldRecord` | `realtime_order_controller.dart:532-553` | this consumer is safe under `DEFAULT` |

## 9. STRONGLY SUSPECTED

| # | Finding | Evidence | Confidence |
|---|---|---|---|
| S1 | `riders` FULL replica identity materially inflates Realtime `list_changes` cost (the #1 DB-time consumer), because every GPS ping ships a full 33-column old tuple to decode + RLS-check + JSON-encode per subscriber | `list_changes` ≈ 27.9 M ms lifetime (9× the next item); GPS updates ≈ dominant `riders` write; earlier `realtime_logs` `"IncreaseSubscriptionConnectionPool: Too many database timeouts"` + `list_changes` `query_canceled` | high |
| S2 | The later-ride realtime-delivery lag (button/state appearing 20–40 s late on the other party's screen) is `list_changes` falling behind under accumulated WAL + Free-tier CPU, and tenant teardown/rebuild on client disconnect between rides | `realtime_logs`: repeated `Tenant … terminated: :shutdown` → re-init (recreate slot, validate publication, create partitions) | high |
| S3 | `net` worker draining `net.http_request_queue` (mean 6–10 ms, **max 2.4 s**) contends for CPU with the status-change transaction that just enqueued into it | `pg_stat_statements` | medium-high |
| S4 | The `riders(id)` row lock held by `complete_order_and_settle` (steps 5–6) serializes against that rider's in-flight GPS write, adding seconds under contention | function body + `riders` GPS update mean 76 ms / max 9 s | medium-high |

## 10. POSSIBLE

| # | Finding | Evidence | Confidence |
|---|---|---|---|
| P1 | Free-tier compute (shared CPU, 60 conn) is a **multiplier** on every item above — my own MCP DB connection timed out once mid-test at ~16:54 | connection timeout event; `max_connections=60`; 28–30 conns at idle | medium (contributing, not sole) |
| P2 | `evaluate_reward_cycle` ×2 per completion could become expensive once the rewards system is actually used (currently ≈4 calls / 33 ms lifetime — negligible now) | `pg_stat_statements` | low now, watch later |
| P3 | `oldRecord` for `riders` may **already** be PK-only today (RLS strips it per Supabase docs) — in which case the client gates already misfire and `DEFAULT` is a no-op for them | Supabase docs vs. contradicting client code comment | unresolved — must capture a live payload |

## 11. DISPROVEN / UNLIKELY

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| D1 | "Vault secret decrypt in the triggers is a major cost" | **DISPROVEN** | `vault.secrets` count = **1**; decrypt is O(1); not present in top `pg_stat_statements` |
| D2 | "`riders` REPLICA IDENTITY FULL is the root cause of the `OTP→complete` 57 s" | **DISPROVEN for that symptom** | completion time is the `complete_order_and_settle` transaction + locks + CPU; replica identity does not affect transaction execution time, only WAL/decode |
| D3 | "GPS writes are unnecessary / can be dropped from Realtime" | **DISPROVEN** | passenger live tracking (`realtime_order_controller`) genuinely consumes `newRecord` lat/lng/heading |
| D4 | "The dispatch/accept slowness is still the `rider_assignments` bug" | **DISPROVEN** | `book→accept` is now 3–10 s; no `PGRST204` since the fix; offer rows created at order time (order `9c17a56c` etc.) |
| D5 | "`trg_reward_cycle` is making completion slow" | **UNLIKELY (now)** | rewards evaluation ≈ 33 ms lifetime total; not measurable in the current traffic |

---

## 12. Is `FULL → DEFAULT` safe to apply right now?

### **NO — not as a bare `ALTER`.**

**What must be investigated / fixed first:**

1. **Capture one real `riders` UPDATE Realtime payload** (from a debug build log line, or a temporary `console.log` on the `realtime_order_controller` / `rider_home_tab` callback in a dev session) and record exactly what `payload.oldRecord` contains for `riders` **today**.
   - If it is already `{id}` only (RLS strips it, per Supabase docs) → the client gates already treat everything as location-only; `FULL → DEFAULT` is then **client-neutral** and safe to apply for the WAL saving. Proceed to a normal migration + test.
   - If it contains real column values → go to step 2.
2. **Fix the 5 client gates** so "cannot prove it's location-only" ⇒ "refresh" (not "skip"):
   ```dart
   final isLocationOnlyUpdate = oldData.isNotEmpty &&
       data.keys.every((key) =>
           _locationHeartbeatFields.contains(key) ||
           (oldData.containsKey(key) && oldData[key] == data[key]));
   ```
   (Files: `rider_home_tab.dart`, `rider_orders_screen.dart`, `rider_profile_tab.dart`, `rider_earnings_tab.dart`, `home_tab.dart`.) Ship + release, then apply the migration.
3. Only then apply `ALTER TABLE public.riders REPLICA IDENTITY DEFAULT`.

**What would remain unchanged in all cases:**
- Rider availability toggling *server-side* (the `UPDATE riders SET account_status` still works and is still published as an INSERT/UPDATE event — only the *old* image shrinks).
- Rider location updates (write path unchanged; passenger tracking reads `newRecord`, unaffected).
- Nearby-rider tracking / dispatch (`find_nearby_riders`, `assign_nearby_searching_orders_core` read the table directly via SQL — replica identity is irrelevant to SELECTs).
- Ride acceptance (`accept-order` — no `riders` `oldRecord` dependency).
- Ride completion (`complete_order_and_settle` — no `riders` `oldRecord` dependency; and no improvement either).
- Passenger tracking map (`realtime_order_controller` uses `newRecord`).

**Exact migration SQL (for when the pre-reqs are cleared):**
```sql
ALTER TABLE public.riders REPLICA IDENTITY DEFAULT;
-- Realtime picks up the change for WAL records generated after this point.
-- If Realtime delivery looks wrong afterwards, the publication may need a nudge:
--   (Dashboard) Database → Replication → toggle `riders` off/on, or
--   ALTER PUBLICATION supabase_realtime DROP TABLE public.riders;
--   ALTER PUBLICATION supabase_realtime ADD  TABLE public.riders;
```

**Rollback:**
```sql
ALTER TABLE public.riders REPLICA IDENTITY FULL;
```
Instant, metadata-only. (Note: WAL already written under `DEFAULT` is not retroactively upgraded — only matters for a replication consumer that was down during the window.)

**Post-change test plan:**
1. Rider app: Go Offline → Go Online. Confirm the home tab's online badge + any other rider tab updates **without** a manual refresh.
2. Complete a ride. Confirm the rider's **today's earnings** figure updates on the home + earnings tabs from realtime (not only after pull-to-refresh).
3. Change a subscription / wallet-affecting value (or complete a ride that credits the wallet). Confirm profile/earnings reflect it.
4. Passenger side: during an active ride, confirm the rider pin still moves smoothly on the map (GPS realtime still flowing).
5. Passenger home tab: confirm active-order card still updates on status changes.
6. Re-run the 6-ride back-to-back test; compare `accept→arrive` / `OTP→complete` to this baseline and check `realtime_logs` for reduced `list_changes` cancellations / tenant restarts.
7. `select … from pg_stat_statements` before/after for the `list_changes` mean/total.

---

## 13. Exact recommended next step

**Do Phase 2b instead of 2a: move the GPS stream to a dedicated `rider_locations` table.**

Why this is better than 2a:
- Removes **~99.9 %** of `riders` UPDATEs → `riders` replica identity (FULL or not) stops mattering; no client-gate risk, because `riders` will only change on real profile/status/wallet events (rare) — which is exactly what those gates want to react to anyway.
- The new table has no `oldRecord` consumer, so it can be `REPLICA IDENTITY DEFAULT` from creation — full WAL saving on the GPS stream.
- Also removes the GPS index-maintenance load on `riders`' 13 indexes and the GPS-vs-`complete_order_and_settle` row-lock contention (§S4).
- Purely **additive** and safely stageable: create table + start dual-writing + point the passenger subscription at the new table + stop writing GPS to `riders` — each step reversible.

Sketch (for a future approved Phase 2b, **not** to apply now):
```sql
CREATE TABLE public.rider_locations (
  rider_id   uuid PRIMARY KEY REFERENCES public.riders(id) ON DELETE CASCADE,
  lat        double precision,
  lng        double precision,
  heading    double precision,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.rider_locations REPLICA IDENTITY DEFAULT;   -- PK only, no oldRecord consumer
-- add to supabase_realtime publication; RLS policy mirroring riders' "view online riders";
-- LocationCacheService writes here; realtime_order_controller._subscribeRider subscribes here;
-- keep riders.current_lat/lng updated at low frequency (or via a light trigger) for dispatch SELECTs.
```

**In parallel / independently** (bigger lever for the `accept→arrive` / `OTP→complete` symptom, also a future phase): lighten `complete_order_and_settle` — move A5 (`on_order_status_update` push enqueue) and A3 off the synchronous completion transaction, and/or split the wallet/tax `riders` writes out of the lock window.

**And:** the Free plan remains the ceiling — none of the above makes a shared-CPU nano instance handle sustained real traffic.
