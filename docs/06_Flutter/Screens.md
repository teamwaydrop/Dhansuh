# WayDrop Flutter Codebase — App Screens & Edge Function Integrations

**Version:** 1.0  
**Last Updated:** July 5, 2026  
**Maintainer:** Lead UI Architect  
**Applies To Commit:** 241d836  

---

## 1. Global Navigation & Mode Switching Architecture

WayDrop uses a **role-based layout structure**. Once authenticated, the application loads `MainNavigationScreen`. Based on the user's role and preferred mode, the UI toggles between two interfaces:

- **Passenger Mode:** Displays tabs for booking rides/parcels, viewing activity history, and managing profile settings.
- **Rider Mode:** Displays tabs for managing online status, viewing nearby order offers, tracking earnings, and managing payout accounts.

---

## 2. Authentication & Onboarding Screens

### 2.1. `LoginScreen`
- **File Location:** `lib/features/auth/screens/login_screen.dart`
- **Purpose:** Collects the user's phone number and initiates the OTP verification flow.
- **UI Components:** Phone number input field with country code picker, animated branding logo, and "Send OTP" button.
- **State & Providers:**
  - `phoneController`: Manages phone number input.
  - Bypasses Msg91 SMS gateway calls for numbers starting with `99999999`.
- **Navigation Transitions:** Transitions to `OtpScreen` on success, passing the phone number as a parameter.
- **Edge Function Calls:** Invokes the `regenerate-otp` Edge Function if the user requests a code resend.

### 2.2. `OtpScreen`
- **File Location:** `lib/features/auth/screens/otp_screen.dart`
- **Purpose:** Verifies the 6-digit OTP code sent via SMS.
- **UI Components:** 6 individual text fields for digit entry, cooldown timer display, and "Resend OTP" button.
- **State & Providers:**
  - Invokes `regenerate-otp` on cooldown expiration.
  - Uses hardcoded code `123456` for bypass phone numbers.
- **Navigation Transitions:** Transitions to `ProfileSetupScreen` on success.
- **Edge Function Calls:** Invokes `regenerate-otp` when the resend timer expires and the user taps "Resend OTP".

### 2.3. `ProfileSetupScreen`
- **File Location:** `lib/features/auth/screens/profile_setup_screen.dart`
- **Purpose:** Collects the user's name and email to complete their profile setup.
- **UI Components:** Text fields for full name and email address.
- **State & Providers:** Updates the `users` table via Supabase client with `full_name`, `email`, and `profile_completed = true`.
- **Navigation Transitions:** Transitions to `PermissionsScreen`.

---

## 3. Passenger Flow Screens

### 3.1. `HomeTab`
- **File Location:** `lib/features/user/home/home_tab.dart`
- **Purpose:** The primary landing screen for passengers, providing map views and service options.
- **UI Components:** Interactive Ola Maps view, service options cards, and active nearby riders bottom sheet.
- **State & Providers:**
  - `userProfileProvider`: Fetches the passenger's details.
  - `activeRidersStreamProvider`: Streams coordinates of online riders to display them on the map.
- **Navigation Transitions:** Tapping booking buttons routes to location selection screens.

### 3.2. Local Ride Screens
- **`RideLocationScreen`** (`lib/features/local_rides/booking/screens/ride_location_screen.dart`): Allows setting pickup and destination pins with geocoding.
- **`RideSearchingScreen`** (`lib/features/local_rides/searching/screens/ride_searching_screen.dart`): Displays dispatcher search radar while searching for local riders.
- **`RideTrackingScreen`** (`lib/features/local_rides/tracking/screens/ride_tracking_screen.dart`): Tracks rider in real-time, displays OTP, and updates transit status.
- **`RiderRatingScreen`** (`lib/features/local_rides/rating/screens/rider_rating_screen.dart`): Allows passenger to submit rating and review for completed ride.

### 3.3. Local Parcel Screens
- **`ParcelLocationScreen`** (`lib/features/local_parcels/booking/screens/parcel_location_screen.dart`): Pickup/destination selector with geocoding for parcel flows.
- **`ParcelDetailsScreen`** (`lib/features/local_parcels/booking/screens/parcel_details_screen.dart`): Collects package weight, receiver name, contact details, and images.
- **`ParcelBookingScreen`** (`lib/features/local_parcels/booking/screens/parcel_booking_screen.dart`): Displays calculated pricing quotes, payment methods, and initiates dispatch.
- **`ParcelSearchingScreen`** (`lib/features/local_parcels/searching/screens/parcel_searching_screen.dart`): Pulses a radar while matching with package couriers.
- **`ParcelTrackingScreen`** (`lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart`): Live transit coordinates monitoring, order chat, and invoice summaries.

### 3.4. Intercity Passenger Screens
- **`IntercityLocationScreen`** (`lib/features/intercity/shared/screens/intercity_location_screen.dart`): Select origin and destination cities for long-distance travel routes.
- **`IntercitySearchingScreen`** (`lib/features/intercity/shared/screens/intercity_searching_screen.dart`): Negotiation bidding board where user receives and accepts traveler fare proposals.
- **`IntercityTrackingScreen`** (`lib/features/intercity/shared/screens/intercity_tracking_screen.dart`): Displays route paths, driver coordinates, and chat messages for intercity transit.
- **`IntercityRidesScreen`** (`lib/features/intercity/rides/dashboard/intercity_rides_screen.dart`): Dashboard ledger for active and past intercity passenger rides.
- **`IntercityParcelsScreen`** (`lib/features/intercity/parcels/dashboard/intercity_parcels_screen.dart`): Dashboard ledger for active and past intercity parcel deliveries.


---

## 4. Rider Flow Screens

### 4.1. `RiderHomeTab`
- **File Location:** `lib/features/rider/dashboard/screens/rider_home_tab.dart`
- **Purpose:** The primary dashboard for riders.
- **UI Components:** Online/offline status toggle switch, incoming booking cards, and performance summaries.
- **State & Providers:** `riderStatusProvider` manages the online state and location updates.
- **Navigation Transitions:** Tapping an order card opens the matching verification views.
- **Edge Function Calls:**
  - Invokes `accept-order` when a rider accepts an offer.
  - Invokes `reject-order` when a rider rejects an offer, triggering their cooldown period.

### 4.2. `RiderKycScreen`
- **File Location:** `lib/features/rider/onboarding/screens/rider_kyc_screen.dart`
- **Purpose:** Multi-step wizard to upload KYC documents.
- **UI Components:** progress indicators, file upload containers, and document number text inputs.
- **State & Providers:** `RiderKycUploadService` manages file uploads to Supabase storage.
- **Navigation Transitions:** Transitions to `RiderKycPendingScreen` on submission.
- **Edge Function Calls:**
  - Invokes `validate-rider-kyc` to verify Aadhaar, PAN, and date of birth formats.
  - Invokes `create-rider-kyc` to insert the verification records into the `rider_kyc` table.

### 4.3. `RiderActiveOrderScreen`
- **File Location:** `lib/features/rider/orders/screens/rider_active_order_screen.dart`
- **Purpose:** Guides the rider through pickup, transit, and delivery.
- **UI Components:** Navigation map, OTP verification inputs, and document upload buttons.
- **State & Providers:** Invokes `process-verification-photo` and `update-order-status` edge functions.
- **Navigation Transitions:** Returns to `RiderHomeTab` on trip completion.
- **Edge Function Calls:**
  - Invokes `update-order-status` when transitioning states (e.g. `'rider_arrived'`, `'picked_up'`).
  - Invokes `process-verification-photo` when uploading parcel verification photos at pickup or dropoff.

### 4.4. `RiderEarningsTab`
- **File Location:** `lib/features/rider/earnings/rider_earnings_tab.dart`
- **Purpose:** Displays wallet transactions, balances, and payout options.
- **UI Components:** Wallet balance card, withdrawal history, and cashout forms.
- **State & Providers:** `walletTransactionsProvider` fetches the rider's ledger.
- **Navigation Transitions:** Routes to `AddPayoutDetailsScreen` if bank details are missing.
- **Edge Function Calls:** Invokes `create-rider-withdrawal` to request a payout transfer.
