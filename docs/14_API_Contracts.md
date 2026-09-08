# WayDrop Technical Documentation — API Contracts Specifications

**Version:** 1.0  
**Last Updated:** July 5, 2026  
**Maintainer:** Lead API Engineer  
**Applies To Commit:** 241d836  

---

## 1. Global Request Specifications & Security Headers

All WayDrop Edge Functions are hosted as serverless endpoints. Standard requests must use these headers:

- **`Content-Type`:** Must be `application/json`.
- **`Authorization`:** Bearer token authentication. Must be either a client JWT (`Bearer <USER_JWT>`) or the admin bypass token (`Bearer <SUPABASE_SERVICE_ROLE_KEY>`).
- **`apikey`:** The Supabase project Anon Key or Service Role Key.
- **CORS Handling:** Handles preflight requests (`OPTIONS` method) automatically, returning `Access-Control-Allow-Origin: *` and `Access-Control-Allow-Headers: authorization, x-client-info, apikey, content-type`.

---

## 2. API Contract Specification Catalog

### 2.1. `accept-intercity-request`
- **Purpose:** Transition an intercity request from pending to active negotiation.
- **HTTP Method:** `POST`
- **Route:** `/accept-intercity-request`
- **Request Parameters:**
  - `request_id` (string, Required): The target UUID of the intercity request. Must be a valid UUID v4 format.
- **Payload Schema:**
  ```json
  {
    "request_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"
  }
  ```
- **Internal Workflow:**
  1. Validates the request caller's JWT token.
  2. Queries the `intercity_requests` table to verify the caller is a participant (sender or traveler).
  3. Updates the `status` column to `'discussion_started'`.
  4. Triggers the database notification function to alert the initiator that negotiation has begun.
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "message": "Request accepted. Discussion channel opened."
  }
  ```
- **Error Codes:**
  - **400 Bad Request:** Missing or invalid `request_id`.
  - **401 Unauthorized:** Invalid or expired JWT token.
  - **404 Not Found:** Request ID does not exist.

---

### 2.2. `accept-order`
- **Purpose:** Assigns a local ride or parcel order to a rider.
- **HTTP Method:** `POST`
- **Route:** `/accept-order`
- **Request Parameters:**
  - `order_id` (string, Required): UUID of the target order.
  - `rider_id` (string, Required): UUID of the accepting rider.
- **Payload Schema:**
  ```json
  {
    "order_id": "4dbf83c1-cf9a-419b-a010-8b1ef382b9e2",
    "rider_id": "7ac984c1-9273-4c92-bb01-28cf8923bc9d"
  }
  ```
- **Internal Workflow:**
  1. Queries the `orders` table to verify the order is still searching.
  2. Validates that the rider's wallet balance is positive, or that they have an active WayDrop MAX subscription.
  3. Acquires a lock on the order row.
  4. Updates the order's status to `'accepted'` and sets `rider_id = rider_id`.
  5. Updates all other pending assignments for this order in `rider_assignments` to `'expired'`.
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "message": "Order accepted successfully."
  }
  ```
- **Error Codes:**
  - **400 Bad Request:** Rider wallet balance is insufficient, or they have too many active orders.
  - **409 Conflict:** Order was already accepted by another rider or cancelled by the user.

---

### 2.3. `calculate-order-pricing`
- **Purpose:** Resolves routes and calculates ride/parcel fares.
- **HTTP Method:** `POST`
- **Route:** `/calculate-order-pricing`
- **Request Parameters:**
  - `pickup_lat` (double, Required): Pickup latitude. Must be between -90 and 90.
  - `pickup_lng` (double, Required): Pickup longitude. Must be between -180 and 180.
  - `destination_lat` (double, Required): Destination latitude.
  - `destination_lng` (double, Required): Destination longitude.
  - `order_type` (string, Required): Restricts to `ride`, `ride_sharing`, `local_parcel`, `intercity_ride`, `intercity_parcel`.
  - `vehicle_type` (string, Optional): Restricts to `bike`, `auto`, `cab`.
  - `promo_code` (string, Optional): Code to validate and apply.
- **Payload Schema:**
  ```json
  {
    "pickup_lat": 17.9812,
    "pickup_lng": 79.5982,
    "destination_lat": 17.9712,
    "destination_lng": 79.5582,
    "order_type": "ride",
    "vehicle_type": "bike",
    "promo_code": "DISCOUNT50"
  }
  ```
- **Internal Workflow:**
  1. Matches the pickup coordinates against active geofence zones in `pricing_zones`.
  2. Resolves route distance and duration using the Ola Maps Routing API.
  3. Queries `pricing_config` for the resolved zone and vehicle type.
  4. Calculates the base fare, distance charge, duration charge, platform fee, and GST.
  5. If `promo_code` is provided, runs the database validation RPC.
  6. Returns the fare breakdown.
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "pricing": {
      "base_fare": 30.00,
      "distance_fare": 45.00,
      "actual_fare": 75.00,
      "final_fare": 75.00,
      "gst_amount": 3.75,
      "commission_amount": 11.25,
      "rider_earning": 63.75
    }
  }
  ```
- **Error Codes:**
  - **400 Service Unavailable:** Pickup or destination coordinates are outside our serviceable zones.

---

### 2.4. `create-order`
- **Purpose:** Creates a new ride or parcel order in the database.
- **HTTP Method:** `POST`
- **Route:** `/create-order`
- **Request Parameters:**
  - `order_type` (string, Required): The type of booking.
  - `vehicle_type` (string, Required): The requested vehicle class.
  - `pickup_address` (string, Required): Pickup address name.
  - `pickup_lat` / `pickup_lng` (double, Required): Pickup coordinates.
  - `destination_address` (string, Required): Destination address name.
  - `destination_lat` / `destination_lng` (double, Required): Destination coordinates.
  - `actual_fare` (double, Required): Billed fare (verified against pricing rules).
  - `payment_mode` (string, Required): Restricts to `cash` or `online`.
  - `parcel_type` (string, Optional): Required for parcel bookings.
  - `receiver_name` / `receiver_phone` (string, Optional): Required for parcel bookings.
  - `weight_category` (string, Optional): Restricts to `0_5`, `6_15`, `16_25`, `26_50`.
  - `parcel_images` (array of strings, Optional): Uploaded image URLs.
- **Payload Schema:**
  ```json
  {
    "order_type": "local_parcel",
    "vehicle_type": "bike",
    "pickup_address": "Warangal, Hanamkonda",
    "pickup_lat": 17.9812,
    "pickup_lng": 79.5982,
    "destination_address": "Kazipet Junction",
    "destination_lat": 17.9712,
    "destination_lng": 79.5582,
    "actual_fare": 90.00,
    "payment_mode": "cash",
    "parcel_type": "Documents",
    "receiver_name": "John Doe",
    "receiver_phone": "9876543210",
    "weight_category": "0_5"
  }
  ```
- **Internal Workflow:**
  1. Verifies the user's active session.
  2. Runs pricing validation checks to ensure the fare matches our rates.
  3. Generates the pickup and dropoff OTPs.
  4. Inserts the order row into the `orders` table.
  5. If the payment mode is `cash`, it immediately triggers the `start-dispatch` matching loop.
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "order_id": "cbf192a0-df12-4c02-990a-8bf823b2c9d1",
    "order_code": "WDP100234"
  }
  ```

---

### 2.5. `create-payment`
- **Purpose:** Initiates a payment session with Cashfree.
- **HTTP Method:** `POST`
- **Route:** `/create-payment`
- **Payload Schema:**
  ```json
  {
    "order_id": "4dbf83c1-cf9a-419b-a010-8b1ef382b9e2",
    "payment_mode": "online"
  }
  ```
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "payment_session_id": "session_tok_abc123",
    "order_token": "cf_order_tok_xyz"
  }
  ```

---

### 2.6. `create-rider-payout`
- **Purpose:** Registers a rider's bank or UPI details as a beneficiary on Cashfree.
- **HTTP Method:** `POST`
- **Route:** `/create-rider-payout`
- **Payload Schema:**
  ```json
  {
    "account_number": "1234567890",
    "ifsc_code": "HDFC0000123",
    "beneficiary_name": "John Doe",
    "beneficiary_phone": "9876543210",
    "upi_vpa": "johndoe@ybl",
    "payout_method": "bank_account"
  }
  ```
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "message": "Payout beneficiary registered successfully in Cashfree."
  }
  ```

---

### 2.7. `create-rider-withdrawal`
- **Purpose:** Requests a payout withdrawal from the rider's wallet balance.
- **HTTP Method:** `POST`
- **Route:** `/create-rider-withdrawal`
- **Payload Schema:**
  ```json
  {
    "amount": 500.00
  }
  ```
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "transfer_id": "WDT12345",
    "message": "Withdrawal processed. Funds will be credited shortly."
  }
  ```

---

### 2.8. `load-testing`
- **Purpose:** Simulated concurrent matching runs for performance testing.
- **HTTP Method:** `POST`
- **Route:** `/load-testing`
- **Payload:**
  ```json
  {
    "scenario": "concurrent_matching",
    "cycles": 100
  }
  ```
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "logs": ["Simulated 100 concurrent matching matches."]
  }
  ```

---

### 2.9. `match-intercity-riders`
- **Purpose:** Matches intercity parcels with riders traveling along the same route.
- **HTTP Method:** `POST`
- **Route:** `/match-intercity-riders`
- **Payload:**
  ```json
  {
    "pickup_city": "Warangal",
    "destination_city": "Hyderabad",
    "travel_date": "2026-07-10T00:00:00Z"
  }
  ```
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "matched_plans": [
      {
        "plan_id": "uuid-string",
        "rider_name": "John Doe",
        "travel_date": "2026-07-10T08:30:00Z",
        "weight_preference": "26_50"
      }
    ]
  }
  ```

---

### 2.10. `process-verification-photo`
- **Purpose:** Verifies parcel photos uploaded at pickup or dropoff.
- **HTTP Method:** `POST`
- **Route:** `/process-verification-photo`
- **Payload:**
  ```json
  {
    "order_id": "uuid-string",
    "verification_type": "pickup",
    "photo_url": "https://storage.../pickup.jpg",
    "latitude": 17.9812,
    "longitude": 79.5982
  }
  ```
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "status": "verified",
    "message": "Verification photo approved."
  }
  ```

---

### 2.11. `regenerate-otp`
- **Purpose:** Re-sends the SMS verification OTP code.
- **HTTP Method:** `POST`
- **Route:** `/regenerate-otp`
- **Payload:**
  ```json
  {
    "phone": "+919876543210"
  }
  ```
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "message": "OTP regenerated and sent successfully."
  }
  ```

---

### 2.12. `reject-order`
- **Purpose:** Rejects an assigned order and triggers a cooldown for the rider.
- **HTTP Method:** `POST`
- **Route:** `/reject-order`
- **Payload:**
  ```json
  {
    "order_id": "uuid-string",
    "rider_id": "uuid-string",
    "reason": "Flat tire"
  }
  ```
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "message": "Order assignment rejected."
  }
  ```

---

### 2.13. `send-push-notification`
- **Purpose:** Dispatches push notifications to devices via FCM.
- **HTTP Method:** `POST`
- **Route:** `/send-push-notification`
- **Payload:**
  ```json
  {
    "user_id": "uuid-string",
    "title": "Alert ⚡",
    "body": "Your order status has updated.",
    "data": {
      "type": "order_status",
      "order_id": "uuid-string"
    }
  }
  ```
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "sent_count": 1
  }
  ```

---

### 2.14. `start-dispatch`
- **Purpose:** Runs the matching loop to assign orders to nearby riders.
- **HTTP Method:** `POST`
- **Route:** `/start-dispatch`
- **Payload:**
  ```json
  {
    "order_id": "uuid-string",
    "is_background": false
  }
  ```
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "message": "Dispatch matching process started in the background"
  }
  ```

---

### 2.15. `update-order-status`
- **Purpose:** Updates order status codes and logs history.
- **HTTP Method:** `POST`
- **Route:** `/update-order-status`
- **Payload:**
  ```json
  {
    "order_id": "uuid-string",
    "status": "rider_arrived"
  }
  ```
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "status": "rider_arrived",
    "message": "Order status updated."
  }
  ```

---

### 2.16. `verify-payment`
- **Purpose:** Confirms payment details and status with Cashfree.
- **HTTP Method:** `POST`
- **Route:** `/verify-payment`
- **Payload:**
  ```json
  {
    "order_id": "uuid-string",
    "payment_id": "cf_pay_12345"
  }
  ```
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "status": "success",
    "message": "Payment verified and recorded successfully."
  }
  ```
