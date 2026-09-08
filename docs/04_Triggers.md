# WayDrop Technical Documentation — Database Triggers & Functions Specification

**Version:** 1.0  
**Last Updated:** July 5, 2026  
**Maintainer:** Lead Database Engineer  
**Applies To Commit:** 241d836  

---

## 1. PostgreSQL Database Trigger Engine

WayDrop uses triggers to automate status updates, push alerts, check limits, and generate unique codes. Triggers run inside database transactions. If a trigger function fails, the entire transaction (e.g., updating a booking status or registering a user) rolls back, keeping the database consistent.

### Trigger Execution Principles
- **`BEFORE` Triggers:** Modifies values (e.g. assigning unique alphanumeric registration codes or checking updates limits) before they are written to disk.
- **`AFTER` Triggers:** Handles side-effects (e.g. creating logs, sending notifications, or triggering matching loops) after changes are written.
- **`SECURITY DEFINER`:** Executes functions with the privileges of the creator (usually `postgres` or `admin`), bypassing Row-Level Security policies. This is useful for triggers that update other users' tables.

---

## 2. Detailed Database Trigger & PL/pgSQL Function Specifications

Below is the complete database catalog of triggers and their PL/pgSQL functions:

### 2.1. Dispatch & Matching Triggers

#### Function: `public.assign_nearby_searching_orders_to_rider()`
- **Timing:** `AFTER UPDATE OF account_status, current_lat, current_lng` on `public.riders`
- **Execution Rule:** `FOR EACH ROW WHEN (NEW.account_status = 'online' AND (OLD.account_status IS DISTINCT FROM 'online' OR NEW.current_lat IS DISTINCT FROM OLD.current_lat OR NEW.current_lng IS DISTINCT FROM OLD.current_lng))`
- **Input Parameters:** None (takes row variables `NEW` and `OLD`).
- **Security Context:** `SECURITY DEFINER`
- **Step-by-Step Logic:**
  1. Checks if the rider's coordinates (`NEW.current_lat`, `NEW.current_lng`) are valid.
  2. Queries `public.orders` to find bookings with `order_status = 'searching'`.
  3. Uses a Haversine formula to compute the distance between the rider's coordinates and the order's pickup coordinates:
     $$d = 6371 \times \arccos\left(\sin(\text{lat}_1)\sin(\text{lat}_2) + \cos(\text{lat}_1)\cos(\text{lat}_2)\cos(\text{lng}_2 - \text{lng}_1)\right)$$
  4. If the distance is within the geofence radius and the rider's vehicle matches the order type (e.g. bike for parcels $<10$ kg, auto/cab for rides), it continues.
  5. Checks the `rider_assignments` table to verify this rider doesn't already have an active assignment for this order.
  6. Creates a new assignment row in `public.rider_assignments` with `assignment_status = 'sent'`.
  7. Inserts a matching log row in `public.order_assignment_logs`.
  8. If the rider already has an expired assignment, it resets the status back to `'sent'` to offer the order again if the rider has been online for a minute.
- **Exception/Safety Handling:** Wraps insertions in a `BEGIN ... EXCEPTION WHEN unique_violation THEN NULL; END;` block. This prevents concurrent inserts from failing the transaction.

---

### 2.2. Order Status & History Triggers

#### Function: `public.on_order_status_update()`
- **Timing:** `AFTER UPDATE OF order_status` on `public.orders`
- **Execution Rule:** `FOR EACH ROW WHEN (OLD.order_status IS DISTINCT FROM NEW.order_status)`
- **Input Parameters:** None.
- **Security Context:** `SECURITY DEFINER`
- **Step-by-Step Logic:**
  1. Logs the status update in `public.order_status_history`, recording the previous status, the new status, and the user who triggered the change.
  2. Evaluates the new status to construct notification messages:
     - **`accepted`:** Sends a push notification to the passenger: "Rider [Name] has accepted your request."
     - **`rider_arrived`:** Sends a push notification: "Rider has arrived at the pickup location."
     - **`picked_up`:** Sends a push notification: "Your trip is on the way."
     - **`completed`:** Sends a push notification: "Trip completed successfully."
     - **`cancelled`:** Sends a push notification: "Your booking was cancelled."
  3. Inserts the notification text into `public.notifications`, which automatically triggers the FCM push function.
  4. If the status transitions to `completed` and the payment mode was `cash`, it updates the rider's stats:
     - Deducts the platform commission from the rider's wallet balance (`wallet_balance`).
     - Adds the fare to the rider's cash-held balance (`cod_pending_amount`).

---

### 2.3. Wallet & Payout Triggers

#### Function: `public.on_rider_wallet_balance_update()`
- **Timing:** `AFTER UPDATE OF wallet_balance` on `public.riders`
- **Execution Rule:** `FOR EACH ROW WHEN (OLD.wallet_balance IS DISTINCT FROM NEW.wallet_balance)`
- **Security Context:** `SECURITY DEFINER`
- **Step-by-Step Logic:**
  1. Checks if the rider's wallet balance has dropped below the threshold (e.g. `0` or negative values).
  2. If the balance falls below `-250 INR`, it inserts a notification row warning the rider that their account will be suspended if they do not top up their wallet.
  3. Inserts a row in `wallet_audit_logs` to log the transaction.

#### Function: `public.check_payout_update_limit()`
- **Timing:** `BEFORE INSERT OR UPDATE` on `public.rider_payout_accounts`
- **Execution Rule:** `FOR EACH ROW`
- **Security Context:** `SECURITY DEFINER`
- **Step-by-Step Logic:**
  1. Queries the `rider_payout_updates_log` table to count updates made by this user in the last 24 hours.
  2. If the count is $\ge 2$, it throws an exception: `RAISE EXCEPTION 'Bank details can only be updated twice in a 24-hour window.'`.
  3. Otherwise, it logs the update in `rider_payout_updates_log` and allows the edit.

---

### 2.4. Verification & Security Triggers

#### Function: `public.on_notification_insert()`
- **Timing:** `AFTER INSERT` on `public.notifications`
- **Execution Rule:** `FOR EACH ROW`
- **Security Context:** `SECURITY DEFINER`
- **Step-by-Step Logic:**
  1. Calls Supabase's `pg_net` extension to make an asynchronous HTTP POST request to the `send-push-notification` edge function:
     ```sql
     SELECT net.http_post(
       url := 'https://yvwpchffctiagevpqgwy.supabase.co/functions/v1/send-push-notification',
       headers := jsonb_build_object(
         'Content-Type', 'application/json',
         'Authorization', 'Bearer ' || CURRENT_SETTING('app.settings.service_role_key')
       ),
       body := jsonb_build_object('notification_id', NEW.id),
       timeout_ms := 5000
     );
     ```
  2. Exits immediately, allowing the SQL transaction to commit without waiting for the network call to finish.

#### Function: `public.on_new_chat_message()`
- **Timing:** `AFTER INSERT` on `public.order_chat_messages`
- **Execution Rule:** `FOR EACH ROW`
- **Security Context:** `SECURITY DEFINER`
- **Step-by-Step Logic:**
  1. Checks the sender type (`user`, `rider`, `admin`).
  2. Identifies the recipient user ID.
  3. Inserts a push notification row in `public.notifications` with the message excerpt to alert the recipient of the new message.

---

### 2.5. Code Generation Triggers

To prevent ID enumeration attacks, the system assigns unique alphanumeric codes to key resources before they are written to disk:

#### Function: `public.trg_users_user_code()`
- **Timing:** `BEFORE INSERT` on `public.users`
- **Logic:** Calls `generate_unique_user_code()` which loops up to 10 times using `generate_random_alphanumeric(6)` to find a unique, unused string. Assigns the result (e.g. `WDU102934`) to the `user_code` field.

#### Function: `public.trg_orders_order_code()`
- **Timing:** `BEFORE INSERT` on `public.orders`
- **Logic:** Evaluates the `order_type`. Fetches the prefix (e.g. `WDR` for rides, `WDP` for local parcels, `WDI` for intercity) and generates a unique code (e.g. `WDP123456`).

---

## 3. Background Cron Schedules (`pg_cron` Catalog)

WayDrop uses `pg_cron` inside PostgreSQL to manage time-based cleanup tasks:

### 3.1. Clean Stale Travel Plans
- **Schedule:** `0 0 * * *` (Every night at 12:00 AM UTC)
- **SQL Execution:**
  ```sql
  UPDATE public.rider_travel_plans
  SET status = 'completed'::travel_plan_status_enum
  WHERE travel_date < NOW() AND status = 'active'::travel_plan_status_enum;
  ```

### 3.2. Daily Wallet Auditing
- **Schedule:** `0 2 * * *` (Daily at 2:00 AM UTC)
- **SQL Execution:** `SELECT public.audit_rider_wallets();`
- **Logic:** Compares every rider's current wallet balance against the sum of their transactions in `wallet_transactions`. Logs discrepancies in `wallet_audit_logs`.
