# WayDrop Technical Documentation — Supabase Edge Functions Reference

**Version:** 1.0  
**Last Updated:** July 5, 2026  
**Maintainer:** Lead Backend Architect  
**Applies To Commit:** 241d836  

---

## 1. Runtime Environment & Global Standards

WayDrop uses **Supabase Edge Functions** built on Deno. This provides low-latency execution near the users. Deno executes TypeScript natively, using web-standard APIs (e.g. `fetch`, `Request`, `Response`).

### 1.1. CORS (Cross-Origin Resource Sharing)
All client-facing edge functions must handle HTTP `OPTIONS` preflight requests and append standard CORS headers to permit web, Android, and iOS client connections:

```typescript
export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
```

### 1.2. JWT Verification & Client Instantiation
To secure endpoints, Deno services decode the client's Bearer JWT:

```typescript
const authHeader = req.headers.get('Authorization')!;
const token = authHeader.replace('Bearer ', '');
const supabaseClient = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_ANON_KEY')!,
  { global: { headers: { Authorization: authHeader } } }
);
```

---

## 2. Database-to-Edge-Function Trigger Integrations

WayDrop triggers edge functions from PostgreSQL using database events. This is managed by the `pg_net` extension, which executes asynchronous HTTP requests from trigger functions without blocking the database transaction.

### 2.1. Trigger Function: `public.deliver_push_notification_http_fnc`
* **Trigger Timing:** `AFTER INSERT` on `public.notifications` via `on_notification_insert`.
* **Execution Logic:** Whenever a notification row is written to the database, this function sends an asynchronous HTTP POST request to the `send-push-notification` Edge Function:
  ```sql
  CREATE OR REPLACE FUNCTION public.deliver_push_notification_http_fnc(
      p_user_id uuid,
      p_title text,
      p_body text,
      p_data jsonb
  )
   RETURNS void
   LANGUAGE plpgsql
   SECURITY DEFINER
  AS $function$
  BEGIN
      PERFORM net.http_post(
          url := 'https://yvwpchffctiagevpqgwy.supabase.co/functions/v1/send-push-notification',
          headers := '{"Content-Type": "application/json", "Authorization": "Bearer <anon_key>"}'::jsonb,
          body := jsonb_build_object(
              'user_id', p_user_id,
              'title', p_title,
              'body', p_body,
              'data', p_data
          )
      );
  END;
  $function$;
  ```

---

## 3. Complete Edge Function Catalog & Client Connections

### 3.1. `accept-intercity-request`
- **Purpose:** Opens a chat negotiation channel between a traveler and a sender.
- **Database Tables:** `intercity_requests`, `order_chat_messages`.
- **Client Invocation:** Called on intercity negotiation and search screens.
  - **File:** [intercity_searching_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/intercity/shared/screens/intercity_searching_screen.dart#L248)
  - **Invocation:**
    ```dart
    final response = await supabase.functions.invoke('accept-intercity-request', body: {'request_id': requestId});
    ```

---

### 3.2. `accept-order`
- **Purpose:** Assigns a local ride or parcel order to a rider.
- **Database Tables:** `orders` (updates status and rider details), `rider_assignments` (expires other assignments).
- **Client Invocation:**
  - **Files:**
    - [rider_home_tab.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/rider/dashboard/screens/rider_home_tab.dart#L1743)
    - [incoming_order_card.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/rider/incoming_order_card.dart#L267)
  - **Invocation:**
    ```dart
    final response = await supabase.functions.invoke('accept-order', body: {
      'order_id': orderId,
      'rider_id': riderId,
    });
    ```

---

### 3.3. `calculate-order-pricing`
- **Purpose:** Geolocates pickup coordinates, calls Ola Maps to get distance/duration, and applies config rules to calculate the fare.
- **Database Tables:** `pricing_zones` (reads geofence limits), `pricing_config` (reads rates).
- **Client Invocation:**
  - **Files:**
    - [pricing_controller.dart](file:///c:/Users/munee/Desktop/waydrop/lib/transport/pricing_controller.dart#L120)
    - [ride_location_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/local_rides/booking/screens/ride_location_screen.dart#L1710)
    - [parcel_booking_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/local_parcels/booking/screens/parcel_booking_screen.dart#L368)
    - [intercity_ride_booking_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/intercity_rides/intercity_ride_booking_screen.dart#L353)
    - [intercity_booking_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/intercity/intercity_booking_screen.dart#L364)
  - **Invocation:**
    ```dart
    final response = await supabase.functions.invoke('calculate-order-pricing', body: {
      'pickup_lat': pickupLat,
      'pickup_lng': pickupLng,
      'destination_lat': destLat,
      'destination_lng': destLng,
      'order_type': orderType,
      'vehicle_type': vehicleType,
    });
    ```

---

### 3.4. `create-order`
- **Purpose:** Inserts new ride/parcel bookings into the database and generates verification OTPs.
- **Database Tables:** `orders` (inserts order), `user_devices` (logs device details).
- **Client Invocation:**
  - **Files:**
    - [ride_searching_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/local_rides/searching/screens/ride_searching_screen.dart#L263)
    - [parcel_searching_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/local_parcels/searching/screens/parcel_searching_screen.dart#L265)
    - [intercity_ride_searching_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/intercity_rides/intercity_ride_searching_screen.dart#L257)
    - [intercity_searching_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/intercity/shared/screens/intercity_searching_screen.dart#L248)
  - **Invocation:**
    ```dart
    final response = await supabase.functions.invoke('create-order', body: orderPayload);
    ```

---

### 3.5. `create-payment`
- **Purpose:** Generates a Cashfree session and updates transaction rows.
- **Database Tables:** `payments` (updates status and records session tokens).
- **Client Invocation:**
  - **File:** [payment_service.dart](file:///c:/Users/munee/Desktop/waydrop/lib/modules/payments/services/payment_service.dart#L97)
  - **Invocation:**
    ```dart
    await supabase.functions.invoke('create-payment', body: {
      'order_id': orderId,
      'payment_mode': 'online',
    });
    ```

---

### 3.6. `create-rider-payout`
- **Purpose:** Registers a rider's bank or UPI account on Cashfree.
- **Database Tables:** `rider_payout_accounts` (stores payout accounts).
- **Client Invocation:**
  - **Files:**
    - [rider_payout_details_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/rider/onboarding/screens/rider_payout_details_screen.dart#L137)
    - [rider_payouts_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/rider/rider_payouts_screen.dart#L48)
  - **Invocation:**
    ```dart
    await supabase.functions.invoke('create-rider-payout', body: payoutPayload);
    ```

---

### 3.7. `create-rider-withdrawal`
- **Purpose:** Initiates a withdrawal from a rider's wallet balance.
- **Database Tables:** `rider_withdrawals` (inserts request), `wallet_transactions` (deducts funds).
- **Client Invocation:**
  - **File:** [rider_earnings_tab.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/rider/earnings/rider_earnings_tab.dart#L119)
  - **Invocation:**
    ```dart
    final response = await supabase.functions.invoke('create-rider-withdrawal', body: {'amount': amount});
    ```

---

### 3.8. `create-rider-kyc` / `validate-rider-kyc`
- **Purpose:** Validates documents (PAN, Aadhaar, DOB format) and inserts KYC records.
- **Database Tables:** `rider_kyc` (inserts records).
- **Client Invocation:**
  - **File:** [rider_kyc_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/rider/onboarding/screens/rider_kyc_screen.dart#L360)
  - **Invocation:**
    ```dart
    final response = await supabase.functions.invoke('create-rider-kyc', body: kycPayload);
    ```

---

### 3.9. `reject-order`
- **Purpose:** Rejects an assigned order, updates assignment states, and triggers a cooldown for the rider.
- **Database Tables:** `rider_assignments` (sets status to `'rejected'`), `orders` (increments reject count).
- **Client Invocation:**
  - **Files:**
    - [rider_home_tab.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/rider/dashboard/screens/rider_home_tab.dart#L1618)
    - [incoming_order_card.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/rider/incoming_order_card.dart#L297)
  - **Invocation:**
    ```dart
    await supabase.functions.invoke('reject-order', body: {
      'order_id': orderId,
      'rider_id': riderId,
      'reason': reason,
    });
    ```

---

### 3.10. `send-push-notification`
- **Purpose:** Sends FCM push notifications to registered devices. Called by database triggers and support tools.
- **Database Tables:** `user_device_tokens` (reads tokens).
- **Invocation:** Automatically triggered via `deliver_push_notification_http_fnc` whenever a row is inserted into the `notifications` table.

---

### 3.11. `start-dispatch`
- **Purpose:** Runs the matching loop to locate nearby riders.
- **Database Tables:** `orders` (locks row and sets search flags), `riders` (checks coordinate history).
- **Client Invocation:**
  - **Files:**
    - [ride_searching_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/local_rides/searching/screens/ride_searching_screen.dart#L877)
    - [parcel_searching_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/local_parcels/searching/screens/parcel_searching_screen.dart#L878)
  - **Invocation:**
    ```dart
    await supabase.functions.invoke('start-dispatch', body: {'order_id': orderId});
    ```

---

### 3.12. `update-order-status`
- **Purpose:** Updates order status codes and logs status history.
- **Database Tables:** `orders` (updates status), `order_status_history` (logs changes).
- **Client Invocation:**
  - **File:** [rider_active_order_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/rider/orders/screens/rider_active_order_screen.dart#L224)
  - **Invocation:**
    ```dart
    await supabase.functions.invoke('update-order-status', body: {
      'order_id': orderId,
      'status': newStatus,
    });
    ```

---

### 3.13. `process-verification-photo`
- **Purpose:** Compares the coordinates of uploaded verification photos against the pickup/destination coordinates to ensure validity.
- **Database Tables:** `order_verifications` (records image URLs).
- **Client Invocation:**
  - **File:** [rider_active_order_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/rider/orders/screens/rider_active_order_screen.dart#L1002)
  - **Invocation:**
    ```dart
    await supabase.functions.invoke('process-verification-photo', body: photoPayload);
    ```

---

### 3.14. `verify-payment`
- **Purpose:** Confirms payment details with Cashfree.
- **Database Tables:** `payments` (updates payment state), `orders` (sets payment status to `'paid'`).
- **Client Invocation:**
  - **File:** [payment_service.dart](file:///c:/Users/munee/Desktop/waydrop/lib/modules/payments/services/payment_service.dart#L162)
  - **Invocation:**
    ```dart
    await supabase.functions.invoke('verify-payment', body: {
      'order_id': orderId,
      'payment_id': paymentId,
    });
    ```

---

### 3.15. `match-intercity-riders`
- **Purpose:** Matches intercity parcels with riders traveling along the same route.
- **Database Tables:** `rider_travel_plans`, `orders`.
- **Client Invocation:**
  - **File:** [intercity_parcels_screen.dart](file:///c:/Users/munee/Desktop/waydrop/lib/features/intercity/parcels/dashboard/intercity_parcels_screen.dart#L812)
  - **Invocation:**
    ```dart
    final response = await supabase.functions.invoke('match-intercity-riders', body: queryPayload);
    ```
