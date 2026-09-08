# WayDrop Technical Documentation — Row Level Security (RLS) Specifications

**Version:** 1.0  
**Last Updated:** July 5, 2026  
**Maintainer:** Security Lead  
**Applies To Commit:** 241d836  

---

## 1. RLS Model & Security Contexts

PostgreSQL Row Level Security (RLS) is enabled on all tables in WayDrop's `public` schema. When a client performs SQL queries via PostgREST (the Supabase REST interface), the transaction is checked against the client's JSON Web Token (JWT) credentials.

### Target Security Roles
- **`authenticated`:** Users logged in via phone verification. `auth.uid()` resolves to their unique User UUID.
- **`anon`:** Unauthenticated public requests (e.g. initial OTP code generation and reading basic pricing zone metadata).
- **`public` (implicit postgres role):** Standard baseline rules.
- **`service_role` (Bypass role):** Instantiated only in server-side Edge Functions. Bypasses all RLS checks to perform operations that users cannot directly edit (e.g., verifying payments or writing audit records).

---

## 2. Complete Row-Level Security Policy Index

Below is the complete database catalog of RLS policies, including the exact SQL queries used for `USING` (qualifier check) and `WITH CHECK` (insert/update write check) validations:

### 2.1. Table: `public.users`

#### Policy 1: `Users can view own profile`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(auth.uid() = id)`
- **Purpose:** Restricts profile reads (full name, phone, email) so users can only access their own data.

#### Policy 2: `Users can update own profile`
- **Allowed Command:** `UPDATE`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(auth.uid() = id)`
- **Purpose:** Restricts profile updates so users can only modify their own profile data.

#### Policy 3: `Users can insert own profile`
- **Allowed Command:** `INSERT`
- **Target Role:** `authenticated`
- **SQL WITH CHECK:** `(auth.uid() = id)`
- **Purpose:** Allows users to insert their initial user row during profile setup.

---

### 2.2. Table: `public.riders`

#### Policy 1: `Users can view own rider profile`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **Purpose:** Allows passengers to view their own profile details.

#### Policy 2: `Riders can view own rider profile`
- **Allowed Command:** `SELECT`
- **Target Role:** `public`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **Purpose:** Allows riders to read their own profile details.

#### Policy 3: `Allow authenticated users to view online riders`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `((account_status = 'online'::rider_account_status_enum) OR (auth.uid() = user_id))`
- **Purpose:** Allows passengers to view active riders on the map, and allows riders to see themselves.

#### Policy 4: `Riders can update own rider profile`
- **Allowed Command:** `UPDATE`
- **Target Role:** `public`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **Purpose:** Allows riders to toggle online/offline status or update current coordinates.

#### Policy 5: `Allow riders to update their own profile`
- **Allowed Command:** `UPDATE`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **SQL WITH CHECK:** `(auth.uid() = user_id)`
- **Purpose:** Secures coordinates and status updates on client-side requests.

---

### 2.3. Table: `public.rider_kyc`

#### Policy 1: `Riders can view own KYC`
- **Allowed Command:** `SELECT`
- **Target Role:** `public`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **Purpose:** Allows riders to check their own KYC status.

#### Policy 2: `Users can view own kyc`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **Purpose:** Restricts KYC status checks to the account owner.

#### Policy 3: `Users can create own kyc`
- **Allowed Command:** `INSERT`
- **Target Role:** `authenticated`
- **SQL WITH CHECK:** `(auth.uid() = user_id)`
- **Purpose:** Allows users to submit their initial KYC form.

#### Policy 4: `Users can update own kyc`
- **Allowed Command:** `UPDATE`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **Purpose:** Allows riders to correct or resubmit documents after rejection.

#### Policy 5: `Riders can insert own KYC`
- **Allowed Command:** `INSERT`
- **Target Role:** `public`
- **SQL WITH CHECK:** `(auth.uid() = user_id)`
- **Purpose:** General insert check.

#### Policy 6: `Allow view own KYC or online rider KYC`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `((auth.uid() = user_id) OR (EXISTS (SELECT 1 FROM riders r WHERE ((r.user_id = rider_kyc.user_id) AND (r.account_status = 'online'::rider_account_status_enum)))))`
- **Purpose:** Restricts access to sensitive document URLs (Aadhaar, PAN, License) of pending riders while permitting lookup checks for active riders.

---

### 2.4. Table: `public.orders`

#### Policy 1: `user_can_view_own_orders`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **Purpose:** Allows passengers to view their booking history.

#### Policy 2: `rider_can_view_assigned_orders`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(rider_id IN (SELECT riders.id FROM riders WHERE (riders.user_id = auth.uid())))`
- **Purpose:** Allows riders to view bookings assigned to them.

#### Policy 3: `Allow users to view their own or assigned orders`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `((auth.uid() = user_id) OR (EXISTS (SELECT 1 FROM riders r WHERE ((r.id = orders.rider_id) AND (r.user_id = auth.uid())))) OR check_is_order_candidate_rider(id, auth.uid()))`
- **Purpose:** Combines passenger and rider read access. Uses `check_is_order_candidate_rider()` to allow nearby matched riders to view the order details before accepting.

#### Policy 4: `Allow passengers to create orders`
- **Allowed Command:** `INSERT`
- **Target Role:** `authenticated`
- **SQL WITH CHECK:** `(auth.uid() = user_id)`
- **Purpose:** Restricts order creation to the logged-in owner account.

#### Policy 5: `user_can_update_own_order`
- **Allowed Command:** `UPDATE`
- **Target Role:** `authenticated`
- **SQL USING Check:** `((auth.uid() = user_id) AND (order_status = 'searching'::order_status_enum))`
- **SQL WITH CHECK:** `(auth.uid() = user_id)`
- **Purpose:** Allows passengers to cancel searching rides, or modify locations before acceptance.

#### Policy 6: `Allow passengers and assigned riders to update orders`
- **Allowed Command:** `UPDATE`
- **Target Role:** `authenticated`
- **SQL USING Check:** `((auth.uid() = user_id) OR (EXISTS (SELECT 1 FROM riders r WHERE ((r.id = orders.rider_id) AND (r.user_id = auth.uid())))))`
- **Purpose:** Allows both the passenger and the assigned rider to update the order state during a trip.

---

### 2.5. Table: `public.rider_assignments`

#### Policy 1: `Allow passengers to view assignments for their own orders`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `check_is_order_passenger(order_id, auth.uid())`
- **Purpose:** Allows passengers to track the dispatch status of their bookings.

#### Policy 2: `Allow riders to view their own assignments`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(EXISTS (SELECT 1 FROM riders r WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = auth.uid()))))`
- **Purpose:** Restricts dispatch offers so only the targeted rider can view them.

#### Policy 3: `Riders can view own assignments`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(EXISTS (SELECT 1 FROM riders r WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = auth.uid()))))`
- **Purpose:** Duplicate policy fallback for reliability.

#### Policy 4: `Riders can update own assignments`
- **Allowed Command:** `UPDATE`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(EXISTS (SELECT 1 FROM riders r WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = auth.uid()))))`
- **SQL WITH CHECK:** `(EXISTS (SELECT 1 FROM riders r WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = auth.uid()))))`
- **Purpose:** Allows riders to accept or reject assignments.

#### Policy 5: `Allow passengers to insert assignments for their own orders`
- **Allowed Command:** `INSERT`
- **Target Role:** `authenticated`
- **SQL WITH CHECK:** `check_is_order_passenger(order_id, auth.uid())`
- **Purpose:** Allows passengers to trigger initial dispatch attempts.

#### Policy 6: `Allow passengers to update assignments for their own orders`
- **Allowed Command:** `UPDATE`
- **Target Role:** `authenticated`
- **SQL USING Check:** `check_is_order_passenger(order_id, auth.uid())`
- **SQL WITH CHECK:** `check_is_order_passenger(order_id, auth.uid())`
- **Purpose:** Allows passengers to update status codes.

#### Policy 7: `Authenticated can insert rider assignments`
- **Allowed Command:** `INSERT`
- **Target Role:** `authenticated`
- **SQL WITH CHECK:** `true`
- **Purpose:** Allows initial matching entries to be logged.

#### Policy 8: `Allow riders to update their own assignments`
- **Allowed Command:** `UPDATE`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(EXISTS (SELECT 1 FROM riders r WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = auth.uid()))))`
- **SQL WITH CHECK:** `(EXISTS (SELECT 1 FROM riders r WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = auth.uid()))))`
- **Purpose:** General update check fallback.

---

### 2.6. Table: `public.intercity_requests`

#### Policy 1: `Allow request participants to read/write`
- **Allowed Command:** `ALL`
- **Target Role:** `authenticated`
- **SQL USING Check:** `((sender_id = auth.uid()) OR (EXISTS (SELECT 1 FROM riders r WHERE ((r.id = traveller_id) AND (r.user_id = auth.uid())))))`
- **SQL WITH CHECK:** `((sender_id = auth.uid()) OR (EXISTS (SELECT 1 FROM riders r WHERE ((r.id = traveller_id) AND (r.user_id = auth.uid())))))`
- **Purpose:** Restricts intercity request management to the sender and the traveller.

---

### 2.7. Table: `public.order_chat_messages`

#### Policy 1: `Allow chat participants to read/write`
- **Allowed Command:** `ALL`
- **Target Role:** `authenticated`
- **SQL USING Check:** `((EXISTS (SELECT 1 FROM users WHERE ((users.id = auth.uid()) AND ((users.role = 'admin'::text) OR (users.role = 'support'::text))))) OR (sender_id = auth.uid()) OR (user_id = auth.uid()) OR ((order_id IS NOT NULL) AND ((EXISTS (SELECT 1 FROM orders o WHERE ((o.id = order_chat_messages.order_id) AND (o.user_id = auth.uid())))) OR (EXISTS (SELECT 1 FROM riders r WHERE ((r.user_id = auth.uid()) AND ((r.id = order_chat_messages.rider_id) OR (r.id IN (SELECT o.rider_id FROM orders o WHERE (o.id = order_chat_messages.order_id))) OR (r.id IN (SELECT ra.rider_id FROM rider_assignments ra WHERE (ra.order_id = ra.order_id))))))))) OR ((order_id IS NULL) AND ((sender_id = auth.uid()) OR (rider_id IN (SELECT riders.id FROM riders WHERE (riders.user_id = auth.uid()))))))`
- **Purpose:** Restricts chat access to passengers, assigned riders, candidate riders during the dispatch phase, and support admins.

---

### 2.8. Table: `public.rider_payout_accounts`

#### Policy 1: `rider_select_own_payout_account`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **Purpose:** Restricts payout profile views to the owner.

#### Policy 2: `rider_insert_own_payout_account`
- **Allowed Command:** `INSERT`
- **Target Role:** `authenticated`
- **SQL WITH CHECK:** `(auth.uid() = user_id)`
- **Purpose:** Restricts adding payout details to the account owner.

#### Policy 3: `rider_update_own_payout_account`
- **Allowed Command:** `UPDATE`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **SQL WITH CHECK:** `(auth.uid() = user_id)`
- **Purpose:** Restricts updating payout details to the account owner.

---

### 2.9. Table: `public.rider_withdrawals`

#### Policy 1: `Riders can view their own withdrawals`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **Purpose:** Restricts payout history views to the requesting rider.

#### Policy 2: `Users can view own withdrawals`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **Purpose:** Duplicate policy check fallback.

---

### 2.10. Table: `public.rider_withdrawal_events`

#### Policy 1: `Users can view own withdrawal events`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(EXISTS (SELECT 1 FROM rider_withdrawals rw WHERE ((rw.id = rider_withdrawal_events.withdrawal_id) AND (rw.user_id = auth.uid()))))`
- **Purpose:** Secures transactional state history.

#### Policy 2: `Riders can view their own withdrawal events`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(EXISTS (SELECT 1 FROM rider_withdrawals w WHERE ((w.id = rider_withdrawal_events.withdrawal_id) AND (w.user_id = auth.uid()))))`
- **Purpose:** Duplicate policy check fallback.

---

### 2.11. Table: `public.rider_travel_plans`

#### Policy 1: `Allow authenticated users to view active travel plans`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `((status = 'active'::travel_plan_status_enum) OR (EXISTS (SELECT 1 FROM riders r WHERE ((r.id = rider_travel_plans.rider_id) AND (r.user_id = auth.uid())))))`
- **Purpose:** Allows passengers to search active plans, and allows the planning rider to view their own archived plans.

#### Policy 2: `Allow riders to delete their own travel plans`
- **Allowed Command:** `DELETE`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(EXISTS (SELECT 1 FROM riders r WHERE ((r.id = rider_travel_plans.rider_id) AND (r.user_id = auth.uid()))))`
- **Purpose:** Restricts deletion to the plan owner.

#### Policy 3: `Allow riders to insert their own travel plans`
- **Allowed Command:** `INSERT`
- **Target Role:** `authenticated`
- **SQL WITH CHECK:** `(EXISTS (SELECT 1 FROM riders r WHERE ((r.id = rider_travel_plans.rider_id) AND (r.user_id = auth.uid()))))`
- **Purpose:** Restricts plan creation to the matching rider profile.

#### Policy 4: `Allow riders to update their own travel plans`
- **Allowed Command:** `UPDATE`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(EXISTS (SELECT 1 FROM riders r WHERE ((r.id = rider_travel_plans.rider_id) AND (r.user_id = auth.uid()))))`
- **SQL WITH CHECK:** `(EXISTS (SELECT 1 FROM riders r WHERE ((r.id = rider_travel_plans.rider_id) AND (r.user_id = auth.uid()))))`
- **Purpose:** Restricts updates to the plan owner.

---

### 2.12. Table: `public.notifications`

#### Policy 1: `Users can view their own notifications`
- **Allowed Command:** `SELECT`
- **Target Role:** `public`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **Purpose:** Protects notification lists.

#### Policy 2: `Users can update their own notifications`
- **Allowed Command:** `UPDATE`
- **Target Role:** `public`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **SQL WITH CHECK:** `(auth.uid() = user_id)`
- **Purpose:** Allows users to mark notifications as read.

---

### 2.13. Table: `public.wallet_transactions`

#### Policy 1: `Riders can view their own wallet transactions`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(EXISTS (SELECT 1 FROM riders r WHERE ((r.id = wallet_transactions.rider_id) AND (r.user_id = auth.uid()))))`
- **Purpose:** Restricts wallet ledger views to the owner.

---

### 2.14. Table: `public.user_devices`

#### Policy 1: `Allow users to select their own devices`
- **Allowed Command:** `SELECT`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **Purpose:** Device tracking limit read check.

#### Policy 2: `Allow users to insert their own devices`
- **Allowed Command:** `INSERT`
- **Target Role:** `authenticated`
- **SQL WITH CHECK:** `(auth.uid() = user_id)`
- **Purpose:** Device tracking registration check.

#### Policy 3: `Allow users to update their own devices`
- **Allowed Command:** `UPDATE`
- **Target Role:** `authenticated`
- **SQL USING Check:** `(auth.uid() = user_id)`
- **SQL WITH CHECK:** `(auth.uid() = user_id)`
- **Purpose:** Device tracking updates check.
