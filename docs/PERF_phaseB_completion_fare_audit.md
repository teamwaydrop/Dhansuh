# PERF — Phase B: completion / fare read-only audit (B1)

**Date:** 2026-09-08 · **Type:** read-only, production evidence · **Result: completion/fare is NOT
the proven remaining bottleneck → B2/B3 not implemented (per the phase's critical safety rule).**

Nothing was changed. `git status` clean, `HEAD == dhanush/main == 418b1b4`.

---

## Method

- `pg_get_functiondef` of `complete_order_and_settle` and every function/trigger it touches.
- All triggers on `public.orders` and `public.riders`.
- Indexes on every table the completion path reads/writes.
- `extensions.pg_stat_statements` — all-time top consumers + the completion-path statements.
- `postgres_logs` — statement timeouts, lock waits, deadlocks, slow-query durations (24 h windows).
- The clean controlled live ride (`WDRM5HWY4`) completion trace.

---

## The completion transaction, as it actually runs

`complete_order_and_settle(p_order_id, p_new_status, p_previous_status, …)` — `SECURITY DEFINER`,
service_role-only, `md5 6d2fa3f5b4da967762365d5f57bc8d19` (unchanged since B-lite; Phase A did not
touch it).

| # | statement | rows | notes |
|---|---|---|---|
| 1 | `UPDATE orders SET order_status, completed_at, updated_at, fare_payment_method, payment_status, fare_paid_at, fare_payment_reference, fare_payment_screenshot_url WHERE id = ? AND order_status = ? RETURNING *` | 1 | **mandatory.** Doubles as the optimistic-lock / conflict check. |
| 2 | `UPDATE rider_assignments SET assignment_status='expired', updated_at, responded_at WHERE order_id=? AND rider_id=? AND assignment_status='accepted'` | 0–1 | settle the accepted offer. Uses `rider_assignments_order_id_rider_id_key`. |
| 3 | `SELECT subscription_active, subscription_expires_at FROM riders WHERE id=?` | 1 | plain read, **no `FOR UPDATE`**. |
| 4a | *(eligible Cashfree ride)* `UPDATE orders SET commission_amount, gst_amount, pg_charge_amount, rider_earning, subscription_commission_waived WHERE id=?` | 1 | **2nd write to the same `orders` row.** Subscriber + Cashfree only. |
| 4b | *(waiver: sub + ride/local_parcel)* `calculate_fare_breakdown(...)` (IMMUTABLE, pure) then `UPDATE orders SET commission_amount, rider_earning, gst_amount, subscription_commission_waived WHERE id=?` | 1 | **2nd write to the same `orders` row.** Subscribers only. |
| 4c | *(no waiver — the common case)* — | — | no 2nd `orders` write. |
| 5 | `apply_order_government_tax(...)` inside `BEGIN…EXCEPTION` (skipped for eligible Cashfree ride) | — | see below. |
| 6 | `credit_rider_for_completed_order(...)` | — | see below. |
| 7 | `INSERT INTO order_status_history (order_id, previous_status, new_status, changed_by)` | 1 | uses `idx_order_status_history_order_id`. |

### `apply_order_government_tax`
- SELECT `government_tax_ledger WHERE order_id=? AND entry_type='ORDER_TAX'` — hits the partial index
  `idx_gov_tax_ledger_one_order_tax_per_order`. Idempotency fast-path.
- SELECT `tax_rate_config` (3 rows, indexed) `LIMIT 1`.
- `INSERT INTO government_tax_ledger … ON CONFLICT DO NOTHING`.
- **direct collection (cash / personal_upi):** `UPDATE riders SET government_tax_due_balance = … WHERE id=?`
- **Cashfree-collected:** a 2nd `INSERT government_tax_ledger` (`ORDER_TAX_WITHHELD`, offsetting).
- `government_tax_ledger` = 375 rows. All lookups indexed. No scan.

### `credit_rider_for_completed_order`
- `set_config('app.bypass_rider_financial_guard','true', true)` (txn-local GUC)
- **one** `UPDATE riders SET total_orders, total_completed_orders, total_earnings, today_earnings,
  wallet_balance, cod_pending_amount, updated_at WHERE id=?`

### Triggers fired by the completion writes

| trigger | on | fires for | cost |
|---|---|---|---|
| `protect_order_state_columns_trigger` | BEFORE UPDATE OF order_status,… | write #1 | `IF auth.role() <> 'service_role'` → **false for the RPC → instant skip** |
| `trg_orders_compliance_retention` | BEFORE UPDATE OF order_status | write #1 | sets one column, trivial |
| `protect_order_financial_columns_trigger` | BEFORE UPDATE OF commission_amount,… | write #4a/4b only | same instant service_role skip |
| `trg_order_completion_side_effects` → `enqueue_order_completion_side_effects` | AFTER UPDATE OF order_status | write #1 | 1 dedup `INSERT` + 1 `net.http_post` **enqueue** — B-lite, never blocks |
| `trigger_order_status_update` → `on_order_status_update` | AFTER UPDATE OF order_status | write #1 | 1 vault read + 1 `net.http_post` **enqueue** (5 s is the eventual HTTP timeout, not a wait) |
| `trigger_assign_nearby_orders_on_rider_freed` → `assign_nearby_searching_orders_on_rider_freed` | AFTER UPDATE OF order_status, `WHEN old∈active ∧ new∉active` | write #1 | early-returns unless rider still `online`; else 1 riders read + 1 vault read + 1 `net.http_post` **enqueue**. The real rematch runs in a *separate* pg_net request. |
| `protect_rider_financial_columns_trigger` | BEFORE UPDATE (guard) | riders writes in #5/#6 | instant service_role skip / GUC bypass |
| `trigger_rider_wallet_balance_update` → `on_rider_wallet_balance_update` | AFTER UPDATE OF wallet_balance | #6 (non-direct only) | no-op unless `wallet_balance < -500` crossing |

**Every trigger on the completion path is a cheap guard or an enqueue-only call.** The 3 heavy
non-financial triggers were already moved async by B-lite. Nothing heavy runs synchronously in the
completion transaction beyond the financial writes themselves.

---

## Production evidence

### `pg_stat_statements` — all-time top DB-time consumers

| rank | statement | calls | total | mean | max | % of all DB time |
|---|---|---|---|---|---|---|
| **1** | `SELECT wal->>… ` (**Realtime `list_changes` WAL decode**) | 2,465,332 | 28,374 s | 11.5 ms | 15,866 ms | **38.6 %** |
| 2 | `SELECT wal->>…` (2nd realtime decode variant) | 479,595 | 3,058 s | 6.4 ms | 7,034 ms | 4.2 % |
| 3 | realtime publication introspection (`sub_tables … pg_publication_tables`) | 32,383 | 2,964 s | 91 ms | 9,651 ms | 4.0 % |
| **4** | `UPDATE riders SET current_heading, current_lat, …` (**GPS write**) | 25,589 | 1,984 s | 77.5 ms | 9,005 ms | 2.7 % |
| 5 | `SELECT … pg_available_extensions` (Supabase advisor/dashboard) | 3,407 | 1,957 s | 574 ms | **54,966 ms** | 2.7 % |
| 6 | `redispatch_stalled_searching_orders()` cron | 109,972 | 1,908 s | 17.4 ms | 8,889 ms | 2.6 % |
| 7 | `SELECT name FROM pg_timezone_names` (schema-cache reload) | 2,552 | 1,657 s | 649 ms | 5,876 ms | 2.3 % |
| 8 | PostgREST per-request `set_config(...)` | 917,579 | 1,450 s | 1.6 ms | 2,754 ms | 2.0 % |
| 9 | an `…p_order_id…` RPC (completion / status-notif family) | 6,142 | 1,403 s | 228 ms | 12,090 ms | 1.9 % |
| 12 | `with base_table_info as (…)` pg_meta introspection | 7,941 | 1,079 s | 136 ms | **32,488 ms** | 1.5 % |
| 13 | `DELETE FROM net._http_response WHERE created < …` (pg_net GC) | 7,425 | 1,074 s | 145 ms | 16,357 ms | 1.5 % |

`complete_order_and_settle` specifically (matched by its `p_order_id, p_new_status, p_previous_status`
signature): **~247–6,142 calls, mean ≈ 228–400 ms, max ≈ 4.2–12 s, stddev ≈ 640 ms** — of which
`apply_order_government_tax` ≈ 282 ms mean and `credit_rider_for_completed_order` ≈ 119 ms mean
(nested-statement time, also attributed to the parent). **≈ 2 % of total database time.**

### `postgres_logs` (24 h)

- **27 × "canceling statement due to statement timeout"** — clustered in bursts (≈07:44–08:24,
  11:10–11:40, 13:52–14:01). Sampling the 13:59–14:01 burst: the timed-out / slow statements are
  **Supabase's own introspection and advisor queries** — `pg_meta` `base_table_info` (14.3 s),
  storage-bucket lint `0025_public_bucket_allows_listing` (28.3 s), `pg_meta` `tables` RLS query
  (22.6 s), `pg_available_extensions` (12.2 s). During the same burst: **`cron job 5 / 7 job startup
  timeout`** (pg_cron could not even *start* redispatch) and a **38 s checkpoint write**. This is
  whole-instance CPU/IO saturation, not a transactional-statement problem.
- **1 × "still waiting for ShareLock on transaction … after 1000 ms"** and **1 × AccessShareLock on a
  relation** in 18 h — i.e. essentially **no row-lock contention**. (The AccessShareLock wait lines
  up with the A4 migration's brief `DROP TRIGGER` AccessExclusiveLock.)
- Repeated **`column orders.instructions does not exist`** (dozens/day) — a real application query bug
  (some caller/view references `orders.instructions`; the column is `special_instructions`). Generates
  error spam + wasted round trips. **Out of Phase B scope** (not fare/completion) — logged as a
  separate finding.

### Controlled live ride `WDRM5HWY4` (23:16–23:19, clean conditions)

`POST 200 /rpc/complete_order_and_settle` at 23:19:29.069; `order_status_history payment_pending →
completed` at 23:19:29.076. **No slow-query log line** → the completion RPC ran well under the slow
threshold (a few hundred ms). `payment_pending → completed` gap 5.2 s is the client→edge→RPC→response
round trip, not DB time.

---

## B1 findings

### A. Confirmed bottleneck
- **Realtime WAL-decode pipeline (`realtime.list_changes` → `SELECT wal->>…`): 38.6 % + 4.2 % =
  ≈ 43 % of all database time.** Unchanged as the #1 consumer. Phase A reduced its *inputs* (GPS
  write frequency ↓ ~65–80 %, per-write WAL size for the new lean `rider_locations` table), but the
  decode cost per event and the subscriber fan-out remain. **This is the remaining bottleneck.**
- **Free-tier compute saturation under burst load** — the statement-timeout bursts, `cron job
  startup timeout`, 38 s checkpoints, and 30–55 s introspection queries all point to raw CPU/IO
  starvation when several rides run back-to-back. This is exactly the "fast at first, slow after
  several rides" symptom, and it is **capacity**, not code.

### B. Suspected bottlenecks (secondary)
- `UPDATE riders … current_lat/current_lng` GPS write: mean 77.5 ms, 2.7 % — still `REPLICA IDENTITY
  FULL` + 13 indexes. Addressed further only by Phase 2a (FULL→DEFAULT, blocked by 5 Flutter
  `payload.oldRecord` consumers) or A6 (drop the columns).
- Supabase platform introspection / advisor / schema-cache queries (rows 5, 7, 12): ~6–8 % combined,
  individual max 30–55 s. Not app-controllable; shrinks with a compute upgrade and by not holding the
  dashboard/advisor open during load.
- `pg_net` `_http_response` GC (`DELETE …`): 1.5 %, max 16 s — the pg_net worker's own cleanup
  competing for I/O. Retention tuning is possible (was explicitly dropped from Phase 1 as low-value).
- redispatch crons (rows 6, 11): 4.1 % combined — already throttled in Phase 1.

### C. Proven NON-bottlenecks
- **`complete_order_and_settle` itself** — ≈ 2 % of DB time, ~228–400 ms mean; ran sub-threshold in
  the clean live ride.
- **Lock contention on `orders` / `riders` / wallet rows** — 1 real lock wait in 18 h.
- **`SELECT … FOR UPDATE`** — the function uses none; row locks are taken implicitly by the UPDATEs
  and released at commit; no explicit lock ordering hazard on the completion path.
- **Missing/inefficient indexes on the completion path** — every lookup (`government_tax_ledger`,
  `tax_rate_config`, `rider_assignments`, `order_status_history`, `riders`, `orders`) is a PK or
  covering-index hit against a tiny or small table.
- **Trigger cascade on completion** — all guards no-op for service_role; all side-effect triggers are
  enqueue-only (B-lite already did the heavy lifting).
- **Repeated fare calculation** — `calculate_fare_breakdown` is `IMMUTABLE`, pure, called **once**,
  and only in the subscriber-waiver branch.
- **Redundant SELECTs** — the only SELECT is the single `riders` subscription read (#3); it is not
  repeated.

### D. Exact SQL / functions involved
`public.complete_order_and_settle/9`, `public.apply_order_government_tax/5`,
`public.credit_rider_for_completed_order/4`, `public.calculate_fare_breakdown/5`,
`public.enqueue_order_completion_side_effects`, `public.on_order_status_update`,
`public.assign_nearby_searching_orders_on_rider_freed`, `public.on_rider_wallet_balance_update`,
`public.protect_order_*` / `protect_rider_financial_columns`, `public.set_compliance_retention`.

### E. Theoretical optimization opportunities (NOT recommended — see F/G)
1. Fold the subscriber-waiver 2nd `orders` UPDATE (#4a/#4b) into the completion UPDATE (#1) by
   reading the rider subscription **before** #1. Saves one full-row WAL record **for subscribers
   only**; requires restructuring the optimistic-lock/conflict check.
2. Fold the direct-collection `apply_order_government_tax` `UPDATE riders SET
   government_tax_due_balance` and `credit_rider_for_completed_order`'s `UPDATE riders` into one
   statement (disjoint columns). Requires merging logic across two independently-tested financial
   `SECURITY DEFINER` functions.

Both save only a handful of milliseconds / one or two WAL records per completion, on a function that
is ≈ 2 % of DB time, and both mean editing settlement code.

### F. Financial-risk assessment
- Every consolidation in E touches a `SECURITY DEFINER` settlement function whose final DB state is
  contractually fixed per branch (normal / waiver / Cashfree / direct-collection / idempotent-retry).
- The payoff is negligible (≈ ms, ≈ 1 WAL record, subscribers only).
- The phase's own rules: *"Financial correctness has absolute priority over performance"*, *"Never
  optimize by changing … settlement semantics"*, *"If safe consolidation cannot be proven: DO NOT
  implement it."*
- Risk/benefit is decisively negative.

### G. Recommendation for B2 / B3
**Do not implement B2 or B3.** The completion/fare transaction is not the remaining bottleneck; the
evidence puts the remaining slowdown on the Realtime WAL-decode pipeline (≈ 43 %) and Free-tier
compute capacity under burst load. Forcing a settlement-function refactor here would add financial
risk for an unmeasurable gain and would not move the progressive-slowdown symptom.

**Next evidence-based steps (outside Phase B's stated scope, for a future phase):**
1. **Compute / pooler upgrade** (Phase 3): raise `max_connections`, add the transaction pooler for
   edge functions, move off the smallest instance. This is what the timeout bursts, cron-startup
   timeouts, and 30–55 s introspection queries are asking for.
2. **Realtime surface reduction:** audit the 21-table publication and the 7 `riders` realtime
   subscriptions; retire any the client no longer needs; finish Phase 2a (`riders` FULL→DEFAULT)
   once the 5 `payload.oldRecord` consumers are migrated, or do A6.
3. **Fix the `orders.instructions does not exist` query bug** (separate, small).
4. Optional: `net._http_response` retention trim.
