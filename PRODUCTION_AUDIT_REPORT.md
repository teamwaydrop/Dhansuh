# WayDrop Production Readiness Audit

**Audit date:** 2026-07-15
**Scope:** Full codebase — 117 Flutter/Dart files, 16 Supabase Edge Functions, 56 SQL migrations, Android release configuration.
**Method:** Static, read-only inspection. No code was modified, committed, pushed, or deployed as part of this audit.
**Excluded (already fixed and re-verified as still fixed):** realtime memory leak, logout realtime subscription leak, mounted/dispose race conditions, duplicate stream subscriptions, UserSession realtime cleanup, `accept-order` double-assignment race condition, incoming-order-card overflow issue.

---

## Executive Summary

| Metric | Value |
|---|---|
| Total Critical Bugs | **12** |
| Total High Bugs | **20** |
| Total Medium Bugs | **26** |
| Total Low Bugs | **11** |
| **Total Bugs Found** | **69** |
| **Overall Production Readiness Score** | **38 / 100** |
| **Google Play Internal Testing Ready?** | **NO** |
| **Estimated effort to reach Internal Testing readiness** | **3–5 focused engineering days** (Critical + must-fix High items only) |

### Score breakdown (weighted)

| Category | Score | Weight | Notes |
|---|---|---|---|
| Auth / Session Security | 15 / 100 | 20% | Hardcoded OTP bypass live in prod; core order endpoints have no caller auth |
| Payments & Financial Integrity | 20 / 100 | 20% | Unfiltered payment-status UPDATE; client-controlled amounts; no wallet double-credit guard |
| Database / RLS | 30 / 100 | 15% | Several tables wide open or world-callable RPCs; but well-designed patterns exist elsewhere (withdrawals, `order_verifications`) |
| Order Lifecycle (rider/user/parcel flows) | 45 / 100 | 15% | Missing `cancel-order` function; solid accept-flow locking; dispatch trigger regression |
| Flutter Stability (lifecycle/memory) | 60 / 100 | 10% | One crash-risk on the core completion flow; several inconsistent `mounted` guards elsewhere |
| UI / Layout | 85 / 100 | 5% | Codebase is largely hardened already; only narrow overflow gaps remain |
| Notifications / Realtime / Offline | 55 / 100 | 5% | Reconnect logic and offline chat queueing are genuinely solid; one unscoped channel causes platform-wide fan-out |
| Android / Play Store Config | 70 / 100 | 5% | Manifest, signing, target SDK all correct; missing ProGuard keep rules and a committed `.env` secret |
| Performance | 65 / 100 | 5% | No systemic issue; some redundant polling and uncached list filtering |

**Weighted overall: 38/100.** The architecture itself (realtime reconnect, offline chat queueing, `accept-order` locking, most RLS design, Android build config, UI layout discipline) is mature and well above average for a project at this stage. The score is pulled down almost entirely by a concentrated cluster of Critical security/financial defects that are launch-blocking regardless of how solid the rest of the app is.

---

# Critical Bugs

### C1 — Hardcoded Authentication Bypass Live in Production
- **Severity:** Critical
- **Root Cause:** `login_screen.dart` and `otp_screen.dart` contain a hardcoded bypass: any phone number containing the substring `99999999` combined with OTP `123456` skips real OTP verification and signs the user in anonymously. This is not gated by `kDebugMode`, a build flavor, or any environment flag.
- **Production Impact:** Any real user can fully bypass authentication on the released app, sign in without a valid phone number, and receive an auto-completed fake profile ("Cashfree Tester"). Full authentication bypass reachable by the public.
- **Files Involved:** `lib/features/auth/screens/login_screen.dart:107`, `lib/features/auth/screens/otp_screen.dart:127`
- **Fix Required:** Remove the bypass entirely, or gate it strictly behind `kDebugMode` / a dedicated internal QA build flavor that is never shipped to Play Store.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 15 minutes

### C2 — `verify-payment` Unfiltered UPDATE Corrupts the Entire Orders Table
- **Severity:** Critical
- **Root Cause:** The `orders` table UPDATE in `verify-payment` has no `.eq(...)` filter clause, unlike the adjacent block a few lines below it which correctly filters. Using the service-role key (RLS bypassed), the query runs unfiltered.
- **Production Impact:** Every time any payment is successfully verified, `payment_status` is set to `"paid"` on **every row in the `orders` table**, including cash-on-delivery orders and orders belonging to unrelated users. Confirmed by direct code inspection.
- **Files Involved:** `supabase/functions/verify-payment/index.ts:468-475`
- **Fix Required:** Add `.eq("id", payment.reference_id)` (or the correct order-reference column) to scope the update to the single order being verified.
- **Requires Flutter?** No
- **Requires Edge Function?** Yes
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 15 minutes

### C3 — `create-order` Marks Non-Cash Orders "Paid" With No Verification
- **Severity:** Critical
- **Root Cause:** `payment_status` is set to `"paid"` for any non-cash `payment_mode` at order-creation time, without any check that a real payment (Cashfree transaction, `create-payment`/`verify-payment` round trip) ever occurred.
- **Production Impact:** Combined with C5 (no caller auth), any client can create an order with `payment_mode: "online"` and receive an instantly "paid" order with zero real payment — a free-ride/free-delivery exploit.
- **Files Involved:** `supabase/functions/create-order/index.ts:784-794`
- **Fix Required:** Force `payment_status: "pending"` for all non-cash orders at creation; only `verify-payment` (after fixing C2) should ever flip it to `"paid"`.
- **Requires Flutter?** No
- **Requires Edge Function?** Yes
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 30 minutes

### C4 — `create-payment` Never Validates Client-Supplied Amount
- **Severity:** Critical
- **Root Cause:** The only validation on the client-supplied `amount` is `amount <= 0`; it is never cross-checked against the order's actual fare/total before being sent to Cashfree as `order_amount`.
- **Production Impact:** A client can submit `amount: 1` for a ₹500 order; Cashfree creates a ₹1 payment, which (via C2) then marks the full order as paid. Direct financial exploit.
- **Files Involved:** `supabase/functions/create-payment/index.ts:210-214, 300-306, 408-414`
- **Fix Required:** Recompute the expected amount server-side from the order's stored fare/boost fields and reject the request if the client-supplied amount doesn't match.
- **Requires Flutter?** No
- **Requires Edge Function?** Yes
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 2 hours

### C5 — No JWT / Ownership Verification on Core Order-Lifecycle Functions
- **Severity:** Critical
- **Root Cause:** `accept-order`, `reject-order`, `update-order-status`, `create-order`, `process-verification-photo`, and `start-dispatch` never call `supabase.auth.getUser()` or otherwise verify the caller's identity. Rider/user IDs are taken directly from the request body and trusted.
- **Production Impact:** Anyone who knows (or enumerates) an `order_id` can accept orders as an arbitrary rider, force an order to `completed`/`delivered` (crediting a rider's wallet), mark pickup verification as complete, reject any order, or create orders under any `user_id` — with no proof of identity at all.
- **Files Involved:** `supabase/functions/accept-order/index.ts`, `supabase/functions/reject-order/index.ts`, `supabase/functions/update-order-status/index.ts`, `supabase/functions/create-order/index.ts`, `supabase/functions/process-verification-photo/index.ts`, `supabase/functions/start-dispatch/index.ts`
- **Fix Required:** Add `supabase.auth.getUser(token)` to every function; derive rider/user identity from the authenticated session, not the request body; verify the caller actually owns/is-assigned-to the order before any mutation.
- **Requires Flutter?** No
- **Requires Edge Function?** Yes
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 5–6 hours (6 functions)

### C6 — `regenerate-otp` Trusts Client-Asserted Identity and Leaks the OTP
- **Severity:** Critical
- **Root Cause:** Identity comes from plain body fields (`actor_user_id`/`actor_rider_id`) with no JWT verification. The function also returns the newly generated OTP directly in the JSON response.
- **Production Impact:** Anyone who knows an order's `user_id`/`rider_id` can request and receive a valid pickup/delivery OTP, defeating the physical-handover proof the OTP system exists for.
- **Files Involved:** `supabase/functions/regenerate-otp/index.ts:229-277, 457-469`
- **Fix Required:** Verify the caller's JWT via `auth.getUser()`; derive `actor_user_id`/`actor_rider_id` from the authenticated session, never from the request body; do not return the OTP to any caller other than the legitimately verified order participant it was generated for.
- **Requires Flutter?** No
- **Requires Edge Function?** Yes
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 1.5 hours

### C7 — `trip_share_tokens` RLS Policy Leaks All Live Share Tokens
- **Severity:** Critical
- **Root Cause:** The SELECT policy `USING (is_revoked = false AND expires_at > now())` has no `TO` clause (defaults to `PUBLIC`) and never matches against the specific token being requested — it returns every currently valid row to any caller.
- **Production Impact:** Anyone, unauthenticated, can enumerate every live "share my trip" token and associated `order_id` currently active on the platform, fully defeating the safety feature.
- **Files Involved:** `supabase/migrations/20260616000007_otp_limits_rls.sql:139-143`
- **Fix Required:** New migration to scope SELECT to the exact token supplied in the request (e.g., via a `SECURITY DEFINER` RPC that takes a token parameter), or remove public SELECT and serve share-link lookups through an authenticated edge function.
- **Requires Flutter?** No
- **Requires Edge Function?** Possibly (if lookup is moved server-side)
- **Requires SQL?** Yes
- **Requires Migration?** Yes
- **Requires RLS?** Yes
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 1.5 hours

### C8 — Push-Notification RPCs Are World-Callable
- **Severity:** Critical
- **Root Cause:** `send_push_notification_fnc`, `deliver_push_notification_http_fnc`, `check_dormant_riders`, and `send_admin_push_notification` are `SECURITY DEFINER` functions with no `REVOKE EXECUTE ... FROM PUBLIC` applied, unlike other sensitive functions in the same codebase (`initiate_withdrawal`, `check_otp_lockout`) which are correctly locked down.
- **Production Impact:** Any authenticated (arguably anonymous) client can call `rpc/send_admin_push_notification` to send arbitrary phishing/spam push notifications to every user or rider on the platform, or spoof a targeted notification to any specific `user_id`.
- **Files Involved:** `supabase/migrations/20260602000002_create_notification_triggers.sql`, `supabase/migrations/20260602000003_expand_notifications_logic.sql`, `supabase/migrations/20260617000000_add_order_notification_mode.sql`
- **Fix Required:** New migration adding `REVOKE EXECUTE ... FROM PUBLIC` on all four functions, with `GRANT EXECUTE` limited to `service_role` only.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** Yes
- **Requires Migration?** Yes
- **Requires RLS?** No (function-level GRANT/REVOKE, not table RLS)
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 30 minutes

### C9 — Compliance / SOS Evidence Tables Are Wide Open
- **Severity:** Critical
- **Root Cause:** `parcel_security_logs`, `order_declarations`, `police_sos_logs`, `order_parcel_photos`, and `parcel_compliance_reports` have RLS enabled but with `USING (true)` / `WITH CHECK (true)` policies for SELECT/INSERT — effectively no restriction for any authenticated user.
- **Production Impact:** Any user or rider can read every other user's SOS notes, GPS/IP/device data, and compliance photos, and can insert forged security/SOS/declaration records against any `order_id` — corrupting evidence intended for legal/police use.
- **Files Involved:** `supabase/migrations/20260612000002_compliance_tables_and_columns.sql:96-161`, `supabase/migrations/20260612000003_compliance_adjustments.sql:132-141`
- **Fix Required:** New migration scoping SELECT/INSERT to order participants (owner or assigned rider), matching the correct pattern already used for the `order_verifications` table.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** Yes
- **Requires Migration?** Yes
- **Requires RLS?** Yes
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 2.5 hours (5 tables)

### C10 — `cancel-order` Edge Function Does Not Exist
- **Severity:** Critical
- **Root Cause:** Six screens call a `cancel-order` edge function that was never created (`supabase/functions/` has no such directory). Every call 404s and falls through to a `catch` block that performs a raw, unvalidated `orders.update({order_status:'cancelled'})` from the client.
- **Production Impact:** Every cancellation on both rider and user sides bypasses all server-side transition validation, leaves stale `rider_assignments`/`order_assignment_logs` rows behind, writes no audit trail, and has no guard preventing cancellation from an in-progress state (e.g. `ongoing`).
- **Files Involved:** `lib/features/local_rides/searching/screens/ride_searching_screen.dart:281`, `lib/features/local_rides/tracking/screens/ride_tracking_screen.dart:1385`, `lib/features/local_parcels/searching/screens/parcel_searching_screen.dart:266`, `lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart:1372`, `lib/features/intercity/shared/screens/intercity_searching_screen.dart:1253`, `lib/features/intercity/shared/screens/intercity_tracking_screen.dart:1717`
- **Fix Required:** Build a proper `cancel-order` Edge Function (or route cancellation through `update-order-status` with `new_status:'cancelled'`) that validates the current state, expires assignments, writes an audit row, and enforces caller ownership; update all 6 Flutter call sites accordingly.
- **Requires Flutter?** Yes (6 files)
- **Requires Edge Function?** Yes (new function or reuse of existing one)
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 4 hours

### C11 — setState-After-Dispose Crash Risk on the Ride/Parcel Completion Flow
- **Severity:** Critical
- **Root Cause:** The direct-call completion path (`completeOnlineRide`, cash-collection swipe confirmation — used on every single completed order) calls `setState()` after multiple `await`s with no `mounted` guard, unlike the realtime-driven completion path in the same file, which is correctly guarded.
- **Production Impact:** If the rider backgrounds the app or navigates away during the ~800ms+ network round trip, the app throws a framework exception ("setState() called after dispose()"), crashing the app on the primary earning-completion flow used by every rider on every order.
- **Files Involved:** `lib/features/rider/orders/screens/rider_active_order_screen.dart:2983-2991, 3000-3007`
- **Fix Required:** Add `if (!mounted) return;` guards before both `setState` calls, matching the pattern already used correctly elsewhere in the same file.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 20 minutes

### C12 — Live Production Secrets Committed to Git History
- **Severity:** Critical
- **Root Cause:** The repo-root `.env` file is tracked in git despite being listed in `.gitignore` — it was committed before the ignore rule took effect and modified again in later commits. It contains a live `OLA_MAPS_API_KEY` and `CASHFREE_ENV=production`.
- **Production Impact:** Anyone with access to the repository (or a future fork/leak) has a billable, quota-bound production API key, and confirmation that this is a live production configuration.
- **Files Involved:** `.env` (repo root)
- **Fix Required:** Rotate `OLA_MAPS_API_KEY` immediately, scrub `.env` from git history (`git filter-repo` or BFG Repo-Cleaner), keep only a `.env.example` template in source control.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 1.5 hours (key rotation + history scrub)

---

# High Priority Bugs

### H1 — Fare Manipulable via Client-Supplied Distance
- **Severity:** High
- **Root Cause:** `create-order` forwards the client-supplied `distance_km` to `calculate-order-pricing`, which uses it directly in fare calculation with no cross-check against pickup/destination coordinates.
- **Production Impact:** A client can submit a small `distance_km` for a long trip to obtain a near-minimum fare.
- **Files Involved:** `supabase/functions/create-order/index.ts:209-238`, `supabase/functions/calculate-order-pricing/index.ts:397,488`
- **Fix Required:** Compute distance server-side from coordinates (routing API or Haversine sanity bound) instead of trusting the client value.
- **Requires Flutter?** No
- **Requires Edge Function?** Yes
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No (fix before wider/paid rollout)
- **Estimated Fix Time:** 2.5 hours

### H2 — `load-testing` Function Live in Production, Unauthenticated
- **Severity:** High
- **Root Cause:** `load-testing` has no auth check; `simulate_locations` overwrites real riders' live coordinates, and `cleanup` deletes real, in-flight `rider_assignments` rows with `assignment_status='sent'` unscoped to test data.
- **Production Impact:** Any caller can corrupt live dispatch data or delete real in-flight assignments; also an unbounded resource-exhaustion/DoS vector.
- **Files Involved:** `supabase/functions/load-testing/index.ts`
- **Fix Required:** Remove from production deployment, or gate behind an admin-only JWT plus an explicit environment flag; scope all mutations to rows explicitly tagged as test data.
- **Requires Flutter?** No
- **Requires Edge Function?** Yes
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes (undeploy or gate before test track opens)
- **Estimated Fix Time:** 1 hour

### H3 — Auto-Dispatch Trigger Regression
- **Severity:** High
- **Root Cause:** The self-matching prevention fix and weight/vehicle-aware matching applied earlier were reverted by the latest redefinition of `assign_nearby_searching_orders_to_rider()`.
- **Production Impact:** The trigger-based auto-assignment path can once again match a user to their own rider account and mismatch vehicle type to parcel weight; inconsistent with the RPC-based search path, which still has the fix.
- **Files Involved:** `supabase/migrations/20260623000000_suggested_dispatch_logic.sql:20-227`
- **Fix Required:** New migration re-merging the exclusion and weight-aware matching logic into the current trigger function.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** Yes
- **Requires Migration?** Yes
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No (but before broader rollout)
- **Estimated Fix Time:** 2 hours

### H4 — Wallet Ledger Never Populated by Withdrawal Functions
- **Severity:** High
- **Root Cause:** `initiate_withdrawal`, `fail_withdrawal`, and `complete_withdrawal` directly `UPDATE riders SET wallet_balance = ...` but never insert into `wallet_transactions`.
- **Production Impact:** The nightly `audit_rider_wallets()` reconciliation will permanently flag a false discrepancy for every rider who has ever withdrawn funds; the "immutable ledger" doesn't record the events it's meant to reconcile.
- **Files Involved:** `supabase/migrations/20260530000001_rider_withdrawals.sql:165-168,229-232,291-293`, `supabase/migrations/20260611000002_prefixed_alphanumeric_codes.sql:338-341`
- **Fix Required:** New migration adding `INSERT INTO wallet_transactions` alongside each `wallet_balance` mutation in these three functions.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** Yes
- **Requires Migration?** Yes
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No (fix before payouts are audited/relied upon)
- **Estimated Fix Time:** 2 hours

### H5 — Passengers Can Forge `rider_assignments` Transitions
- **Severity:** High
- **Root Cause:** The passenger RLS policy grants table-level UPDATE/INSERT on `rider_assignments` for the passenger's own orders, gated only by order ownership — not by which columns change or what transition is valid.
- **Production Impact:** A malicious passenger can set `assignment_status='accepted'` for a rider who never responded, or tamper with `distance_km`/`estimated_earnings`, bypassing dispatch logic entirely.
- **Files Involved:** `supabase/migrations/20260601000014_rider_assignments_passenger_policy.sql`, `supabase/migrations/20260601000015_fix_orders_recursion.sql`
- **Fix Required:** Narrow the policy to specific columns/transitions, or move assignment mutation entirely behind a `SECURITY DEFINER` RPC.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** Yes
- **Requires Migration?** Yes
- **Requires RLS?** Yes
- **Must Fix Before Internal Testing?** No (low likelihood of accidental trigger by internal testers, but flag for fix soon)
- **Estimated Fix Time:** 1.5 hours

### H6 — No Optimistic Lock on Wallet-Crediting Status Update
- **Severity:** High
- **Root Cause:** `update-order-status`'s order write uses only `.eq("id", order_id)` with no `.eq("order_status", currentStatus)` guard, unlike `accept-order`, which correctly uses an optimistic lock. The wallet-credit block does a plain read-then-write with no row lock.
- **Production Impact:** Concurrent or retried "complete ride" calls for the same order could both pass the transition check and both execute the wallet credit, double-paying a rider. Client-side button-disable mitigates simple double-taps but not retries from other callers.
- **Files Involved:** `supabase/functions/update-order-status/index.ts:323-328, 590-714`
- **Fix Required:** Add `.eq("order_status", currentStatus)` to the order update (or use a `SELECT ... FOR UPDATE` Postgres function) so only one concurrent call can succeed.
- **Requires Flutter?** No
- **Requires Edge Function?** Yes
- **Requires SQL?** Possibly (if moved to a locking RPC)
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No (client-side gating reduces near-term risk, but should be fixed early)
- **Estimated Fix Time:** 2 hours

### H7 — Onboarding Screens Trap the User With No Exit
- **Severity:** High
- **Root Cause:** `profile_setup_screen.dart` and `permissions_screen.dart` use `PopScope(canPop: false)` with no `onPopInvokedWithResult` handler; the profile screen only shows a snackbar (never signs out or redirects) if the session is expired; the "Skip for now" button has no try/catch.
- **Production Impact:** A user with an expired session, or one who hits a network error on "Skip", is stuck on the onboarding screen with no back button and no way to proceed — forced to force-close the app.
- **Files Involved:** `lib/features/auth/screens/profile_setup_screen.dart:79-87,137-138`, `lib/features/auth/screens/permissions_screen.dart:51-52,170-176`
- **Fix Required:** Add a real `onPopInvokedWithResult` (or a "Sign out" affordance); redirect to Login when `user == null`; wrap `completeOnboarding()` in try/catch with visible error feedback.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes (onboarding is the very first flow every tester hits)
- **Estimated Fix Time:** 1.5 hours

### H8 — `permissions_screen.dart` setState After Dispose
- **Severity:** High
- **Root Cause:** `requestPermissions()` calls `setState()` after an `await` (which itself includes a navigation call) with no `mounted` guard.
- **Production Impact:** Crash risk right after the app's very first onboarding navigation, hit by every user.
- **Files Involved:** `lib/features/auth/screens/permissions_screen.dart:36-47`
- **Fix Required:** Add `if (!mounted) return;` before the `setState` call.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 10 minutes

### H9 — Inconsistent Mounted Guards in Rider OTP Sheet
- **Severity:** High
- **Root Cause:** `OtpSheetContent._resendOtp`/`_onVerifyPressed` call `setState()` after awaits with no mounted guard on the success/error paths, while the `finally` block two lines later is correctly guarded.
- **Production Impact:** Crash risk on the OTP bottom sheet used for every pickup/delivery/ride-start if the sheet is dismissed mid-request.
- **Files Involved:** `lib/features/rider/orders/screens/rider_active_order_screen.dart:3763, 3796`
- **Fix Required:** Add `mounted` guards consistently across all branches of both methods.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 20 minutes

### H10 — Rider KYC Screen setState After Dispose
- **Severity:** High
- **Root Cause:** State restoration continues through several `await`s after an initial `mounted` check and calls `setState({})` unguarded; `pickSelfieImage()` awaits the camera picker then sets state unguarded.
- **Production Impact:** Crash risk on the mandatory rider KYC screen, particularly around the camera round-trip where back-navigation during the await is realistic.
- **Files Involved:** `lib/features/rider/onboarding/screens/rider_kyc_screen.dart:140-210, 445-454`
- **Fix Required:** Add `mounted` guards before all `setState` calls following an `await`.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes (mandatory flow for every new rider tester)
- **Estimated Fix Time:** 30 minutes

### H11 — WebView `onPageFinished` Theme Access Without Mounted Guard
- **Severity:** High
- **Root Cause:** Four tracking screens share a copy-pasted `onPageFinished` callback that calls `Theme.of(context)` with no mounted check, inside an asynchronous webview callback that can fire after the screen is popped.
- **Production Impact:** Crash risk on the core order-tracking screens (hit on nearly every ride/parcel) if the user backs out while map tiles/JS are still loading.
- **Files Involved:** `lib/features/rider/orders/screens/rider_active_order_screen.dart:3485-3499`, `lib/features/local_rides/tracking/screens/ride_tracking_screen.dart:315-331`, `lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart:319-334`, `lib/features/intercity/shared/screens/intercity_tracking_screen.dart:344-359`
- **Fix Required:** Add `if (!mounted) return;` before accessing `Theme.of(context)` in all four files.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 30 minutes (4 files)

### H12 — Address-Picker Screen setState After Await Unguarded
- **Severity:** High
- **Root Cause:** `_initWebView`'s `onPageFinished`/`catch`, and `_recenterToCurrentLocation()`, call `setState()` after awaits with no mounted guard.
- **Production Impact:** Crash risk on the address-picker screen used on nearly every booking.
- **Files Involved:** `lib/features/user/home/home_location_screen.dart:174-183, 317`
- **Fix Required:** Add `mounted` guards before the affected `setState` calls.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 20 minutes

### H13 — Searching→Tracking Navigation Has No Re-Entry Guard
- **Severity:** High
- **Root Cause:** `openTracking()` has no re-entry guard and is invoked from a listener that fires on every realtime event or poll tick, not only on genuine status transitions. The intercity screen has two independent trigger paths that can both call it.
- **Production Impact:** Risk of a duplicate tracking screen push (double WebView/map init, double realtime subscription) or a visible double-transition.
- **Files Involved:** `lib/features/local_rides/searching/screens/ride_searching_screen.dart:171-270`, `lib/features/local_parcels/searching/screens/parcel_searching_screen.dart`, `lib/features/intercity/shared/screens/intercity_searching_screen.dart:251-255,909,1229-1239`
- **Fix Required:** Add a `bool _trackingOpened` guard checked and set before calling `Navigator.pushReplacement` in all three files.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes
- **Estimated Fix Time:** 1 hour (3 files)

### H14 — Unscoped Realtime Subscription Causes Platform-Wide Fan-Out
- **Severity:** High
- **Root Cause:** A second realtime subscription in the rider orders screen is missing `filterColumn`/`filterValue`, unlike every other subscription in the codebase, which is consistently scoped.
- **Production Impact:** Every online rider's device receives and reacts to every order-status change on the entire platform, causing N×M query amplification (N riders × M order updates) as order volume grows — a real scalability/battery/data-usage concern.
- **Files Involved:** `lib/features/rider/orders/rider_orders_screen.dart:452-470`
- **Fix Required:** Add `filterColumn: 'rider_id', filterValue: riderId!` to the subscription call.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Recommended (low tester count limits near-term impact, but trivial to fix now)
- **Estimated Fix Time:** 10 minutes

### H15 — `send-push-notification` Out-of-Scope Variable Breaks Error Handling
- **Severity:** High
- **Root Cause:** `notificationId` is declared inside the `try` block but referenced in the `catch` block, throwing a `ReferenceError` on any failure before the graceful JSON error response can execute.
- **Production Impact:** Any failure inside push-notification sending (malformed service account key, OAuth failure, DB error) escapes as an unhandled 500 instead of a diagnosable response, and the notification's `delivery_status` is never marked `'failed'` — silently breaking failure observability/retry.
- **Files Involved:** `supabase/functions/send-push-notification/index.ts:96, 307`
- **Fix Required:** Hoist `let notificationId: string | undefined;` above the `try` block.
- **Requires Flutter?** No
- **Requires Edge Function?** Yes
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Recommended
- **Estimated Fix Time:** 10 minutes

### H16 — Missing/Inconsistent Timeouts on Supabase Calls
- **Severity:** High
- **Root Cause:** Several critical paths (chat send, notification token registration/mark-as-read/order lookup, active-order check on home) have no `.timeout(...)` wrapper, unlike other screens that do guard consistently.
- **Production Impact:** On a degraded (not fully dropped) connection, these `await`s can hang indefinitely with no user feedback or fallback.
- **Files Involved:** `lib/modules/chat/screens/order_chat_screen.dart:1137-1141`, `lib/modules/notifications/services/notification_service.dart:258-332`, `lib/features/user/home/home_tab.dart:867-884`
- **Fix Required:** Wrap these calls in a consistent timeout (matching the pattern already used elsewhere in the codebase) with user-facing fallback/error handling.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No (functional today; degrades gracefully into "stuck loading" rather than crashing)
- **Estimated Fix Time:** 2 hours

### H17 — No Rider-Inactivity Detection on User's Tracking Screen
- **Severity:** High
- **Root Cause:** There is no staleness/heartbeat check for rider location updates; if the rider's app is killed/crashes mid-ride, the user's map silently stops updating with no explanation, and the cancel button is only rendered for `accepted`/`rider_arrived`, not `ongoing`.
- **Production Impact:** A user can be stuck indefinitely waiting on a frozen tracking screen with no way to cancel or recover if the rider goes dark mid-ride.
- **Files Involved:** `lib/features/local_rides/tracking/screens/ride_tracking_screen.dart`
- **Fix Required:** Add a last-update timestamp check with a visible "rider hasn't updated location" state and a support/cancel escape hatch, ideally paired with a server-side staleness signal.
- **Requires Flutter?** Yes
- **Requires Edge Function?** Possibly (for a server-driven staleness signal)
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No (edge case, but worth prioritizing early given real user impact)
- **Estimated Fix Time:** 4 hours

### H18 — Duplicate-Submission Risk on Swipe-to-Confirm Buttons
- **Severity:** High
- **Root Cause:** `SwipeToConfirmButton` resets its local completion lock after a fixed 600ms regardless of whether the in-flight network call has actually finished. Several transitions (`accepted→rider_arrived`, parcel `picked_up→rider_at_drop`) are not additionally gated by the parent's `loading` flag.
- **Production Impact:** On a slow network (>600ms round trip), a rider can swipe again before the first request resolves, firing a duplicate `update-order-status` call — compounded by H6's missing optimistic lock.
- **Files Involved:** `lib/features/rider/orders/screens/rider_active_order_screen.dart:3641-3656` and call sites
- **Fix Required:** Gate all `updateStatus` calls behind a single in-flight boolean, matching the pattern already correctly used in `RiderOrdersScreen.acceptOrder`/`IncomingOrderCard.acceptOrder`.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Recommended
- **Estimated Fix Time:** 1 hour

### H19 — No ProGuard Keep Rules for Bundled Native SDKs
- **Severity:** High
- **Root Cause:** `isMinifyEnabled = true` and `isShrinkResources = true` are set for release builds, but no `proguard-rules.pro` file exists, and no keep rules are wired in for the bundled local AARs (Ola Maps Navigation SDK, Ola Maps SDK, Places SDK) or the Cashfree payment SDK.
- **Production Impact:** This class of bug typically only manifests in the signed release build (maps fail to load, payment SDK throws `ClassNotFoundException`/`NoSuchMethodError`) — exactly the build used for Play Store upload — and is easy to miss since debug builds aren't minified.
- **Files Involved:** `android/app/build.gradle.kts:97-108` (no `android/app/proguard-rules.pro` exists)
- **Fix Required:** Add `proguard-rules.pro` with keep rules for the Ola Maps, Cashfree, and Places SDK packages; wire it into `buildTypes.release`; verify by running and exercising an actual signed release build before upload.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Yes (Internal Testing is typically distributed via a release/signed build)
- **Estimated Fix Time:** 3 hours (including a manual release-build verification pass)

### H20 — Crash Reporting Not Wired Up
- **Severity:** High
- **Root Cause:** Firebase is integrated (`google-services.json` present, Firebase BOM in Gradle), but Crashlytics is not added as a dependency; the error handlers in `main.dart` contain only commented-out placeholders.
- **Production Impact:** Not a Play Console blocker, but crashes hit by internal testers will be invisible beyond Play Console's own limited ANR/crash reports — no stack-trace-level visibility during the test period.
- **Files Involved:** `lib/main.dart:88-89, 108-109`
- **Fix Required:** Add `firebase_crashlytics` (low-effort given Firebase is already integrated) or Sentry, and wire up the existing error handlers.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** Recommended (strongly — without it, this whole audit's remaining unknowns are much harder to catch during testing)
- **Estimated Fix Time:** 2.5 hours

---

# Medium Priority Bugs

### M1 — Overflow Risk on Sender Name / Payment Label / City Rows
- **Severity:** Medium
- **Root Cause:** Several `Row`s carrying variable-length text (payment-type label, intercity city names) have no `Expanded`/`Flexible` wrapper, unlike most of the codebase which handles this defensively.
- **Production Impact:** Possible `RenderFlex` overflow on long payment labels or long city names, especially on small/low-end Android screens.
- **Files Involved:** `lib/modules/payments/screens/payment_processing_screen.dart:358-378`, `lib/features/intercity/shared/screens/intercity_searching_screen.dart:3779-3826`, `lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart:1126-1131`
- **Fix Required:** Wrap the affected `Text` widgets in `Flexible`/`FittedBox` with `overflow: TextOverflow.ellipsis`, matching the pattern already used in `incoming_order_card.dart`.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 45 minutes (3 files)

### M2 — `send-push-notification` Has No Auth Check
- **Severity:** Medium
- **Root Cause:** `user_id`, `title`, and `body` are taken directly from the request with no caller verification.
- **Production Impact:** Anyone can push arbitrary notification text to any guessable `user_id` (phishing/spam/harassment risk).
- **Files Involved:** `supabase/functions/send-push-notification/index.ts:94-103`
- **Fix Required:** Require service-role-only invocation, or authenticate and restrict `user_id` to the caller/admins.
- **Requires Flutter?** No
- **Requires Edge Function?** Yes
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 1 hour

### M3 — `match-intercity-riders` Leaks Customer PII With No Auth
- **Severity:** Medium
- **Root Cause:** No auth check; the function returns full name, phone, and exact pickup/destination addresses for `searching` orders to any caller supplying a synthetic `plan` object.
- **Production Impact:** PII exposure to unauthenticated callers.
- **Files Involved:** `supabase/functions/match-intercity-riders/index.ts:577-604, 801-811`
- **Fix Required:** Add auth and restrict results to the caller's own registered travel plan.
- **Requires Flutter?** No
- **Requires Edge Function?** Yes
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 1.5 hours

### M4 — `process-verification-photo` SSRF Risk
- **Severity:** Medium
- **Root Cause:** The function fetches a client-supplied `photo_url` server-side with no allow-list restricting it to the project's own storage bucket, compounded by no auth (see C5).
- **Production Impact:** An unauthenticated caller could make the edge function issue outbound requests to arbitrary URLs.
- **Files Involved:** `supabase/functions/process-verification-photo/index.ts:41-48`
- **Fix Required:** Validate that `photo_url` matches the expected storage bucket domain before fetching.
- **Requires Flutter?** No
- **Requires Edge Function?** Yes
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 45 minutes

### M5 — Internal Errors Leaked Verbatim to Clients
- **Severity:** Medium
- **Root Cause:** Several functions return raw error/database objects directly in the client-facing response.
- **Production Impact:** Potential leakage of table/column/constraint names or internal gateway response details.
- **Files Involved:** `supabase/functions/create-payment/index.ts:485-509,592-616`, `supabase/functions/accept-order/index.ts:267-278`, `supabase/functions/reject-order/index.ts:123-136`
- **Fix Required:** Log the detailed error server-side; return a generic, client-safe error message.
- **Requires Flutter?** No
- **Requires Edge Function?** Yes
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 1 hour

### M6 — Cross-Party Chat Message Editing/Deletion
- **Severity:** Medium
- **Root Cause:** The single FOR-ALL RLS policy on `order_chat_messages` governs SELECT/INSERT/UPDATE/DELETE with the same "is a participant" predicate, never restricting UPDATE/DELETE to `sender_id = auth.uid()`.
- **Production Impact:** A rider can delete/edit a customer's chat message (including system negotiation messages) and vice versa.
- **Files Involved:** `supabase/migrations/20260601000009_generic_chat_and_roles.sql:26-70`
- **Fix Required:** New migration splitting UPDATE/DELETE into a policy scoped to `sender_id = auth.uid()`.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** Yes
- **Requires Migration?** Yes
- **Requires RLS?** Yes
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 45 minutes

### M7 — `users.role` Escalation Surface Unverified
- **Severity:** Medium
- **Root Cause:** No migration in this set explicitly defines or restricts an UPDATE policy on `users.role`, which grants elevated chat visibility to `admin`/`support` roles.
- **Production Impact:** Whether ordinary users can write their own `role` column depends entirely on RLS defined outside this migration set — unverified, needs explicit confirmation.
- **Files Involved:** `supabase/migrations/20260601000009_generic_chat_and_roles.sql:9`
- **Fix Required:** Verify current UPDATE policy on `users`; if self-role-write is possible, add a trigger or column-level privilege revocation blocking it.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** Yes
- **Requires Migration?** Possibly
- **Requires RLS?** Yes
- **Must Fix Before Internal Testing?** No (verify first — may already be safe)
- **Estimated Fix Time:** 1 hour (verification) + 30 min (fix if needed)

### M8 — Promo Redemption Race Condition
- **Severity:** Medium
- **Root Cause:** `validate_and_calculate_promo()` checks `uses_count >= max_uses` without a row lock; the actual increment happens later in a separate trigger.
- **Production Impact:** Concurrent redemptions near the cap can all pass validation and all insert, letting `uses_count` exceed `max_uses`.
- **Files Involved:** `supabase/migrations/20260616000008_promos.sql:127-196`
- **Fix Required:** Add `FOR UPDATE` row locking on the `promo_codes` row during validation, or combine validation and increment into a single atomic function.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** Yes
- **Requires Migration?** Yes
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 1.5 hours

### M9 — `intercity_requests` Direct Write Bypasses Atomic RPCs
- **Severity:** Medium
- **Root Cause:** The table's only RLS policy lets sender/traveller freely UPDATE `status`, `proposed_fare`, `sender_confirmed`, `traveller_confirmed` directly, even though the safe state machine (locking, capacity checks) only lives in the dedicated RPCs.
- **Production Impact:** A client writing directly to the table (by accident or intent) can set `status='confirmed'` without ever going through capacity/weight validation.
- **Files Involved:** `supabase/migrations/20260603000001_create_intercity_requests.sql:39-54`
- **Fix Required:** Narrow the policy to the specific columns/transitions that are safe for direct client writes; route state changes through the RPCs.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** Yes
- **Requires Migration?** Yes
- **Requires RLS?** Yes
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 1.5 hours

### M10 — Travel-Plan Weight Capacity Not Enforced
- **Severity:** Medium
- **Root Cause:** `confirm_intercity_booking` snapshots `max_weight_kg` and `actual_weight_kg` into metadata but never compares them — only booking count is enforced.
- **Production Impact:** A rider's parcel capacity can be overbooked by weight even though a display-only capacity view exists.
- **Files Involved:** `supabase/migrations/20260617000001_intercity_workflow_updates.sql:226-317`
- **Fix Required:** Add a weight-capacity check alongside the existing booking-count check before confirming.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** Yes
- **Requires Migration?** Yes
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 1 hour

### M11 — Hardcoded Credentials in Migration SQL
- **Severity:** Medium
- **Root Cause:** A Supabase anon JWT and functions URL are inlined directly in two migration files rather than sourced from config/Vault.
- **Production Impact:** The bearer token/URL pair is permanently in git history and can't be rotated without editing and re-deploying SQL.
- **Files Involved:** `supabase/migrations/20260602000002_create_notification_triggers.sql:23`, `supabase/migrations/20260617000000_add_order_notification_mode.sql:61`
- **Fix Required:** New migration replacing the hardcoded values with `current_setting(...)` reads from Supabase Vault/config.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** Yes
- **Requires Migration?** Yes
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 1 hour

### M12 — `SECURITY DEFINER` Functions Missing `SET search_path`
- **Severity:** Medium
- **Root Cause:** Roughly 20 `SECURITY DEFINER` functions omit `SET search_path = public`, a known Postgres privilege-escalation hardening gap (though current exploitability is low since all table references are schema-qualified).
- **Production Impact:** One bad future edit away from being exploitable; also a standard Supabase security-linter flag.
- **Files Involved:** Multiple migrations (e.g. `check_payout_update_limit`, `initiate_withdrawal`, `assign_nearby_searching_orders_to_rider`, `send_push_notification_fnc`, `accept_intercity_request`, and ~15 others)
- **Fix Required:** Single hardening migration adding `SET search_path = public` to all affected functions.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** Yes
- **Requires Migration?** Yes
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 2 hours

### M13 — Order Chat Screen Missing Mounted Guards
- **Severity:** Medium
- **Root Cause:** Several methods (`_acceptOffer`, `_confirmBooking`, `_payBooking`, `_confirmHandover`, `_handleCallAction`) call `ScaffoldMessenger.of(context)` after awaits with no `mounted` guard, inconsistent with the file's own correct guarding elsewhere.
- **Production Impact:** Crash risk in the chat screen (opened for every active order) if the user backs out during a slow network call.
- **Files Involved:** `lib/modules/chat/screens/order_chat_screen.dart:577,591,617,654,1292`
- **Fix Required:** Add `mounted` guards consistently across all five methods.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 30 minutes

### M14 — Rider Intercity Bookings Screen Missing Mounted Guards
- **Severity:** Medium
- **Root Cause:** Five methods (`_deleteTravelPlan`, `_completeParcel`, `_markRideArrived`, `_verifyOtp`, `_resendOtp`) call `ScaffoldMessenger.of(context)` after awaits with no `mounted` guard.
- **Production Impact:** Crash risk for riders using the intercity feature.
- **Files Involved:** `lib/features/rider/intercity/intercity_bookings_screen.dart:139-243`
- **Fix Required:** Add `mounted` guards consistently across all five methods.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 30 minutes

### M15 — Travel Plan Location Autocomplete Missing All Mounted Checks
- **Severity:** Medium
- **Root Cause:** Debounced location-autocomplete timer callbacks have no `mounted` checks at all, a regression compared to sibling location screens that are correctly guarded.
- **Production Impact:** A 400ms-debounced geocode call is a realistic window for the user to navigate away, risking a crash.
- **Files Involved:** `lib/features/rider/travel_plans/screens/post_travel_plan_screen.dart:807-849, 887-929`
- **Fix Required:** Add `mounted` checks matching the pattern already used in `ride_location_screen.dart`/`parcel_location_screen.dart`/`intercity_location_screen.dart`.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 30 minutes

### M16 — `rider_profile_tab.dart` `switchToUser` Missing Mounted Guard
- **Severity:** Medium
- **Root Cause:** `switchToUser` calls `ScaffoldMessenger.of(context)` after an await with no `mounted` guard, inconsistent with the adjacent, correctly-guarded logout method in the same file.
- **Production Impact:** Crash risk when a rider switches to user mode under a slow network.
- **Files Involved:** `lib/features/rider/profile/rider_profile_tab.dart:260-289`
- **Fix Required:** Add `mounted` guard matching the adjacent logout method.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 15 minutes

### M17 — `NotServiceableScreen` Zero Mounted Check
- **Severity:** Medium
- **Root Cause:** A stateless `ConsumerWidget` button handler calls `Navigator.pushAndRemoveUntil` and `ScaffoldMessenger.of(context)` after an await with zero `context.mounted` check.
- **Production Impact:** Crash risk, though this is a rarely-visited screen (only shown when location isn't serviceable).
- **Files Involved:** `lib/shared/screens/not_serviceable_screen.dart:277-291`
- **Fix Required:** Add `context.mounted` checks before both post-await calls.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 15 minutes

### M18 — Boost Retry Bypasses Transition Validator
- **Severity:** Medium
- **Root Cause:** The search "boost" retry writes `order_status: 'searching'` directly via a raw table update rather than routing through `update-order-status`'s transition/cleanup logic.
- **Production Impact:** Functionally works today but duplicates business logic that already exists server-side and could drift out of sync over time.
- **Files Involved:** `lib/features/local_rides/searching/screens/ride_searching_screen.dart:930-988`
- **Fix Required:** Route the retry through the `update-order-status` function instead of a raw table write.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 45 minutes

### M19 — Rider Cancel Option Restricted to `accepted` Status
- **Severity:** Medium
- **Root Cause:** The UI only exposes the rider-initiated cancel option while `order_status == 'accepted'`, even though the backend transition table also permits `rider_arrived → cancelled`.
- **Production Impact:** Minor UX/business-logic mismatch — a rider cannot back out once they've marked arrival, even though the backend would allow it.
- **Files Involved:** `lib/features/rider/orders/screens/rider_active_order_screen.dart:1534`
- **Fix Required:** Extend the cancel-button visibility condition to include `rider_arrived`, if that's the intended business behavior.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 20 minutes

### M20 — Rider-Side `rider_assignments` RLS Unverified
- **Severity:** Medium
- **Root Cause:** Client-side assignment-expiry writes are issued directly from the rider's authenticated session; it could not be confirmed within the audit whether riders actually hold UPDATE rights on their own assignment rows (functionally masked today by a separate client-side filter).
- **Production Impact:** If the RLS grant is missing, these writes silently no-op (no error is thrown), which is currently masked but should be explicitly confirmed.
- **Files Involved:** `lib/features/rider/orders/rider_orders_screen.dart:294-321`, `lib/features/rider/orders/widgets/incoming_order_card.dart:97-129`
- **Fix Required:** Verify the current RLS policy for `rider_assignments` UPDATE by riders; add an explicit policy if missing.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** Possibly
- **Requires Migration?** Possibly
- **Requires RLS?** Yes
- **Must Fix Before Internal Testing?** No (verify first)
- **Estimated Fix Time:** 45 minutes (verification)

### M21 — Duplicate Polling Layered on Top of Realtime
- **Severity:** Medium
- **Root Cause:** Several screens run periodic timers (10s/30s/5s) that re-fetch data already covered by an active realtime subscription on the same screen.
- **Production Impact:** Redundant database queries and unnecessary battery/network usage, compounding H14's fan-out issue.
- **Files Involved:** `lib/features/rider/orders/rider_orders_screen.dart:220-228`, `lib/features/user/home/home_tab.dart:174-182,999-1005`, `lib/features/user/activity/activity_tab.dart`, `lib/features/rider/activity/rider_activity_tab.dart`
- **Fix Required:** Remove or significantly lengthen the polling intervals now that realtime coverage exists; keep only as an infrequent safety-net.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 1.5 hours

### M22 — `RealtimeManager` Doesn't Validate Channel Name Collisions
- **Severity:** Medium
- **Root Cause:** If a second caller passes an existing channel name with a different table/filter configuration, the manager silently appends the new listener to the first caller's subscription rather than erroring.
- **Production Impact:** Currently dormant (all call sites use unique, ID-suffixed names), but a latent footgun with no compile-time or runtime guard.
- **Files Involved:** `lib/core/services/realtime/realtime_manager.dart:90-102`
- **Fix Required:** Add a runtime assertion/error when a channel name is reused with mismatched configuration.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 45 minutes

### M23 — Expensive List Filtering Recomputed on Every Build
- **Severity:** Medium
- **Root Cause:** Several `.where().toList()` filtering passes over up to 150 activity items run directly inside `build()` rather than being cached from the initial load.
- **Production Impact:** Wasted CPU on every rebuild (tab switches, theme changes, debounced realtime refresh); modest impact today given list size, but a textbook anti-pattern.
- **Files Involved:** `lib/features/user/activity/activity_tab.dart:179-200` (rider activity tab is structurally similar)
- **Fix Required:** Cache the filtered lists in state when data loads/updates, rather than recomputing inside `build()`.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 1 hour

### M24 — Killed-App Notification Tap Can Race Cold-Start Flow
- **Severity:** Medium
- **Root Cause:** `getInitialMessage()` waits only 1000ms before handling a notification tap, while the app's cold-start auth/profile resolution can take up to 8 seconds; the order-detail lookup triggered by the tap also has no timeout (H16).
- **Production Impact:** Not a crash, but if the network is also degraded during this window, the user can be left on the splash screen indefinitely with no visible deep-link outcome.
- **Files Involved:** `lib/modules/notifications/services/notification_service.dart:178-185,328-332`, `lib/app_start_screen.dart:79-85`
- **Fix Required:** Add a timeout to the order-detail lookup in `handleNotificationTap`, and/or defer the tap handling until the app's cold-start flow has resolved.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 1 hour

### M25 — Stale Dead-Code `MainActivity.kt`
- **Severity:** Medium
- **Root Cause:** A leftover `MainActivity.kt` under the old `com.example.waydrop` package still exists alongside the real, correctly-referenced `MainActivity` under `com.waydrop.app`.
- **Production Impact:** No functional/build impact (unreachable, unused class), but dead code that risks confusion about which `MainActivity` is authoritative.
- **Files Involved:** `android/app/src/main/kotlin/com/example/waydrop/MainActivity.kt`
- **Fix Required:** Delete the stale file.
- **Requires Flutter?** No
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 5 minutes

### M26 — Edge-to-Edge Enforcement Not Visually Verified
- **Severity:** Medium
- **Root Cause:** `targetSdk 35` (Android 15) enforces edge-to-edge display by default; Flutter generally handles inset management automatically, but this cannot be confirmed by static file reading alone.
- **Production Impact:** A common source of Play Console pre-launch-report warnings if any content is obscured by system bars.
- **Files Involved:** `android/app/build.gradle.kts:80-81`
- **Fix Required:** Manual visual QA pass on an Android 15 device/emulator across all main screens.
- **Requires Flutter?** Possibly (if issues are found)
- **Requires Edge Function?** No
- **Requires SQL?** No
- **Requires Migration?** No
- **Requires RLS?** No
- **Must Fix Before Internal Testing?** No (verify during testing)
- **Estimated Fix Time:** 1 hour (manual QA)

---

# Low Priority Bugs

### L1 — Package Photos Header Row Overflow Risk
- **Severity:** Low
- **Root Cause:** A static header string plus a photo-count label sit in a `spaceBetween` row with no `Flexible`; borderline overflow only on the smallest devices.
- **Production Impact:** Cosmetic overflow risk on very small screens only.
- **Files Involved:** `lib/features/intercity/parcels/booking/intercity_details_screen.dart:1330-1346`
- **Fix Required:** Wrap in `Flexible`/`FittedBox`.
- **Requires Flutter?** Yes
- **Requires Edge Function?** No / **Requires SQL?** No / **Requires Migration?** No / **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 10 minutes

### L2 — Wildcard CORS on All Edge Functions
- **Severity:** Low
- **Root Cause:** Every edge function returns `Access-Control-Allow-Origin: *`.
- **Production Impact:** Standard for a mobile-only backend; combined with the unauthenticated endpoints (C5), those are reachable from any web origin too.
- **Files Involved:** All `supabase/functions/*`
- **Fix Required:** Restrict allowed origins if browser access should be limited.
- **Requires Flutter?** No / **Requires Edge Function?** Yes / **Requires SQL?** No / **Requires Migration?** No / **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 30 minutes

### L3 — Non-Constant-Time OTP Comparison
- **Severity:** Low
- **Root Cause:** OTP values are compared with plain `!==` rather than a constant-time comparison.
- **Production Impact:** Low practical risk since rate-limiting (`check_otp_lockout`/`log_otp_attempt`) already exists.
- **Files Involved:** `supabase/functions/update-order-status/index.ts:150,209,254`
- **Fix Required:** Use a constant-time string comparison utility.
- **Requires Flutter?** No / **Requires Edge Function?** Yes / **Requires SQL?** No / **Requires Migration?** No / **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 20 minutes

### L4 — Loose Amount Validation in `create-payment`
- **Severity:** Low
- **Root Cause:** `!amount || amount <= 0` doesn't explicitly reject non-numeric strings; relies on Cashfree to reject malformed input.
- **Production Impact:** Minor; Cashfree acts as a backstop.
- **Files Involved:** `supabase/functions/create-payment/index.ts:210-214`
- **Fix Required:** Add explicit numeric-type validation.
- **Requires Flutter?** No / **Requires Edge Function?** Yes / **Requires SQL?** No / **Requires Migration?** No / **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 15 minutes

### L5 — Missing CHECK Constraint on `proposed_fare`
- **Severity:** Low
- **Root Cause:** `intercity_requests.proposed_fare` has no `CHECK (proposed_fare > 0)`.
- **Production Impact:** A zero/negative fare could theoretically flow through into `orders.final_fare`.
- **Files Involved:** `supabase/migrations/20260603000001_create_intercity_requests.sql:25`
- **Fix Required:** New migration adding the CHECK constraint.
- **Requires Flutter?** No / **Requires Edge Function?** No / **Requires SQL?** Yes / **Requires Migration?** Yes / **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 15 minutes

### L6 — OTP Codes Stored in Plaintext With No Purge Policy
- **Severity:** Low
- **Root Cause:** `otp_attempts.otp_code` has no retention/TTL purge job. Access is already correctly locked down at the RLS/function layer.
- **Production Impact:** Low risk today given access controls, but worth a retention policy for OTP material.
- **Files Involved:** `supabase/migrations/20260616000007_otp_limits_rls.sql:2-10`
- **Fix Required:** Add a scheduled purge job or TTL policy.
- **Requires Flutter?** No / **Requires Edge Function?** No / **Requires SQL?** Yes / **Requires Migration?** Yes / **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 1 hour

### L7 — Connectivity Detection Uses DNS Polling
- **Severity:** Low
- **Root Cause:** Connectivity is checked via `InternetAddress.lookup()` polling every 8 seconds rather than an event-driven OS connectivity API.
- **Production Impact:** Works correctly and is reasonably robust, but less battery-efficient and adds up to 8s detection lag.
- **Files Involved:** `lib/shared/helpers/connectivity_wrapper.dart:32,60-64`
- **Fix Required:** Consider adopting `connectivity_plus` for event-driven detection.
- **Requires Flutter?** Yes / **Requires Edge Function?** No / **Requires SQL?** No / **Requires Migration?** No / **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 1.5 hours

### L8 — Inline TextEditingControllers Never Disposed
- **Severity:** Low
- **Root Cause:** Several dialog/bottom-sheet builders create `TextEditingController`s that are never explicitly disposed. No active listeners are attached, so this does not cause a crash — the controller is simply unreachable and GC'd.
- **Production Impact:** Minor; triggers lint warnings, no runtime defect.
- **Files Involved:** `lib/features/user/profile/profile_tab.dart:158`, `lib/features/rider/earnings/rider_earnings_tab.dart:804`, `lib/features/rider/intercity/intercity_bookings_screen.dart:252`, `lib/modules/chat/screens/order_chat_screen.dart:379`, and three searching screens
- **Fix Required:** Convert to `StatefulWidget`s with proper `dispose()`, or explicitly dispose after the dialog closes.
- **Requires Flutter?** Yes / **Requires Edge Function?** No / **Requires SQL?** No / **Requires Migration?** No / **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 1 hour (batch fix across files)

### L9 — Double-Tap Risk on "Enter OTP" Shortcut
- **Severity:** Low
- **Root Cause:** The "Enter OTP" shortcut button calls `Navigator.push` directly with no debounce guard, unlike the adjacent `sendOtp()` flow.
- **Production Impact:** A fast double-tap can push `OtpScreen` twice; both instances are functionally identical, so impact is low.
- **Files Involved:** `lib/features/auth/screens/login_screen.dart:464-473`
- **Fix Required:** Disable the button while a push is pending, or route through the already-guarded `sendOtp()`.
- **Requires Flutter?** Yes / **Requires Edge Function?** No / **Requires SQL?** No / **Requires Migration?** No / **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 15 minutes

### L10 — Duplicate Exit-Confirmation Sheets on Ride Tracking
- **Severity:** Low
- **Root Cause:** The visible back-arrow button and the `PopScope` handler both independently call `_showExitConfirmation` with no in-flight guard.
- **Production Impact:** A rapid double-tap can stack two confirmation bottom sheets; both resolve to the same action, so no functional/data-loss impact.
- **Files Involved:** `lib/features/local_rides/tracking/screens/ride_tracking_screen.dart:704-712,731-739`
- **Fix Required:** Add an in-flight guard shared by both call sites.
- **Requires Flutter?** Yes / **Requires Edge Function?** No / **Requires SQL?** No / **Requires Migration?** No / **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 15 minutes

### L11 — Expired JWT Misclassified as Connection Error
- **Severity:** Low
- **Root Cause:** The cold-start error handler only specifically checks for `SocketException`/`Failed host lookup`; any other exception (including an expired/invalid JWT) falls into a generic "connection" error with a Retry button that will simply fail again.
- **Production Impact:** Misleading messaging; not a hang or crash since a Retry option is still offered, and Supabase's own token refresh should eventually resolve it.
- **Files Involved:** `lib/app_start_screen.dart:227-241`
- **Fix Required:** Detect auth-related exceptions specifically and route to `LoginScreen` instead of the generic connection-error screen.
- **Requires Flutter?** Yes / **Requires Edge Function?** No / **Requires SQL?** No / **Requires Migration?** No / **Requires RLS?** No
- **Must Fix Before Internal Testing?** No
- **Estimated Fix Time:** 30 minutes

---

# Recommended Fix Order

A safe, dependency-aware sequence — each phase should be fully verified before moving to the next.

### ✅ Phase 1 — Critical Security
- [ ] C1 — Remove hardcoded OTP-bypass backdoor
- [ ] C5 — Add JWT/ownership verification to `accept-order`, `reject-order`, `update-order-status`, `create-order`, `process-verification-photo`, `start-dispatch`
- [ ] C6 — Add JWT verification to `regenerate-otp`; stop leaking OTP in response
- [ ] C7 — Fix `trip_share_tokens` RLS policy
- [ ] C8 — Revoke public execute on push-notification RPCs
- [ ] C9 — Lock down compliance/SOS table RLS
- [ ] C12 — Rotate leaked API key, scrub `.env` from git history
- [ ] H2 — Undeploy or gate `load-testing` function

### ✅ Phase 2 — Payments
- [ ] C2 — Fix unfiltered UPDATE in `verify-payment`
- [ ] C3 — Stop marking non-cash orders "paid" without verification
- [ ] C4 — Validate `create-payment` amount server-side against order total
- [ ] H1 — Validate fare/distance server-side
- [ ] H4 — Populate wallet ledger on withdrawal state changes
- [ ] H6 — Add optimistic lock to wallet-crediting status update

### ✅ Phase 3 — Order Lifecycle
- [ ] C10 — Build `cancel-order` Edge Function; fix 6 Flutter call sites
- [ ] H3 — Restore self-matching prevention and weight/vehicle matching in dispatch trigger
- [ ] H5 — Tighten `rider_assignments` passenger RLS policy
- [ ] H17 — Add rider-inactivity detection to user tracking screen
- [ ] H18 — Fix swipe-button duplicate-submission risk
- [ ] M8, M9, M10 — Promo race, intercity direct-write bypass, weight-capacity enforcement

### ✅ Phase 4 — Flutter Stability (Crashes)
- [ ] C11 — Fix setState-after-dispose on ride/parcel completion
- [ ] H7, H8 — Fix onboarding trap and setState crash
- [ ] H9, H10, H11, H12 — Fix remaining mounted-guard gaps in OTP sheet, KYC screen, WebView callbacks, address picker
- [ ] H13 — Add re-entry guard to searching→tracking navigation
- [ ] M13–M17 — Remaining mounted-guard inconsistencies across chat, rider intercity, travel plans, profile, not-serviceable screens

### ✅ Phase 5 — Realtime & Performance
- [ ] H14 — Scope the unfiltered rider-orders realtime subscription
- [ ] H15 — Fix `send-push-notification` scope bug
- [ ] H16 — Add timeouts to unguarded Supabase calls
- [ ] M21, M22, M23 — Remove redundant polling, guard channel-name collisions, cache activity-list filtering

### ✅ Phase 6 — UI & Play Store Polish
- [ ] M1, L1 — Fix remaining overflow risks
- [ ] H19 — Add ProGuard keep rules; verify signed release build
- [ ] H20 — Wire up crash reporting
- [ ] M25, M26 — Remove dead code; verify edge-to-edge visually
- [ ] Remaining Medium/Low items — address opportunistically during/after the test period

---

# Google Play Checklist

**Authentication**
- [ ] Remove hardcoded auth bypass (C1)
- [ ] Verify login/logout/session-restore handle expired tokens gracefully (H7, L11)
- [ ] Confirm onboarding has a working exit path on failure (H7)

**Payments**
- [ ] Fix unfiltered payment-status update (C2)
- [ ] Verify amounts server-side before creating Cashfree orders (C4)
- [ ] Confirm non-cash orders aren't marked "paid" without verification (C3)
- [ ] Confirm `CASHFREE_ENV` and any sandbox/production key usage is correct for the test track

**Notifications**
- [ ] FCM foreground/background/killed-app handling verified (confirmed present and correctly wired)
- [ ] Fix push-notification RPC authorization (C8, M2, M3)
- [ ] Fix `send-push-notification` scope bug (H15)

**Permissions**
- [ ] Confirm all dangerous permissions (location, background location, notifications) are declared and justified (confirmed present and correctly scoped)
- [ ] Confirm foreground service type/permission pairing for location (confirmed correct)

**Privacy**
- [ ] Rotate and remove leaked API key from git history (C12)
- [ ] Lock down compliance/SOS/PII-exposing tables and functions (C9, M3)
- [ ] Confirm a privacy policy is linked in the Play Console listing (outside this codebase's scope — confirm separately)

**Crash Risks**
- [ ] Fix C11 (completion-flow crash) and all High-severity mounted-guard gaps (H8–H12)
- [ ] Wire up Crashlytics/Sentry before opening the test track (H20)

**Release Build**
- [ ] Add ProGuard keep rules for Ola Maps/Cashfree/Places SDKs and verify a real signed release build (H19)
- [ ] Confirm release keystore/`key.properties` are present on the build machine (operational — not a code defect)
- [ ] Confirm signing config is a real release config, not falling back to debug signing (confirmed correct)

**Android 15**
- [ ] Verify edge-to-edge rendering visually on an Android 15 device/emulator (M26)
- [ ] Confirm `targetSdk`/`compileSdk` meet current Play Store requirements (confirmed: `targetSdk 35`, `compileSdk 36`)
- [ ] Confirm predictive back gesture support (confirmed: `enableOnBackInvokedCallback` present)

**Edge Functions**
- [ ] Add auth/ownership checks to all order-lifecycle functions (C5, C6)
- [ ] Remove or gate `load-testing` in production (H2)
- [ ] Stop leaking internal errors to clients (M5)

**Supabase**
- [ ] Fix `trip_share_tokens` RLS leak (C7)
- [ ] Revoke public execute on notification RPCs (C8)
- [ ] Lock down compliance table RLS (C9)
- [ ] Harden remaining `SECURITY DEFINER` functions with `SET search_path` (M12)

---

# Internal Testing Checklist

Flows that must be manually exercised end-to-end before/while opening the test track:

- [ ] User Login (valid OTP)
- [ ] User Login (invalid OTP, rate-limited, network failure)
- [ ] OTP resend / expiry handling
- [ ] Profile setup / onboarding (including simulated session expiry)
- [ ] Permission grants (location, notifications) and "Skip" path
- [ ] Ride Booking (local)
- [ ] Ride Booking (intercity)
- [ ] Ride Searching → timeout / no riders available
- [ ] Ride Acceptance (rider side)
- [ ] Ride Tracking (user side), including rider going offline/app-killed mid-ride
- [ ] Ride Start / OTP verification at pickup
- [ ] Ride Completion (cash and online payment)
- [ ] Ride Cancellation (by user, before and after acceptance)
- [ ] Ride Cancellation (by rider, after acceptance)
- [ ] Parcel Booking (local)
- [ ] Parcel Booking (intercity)
- [ ] Parcel Acceptance / Tracking / Completion
- [ ] Parcel Cancellation
- [ ] Intercity travel-plan posting and matching
- [ ] Wallet balance update after ride/parcel completion
- [ ] Wallet withdrawal request and status tracking
- [ ] Ride/Order History (rider and user)
- [ ] In-app Chat (order negotiation, handover confirmation)
- [ ] Push Notifications — foreground
- [ ] Push Notifications — background
- [ ] Push Notifications — app killed, tap to deep-link
- [ ] Realtime order updates (status changes reflected live on both sides)
- [ ] Offline handling — disconnect mid-booking
- [ ] Offline handling — disconnect mid-chat (queued send + resync)
- [ ] Reconnect — realtime channels resubscribe correctly after connectivity returns
- [ ] App Kill — mid-ride, mid-payment, mid-chat, then relaunch
- [ ] Rider Go Online / Go Offline toggle
- [ ] Rider KYC submission flow
- [ ] Small-screen device pass (layout/overflow check)
- [ ] Android 15 device pass (edge-to-edge, predictive back)
- [ ] Signed release build smoke test (maps load, payment SDK initializes — verifies ProGuard rules)

---

# Final Recommendation

### 1. Is the app safe for Internal Testing?

**Not yet.** The application's overall architecture is solid — realtime reconnect logic, offline chat queueing, the `accept-order` locking pattern, most of the Android release configuration, and the general UI layout discipline are all well above average for a project at this stage. However, a concentrated cluster of **12 Critical bugs** — several of which are live, exploitable security and financial-integrity defects reachable by any installed tester, not just theoretical edge cases — make the app unsafe to distribute in its current state, even to a small trusted internal group. Because this app is wired to a live production Supabase project and a live Cashfree production environment (`CASHFREE_ENV=production`), any tester (or anyone who gets hold of the test build) could currently corrupt real order data, bypass authentication entirely, or manipulate real payments.

### 2. Which bugs absolutely must be fixed before Internal Testing?

All 12 Critical bugs (C1–C12), plus these High-severity items that are effectively launch-blocking for a released build:
- **H2** — `load-testing` function must be undeployed/gated before any real testers are active on the platform (it can delete real in-flight assignments).
- **H7, H8, H9, H10, H11, H12, H13** — the crash-risk and stuck-onboarding bugs that will be hit by essentially every tester in the very first minutes of using the app.
- **H19** — ProGuard keep rules, since Internal Testing is distributed as a signed release build and these classes of crashes are invisible in debug testing.

### 3. Which bugs can safely wait until after Internal Testing?

The remaining High-severity items (H1, H3–H6, H14–H18, H20), all Medium-severity items, and all Low-severity items can be addressed iteratively during or shortly after the Internal Testing period. None of them expose testers to data corruption, financial exploitation, or app-breaking crashes in the same immediate way the Critical list does — they represent scalability concerns, UX rough edges, defense-in-depth gaps, and code-quality debt that are appropriate to fix on a normal sprint cadence while real usage data comes in from the test track.

### 4. Recommended release plan

1. **Day 1–2:** Execute Phase 1 (Critical Security) and Phase 2 (Payments) from the Recommended Fix Order above. These are the items with direct exploit potential against live production data and money.
2. **Day 2–3:** Execute Phase 3 (Order Lifecycle) and Phase 4 (Flutter Stability), focusing first on the crash-risk and stuck-flow bugs that every tester will encounter immediately.
3. **Day 3:** Add ProGuard keep rules and produce a real signed release build; manually smoke-test maps, payments, and Android 15 edge-to-edge rendering on that exact build (not a debug build).
4. **Day 4:** Wire up Crashlytics/Sentry so that any remaining unknown issues surfaced during Internal Testing are actually visible to the team.
5. **Day 4–5:** Walk the full Internal Testing Checklist above manually against the signed release build.
6. **Open the Internal Testing track** once Phases 1–4 are verified fixed and the checklist passes.
7. **During the test period:** work through Phase 5 (Realtime & Performance) and Phase 6 (UI & Play Store Polish), plus the remaining Medium/Low backlog, in parallel with tester feedback — none of these block the track from opening, but all should land before any broader (Closed/Open Testing or Production) rollout.

---

*This report is a static, read-only audit. No code, configuration, or infrastructure was modified as part of producing it.*
