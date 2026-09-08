# WayDrop Technical Documentation — Testing & QA Guide

**Version:** 1.0  
**Last Updated:** July 5, 2026  
**Maintainer:** Lead QA Engineer  
**Applies To Commit:** 241d836  

---

## 1. QA Bypass Credentials & Credentials

To facilitate rapid local testing without incurring SMS delivery fees or using real phone numbers, the system implements a hardcoded authentication bypass.

### 1.1. Login Bypass Parameters
- **Test Phone Number Prefix:** Any phone number starting with **`99999999`** (e.g. `+919999999901`, `+919999999999`).
- **Hardcoded Verification OTP:** **`123456`**
- **Trigger Behavior:**
  1. Bypasses the SMS gateway (Msg91) call.
  2. Bypasses standard verification checks and completes authentication anonymously.
  3. Automatically registers a profile under `public.users` with the name "Cashfree Tester".
  4. Automatically redirects past the onboarding screens to `MainNavigationScreen`.

### 1.2. Payment Sandbox Gateway Bypasses
- When checkout triggers, use Cashfree's **Sandbox environment**.
- **Mock Payment Instruments:**
  - **UPI Success:** Input `success@gocashfree` to simulate a successful payment.
  - **UPI Failure:** Input `fail@gocashfree` to test rollback flows.
  - **Test Card:** Use standard test card numbers provided in the Cashfree Sandbox docs with any future expiry date and a random 3-digit CVV.

---

## 2. Location Mocking & Geofencing Parameters

Because dispatch matching is radius-dependent, you must mock your device's location to test matching flows on emulators:

### 2.1. Standard Test Locations

| Location | Latitude | Longitude | Purpose |
| :--- | :--- | :--- | :--- |
| **Warangal Center (Hanamkonda)** | `17.9812` | `79.5982` | Primary active pricing zone. Used to test local rides and parcel dispatch. |
| **Kazipet Junction** | `17.9712` | `79.5582` | Used to test local matches within the 5.0 km radius. |
| **Hyderabad (Begumpet)** | `17.3850` | `78.4867` | Secondary pricing zone. Used to test intercity routing and corridor plans. |

### 2.2. Setting Up Mock Locations
- **Android Emulator:**
  1. Open emulator settings (three dots menu).
  2. Go to the **Location** tab.
  3. Enter the test coordinates (e.g. `17.9812, 79.5982`).
  4. Click **Set Location**.
- **iOS Simulator:**
  1. In the top menu, go to **Features** $\rightarrow$ **Location** $\rightarrow$ **Custom Location...**
  2. Enter the latitude and longitude coordinates.

---

## 3. End-to-End QA Checklists

### 3.1. Local Booking Flow
1. Log in using a bypass number (e.g., `+919999999901`, OTP `123456`).
2. Open `AddressSelectionScreen` and select Hanamkonda as pickup and Kazipet as destination.
3. Verify that fares are calculated and displayed in the bottom sheet.
4. Select **Online Payment** and tap **Pay & Book**.
5. Input the success UPI handler (`success@gocashfree`) to complete the payment.
6. Verify that the screen transitions to the pulsing radar `SearchingRiderScreen`.

### 3.2. Rider Onboarding Flow
1. Log in with a separate bypass number.
2. Complete profile setup and switch to Rider Mode.
3. Upload mock document photos in the `RiderKycScreen` wizard and submit the form.
4. Access the Supabase dashboard (or run an update script) to change `kyc_status` to `approved` and `activation_status` to `active` on the `rider_kyc` table.
5. In the app, verify that the rider is transitioned to `RiderDashboard` and can toggle their status to **Online**.


### 3.3. Intercity Via Locations / declared route (`docs/13_Business_Logic.md` section 5)

Manual QA for the "Your Route" / Via-locations step in `PostTravelPlanScreen` and the
declared-route matching it feeds.

1. Log in as a rider (bypass number), switch to Intercity Traveller mode, open **Post Travel Plan**.
2. **CASE 1 -- no Via locations.** Select From = Bhadrachalam, To = Guntur. Do **not** add any Via
   location. Fill the rest and **Post Travel Plan**.
   - **Expect:** plan posts normally. In Supabase, the new row has `route_selection_status = 'none'`
     and `selected_route_geometry` / `selected_route_meta` = `NULL`. `route_geometry` / `distance_km`
     / `price_per_seat` are populated exactly as before this feature.
3. **CASE 2 -- full declared route.** From = Bhadrachalam, To = Guntur. In "Your Route" tap
   **+ Add Via Location** and add, in order: Kothagudem, Tiruvuru, Vijayawada. Post the plan.
   - **Expect:** each Via row shows a numbered chip after selection; order is 1 Kothagudem /
     2 Tiruvuru / 3 Vijayawada. Plan posts.
   - In Supabase: `route_selection_status = 'via_declared'`;
     `selected_route_meta.waypoints` has 5 entries in order with `type` origin/via/via/via/destination
     and increasing `along_track_km` (0 first, `total_distance_km` last); `built_via = 'multi_leg'`,
     `leg_count = 4`. `selected_route_geometry` is a non-empty polyline.
   - `distance_km` / `price_per_seat` are **unchanged** vs CASE 1 for the same From/To (the Via
     route does not affect the fare).
4. **CASE 3 -- one Via.** From = Bhadrachalam, Via = Vijayawada, To = Guntur. Post.
   - **Expect:** `leg_count = 2`, 3 waypoints stored.
5. **Validation.**
   - Add a Via, type text, don't pick a suggestion -> Post -> *"Finish selecting Via location 1..."*.
   - Add a Via equal to the From town -> Post -> *"...is the same as your departure location."*.
   - Add two identical Via locations -> Post -> *"Via locations 1 and 2 are the same place."*.
   - Remove a Via with its `x` button -> it disappears and the numbers re-flow.
   - Add 5 Via locations -> the **+ Add Via Location** button is replaced by "Maximum 5 Via
     locations."
6. **Routing failure.** Put the device in airplane mode after picking all locations, then Post a
   plan that has >=1 Via location.
   - **Expect:** *"Could not build a route through your Via locations. Remove a stop or try
     again."* and **no** plan row is created (check Supabase).
7. **Matching -- CASE 4 (MATCH).** With the CASE 2 traveller plan active, create a passenger
   Intercity trip Tiruvuru -> Guntur for a nearby date.
   - **Expect:** the traveller appears as a match. In `match-intercity-riders` logs:
     `[MatchIntercity][SelectedRoute] ... newDecision=true reason=match`.
8. **Matching -- CASE 5 (NO MATCH, reversed).** Create a passenger trip Guntur -> Tiruvuru.
   - **Expect:** this traveller is **not** matched via the declared route. Logs:
     `[MatchIntercity][SelectedRoute] ... newDecision=false reason=reverse_of_selected_route`.
     (It may still match via a legacy city/coordinate rule if the endpoints happen to line up --
     the declared-route signal only ever *adds* matches, it never removes them.)
9. **Matching -- CASE 6 (near a Via).** Create a passenger trip with pickup ~5-10 km away from
   Tiruvuru (not exactly on it), destination Guntur.
   - **Expect:** still matched -- pickup snaps to the Tiruvuru waypoint within the 15 km radius.
10. **Matching -- CASE 7 (no regression).** Confirm a plain intercity plan with no Via locations
    (CASE 1, or any pre-feature plan) still matches passengers exactly as before -- the
    `[MatchIntercity][SelectedRoute]` line is not logged for it at all.
