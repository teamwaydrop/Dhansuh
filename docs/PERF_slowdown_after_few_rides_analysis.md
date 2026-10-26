# WayDrop — Why the app slows down after a few rides, and how to fix it

**Date:** 2026-09-08
**Status:** Analysis + implementation plan only. **No code or database change has been made.**
**Scope of investigation:** Supabase Postgres (schema, triggers, cron, RLS, pg_stat_statements, logs, advisors) + the Flutter realtime/polling layer.

---

## 0. One-paragraph summary (simple)

The lag is **not** a bug in one screen. During a test session, background work
(rider GPS writes + dispatch cron jobs + realtime change-streaming) piles onto the
database **faster than your current Supabase instance can clear it**. The first 2–3
minutes are fine because nothing is backed up yet. After a few rides the backlog
grows, the Realtime service starts timing out against Postgres, drops its
connection and reconnects — and during every one of those gaps **no live update is
delivered**: the passenger's price never arrives, the rider's "new ride" card
never arrives, "ride completed" never arrives. That is exactly the symptom you see.

It is fixable **without changing how the app works**. But "millions of users like
Rapido" is also a *plan-size* question — you are currently on the smallest tier
(60 database connections total, shared by the API, edge functions, realtime and cron).

---

## 1. Hard evidence from YOUR project

| # | Evidence | Where it came from | What it means |
|---|----------|--------------------|---------------|
| E1 | `IncreaseSubscriptionConnectionPool: Too many database timeouts` | `realtime_logs` | The Realtime service's own queries against Postgres are **exceeding the 8-second timeout** and it is scrambling to add connections. |
| E2 | `Tenant … has been terminated: :shutdown` / `Tenant … is initializing` repeated 9× | `realtime_logs` | Realtime keeps **falling over and reconnecting**. Every cycle = a window with **no realtime delivery** → frozen UI. |
| E3 | Rider location `UPDATE public.riders …` → **25,456 calls, mean 75 ms**, ~1.9M ms total | `pg_stat_statements` | A single-row update by primary key taking 75 ms is ~15–30× too slow. Something is very heavy on that write. |
| E4 | WAL-read query `SELECT wal->>… slot …` → **2,453,405 calls, mean 11 ms, 27,901,819 ms (≈7.7 hours) total** | `pg_stat_statements` | This one query is **~9× more total DB time than anything else**. It is Realtime decoding the write-ahead log. It is drowning. |
| E5 | `redispatch_stalled_searching_orders()` every **30 s**; `redispatch_freed_riders()` every **20 s** | `cron.job` | Two heavy sweeps run constantly. Each stuck test order gets re-dispatched ~30 times over its 15-minute life. |
| E6 | `riders` table has **14 indexes**, incl. `idx_riders_current_lat` and `idx_riders_current_lng` (flagged **unused** by the advisor) | `pg_indexes` + performance advisor | Every GPS ping must update ~4–5 index entries, two of which are useless for geo lookups. |
| E7 | `riders`, `orders`, `users`, `notifications`, `rider_assignments`, `order_chat_messages`, … all have **REPLICA IDENTITY FULL** | `pg_class.relreplident` | Every UPDATE on these tables copies the **entire old row** into the WAL — this is what feeds E4. |
| E8 | Performance advisor: **"Multiple Permissive Policies"** — `orders` has **6** SELECT + **2** UPDATE policies; `riders` **4** SELECT + **3** UPDATE; also `users`, `rider_assignments`, `rider_kyc`, … | performance advisor | Postgres runs **every** policy for **every** row on **every** query — and Realtime runs them again per changed row, per subscriber. |
| E9 | `authenticator` role: `statement_timeout = 8s`, `lock_timeout = 8s` | `pg_roles` | When a realtime/RLS query gets slow enough it is **killed at 8 s** → this is the mechanism behind E1/E2. |
| E10 | `max_connections = 60` | `SHOW max_connections` | Smallest compute tier. API + PostgREST + edge functions + Realtime + cron + your SQL all share these 60. |
| E11 | 26 × `canceling statement due to statement timeout`, 5 × lock-wait in last 24 h | `postgres_logs` | Confirms queries are actually being cancelled in production, not just theoretically slow. |
| E12 | `net._http_response`: 8.6 MB for only 114 rows; cleanup DELETE averages 144 ms | `execute_sql` + `pg_stat_statements` | Every push notification's full HTTP response body is stored then bulk-deleted. Minor, but adds churn. |

---

## 2. How the slowdown builds up (the mechanism, step by step)

1. **Rider goes online** → the app streams GPS: an `UPDATE public.riders` roughly every 10 seconds per online rider.
2. Because `riders` is **REPLICA IDENTITY FULL** (E7) with **14 indexes** (E6), 3 permissive UPDATE RLS policies (E8) and a per-ping trigger (`trigger_near_destination_check`), each of those "tiny" updates costs **~75 ms** and dumps a **full-row image into the WAL** (E3).
3. **Passenger creates an order.** It sits in `order_status = 'searching'` until a rider accepts.
4. **Cron job 5** (every 30 s) sees the searching order and fires an HTTP call to the `start-dispatch` edge function. **Cron job 7** (every 20 s) loops over every recently-active rider and re-scans all searching orders. Every pass writes `rider_assignments` + `order_assignment_logs` rows and sends push — **more WAL** (E5).
5. `orders` is also **REPLICA IDENTITY FULL** with **6 SELECT RLS policies** (E8). Every order update (status, fare, dispatch flags) ships the whole row through the WAL and Realtime re-checks all 6 policies for every subscriber.
6. Now the **Realtime WAL reader** (E4) has to decode: full-row rider GPS images + full-row order images + assignment inserts + notification inserts — all at once, on a 60-connection box (E10).
7. It can't keep up. A decode/RLS query crosses the **8-second `authenticator` timeout** (E9) → Postgres cancels it → Realtime logs **"too many database timeouts"** (E1) → the tenant is **terminated and reconnects** (E2).
8. **During that gap, nothing is delivered.** The passenger's price update (delivered as an `orders` realtime UPDATE + the `get-live-order-status` enrichment), the rider's new-assignment card (`rider_assignments` realtime INSERT), and "ride completed" (`orders` realtime UPDATE) **all stall**.
9. The backlog never fully clears during a continuous test session, so it feels like the app "got slow and stayed slow" after ~3 rides.

**Why the first 2–3 minutes are fine:** the WAL backlog and the cron re-dispatch storm haven't accumulated yet. It's a *compounding* problem, not an instant one.

---

## 3. What is **NOT** the cause (checked and cleared)

- **The Flutter `RealtimeManager`** (`lib/core/services/realtime/realtime_manager.dart`): it correctly pools one channel per config, ref-counts listeners, and tears the channel down at zero subscribers. Reconnect loop is single-flighted with backoff. No channel leak across rides.
- **`RealtimeOrderController`** (`lib/core/services/realtime/realtime_order_controller.dart`): disposes its timer and subscriptions, guards every async gap with `_isDisposed`, coalesces concurrent refreshes, and has an adaptive polling backoff. Not the leak.
- **Client polling**: already hardened (realtime-health gate, exponential backoff, in-flight coalescing). Not hammering the backend.

The problem is **server-side load**, not client-side leakage.

---

## 4. Implementation plan — safe, staged, no change to how the app behaves

> Principle for every step: ride create, ride accept, ride complete and all existing
> flows keep working exactly as today. Each change is either reversible or
> behaviour-identical. **Nothing goes to production without your approval and a test pass.**

### Phase 0 — Confirm on a real test session (½ day, read-only)
- Reproduce your "3 rides" test while watching: `pg_stat_activity`, Realtime logs, and `pg_replication_slots` lag.
- Capture `EXPLAIN (ANALYZE, BUFFERS)` for the rider-GPS `UPDATE` and for `find_nearby_riders`.
- Goal: a before/after baseline so we can prove each fix worked.

### Phase 1 — Cheap, low-risk wins (~1 day, all reversible)
1. **Drop the two dead indexes** `idx_riders_current_lat`, `idx_riders_current_lng` (advisor says never used; useless for distance search anyway). Expect **~15–25 % faster GPS writes** immediately. Fully reversible.
2. **Tame the re-dispatch storm** without weakening dispatch:
   - Add a per-order cap / exponential spacing to `redispatch_stalled_searching_orders` (e.g. stop re-invoking after N rounds, widen the gap each round).
   - Optionally lower `dispatch_config.max_search_duration_sec` from 900 s so abandoned test orders stop churning sooner.
   - Real dispatch (rider actually gets offers) is unaffected — this only throttles *repeat* re-invocations of already-searching orders.
3. **Reduce `pg_net` response retention** so `net._http_response` stays small.
4. **Cache the vault service-role key** in `on_order_status_update` / the other trigger functions instead of decrypting it on every status change.

### Phase 2 — The big WAL reduction (~2–3 days, needs careful verification + a test window)
5. **Change `REPLICA IDENTITY FULL` → `DEFAULT` on `riders`** (then evaluate `notifications`, `users`).
   - First verify every realtime subscription's filter column: for `riders` the app filters only on `id` and `user_id`, both immutable and both uniquely indexed → safe in principle, **must be load-tested**.
   - Expected: a large drop in E4 (WAL decode time) and E1/E2 (Realtime timeouts).
6. **Move live rider GPS to its own table** `rider_locations` (`rider_id` PK, ~3 columns, 1 index, `REPLICA IDENTITY DEFAULT`, its own publication).
   - This is the "Rapido-style" split: the high-frequency location stream stops touching the transactional `riders` table and its 14 indexes / heavy RLS entirely.
   - App change: the location-write call and the passenger's rider-location subscription point at the new table. `riders.current_lat/lng` can still be updated at low frequency (or by a lightweight trigger) so dispatch queries don't change.
7. **Consolidate the multiple permissive RLS policies** (E8) into one policy per `(table, action)`, combined with `OR`. Behaviour is identical; evaluation cost drops roughly in proportion to the number of policies removed. Do `orders`, `riders`, `rider_assignments`, `users` first.

### Phase 3 — Headroom for real traffic (config / plan, not code)
8. **Upgrade the Supabase compute instance** — more connections + CPU. Required before any real user load; Phase 1–2 make each request cheaper, Phase 3 raises the ceiling.
9. Run edge functions through the **transaction-mode pooler**; set explicit, short per-request statement timeouts so one slow query can't hold a connection.
10. At real scale: consider a **dedicated Realtime instance / read replica**.
11. **Load-test before launch** using the existing `test/load_test_websocket.dart` and `test/network_chaos_verifier.dart` at your target concurrency.

---

## 5. Expected outcome

- **After Phase 1 + 2:** a continuous test session of 10–20 back-to-back rides should stay responsive; Realtime "database timeout" / tenant-restart events should drop to ~zero; rider-GPS write time should fall from ~75 ms toward single digits.
- **"Millions of users":** that is Phase 3 (instance size + replicas), and it only works *after* Phase 1–2 — otherwise a bigger instance just hits the same wall a bit later.

---

## 6. What I need from you to proceed

1. Approval to run **Phase 0 + Phase 1** (read-only diagnostics + reversible changes).
2. Your current **Supabase plan / compute instance size** (for Phase 3 sizing).
3. A **test or low-traffic window** for Phase 2 (the `REPLICA IDENTITY` and GPS-table changes must be verified live).

---

### Appendix — key raw numbers

- `pg_stat_statements` top consumers (total exec time): (1) Realtime WAL read ≈ 27.9M ms / 2.45M calls; (2) 2nd WAL read ≈ 3.06M ms; (3) publication-table resolution ≈ 2.88M ms / 32k calls; (5) `riders` GPS UPDATE ≈ 1.92M ms / 25k calls; (6) `redispatch_stalled_searching_orders` ≈ 1.86M ms / 109k calls; `redispatch_freed_riders` ≈ 1.10M ms / 120k calls.
- `riders`: 23 live rows, 14 indexes, ~30,408 lifetime updates, only ~5 % HOT.
- Cron: job 1 `expire_stale_searching_orders` every 2 min; job 5 `redispatch_stalled_searching_orders` every 30 s; job 7 `redispatch_freed_riders` every 20 s; job 6 `expire_stale_active_orders` every 10 min.
- Roles: `authenticated`/`anon` `statement_timeout = 20s`; `authenticator` `statement_timeout = 8s`, `lock_timeout = 8s`. `max_connections = 60`.
