# WayDrop — Final Deployment Checklist (C1–C12)

**Status as of this checklist: nothing has been deployed, committed, or pushed.** Everything below reflects local, uncommitted changes only (confirmed via `git status`). This document is a plan to follow when you're ready — it does not perform any action itself.

---

## 1. Edge Functions Still Needing Deployment (10)

| # | Function | Fixes | Change type |
|---|---|---|---|
| 1 | `verify-payment` | C2 | Added missing `.eq()` filter on the orders UPDATE |
| 2 | `create-order` | C3, C4, C5 | Payment verification before marking paid; JWT auth + ownership; `payment_for` mapping bugfix |
| 3 | `create-payment` | C4 | Server-side price derivation via `pricing_context`; ignores client `amount` for order/boost payments |
| 4 | `accept-order` | C5 | JWT auth + rider ownership check |
| 5 | `reject-order` | C5 | JWT auth + rider ownership check (rider row fetch added) |
| 6 | `update-order-status` | C5 | JWT auth + ownership check (order's user or assigned rider) |
| 7 | `process-verification-photo` | C5 | JWT auth + rider ownership check |
| 8 | `start-dispatch` | C5 | JWT auth (accepts user JWT or service-role key) |
| 9 | `regenerate-otp` | C6 | JWT auth; identity resolved from session, not request body |
| 10 | `cancel-order` | C10 | **New function** — thin proxy to `update-order-status` |

None of these have been deployed. `cancel-order` doesn't exist in the live project at all yet.

## 2. SQL Migrations Still Needing to Be Applied (3)

| # | File | Fixes | What it does |
|---|---|---|---|
| 1 | `supabase/migrations/20260715000001_fix_trip_share_tokens_rls.sql` | C7 | Removes the public blanket-SELECT policy on `trip_share_tokens`; adds a token-scoped `get_trip_share_token()` RPC |
| 2 | `supabase/migrations/20260715000002_revoke_public_notification_rpcs.sql` | C8 | `REVOKE EXECUTE FROM PUBLIC` on 4 push-notification functions, `GRANT` to `service_role`/`postgres` only |
| 3 | `supabase/migrations/20260715000003_fix_compliance_tables_rls.sql` | C9 | Scopes SELECT/INSERT on 5 compliance/SOS tables to order participants |

None of these have been applied to the live database. They are plain files on disk in `supabase/migrations/`.

## 2a. Companion Flutter Release (not an Edge Function or migration, but required)

The following are local Flutter code changes, not yet built or distributed to any tester device:
- `lib/features/auth/screens/login_screen.dart`, `otp_screen.dart`, `lib/shared/helpers/auth_session.dart` (C1 — narrowed OTP bypass)
- `lib/modules/payments/services/payment_service.dart` + 4 booking screens (C4 — sends `pricingContext` instead of trusting a precomputed amount)
- `lib/features/rider/orders/screens/rider_active_order_screen.dart` (C11 — crash fix)

**This matters for sequencing** — see Section 3, Phase 4.

---

## 3. Correct Deployment Order

### Phase 1 — Apply SQL migrations first
```
supabase db push
```
Applies all 3 new migrations (C7, C8, C9). These are pure database-side RLS/GRANT tightening with **no dependency on any Edge Function or app version** — they are safe to apply immediately and independently, and close public database-level holes as soon as they land. Run this first because it carries the least risk and the most urgency (world-callable RPCs and open tables are direct, unauthenticated exposure).

### Phase 2 — Deploy the Edge Functions that are safe for both old and new app installs
Deploy together, in this order:
```
supabase functions deploy verify-payment
supabase functions deploy create-order
supabase functions deploy accept-order
supabase functions deploy reject-order
supabase functions deploy update-order-status
supabase functions deploy process-verification-photo
supabase functions deploy start-dispatch
supabase functions deploy regenerate-otp
supabase functions deploy cancel-order
```
**Why these 9 are safe immediately, regardless of which app build a tester has installed:** none of them require a new field the current (already-installed) Flutter app doesn't already send. The JWT-auth additions (C5, C6) just check the `Authorization` header that `supabase.functions.invoke()` already attaches automatically on every call, old build or new. `verify-payment`'s fix is a pure server-side filter with no client contract change. `cancel-order` is brand new but every existing call site (old or new build) already sends the exact request shape it expects.

**One internal ordering note:** deploy `update-order-status` in the same batch as (or just before) `cancel-order`, since `cancel-order` proxies to it — this is not strictly required (the old `update-order-status` would still accept the proxied call, just without the C5 hardening for a brief window), but deploying them together means cancellation gets the full benefit of ownership checks from the moment `cancel-order` goes live.

### Phase 3 — Build and distribute the new Flutter app to all internal testers
Build a new release/internal-test artifact containing the C1, C4, and C11 Flutter changes, and get it installed on **every** tester device before Phase 4. Confirm rollout (e.g., via your test-track distribution list or a version check) before proceeding.

### Phase 4 — Deploy `create-payment` only after Phase 3 is confirmed complete
```
supabase functions deploy create-payment
```
**Why this one is sequenced last and separately:** the new `create-payment` *requires* a `pricing_context` object for any brand-new ride/parcel booking payment and will reject the request with a 400 if it's missing. The **old** Flutter app does not send `pricing_context`. If you deploy this function before every tester is on the new app build, **any tester still on the old build will be unable to complete an online payment** until they update — bookings via cash mode are unaffected, but online-payment bookings will hard-fail with a clear "pricing_context is required" error rather than silently misbehaving. Deploying this last avoids that entirely.

If for any reason you need to deploy `create-payment` before full rollout is confirmed, be aware of and accept that trade-off explicitly — don't let it happen by accident.

---

## 4. Post-Deployment Verification Checklist

Run these directly against the live project (Supabase dashboard SQL editor / CLI) after each phase — I have no live access to your project and cannot run these for you.

**After Phase 1 (migrations):**
- [ ] `select policyname, qual from pg_policies where tablename = 'trip_share_tokens';` — confirm the old "Allow public read of active unexpired share tokens" policy is gone.
- [ ] `select has_function_privilege('anon', 'get_trip_share_token(varchar)', 'execute');` → should be `false`; check `authenticated`/`service_role` → `true`.
- [ ] `select has_function_privilege('anon', 'send_admin_push_notification(text,text,text,text,jsonb)', 'execute');` → should be `false`. Repeat for `send_push_notification_fnc`, `deliver_push_notification_http_fnc`, `check_dormant_riders`.
- [ ] `select policyname, qual from pg_policies where tablename in ('parcel_security_logs','order_declarations','police_sos_logs','order_parcel_photos','parcel_compliance_reports');` — confirm each policy's `qual`/`with_check` references `orders o` / `auth.uid()`, not `true`.
- [ ] Trigger a routine order-status change (e.g. accept a test order) and confirm a push notification still arrives — proves the trigger functions still work post-REVOKE.

**After Phase 2 (9 Edge Functions):**
- [ ] `supabase functions list` — confirm all 9 show a recent deployment timestamp, and `cancel-order` now appears at all.
- [ ] Check function logs (`supabase functions logs <name>` or dashboard) for the first few real invocations of each — confirm no unexpected 401/403/500 spikes from legitimate traffic.
- [ ] Manually call `regenerate-otp` and `update-order-status` with **no** `Authorization` header (e.g. via `curl`) — confirm both now return `401`, not the old unauthenticated success.
- [ ] Call `cancel-order` with a valid order but a **different** user's token — confirm `403`, not a successful cancellation.

**After Phase 3 (Flutter rollout):**
- [ ] Confirm every active tester's app build number matches the new release before proceeding to Phase 4.
- [ ] Spot-check one tester device: attempt the OTP-bypass login with a phone number that merely *contains* `99999999` (not the exact reserved number) — confirm it now fails as invalid, only the exact reserved number + `123456` still works.

**After Phase 4 (`create-payment`):**
- [ ] Book a test ride online-payment end-to-end and confirm success (see smoke tests below).
- [ ] Attempt a `create-payment` call with a deliberately tiny/manipulated amount and no `pricing_context` (e.g. via `curl`/Postman with a valid token) — confirm it's now rejected or the amount is ignored in favor of the server-computed one, not silently accepted.
- [ ] Check `payments` table rows created after deployment — confirm `final_amount` matches the expected fare, not an arbitrary client value.

---

## 5. Smoke Tests To Run After Deployment

Run the full set below after Phase 4 completes (i.e., against the fully-deployed state). These are the same flows this engagement's fixes touch most directly:

**Auth**
- [ ] Real phone number + real OTP login still works end-to-end.
- [ ] Reserved test number (`9999999999`) + `123456` still logs in as the dummy tester (internal testing flow preserved).
- [ ] A phone number containing `99999999` as a substring but not equal to the reserved number is correctly rejected.

**Ride booking (cash)**
- [ ] Book a ride with cash payment mode → order created, dispatched, visible in searching screen.

**Ride booking (UPI intent)** — superseded 2026-07-22: Cashfree no longer touches passenger fares at
all (see `docs/07_Payments.md`). Ride/parcel/intercity payments are now cash or direct UPI intent,
settled at trip completion, not at booking.
- [ ] Book a ride with UPI payment mode → order created with `payment_status: 'pending'` (same as cash), no Cashfree order/session created.
- [ ] Complete the trip → passenger sees "Pay via UPI" at drop-off → driver swipes "Confirm UPI Payment Received" → order flips to `completed` + `payment_status: 'paid'` in one update.
- [ ] Confirm `cod_pending_amount` (not `wallet_balance`) increases by the company's share for a UPI trip, matching cash-mode settlement.

**Driver subscription (Cashfree production)**
- [ ] Buy the ₹40/day subscription with a real production payment → Cashfree production checkout opens (`CFWebCheckoutPaymentBuilder`, `CFEnvironment.PRODUCTION`) → payment succeeds → `subscription_active`/`subscription_expires_at` update within a few seconds.
- [ ] POST a forged payload (invalid/missing `x-webhook-signature`) to the deployed `cashfree-webhook` URL → confirm it's rejected with 400 and no `riders` row changes.

**Rider flow**
- [ ] Rider goes online → receives the test order → accepts it (confirm 403 no longer possible for a mismatched rider, 200 for the real assigned rider).
- [ ] Rider requests OTP regeneration (`regenerate-otp`) → confirm it still succeeds and displays the new OTP as before.
- [ ] Rider completes the ride via the cash-collection swipe button → confirm no crash, wallet updates, and screen doesn't hang (C11 regression check — background the app briefly during the swipe-complete network call if possible).

**Cancellation (all 6 surfaces)**
- [ ] Cancel from ride searching screen.
- [ ] Cancel from ride tracking screen.
- [ ] Cancel from parcel searching screen.
- [ ] Cancel from parcel tracking screen.
- [ ] Cancel from intercity searching screen.
- [ ] Cancel from intercity tracking screen.
- [ ] For each: confirm the order actually reaches `cancelled` status server-side (not just locally), and confirm attempting to cancel an order that's already `ongoing`/`picked_up` is correctly rejected rather than silently succeeding.

**Parcel / SOS**
- [ ] Rider triggers the SOS button on an active parcel order → confirm the `police_sos_logs` and `parcel_security_logs` inserts still succeed (this is the direct-client insert path affected by the C9 migration).

**Compliance data isolation**
- [ ] As User A, attempt to query another user's `parcel_security_logs`/`police_sos_logs`/`order_parcel_photos` rows (e.g. via the Supabase client with a known other `order_id`) → confirm the query returns empty, not the other user's data.

**Push notifications**
- [ ] Trigger any order-status change → confirm the passenger/rider still receives the push notification (proves the C8 REVOKE didn't break the trigger chain).
- [ ] Attempt to call `rpc('send_admin_push_notification', ...)` directly as an authenticated non-admin client → confirm it's now rejected, not silently sent.

---

*No code was modified, no deployment was performed, and nothing was committed or pushed in the course of producing this checklist.*
