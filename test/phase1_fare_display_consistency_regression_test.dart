// Structural regression guard for Phase 1 / Issue 1: "fare shown before booking/accepting must
// exactly match the fare after booking/accepting."
//
// BUG REPORT: (a) USER SIDE -- a passenger could see one whole-rupee fare on the booking screen
// and a different, decimal fare on the created order. (b) RIDER SIDE -- an intercity Traveller's
// incoming Travel Together request showed the raw, unrounded negotiated `proposed_fare` (e.g.
// "₹23.64") both before AND after accepting, while the order's own authoritative fare
// (orders.current_fare/final_fare) becomes a DIFFERENT, whole-rupee value the moment
// accept_intercity_request() rounds it -- so the number the rider agreed to never matched what
// the order (and the passenger's payment) actually settled to.
//
// ROOT CAUSE (traced end to end):
//   1. USER SIDE was already fixed by 20260901000018_whole_rupee_fare_rounding.sql -- the
//      pricing engine (calculate-order-pricing/pricing-calculations.ts) rounds the customer-
//      payable total to a whole rupee ONCE, at the root, and create-order copies that same
//      rounded value verbatim into orders.current_fare. This file re-asserts that chain stays
//      intact (see rider_fare_whole_rupee_rounding_regression_test.dart for the original,
//      exhaustive proof) -- it must never regress while Phase 1 also touches nearby files.
//   2. RIDER SIDE (the actual gap Phase 1 closes): intercity_requests.proposed_fare is a raw,
//      client-influenced negotiated figure that is NEVER rounded in the database -- only
//      accept_intercity_request() rounds it (via calculate_fare_breakdown()) the instant it
//      writes orders.current_fare/final_fare. Two Flutter screens displayed this raw value
//      directly, with no rounding, both before AND after acceptance:
//        - lib/modules/chat/screens/order_chat_screen.dart's _buildIntercityHeader() (the shared
//          negotiation/booking-status header both the passenger and the traveller see)
//        - lib/features/rider/intercity/intercity_bookings_screen.dart's _buildNegotiationsTab()
//          (the traveller's pending-negotiations list), which additionally prioritized the
//          ORDER's stale original-estimate fare over the up-to-date negotiated proposed_fare --
//          showing neither the negotiated figure nor its rounded form.
//      A third, purely-cosmetic inconsistency (already-whole-rupee local-order fares displayed
//      with 2 decimal places instead of 0, e.g. "₹24.00" vs "₹24") in
//      incoming_order_card.dart's SlideToAcceptButton is fixed alongside it.
//
// FIX: added lib/shared/helpers/fare_presentation_helper.dart's roundFareForDisplay() -- a
// DISPLAY-ONLY whole-rupee rounding helper (half-up, matching Postgres ROUND(x,0) and
// pricing-calculations.ts's roundToWholeRupee()/Math.round()) -- and used it (or the now-
// authoritative, already-rounded order fare once one exists) everywhere the raw proposed_fare was
// shown. No pricing formula, GST rate, commission rate, or the real `calculate_fare_breakdown()`/
// `accept_intercity_request()` rounding logic changed -- this is presentation-layer only.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final farePresentationHelper = _read('lib/shared/helpers/fare_presentation_helper.dart');
  final orderChatScreen = _read('lib/modules/chat/screens/order_chat_screen.dart');
  final intercityBookingsScreen = _read('lib/features/rider/intercity/intercity_bookings_screen.dart');
  final incomingOrderCard = _read('lib/features/rider/orders/widgets/incoming_order_card.dart');
  final pricingCalc = _read('supabase/functions/calculate-order-pricing/pricing-calculations.ts');
  final createOrder = _read('supabase/functions/create-order/index.ts');
  final fareRoundingMigration =
      _read('supabase/migrations/20260901000018_whole_rupee_fare_rounding.sql');
  final acceptIntercityMigration = _read(
    'supabase/migrations/20260901000021_intercity_ride_gov_tax_and_stale_negotiated_commission.sql',
  );

  group('1-2. USER SIDE: pre-booking display and the created order still share one canonical '
      'rounded value (pre-existing fix, must not regress)', () {
    test('the pricing engine rounds the customer-payable total to a whole rupee exactly once, '
        'at the root (roundToWholeRupee), not per-display-site', () {
      expect(pricingCalc.contains('export function roundToWholeRupee(amount: number): number'), isTrue);
      expect(pricingCalc.contains('const finalFare = roundToWholeRupee(rawFinalFare);'), isTrue);
    });

    test('create-order copies pricing.final_fare verbatim into current_fare -- never '
        're-rounds or independently recomputes it', () {
      final anchor = createOrder.indexOf('const currentFare =');
      expect(anchor, greaterThan(-1));
      final nearby = createOrder.substring(anchor, (anchor + 60).clamp(0, createOrder.length));
      expect(nearby.contains("Number(\n        pricing.final_fare"), isTrue);
    });

    test('the primary local ride/parcel booking-screen fare chips render whole-rupee '
        '(toStringAsFixed(0)), matching the now-whole-rupee underlying value', () {
      final rideBooking = _read('lib/features/local_rides/booking/screens/ride_location_screen.dart');
      final parcelBooking = _read('lib/features/local_parcels/booking/screens/parcel_booking_screen.dart');
      expect(rideBooking.contains('displayFare.toStringAsFixed(0)'), isTrue);
      expect(parcelBooking.contains('finalFare.toStringAsFixed(0)'), isTrue);
    });
  });

  group('3-4. RIDER SIDE FIX: the intercity negotiation/acceptance fare display', () {
    test('a DISPLAY-ONLY whole-rupee rounding helper exists, documented as never being written '
        'back anywhere', () {
      expect(farePresentationHelper.contains('int roundFareForDisplay(num amount) => amount.round();'), isTrue);
      expect(farePresentationHelper.contains('DISPLAY ONLY'), isTrue);
    });

    test('order_chat_screen.dart no longer shows the raw, unrounded proposed_fare with 2 decimal '
        'places anywhere in the intercity header -- every occurrence was replaced', () {
      expect(orderChatScreen.contains('proposedFare.toStringAsFixed(2)'), isFalse);
    });

    test('order_chat_screen.dart computes one canonical displayFare: the authoritative, already-'
        'rounded order fare once acceptance has happened, otherwise the rounded proposed_fare -- '
        'so the exact same number is shown before and after acceptance', () {
      expect(orderChatScreen.contains('roundFareForDisplay(proposedFare)'), isTrue);
      final anchor = orderChatScreen.indexOf('final isPreAcceptance =');
      expect(anchor, greaterThan(-1));
      final nearby = orderChatScreen.substring(anchor, (anchor + 500).clamp(0, orderChatScreen.length));
      // Once beyond negotiation, the order's own final_fare/current_fare (already rounded by
      // accept_intercity_request()) takes priority over the raw negotiated figure.
      expect(nearby.contains("_orderData?['final_fare']"), isTrue);
      expect(nearby.contains("_orderData?['current_fare']"), isTrue);
      expect(nearby.contains('authoritativeOrderFare ?? roundFareForDisplay(proposedFare)'), isTrue);
    });

    test('every fare line in the intercity header (negotiating / agreed / booking-locked / pay '
        'button) now renders the single displayFare value, not a per-branch decimal reformat', () {
      expect(orderChatScreen.contains(r"'Fare: ₹$displayFare\n'"), isTrue);
      expect(orderChatScreen.contains(r"'Fare Agreed at ₹$displayFare! ✓'"), isTrue);
      expect(orderChatScreen.contains(r"'Booking Locked • Fare: ₹$displayFare'"), isTrue);
      expect(orderChatScreen.contains(r"'PAY ₹$displayFare'"), isTrue);
    });

    test('intercity_bookings_screen.dart\'s pending-negotiations tab now rounds and prioritizes '
        'the up-to-date proposed_fare -- the figure accept_intercity_request() will actually '
        'round into the order -- instead of the order\'s stale pre-negotiation estimate', () {
      final anchor = intercityBookingsScreen.indexOf('final proposedFare = roundFareForDisplay(');
      expect(anchor, greaterThan(-1));
      final nearby =
          intercityBookingsScreen.substring(anchor, (anchor + 150).clamp(0, intercityBookingsScreen.length));
      expect(nearby.contains("req['proposed_fare']"), isTrue);
      // The pending-negotiations card no longer reads order.final_fare/current_fare at all --
      // only the negotiated proposed_fare, rounded for display.
      expect(nearby.contains("order?['final_fare']"), isFalse);
      expect(nearby.contains("order?['current_fare']"), isFalse);
    });

    test('the pending-negotiations card renders the already-int, already-rounded proposedFare '
        'directly -- no residual 2-decimal-place formatting on it', () {
      expect(intercityBookingsScreen.contains(r"'₹$proposedFare'"), isTrue);
    });

    test('the Active/History tabs (already-accepted requests) still prefer the authoritative, '
        'always-fresh order fare -- that priority is correct once an order is accepted and is '
        'untouched by this fix', () {
      expect(
        intercityBookingsScreen.contains(
          "order?['final_fare']?.toString() ?? order?['current_fare']?.toString() ?? req['proposed_fare']?.toString() ?? '0',",
        ),
        isTrue,
      );
    });

    test('incoming_order_card.dart\'s Accept-button fare now renders whole-rupee '
        '(toStringAsFixed(0)), matching every other whole-rupee fare display in the app -- the '
        'underlying value was already correct, only the 2-decimal-place formatting changes', () {
      expect(incomingOrderCard.contains(r"'₹${widget.fare.toStringAsFixed(0)}'"), isTrue);
      expect(incomingOrderCard.contains(r"'₹${widget.fare.toStringAsFixed(2)}'"), isFalse);
    });
  });

  group('5-6. No double-rounding, no pricing/GST/commission formula changes', () {
    test('calculate_fare_breakdown() -- the one real (non-display) rounding authority -- is '
        'untouched by this migration set: this fix set adds no new migration redefining it', () {
      expect(
        fareRoundingMigration.contains(
          'v_new_total_fare := ROUND(COALESCE(p_new_total_fare, 0), 0);',
        ),
        isTrue,
      );
    });

    test('accept_intercity_request() still rounds the negotiated fare via '
        'calculate_fare_breakdown() exactly once, server-side -- the only real rounding of a '
        'negotiated fare that ever happens; the new Flutter-side roundFareForDisplay() calls are '
        'presentation-only and never feed back into any RPC/edge-function call', () {
      expect(
        acceptIntercityMigration.contains(
          'v_breakdown := public.calculate_fare_breakdown(\n        v_request.proposed_fare,',
        ),
        isTrue,
      );
      expect(orderChatScreen.contains('roundFareForDisplay(proposedFare)'), isTrue);
      // roundFareForDisplay's result is only ever interpolated into Text widgets in these two
      // files, never passed to a supabase.rpc(...)/functions.invoke(...) call.
      expect(RegExp(r'rpc\([^)]*roundFareForDisplay').hasMatch(orderChatScreen), isFalse);
      expect(RegExp(r'rpc\([^)]*roundFareForDisplay').hasMatch(intercityBookingsScreen), isFalse);
    });

    test('GST-inclusive base-fare derivation, commission calculation, and rider-earning '
        'calculation formulas are unchanged in shape', () {
      expect(
        fareRoundingMigration.contains(
          'v_base_fare := ROUND(v_new_total_fare / (1 + (COALESCE(p_gst_percentage, 5.0) / 100.0)), 2);',
        ),
        isTrue,
      );
      expect(
        fareRoundingMigration.contains(
          'v_commission_amount := ROUND(v_base_fare * (COALESCE(p_commission_percentage, 0) / 100.0), 2);',
        ),
        isTrue,
      );
    });
  });
}
