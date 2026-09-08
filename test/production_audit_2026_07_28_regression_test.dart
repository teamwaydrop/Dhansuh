// Structural regression guard for the fixes made during the 2026-07-28 production audit:
// Cashfree QR investigation, Intercity double-price, "1 user travelling" notification deep link,
// Travel Together acceptance staying on its Travel Plan, same-day countdown default, and Intercity
// Travel Together completion skipping payment collection. Like the other *_regression_test.dart
// files in this repo, this inspects source files directly rather than running the app -- these
// screens are too Supabase-coupled to unit-test as widgets, but the specific lines that caused each
// bug are cheap and durable to lock in as plain string/structure assertions.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('F. Same-day Travel Plan countdown ("Travel will start in 24 hours")', () {
    final postPlanScreen = _read('lib/features/rider/travel_plans/screens/post_travel_plan_screen.dart');

    test('the date field defaults to now, not now + 24h', () {
      // The bug: DateTime.now().add(Duration(hours: 24)) was both the initial `selectedDate` and
      // the date-picker's initialDate, so a Drop Partner who only touched the Time field (leaving
      // the date untouched, believing "today" was already selected) silently got tomorrow's date.
      expect(postPlanScreen.contains('DateTime.now().add(const Duration(hours: 24))'), isFalse);
      expect(
        RegExp(r'DateTime\s+selectedDate\s*=\s*DateTime\.now\(\)\s*;').hasMatch(postPlanScreen),
        isTrue,
        reason: 'selectedDate must default to DateTime.now(), not a +24h offset',
      );
    });
  });

  group('G/H. Intercity Travel Together completion no longer skips payment_pending', () {
    final bookingsScreen = _read('lib/features/rider/intercity/intercity_bookings_screen.dart');
    final updateOrderStatus = _read('supabase/functions/update-order-status/index.ts');

    test('_verifyOtp no longer writes order_status=completed directly to the orders table', () {
      final verifyOtpStart = bookingsScreen.indexOf('Future<void> _verifyOtp(');
      final verifyOtpEnd = bookingsScreen.indexOf('\n  Future<void> _resendOtp');
      expect(verifyOtpStart, greaterThan(-1));
      expect(verifyOtpEnd, greaterThan(verifyOtpStart));
      final body = bookingsScreen.substring(verifyOtpStart, verifyOtpEnd);

      // Must route through the guarded state machine (update-order-status), never a direct
      // Supabase table write to 'completed' -- a direct write is exactly what let a payable
      // Travel Together ride complete with zero fare collection.
      expect(body.contains("'order_status': 'completed'"), isFalse,
          reason: '_verifyOtp must not directly complete a payable order');
      expect(body.contains('functions.invoke('), isTrue);
      expect(body.contains("'update-order-status'"), isTrue);
      expect(body.contains("'new_status': 'payment_pending'"), isTrue);

      // And it must hand off to the same driver-side collection screen local rides already use
      // (Personal QR / Cashfree QR / Cash), instead of duplicating that financial UI.
      expect(body.contains('RiderActiveOrderScreen(orderId: orderId)'), isTrue);
    });

    test('the now-redundant client-side travel-plan auto-complete helper was removed, not left dead', () {
      // update-order-status's own server-side sync (below) now owns this, since _verifyOtp routes
      // through it -- keeping both would risk them disagreeing on when a plan is "done". (Historical
      // mentions of the old name in comments are fine -- only the declaration must be gone.)
      expect(bookingsScreen.contains('Future<void> _completeTravelPlanIfDone('), isFalse);
    });

    test('update-order-status allows rider_at_drop -> payment_pending for ride-type orders', () {
      final rideTransitionsStart = updateOrderStatus.indexOf('const rideTransitions = {');
      final rideTransitionsEnd = updateOrderStatus.indexOf('const parcelTransitions = {');
      expect(rideTransitionsStart, greaterThan(-1));
      expect(rideTransitionsEnd, greaterThan(rideTransitionsStart));
      final rideTransitions = updateOrderStatus.substring(rideTransitionsStart, rideTransitionsEnd);

      expect(rideTransitions.contains('rider_at_drop: ["payment_pending"]'), isTrue);
      // The existing local-ride path (ongoing -> payment_pending -> completed) must be unchanged.
      expect(rideTransitions.contains('ongoing: ["payment_pending"]'), isTrue);
      expect(rideTransitions.contains('payment_pending: ["completed"]'), isTrue);
    });

    // UPDATED (Product/flow fix -- local parcel payment confirmation flow): parcelTransitions was
    // deliberately widened after this original G/H fix to give local/intercity parcel deliveries
    // the same payment_pending stop rides already had -- a partner completing a drop can no longer
    // jump straight to "delivered" without a payment confirmation step in between. This replaces
    // the old "parcels keep their existing flow" assertion, which encoded the pre-fix state as a
    // guard; that premise is now intentionally reversed by design, not regressed.
    test('parcelTransitions now stops at payment_pending before delivered too (rider_at_drop -> payment_pending -> delivered)', () {
      final parcelTransitionsStart = updateOrderStatus.indexOf('const parcelTransitions = {');
      final parcelTransitionsEnd = updateOrderStatus.indexOf('};', parcelTransitionsStart);
      final parcelTransitions = updateOrderStatus.substring(parcelTransitionsStart, parcelTransitionsEnd);
      expect(parcelTransitions.contains('rider_at_drop: ["payment_pending"]'), isTrue,
          reason: 'a parcel drop must stop at payment_pending, never jump straight to delivered');
      expect(parcelTransitions.contains('payment_pending: ["delivered"]'), isTrue,
          reason: 'delivered must only be reachable from payment_pending, once payment is confirmed');
    });

    test('the payment-pending completion guard (cashfree/personal_upi/cash, driver-only attestation) also covers a parcel\'s payment_pending -> delivered, not just a ride\'s -> completed', () {
      expect(
        updateOrderStatus.contains(
          'if (currentStatus === "payment_pending" && (new_status === "completed" || new_status === "delivered")) {',
        ),
        isTrue,
      );
    });

    test('server-side travel-plan/intercity_requests completion sync still exists (now actually reachable)', () {
      expect(updateOrderStatus.contains('UPDATE TRAVEL PLANS STATUS ON COMPLETED INTERCITY RIDES/PARCELS'),
          isTrue);
      expect(updateOrderStatus.contains("SYNC THE LINKED intercity_requests NEGOTIATION ROW"), isTrue);
    });
  });

  group('C. Legacy same-day/exact-city ad-hoc traveller query stays removed', () {
    // The original "C" fix (2026-07-28) made AvailableTravelersScreen reuse the real matcher
    // instead of a stricter ad-hoc query. That whole screen (the Traveller-side browse/invite
    // flow it belonged to) was later removed entirely -- see
    // reverse_traveller_invitation_removed_regression_test.dart -- so only the still-relevant
    // half of this guard remains: the superseded query must not quietly come back.
    final matchingService =
        _read('lib/features/intercity/shared/services/intercity_matching_service.dart');

    test('the stricter same-day/exact-city ad-hoc query is gone', () {
      expect(matchingService.contains('fetchAvailableTravelersForDate'), isFalse);
    });
  });

  group('B. Intercity Travel Together fare is always the passenger\'s own order total', () {
    final availablePartnersScreen =
        _read('lib/features/user/intercity/screens/available_partners_screen.dart');
    final partnerCard = _read('lib/features/intercity/shared/widgets/partner_card.dart');

    test('proposedFare on the User-initiated Travel Together path no longer uses price_per_seat', () {
      final fnStart = availablePartnersScreen.indexOf('Future<void> _travelTogether(');
      final fnEnd = availablePartnersScreen.indexOf('\n  @override', fnStart);
      expect(fnStart, greaterThan(-1));
      final body = availablePartnersScreen.substring(fnStart, fnEnd);

      expect(body.contains("partner['price_per_seat']"), isFalse,
          reason: 'must not price a Travel Together request off the traveller\'s own route fare');
      expect(body.contains("orderRow?['final_fare'] ?? orderRow?['current_fare']"), isTrue,
          reason: 'must use the passenger\'s own order\'s canonical payable fare');
    });

    test('PartnerCard can display the viewer\'s own fare instead of the traveller\'s price_per_seat', () {
      expect(partnerCard.contains('final double? yourFare;'), isTrue);
      expect(partnerCard.contains('yourFare ?? pricePerSeat'), isTrue);
    });
  });

  group('D/E. Accepting a Travel Together request keeps the Drop Partner on its Travel Plan', () {
    final travelPlanDetails =
        _read('lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart');

    test('_acceptIntercityRequest no longer force-navigates away from the plan on success', () {
      final fnStart = travelPlanDetails.indexOf('Future<void> _acceptIntercityRequest(');
      final fnEnd = travelPlanDetails.indexOf('\n  }', travelPlanDetails.indexOf('} finally {', fnStart));
      expect(fnStart, greaterThan(-1));
      final body = travelPlanDetails.substring(fnStart, fnEnd);

      expect(body.contains('Navigator.pop(context); // Close details page'), isFalse);
      // The plan's own accepted-requests list must still refresh in place.
      expect(body.contains('await _loadIntercityRequests();'), isTrue);
      // 2026-08-02 fix: the "VIEW ORDER" jump-away action was removed entirely and replaced with
      // an OK-only "Request Accepted" dialog -- the traveller can no longer navigate off this
      // page at all from this confirmation, forced or optional.
      expect(body.contains('RiderActiveOrderScreen(orderId: orderId)'), isFalse);
      expect(body.contains('VIEW ORDER'), isFalse);
      expect(body.contains("'Request Accepted'"), isTrue);
    });
  });
}
