# PRE-PRO REALTIME AMPLIFIER CLEANUP — safe-implementation audit

**Date:** 2026-09-09 · HEAD `418b1b4` · project `yvwpchffctiagevpqgwy`
**Result:** 2 changes prepared as ONE local migration (**NOT applied** — awaiting approval). 4 proposed
optimisations classified YELLOW/SKIP. **Zero new test failures.** No Dart / Edge Function change.

Priority order held: **FUNCTIONALITY > DATA/FINANCIAL SAFETY > SECURITY > REALTIME CORRECTNESS > PERFORMANCE.**

---

## Executive summary

| # | proposed optimisation | class | in the migration? |
|---|---|---|---|
| 1 | `orders` — drop 2 permissive `SELECT` policies that are **provable subsets** of a third (`rider_can_view_assigned_orders`, `user_can_view_own_orders`) | **GREEN** | ✅ yes |
| 2 | `users` / `notifications` / `rider_assignments` — `REPLICA IDENTITY FULL → DEFAULT` (0 `oldRecord` consumers, no production DELETE path that matters) | **GREEN** | ✅ yes |
| 3 | `orders` — `REPLICA IDENTITY FULL → DEFAULT` | **YELLOW** → SKIP | ❌ 4 consumers read `payload.oldRecord`; safety unprovable read-only |
| 4 | merge `orders` policies P1–P4 into one | **SKIP** | ❌ different tables/functions; error-prone; not needed |
| 5 | `rider_orders_screen` duplicate `orders` channels | **SKIP (already done)** | ❌ Egress-fix #3 already pooled them onto one `channelName` |
| 6 | collapse the 2–5 `riders` self-subscriptions per rider | **YELLOW → future** | ❌ touches 5 rider-critical screens; not trivial |
| 7 | drop 4 unused `orders` indexes + `idx_riders_subscription_active` | **YELLOW → future** | ❌ geo/device/expiry columns; rare admin/feature query can't be ruled out read-only |

**Expected effect of the migration (estimates):** ~3–7 % less per-burst realtime CPU. This is
**incremental hygiene that makes the Pro upgrade land better — it is not the fix.** The dominant
burst cost (`orders` FULL replica identity + subscriber fan-out) is deliberately left untouched
because it is not clearly GREEN.

---

## CHANGE 1 — `orders` SELECT policy consolidation (GREEN)

### Current live policy set (`pg_policy`, permissive, role `authenticated`, cmd SELECT)

| id | name | USING expression (from `pg_get_expr`) |
|---|---|---|
| P1 | `Allow travellers to browse searching intercity orders` | `order_status = 'searching' AND order_type::text ~~ 'intercity%'` |
| P2 | `Allow travellers to view orders tied to active intercity reques…` | `EXISTS(intercity_requests ir JOIN riders r ON r.id = ir.traveller_id WHERE ir.parcel_id = orders.id AND r.user_id = (SELECT auth.uid()) AND ir.status <> ALL(ARRAY['cancelled','rejected','expired']))` |
| P3 | `Allow users to view their own or assigned orders` | `(SELECT auth.uid()) = user_id OR EXISTS(riders r WHERE r.id = orders.rider_id AND r.user_id = (SELECT auth.uid())) OR check_is_order_candidate_rider(id, (SELECT auth.uid()))` |
| P4 | `admin_can_select_orders` | `is_admin()` |
| **P5** | `rider_can_view_assigned_orders` | `rider_id IN (SELECT riders.id FROM riders WHERE riders.user_id = (SELECT auth.uid()))` |
| **P6** | `user_can_view_own_orders` | `(SELECT auth.uid()) = user_id` |

No RESTRICTIVE policies on `orders` SELECT → effective visibility = `P1 ∨ P2 ∨ P3 ∨ P4 ∨ P5 ∨ P6`.
(The INSERT policy `Deny direct client orders insert` and the 2 UPDATE policies are **not touched**.)

### Equivalence proof

**`P6 ⊆ P3`** — `P6` is `(SELECT auth.uid()) = user_id`; that is **byte-for-byte** P3's first
disjunct. Every row P6 permits, P3 permits.

**`P5 ⊆ P3`** — `P5` is true iff `∃ x ∈ riders : x.id = orders.rider_id ∧ x.user_id = auth.uid()`.
P3's second disjunct `EXISTS(riders r WHERE r.id = orders.rider_id AND r.user_id = auth.uid())` is
true under the **identical** condition (`riders.id` is the PK ⇒ unique ⇒ `IN (subquery of ids)` and
`EXISTS(matching row)` coincide).

| case | P5 | P3-disjunct-2 |
|---|---|---|
| `orders.rider_id IS NULL` | `NULL IN (…)` → not visible | `EXISTS(… r.id = NULL …)` → false | ✅ same |
| user owns no rider (empty subquery) | `x IN ()` → false | `EXISTS()` → false | ✅ same |
| `auth.uid()` NULL | subquery `WHERE user_id = NULL` → 0 rows → false | `EXISTS(… r.user_id = NULL)` → false | ✅ same |
| normal match | true | true | ✅ same |

**Truth table** (M = "current user owns the assigned rider", O = "current user is the order owner";
these are the only conditions P5/P6 test):

| O | M | P5∨P6 | P3 (first two disjuncts) | (P1..P6) | (P1..P4) | equal? |
|---|---|---|---|---|---|---|
| F | F | F | F | P1∨P2∨P4 | P1∨P2∨P4 | ✅ |
| T | F | T | T | **T** | **T** | ✅ |
| F | T | T | T | **T** | **T** | ✅ |
| T | T | T | T | **T** | **T** | ✅ |

⇒ `(P1 ∨ P2 ∨ P3 ∨ P4 ∨ P5 ∨ P6) ≡ (P1 ∨ P2 ∨ P3 ∨ P4)` for **every** role and row.

### Security / behaviour verification

- **No access gained or lost** for: passenger (P3 d1 / P6), owner, assigned rider (P3 d2 / P5),
  candidate rider (P3 d3 — unchanged), active-intercity traveller (P2 — unchanged), admin (P4 —
  unchanged). `service_role` bypasses RLS entirely.
- **REST / PostgREST SELECT**: identical OR of permissive policies → identical result set.
- **Realtime RLS delivery**: identical → same events reach the same subscribers.
- **No user can see another user's order** — P5/P6 removal can only *remove* access, and it removes
  nothing (both are subsets of the retained P3).
- **RPC behaviour**: unaffected (RPCs run as `service_role`, RLS-exempt).
- **Booking / acceptance / tracking / completion**: all depend on the owner/rider seeing their order
  — served by P3, retained.

### Consumers / dependencies

- `pg_get_expr` shows the **phase10d initplan-wrapped** form is live (`(SELECT auth.uid())`) — the
  rollback recreates that exact form.
- Migration `20260907000001_phase10d_rls_initplan_wrap_auth_calls.sql` re-created P5/P6 (comments
  only reference them). Baseline `20260529000000` created them. **Neither file is modified.**
- `test/user_activity_history_pagination_regression_test.dart:190` asserts the **baseline file text**
  contains `CREATE POLICY "user_can_view_own_orders" …` — that file is untouched, so the test still
  passes. Its *intent* ("passenger's own-orders SELECT is restricted to `auth.uid() = user_id`")
  remains true — that restriction now lives as P3's first disjunct.

### Rollback

```sql
CREATE POLICY "rider_can_view_assigned_orders" ON public.orders FOR SELECT TO authenticated
  USING (rider_id IN (SELECT riders.id FROM riders WHERE riders.user_id = (SELECT auth.uid())));
CREATE POLICY "user_can_view_own_orders" ON public.orders FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) = user_id);
```

**Confidence: 99 %** (the only residual is theoretical — a Postgres planner quirk in how it costs the
now-4-policy OR; observationally impossible to change the *result set*).

---

## CHANGE 2 — `users` / `notifications` / `rider_assignments` REPLICA IDENTITY FULL → DEFAULT (GREEN)

### `payload.oldRecord` search (HEAD 418b1b4, all Dart + Edge Functions)

Grep for `oldRecord` / `payload.old` — **every** hit:

| file:line | subscribed table | reads |
|---|---|---|
| `rider_home_tab.dart:592` | **riders** | `isLocationOnlyUpdate` diff |
| `rider_profile_tab.dart:232` | **riders** | `isProfileRelevantUpdate` diff |
| `rider_earnings_tab.dart:228` | **riders** | `isEarningsUiRelevantUpdate` diff |
| `rider_orders_screen.dart:389` | **riders** | `isLocationOnlyUpdate` diff |
| `home_tab.dart:955` | **riders** | `isLocationOnlyUpdate` diff |
| `rider_home_tab.dart:824` | **orders** | `oldRecord['order_status']` |
| `intercity_bookings_screen.dart:199` | **orders** | `oldRecord['order_status']` |
| `rider_active_order_screen.dart:1293-95` | **orders** | `oldRecord['pickup_verification_completed']`, `['delivery_otp']` |
| `home_tab.dart:1024-26` | **orders** | DELETE handler: `oldRecord['user_id']` |

**Zero hits for `users`, `notifications`, or `rider_assignments`.** No Edge Function opens a realtime
channel at all (verified). No SQL trigger/function is affected (trigger `OLD` is executor-provided,
independent of replica identity; and none of the 6 triggers on these 3 tables fires on DELETE).

### Per-table safety

| table | subscribers | DELETE in production? | verdict |
|---|---|---|---|
| **users** | `user_session_service` (event:`update`, `id=` PK, reads `newRecord['is_suspended']`/`['deleted_at']`); `home_tab` (event:`update`, `id=` PK, reads `newRecord`) | **never** — `delete_own_account` nulls fields; `orders.user_id` is `ON DELETE RESTRICT` | **GREEN** — both consumers are UPDATE + PK-filter + newRecord-only ⇒ byte-identical under DEFAULT |
| **notifications** | `notification_badge_service` (event:`all`, `user_id=`, callback = `refresh()`) | only `delete_own_account` (which also logs the user out via `users.deleted_at`) | **GREEN** — badge needs INSERT (new notif) + UPDATE (mark-read), both fully delivered under DEFAULT; the never-exercised filtered DELETE event has no functional effect. No "delete notification" UI exists (grep: no client `.delete()` on `notifications`). |
| **rider_assignments** | `rider_home_tab` / `rider_orders_screen` / `intercity_searching_screen` / `travel_plan_details` (event:`all`, `rider_id=`/`order_id=`); `incoming_order_card` (event:`update`, `id=` PK) | **never** in a user flow — lifecycle sets `assignment_status='expired'` (an UPDATE); the **only** `DELETE` is `supabase/functions/load-testing/index.ts` (QA tool) | **GREEN** — the dispatch/acceptance critical path is **INSERT** (`assignment_status='sent'` → rider's incoming-order sheet) + **UPDATE** (`accepted`/`rejected`/`expired`), both fully delivered under DEFAULT; INSERT always carries the full new row; UPDATE carries the full `newRecord`; PK / `rider_id` / `order_id` filters evaluate fine on INSERT+UPDATE |

**Why FULL is inert here:** with RLS enabled on all 3 (verified), Supabase Realtime already delivers
`payload.old` to clients as **PK-only regardless of replica identity**. FULL only inflates the WAL
old-tuple that `realtime.list_changes` must decode.

### Benefit

Every UPDATE/DELETE to these tables logs the PK (≈ 40 B) instead of the full old row as the old
tuple ⇒ roughly halves the WAL / decode payload for: `notifications` (7,380 lifetime UPDATEs, wide
title/body/jsonb rows), `rider_assignments` (3,148 UPDATEs), `users` (1,930 UPDATEs). INSERT is
unaffected (always full new row).

### Rollback

```sql
ALTER TABLE public.users             REPLICA IDENTITY FULL;
ALTER TABLE public.notifications     REPLICA IDENTITY FULL;
ALTER TABLE public.rider_assignments REPLICA IDENTITY FULL;
```

**Confidence: 95 %** (residual: the P3-style unresolved question of exactly how Supabase Realtime's
server-side RLS re-evaluates an UPDATE under DEFAULT — but for these 3 tables *no client reads the
old record*, so the only observable surface is event **delivery**, and INSERT/UPDATE delivery with
PK / newRecord-column filters is preserved).

---

## SKIPPED / YELLOW

### #3 `orders` REPLICA IDENTITY → DEFAULT — YELLOW, SKIP

4 consumers read `payload.oldRecord` on `orders`. If FULL genuinely delivers the old row to `orders`
subscribers today, flipping to DEFAULT would make 3 diff-gates
(`rider_home_tab:824`, `intercity_bookings_screen:199`, `rider_active_order_screen:1293`) degrade to
"always refresh" (**neutral-to-worse** for CPU — more client queries, not fewer) and one DELETE
handler (`home_tab:1024`) stop matching. `orders` is also **not** DELETEd anywhere in the current
codebase, so that handler may already be dead — but I **cannot prove** the diff-gate behaviour
read-only. **A live `orders` UPDATE payload capture (rider + passenger session active) is required.**
Deferred to the post-Pro test window.

### #4 merge P1–P4 — SKIP

P1 (status literal), P2 (`intercity_requests` join), P3 (`riders` join + `check_is_order_candidate_rider`
function), P4 (`is_admin()`) reference different objects. A single merged expression is error-prone
and offers no benefit over dropping the 2 pure-redundant policies.

### #5 `rider_orders_screen` duplicate `orders` channels — SKIP (already optimised)

`rider_orders_screen.dart:759` and `:988` **both** set `channelName = 'rider-active-order-$riderId'`
(same as `rider_home_tab`'s active-order channel) with identical config — Egress-fix #3 already
merged them: `RealtimeManager` pools all three onto **one** server-side channel with three
client-side callbacks. Server realtime cost is already 1. Merging the callbacks would save one
function call per event (negligible) for real refactor risk.

### #6 `riders` self-subscriptions (2–5 per rider) — YELLOW, future

All 5 (`rider_main_navigation`, `rider_home_tab`, `rider_orders_screen`, `rider_profile_tab`,
`rider_earnings_tab`) use identical config (`table:'riders'`, `event:update`, `filter id=<self>`) but
distinct `channelName`s, so `RealtimeManager` does not pool them → 5 server channels for the rider's
own row. Renaming to one shared `channelName` would pool them into 1 (RealtimeManager ref-counts
listeners). Mechanically low-risk given RealtimeManager's design, **but it touches 5 rider-critical
screens with per-file lifecycle nuances** (tab-visibility gating, app-lifetime channel). Per the
phase rule ("if a safe pooling change is not trivial: SKIP and report as future"), deferred.
Estimated benefit: 5→1 server channels per rider (× N riders) for a row that gets ~1 write/min.

### #7 unused indexes — YELLOW, future

`idx_orders_created_device_record_id`, `idx_orders_pickup_location (pickup_lat,pickup_lng)`,
`idx_orders_destination_location (destination_lat,destination_lng)`, `idx_orders_search_expires_at`,
`idx_riders_subscription_active` — all `idx_scan = 0` for ~4 months, no FK/constraint backing, tiny
(16–88 kB). The 4 expiry/redispatch/dormant crons were verified **not** to use `search_expires_at` or
`riders.subscription_active`. **But** the geo columns (`pickup_lat/lng`, `destination_lat/lng`) and
`created_device_record_id` could serve a rare admin report / anti-fraud check / future geo feature
that a 4-month scan window would miss, and the task's own rule is "if uncertain, leave it untouched."
`idx_riders_subscription_active` (a boolean btree — near-useless by construction) is arguably GREEN
but too marginal (16 kB, ~1 fewer index touch per ~1/min GPS write) to justify a migration on its own.
Deferred; can be revisited with `EXPLAIN` against real query traffic after Pro.

---

## Phase 6 — burst amplification after the GREEN changes (all [E] unless tagged)

10 riders online + 10 concurrent rides + GPS + assignments + notifications + chat:

| metric | before this migration | after this migration | change |
|---|---|---|---|
| DB writes / min | ~110–130 **[M-derived]** | unchanged | 0 (no write path changed) |
| Realtime-decoded events / min | ~95–110 | unchanged (same events) | 0 event count |
| **decode bytes / min** | baseline | `notifications`/`rider_assignments`/`users` UPDATE+DELETE old-tuple ~½ size | **≈ −5–10 %** of decode bytes |
| RLS evaluations / min | ~1,300–2,500 (dominated by `orders` 6-policy) | ~1,000–1,900 (`orders` 4-policy) | **≈ −15–25 %** of `orders` RLS *expressions*, but the OR short-circuits on P3 for owner/rider subscribers, so the *realised* CPU saving is smaller — mostly on non-matching / walrus checks |
| subscriber deliveries / min | ~300–550 | unchanged | 0 |
| follow-up queries / min | ~150–300 | unchanged | 0 |

**First saturation point is unchanged:** `list_changes` decode + per-subscriber RLS on 2 shared
vCPU. These changes push the wall out slightly; they do not move it. **Net expected: ≈ 3–7 % less
per-burst realtime CPU.**

---

## Phase 7 — critical-flow regression audit

| flow | touched? | why it's safe |
|---|---|---|
| passenger / rider signup·login | no | — |
| rider online/offline | no | `riders` untouched (RI + policies) |
| booking / order creation | no | `orders` INSERT policy `Deny direct client orders insert` untouched; fare/serviceability/rider-search unaffected |
| serviceability, fare/price calc | no | — |
| rider discovery / `find_nearby_riders` | no | reads `riders` (untouched) |
| rider assignment (dispatch) | **realtime path** | `rider_assignments` **INSERT** (`status='sent'`) still delivered under DEFAULT (INSERT = full new row); `rider_id`/`order_id`/`id` filters evaluate on INSERT |
| rider accept / reject | **realtime path** | `rider_assignments` **UPDATE** (`accepted`/`rejected`) still delivered (full `newRecord`); `accept-order` RPC is `service_role` (RLS-exempt) |
| rider arrival / OTP / ongoing | **realtime path** | `orders` status **UPDATE** still delivered (orders RI **not** changed — still FULL); `update-order-status` RPC RLS-exempt |
| live rider/passenger tracking, GPS | no | `riders` / `rider_locations` untouched; passenger sees the order via P3 |
| intercity flows | no | P1/P2 (intercity SELECT policies) untouched; `intercity_requests` untouched |
| chat | no | `order_chat_messages` untouched |
| notifications | **RI only** | badge INSERT/UPDATE delivered under DEFAULT; `on_notification_insert` FCM trigger is AFTER INSERT (RI-independent) |
| payment / cash / UPI | no | `payments` untouched; `complete_order_and_settle` untouched |
| completion / settlement / wallet / earnings | no | completion RPC, `government_tax_ledger`, `order_completion_side_effects`, `wallet_transactions` all untouched |
| cancellation | no | `orders` UPDATE policies untouched; `cancel-order` RPC RLS-exempt |
| order history | **RLS read** | passenger's `.from('orders').select()` still returns their orders via P3-disjunct-1 (identical row set) |
| rider earnings screen | no | subscribes `riders` (untouched) + `rider_withdrawals` (untouched) |
| KYC / payout / account deletion | no | `rider_kyc`, `rider_payout_accounts`, `delete_own_account` untouched |
| all existing realtime functionality | **verified per §CHANGE 2** | every INSERT/UPDATE delivery preserved; only never-exercised filtered-DELETE events on 3 tables are affected |

**No business logic, financial behaviour, dispatch algorithm, GPS behaviour, or completion logic is
changed.**

---

## Phase 9 — test results

| check | result |
|---|---|
| migration static (dollar-quotes, DDL, guards, no GRANT/REVOKE) | ✅ balanced, 2 `DROP POLICY IF EXISTS` + 1 guarded `DO` block, 0 GRANT |
| no existing migration modified | ✅ `git diff --stat` empty |
| `flutter test --exclude-tags=live` **with** the migration file | **1986 pass / 17 fail** |
| `flutter test --exclude-tags=live` **without** the migration file (control) | **1986 pass / 17 fail** — **identical** |
| ⇒ new failures introduced | **0** |
| targeted: `phase1`/`phase2` function-lockdown migration scanners | ✅ pass |
| targeted: `user_activity_history_pagination` (references `user_can_view_own_orders`) | ✅ pass |
| targeted: `local_dispatch_latency`, `local_ride_driver_distance` (assert `rider_assignments` FULL in *baseline* files) | ✅ pass (static text on files not modified) |
| targeted: `rider_freed_rematch`, `rider_gps_webview_perf`, `realtime_manager_collision_guard`, `payment_realtime_health_gate` | ✅ pass |
| Dart / Edge Function changes | **none** — `flutter analyze` unaffected |

The 17 pre-existing failures (`rider_self_rematch`, `rider_selfie_capture_restart`, subscription/
travel-plan structural guards, …) fail identically on a clean tree and are unrelated to SQL.

---

## Production migration status

**PREPARED, NOT APPLIED.** File: `supabase/migrations/20260909000000_pre_pro_realtime_amplifier_cleanup.sql`
(untracked). Awaiting explicit approval per Phase 10.

- **SQL changes:** `DROP POLICY IF EXISTS "rider_can_view_assigned_orders" ON public.orders;` ·
  `DROP POLICY IF EXISTS "user_can_view_own_orders" ON public.orders;` · guarded
  `ALTER TABLE public.{users,notifications,rider_assignments} REPLICA IDENTITY DEFAULT;`
- **Dart changes:** none.
- **Risk:** LOW. Change 1 is a provable no-op on the result set. Change 2 has no `oldRecord`
  consumer and preserves all INSERT/UPDATE delivery.
- **Rollback:** one SQL block, in the file (recreate 2 policies in phase10d form; restore FULL on 3
  tables). Metadata-only, seconds, no table rewrite.
- **Expected benefit:** ≈ 3–7 % per-burst realtime CPU; smaller WAL/decode payload on
  `notifications`/`rider_assignments`/`users`; one fewer `orders` SELECT-policy expression.
- **Not a substitute for the Pro upgrade** — the binding constraint (2 shared vCPU) is unchanged.

### Recommended production apply order (after approval)
1. Apply migration `20260909000000` (additive, reversible).
2. Structural verification: 4 SELECT policies on `orders`; `users`/`notifications`/`rider_assignments`
   = DEFAULT; `orders`/`riders` still FULL; publication still 13 tables; no other object changed.
3. Then proceed with the **Pro (Small) compute upgrade** + the 6-continuous-ride validation from the
   prior audit (Part 13).

---

## Git status

`HEAD == dhanush/main == 418b1b4`. **No commit. No push.** Working tree: pre-existing untracked
`docs/PERF_*.md`, `supabase/migrations/20260908000004_*`, `20260908000007_*`, plus the new
`20260909000000_pre_pro_realtime_amplifier_cleanup.sql`. No tracked file modified.
