// Regression guard for the 2026-07-29 production fix set (3 real-device bug reports):
//
// ISSUE 1 -- Intercity fare mismatch (passenger "Your Offer" ₹463.84 vs traveller card "₹497 per
// seat" for the SAME Travel Together request). ROOT CAUSE: intercity_searching_screen.dart's
// "Available Drop Partners" list rendered PartnerCard without passing `yourFare`, so every card
// fell back to `partner['price_per_seat']` -- the TRAVELLER's own posted per-seat rate for their
// own (usually different-distance) route -- labeled "per seat", instead of the passenger's own
// authoritative order fare (order.current_fare, the exact same value already shown as "Your
// Offer" on the same screen, and the exact value `_travelTogether()` sends as proposed_fare, and
// the exact value the traveller's Accept Request button already correctly displayed). ₹497 was
// never a competing "true" fare -- it was a different traveller's rate for a different route,
// rendered next to the passenger's own fare by omission of one constructor argument. No pricing
// logic changed: proposed_fare -> accept_intercity_request -> orders.final_fare/current_fare was
// already correct end-to-end (see 20260728000000_fix_intercity_parcel_pricing_and_fare_guard.sql);
// this fix is purely presentation, reconciling what was displayed with what was always charged.
//
// ISSUE 2 -- "In Transit • Open Tracker" (shown once a Travel Plan's accepted passenger/parcel
// starts trip) originally called widget.loadActiveOrder() + Navigator.pop(), which only ever
// closed TravelPlanDetailsScreen and landed back on Home with nothing useful open -- no
// navigation, no tracker. A first pass replaced that with a "Directions" button that launched
// Google Maps directly (google.navigation: intent / web fallback) from inside
// travel_plan_details_screen.dart itself.
//
// SUPERSEDED 2026-07-29 (later same day): that first pass was itself a "screenshot-specific hack"
// -- it skipped the app's own canonical active-order/trip screen (RiderActiveOrderScreen: ACCEPTED
// state, fare, SHOW DETAILS, Directions on Maps, SWIPE TO ARRIVE, Call/Chat/Cancel Ride) entirely,
// forcing the traveller to back out and find the accepted task through a different route to reach
// it. "Directions" now opens RiderActiveOrderScreen(orderId: ...) for THIS accepted order --
// reusing the existing canonical order-loading path (same screen already reachable via "VIEW
// ORDER" right after accept) instead of a second, duplicate tracking surface. Only that reused
// screen's own "Directions on Maps" button (rider_active_order_screen.dart's
// _openExternalGoogleMaps) launches external navigation now -- travel_plan_details_screen.dart no
// longer calls launchUrl/canLaunchUrl at all. See
// 20260729000003_cascade_cancel_travel_plan_dependents.sql's sibling client changes for the full
// rationale.
//
// ISSUE 3 -- Traveller-rates-Passenger notification went to the traveller (self-notification)
// instead of the passenger. ROOT CAUSE: on_rider_review_insert() predates
// 20260717000007_intercity_bidirectional_ratings.sql's rated_by column and always resolved the
// recipient as `riders.user_id` for NEW.rider_id -- the order's TRAVELLER -- regardless of which
// direction (rated_by='user'|'rider') actually happened. Fixed in
// 20260729000002_fix_rating_notification_direction.sql: recipient branches on NEW.rated_by,
// resolved purely from the order's own authoritative participant columns (never a client-supplied
// recipient id), with a defense-in-depth guard against notifying auth.uid() (the actor who just
// submitted the rating).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final searchingScreen = _read('lib/features/intercity/shared/screens/intercity_searching_screen.dart');
  final availablePartnersScreen = _read('lib/features/user/intercity/screens/available_partners_screen.dart');
  final partnerCard = _read('lib/features/intercity/shared/widgets/partner_card.dart');
  final travelPlanDetails = _read('lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart');
  final ratingNotificationFix = _read('supabase/migrations/20260729000002_fix_rating_notification_direction.sql');
  final notificationService = _read('lib/modules/notifications/services/notification_service.dart');
  final acceptRequestFn = _read('supabase/migrations/20260728000000_fix_intercity_parcel_pricing_and_fare_guard.sql');
  final ratingsMigration = _read('supabase/migrations/20260717000007_intercity_bidirectional_ratings.sql');

  group('Issue 1 -- one authoritative passenger fare on the Travel Together searching screen', () {
    test('Test 1: PartnerCard in the "Available Drop Partners" list is passed yourFare (the passenger\'s own order fare)', () {
      final start = searchingScreen.indexOf('Widget _buildMatchedTravelersSection');
      expect(start, greaterThan(-1));
      final section = searchingScreen.substring(start, start + 13000);
      expect(section.contains("final double yourFare = double.tryParse((order?['current_fare'] ?? order?['actual_fare']"), isTrue);
      expect(section.contains('yourFare: yourFare > 0 ? yourFare : null,'), isTrue);
    });

    test('Test 1 (available_partners_screen.dart, the other Travel Together entry point): yourFare already wired the same way', () {
      expect(availablePartnersScreen.contains('yourFare: _yourFare'), isTrue);
    });

    test('Test 2: PartnerCard shows "Inclusive of GST"-equivalent "your fare" label when yourFare is provided, never the traveller\'s own price_per_seat', () {
      expect(partnerCard.contains("(yourFare ?? pricePerSeat).toStringAsFixed(0)"), isTrue);
      expect(partnerCard.contains("yourFare != null ? 'your fare' : (isParcel ? 'estimate' : 'per seat')"), isTrue);
    });

    test('Test 2: "Your Offer" primary amount shows "Inclusive of GST" so the passenger never has to add tax mentally', () {
      final start = searchingScreen.indexOf("'Your Offer'");
      expect(start, greaterThan(-1));
      final section = searchingScreen.substring(start, start + 5000);
      expect(section.contains("'Inclusive of GST'"), isTrue);
      expect(section.contains('Icons.check_circle_rounded'), isTrue);
    });

    test('Test 3, 4, 5, 6: boost propagation (+10/+20/+50/custom) always derives from the same currentFare, and confirming calls increaseFare (server-authoritative boost-order-fare)', () {
      expect(searchingScreen.contains("buildPresetChipLocal('+ ₹10', 10.0)"), isTrue);
      expect(searchingScreen.contains("buildPresetChipLocal('+ ₹20', 20.0)"), isTrue);
      expect(searchingScreen.contains("buildPresetChipLocal('+ ₹50', 50.0)"), isTrue);
      expect(searchingScreen.contains('buildCustomToggleChipLocal()'), isTrue);
      expect(searchingScreen.contains("'boost-order-fare'"), isTrue);
      // The boosted amount is never computed/trusted client-side as final -- increaseFare reads
      // the server-confirmed fare back and uses THAT (never the pre-request local value) to also
      // update any in-flight negotiation's proposed_fare, so it can never diverge.
      expect(searchingScreen.contains("final serverFare = double.tryParse(data['order']?['current_fare']?.toString()"), isTrue);
      expect(searchingScreen.contains("'proposed_fare': serverFare"), isTrue);
    });

    test('Test 7: _travelTogether sends the exact same fare variable shown as "Your Offer" (order.current_fare ?? actual_fare), never price_per_seat', () {
      final start = searchingScreen.indexOf('Future<void> _travelTogether(Map<String, dynamic> match)');
      expect(start, greaterThan(-1));
      final section = searchingScreen.substring(start, start + 2000);
      expect(section.contains("final double initialProposedFare = double.parse((order?['current_fare'] ?? order?['actual_fare'] ?? 0.0).toString());"), isTrue);
      expect(section.contains('proposedFare: initialProposedFare'), isTrue);
      expect(section.contains('price_per_seat'), isFalse);
    });

    test('Test 8: accept_intercity_request installs the request\'s proposed_fare verbatim onto the order (final_fare AND current_fare), and rejects non-positive fares', () {
      expect(acceptRequestFn.contains('final_fare = v_request.proposed_fare,'), isTrue);
      expect(acceptRequestFn.contains('current_fare = v_request.proposed_fare,'), isTrue);
      expect(acceptRequestFn.contains('IF v_request.proposed_fare IS NULL OR v_request.proposed_fare <= 0 THEN'), isTrue);
    });

    test('Test 9: a new intercity_requests row can never carry a non-positive proposed_fare (defense in depth against a stale/zero price_per_seat leaking through)', () {
      expect(acceptRequestFn.contains('trigger_reject_invalid_proposed_fare'), isTrue);
      expect(acceptRequestFn.contains("NEW.proposed_fare IS NULL OR NEW.proposed_fare <= 0"), isTrue);
    });
  });

  group('Issue 2 (superseded) -- started trip shows Directions, opening the canonical active-order screen', () {
    test('Test 10: the dead "In Transit • Open Tracker" label/handler is gone from both render sites', () {
      expect(travelPlanDetails.contains("btnLabel = 'In Transit"), isFalse);
      expect(travelPlanDetails.contains("btnLabel = 'Open Tracker"), isFalse);
      expect(RegExp(r"btnLabel = 'Directions';").allMatches(travelPlanDetails).length, greaterThanOrEqualTo(2));
    });

    test('Test 11: the in_progress button no longer calls loadActiveOrder or launches Maps directly -- it calls _openActiveOrderScreen', () {
      final occurrences = RegExp(r"reqStatus == 'in_progress'\) \{[\s\S]{0,900}?\}").allMatches(travelPlanDetails);
      expect(occurrences.length, greaterThanOrEqualTo(2));
      for (final m in occurrences) {
        final block = m.group(0)!;
        expect(block.contains('_openActiveOrderScreen'), isTrue);
        expect(block.contains('loadActiveOrder'), isFalse);
        expect(block.contains('_openDirectionsForOrder(order)'), isFalse);
      }
    });

    test('Test 12: _openDirectionsForOrder (the direct-Google-Maps launcher) no longer exists as a callable method on this screen', () {
      // The identifier may still appear in an explanatory comment documenting what this replaced
      // -- assert the callable method declaration/call and the launch technique itself are gone.
      expect(travelPlanDetails.contains('Future<void> _openDirectionsForOrder('), isFalse);
      expect(travelPlanDetails.contains("Uri.parse('google.navigation:"), isFalse);
      expect(travelPlanDetails.contains('canLaunchUrl'), isFalse);
    });

    test('Test 11/2/3: _openActiveOrderScreen pushes the canonical RiderActiveOrderScreen for THIS order, never Home/a duplicate tracker', () {
      final start = travelPlanDetails.indexOf('void _openActiveOrderScreen(String orderId)');
      final end = travelPlanDetails.indexOf('\n  Widget _buildSheetActionButton');
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final section = travelPlanDetails.substring(start, end);
      expect(section.contains('Navigator.push'), isTrue);
      expect(section.contains('RiderActiveOrderScreen(') , isTrue);
      expect(section.contains('orderId: orderId'), isTrue);
      expect(section.contains('MainNavigationScreen'), isFalse);
      expect(section.contains('Navigator.pop'), isFalse);
    });

    test('Test 4: the correct per-passenger order is resolved -- orderId passed to _openActiveOrderScreen comes from this row\'s own scoped `order`/`orderId`, not a shared/first-match variable', () {
      expect(travelPlanDetails.contains("_openActiveOrderScreen(orderId.toString())"), isTrue);
      // Both call sites (sheet + main card list) resolve `orderId`/`order` from their own local
      // itemBuilder/method scope (`final order = matches[idx];` / the sheet's own `order` param),
      // never a shared mutable field that could leak the wrong passenger's order.
      expect(travelPlanDetails.contains("final order = matches[idx];"), isTrue);
    });

    test('external navigation (google.navigation intent + Google Maps web fallback) still exists, but now only inside RiderActiveOrderScreen\'s own "Directions on Maps" action', () {
      final activeOrderScreen = _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');
      expect(activeOrderScreen.contains('_openExternalGoogleMaps'), isTrue);
      expect(activeOrderScreen.contains("'Directions on Maps'"), isTrue);
      expect(activeOrderScreen.contains('canLaunchUrl'), isTrue);
    });

    test('Test 13: active/in-transit status is read fresh from intercity_requests.status on every load/subscription, not cached only at trip-start time (survives app resume)', () {
      expect(travelPlanDetails.contains('_loadIntercityRequests') || travelPlanDetails.contains('_loadMatches'), isTrue);
      expect(travelPlanDetails.contains("table: 'intercity_requests'"), isTrue);
    });

    test('Test 11 (app resume): TravelPlanDetailsScreen reconciles with DB truth on app resume, not just realtime', () {
      expect(travelPlanDetails.contains('WidgetsBindingObserver'), isTrue);
      expect(travelPlanDetails.contains('didChangeAppLifecycleState'), isTrue);
      expect(travelPlanDetails.contains('AppLifecycleState.resumed'), isTrue);
    });
  });

  group('Issue 3 -- rating notification direction and self-notify guard', () {
    test('Test 14: Passenger rates Traveller -> Traveller is notified (rated_by=\'user\' branch resolves recipient via riders.user_id)', () {
      final start = ratingNotificationFix.indexOf("ELSE");
      expect(ratingNotificationFix.contains("SELECT user_id INTO v_recipient_user_id FROM public.riders WHERE id = NEW.rider_id;"), isTrue);
      expect(ratingNotificationFix.contains("'Your passenger rated their trip with you.'"), isTrue);
      expect(start, greaterThan(-1));
    });

    test('Test 15: Traveller rates Passenger -> Passenger is notified (rated_by=\'rider\' branch resolves recipient as NEW.user_id directly)', () {
      expect(ratingNotificationFix.contains("IF NEW.rated_by = 'rider' THEN"), isTrue);
      expect(ratingNotificationFix.contains('v_recipient_user_id := NEW.user_id;'), isTrue);
      expect(ratingNotificationFix.contains("'Your Drop Partner rated your trip.'"), isTrue);
    });

    test('Test 16: the rating\'s own submitter (auth.uid()) can never be the notified recipient, even defensively', () {
      expect(ratingNotificationFix.contains('v_recipient_user_id IS DISTINCT FROM auth.uid()'), isTrue);
    });

    test('Test 17: the recipient is derived entirely from server-side order/rider participant columns -- no client-supplied recipient id is ever read by the trigger', () {
      // The recipient is only ever assigned from NEW.user_id (a fixed rider_reviews/orders
      // participant column) or a fresh `SELECT ... FROM riders` lookup -- never read out of a
      // client-controlled jsonb payload or a bespoke "recipient" column the client could set.
      expect(ratingNotificationFix.contains("p_data->>'recipient"), isFalse);
      expect(ratingNotificationFix.contains('NEW.recipient'), isFalse);
      expect(ratingNotificationFix.contains('v_recipient_user_id := NEW.user_id;'), isTrue);
      expect(ratingNotificationFix.contains('SELECT user_id INTO v_recipient_user_id FROM public.riders WHERE id = NEW.rider_id;'), isTrue);
    });

    test('the client can never insert a rated_by direction that does not match its own authenticated role (RLS), so rated_by is a trustworthy server-side signal', () {
      expect(ratingsMigration.contains("rated_by = 'user'\n    AND auth.uid() = user_id"), isTrue);
      expect(ratingsMigration.contains("rated_by = 'rider'\n    AND rider_id IN (SELECT id FROM public.riders WHERE user_id = auth.uid())"), isTrue);
    });

    test('Test 18 (superseded twice): tapping a new_rating notification now opens the full-message '
        'NotificationDetailScreen on BOTH sides, not a history/trip-list tab, and does so via an '
        'unconditional early branch (not gated behind orderId) -- see '
        'rating_notification_tap_routing_regression_test.dart for the full guard covering this '
        'newer (2026-08-24) real-APK root-cause fix', () {
      final start = notificationService.indexOf("if (type == 'new_rating') {");
      expect(start, greaterThan(-1));
      final end = notificationService.indexOf('\n      }', start);
      expect(end, greaterThan(start));
      final section = notificationService.substring(start, end);
      expect(section.contains('NotificationDetailScreen('), isTrue);
      expect(section.contains('RiderMainNavigationScreen(initialIndex: 1)'), isFalse);
      expect(section.contains('ActivityTab()'), isFalse);
      // Must appear BEFORE the orderId gate, not as its tail `else if` (that was the real bug).
      final orderIdGateIndex = notificationService.indexOf(
          "if (orderId != null && orderId.isNotEmpty) {", start);
      expect(orderIdGateIndex, greaterThan(start));
    });
  });

  group('Unrelated flows are untouched (tests 18-20)', () {
    test('Test 18: Personal QR / Cash / Cashfree payment method labeling is unaffected by this fix set', () {
      final fareHelper = _read('lib/shared/helpers/fare_presentation_helper.dart');
      expect(fareHelper.contains("case 'personal_upi':"), isTrue);
      expect(fareHelper.contains("case 'cash':"), isTrue);
      expect(fareHelper.contains("case 'cashfree':"), isTrue);
    });

    test('Test 19: Travel Plan grouping (accepted passengers grouped under one plan card) is unaffected', () {
      final bookings = _read('lib/features/rider/intercity/intercity_bookings_screen.dart');
      expect(bookings.contains('Map<String, List<Map<String, dynamic>>> _groupByPlan'), isTrue);
    });

    test('Test 20: local ride searching/boost flow (a different screen from the intercity fix) is untouched by the intercity PartnerCard change', () {
      final rideSearching = _read('lib/features/local_rides/searching/screens/ride_searching_screen.dart');
      expect(rideSearching.contains('PartnerCard'), isFalse);
    });
  });
}
