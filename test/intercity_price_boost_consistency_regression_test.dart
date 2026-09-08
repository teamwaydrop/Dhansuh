// Regression guard for PHASE 3, Issue 4: a passenger's fare boost must be reflected consistently
// on every screen -- Travel Plan Details, Intercity Bookings negotiations/history, matching --
// never the stale base amount.
//
// ROOT CAUSE: orders.final_fare/current_fare (written correctly by boost-order-fare) is the single
// authoritative post-boost amount -- already correctly used, unmodified, by
// complete_intercity_parcel_delivery(). intercity_requests.proposed_fare is a denormalized
// snapshot taken once at request-send time. increaseFare()'s existing best-effort re-sync used the
// WRONG COLUMN NAME (.eq('order_id', ...) -- intercity_requests has no such column, only
// 'parcel_id'), so it silently failed on every call, not just for narrow statuses.
// retrySearchWithBoost() (the "boost & search again" timeout path) never attempted a sync at all.
// Multiple screens read the stale proposed_fare as primary/sole source instead of the fresh order
// fare they already have joined/in-scope.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('intercity_searching_screen.dart -- both boost paths sync proposed_fare correctly', () {
    final source = _read('lib/features/intercity/shared/screens/intercity_searching_screen.dart');

    test('_syncProposedFareToRequest uses the correct column (parcel_id, not order_id) and covers '
        'all three pre-confirmed negotiation statuses', () {
      final start = source.indexOf('Future<void> _syncProposedFareToRequest(double serverFare) async {');
      final end = source.indexOf('Future<void> increaseFare(', start);
      expect(start, greaterThanOrEqualTo(0));
      final body = source.substring(start, end);
      expect(body.contains("eq('parcel_id', widget.orderId)"), isTrue);
      expect(body.contains("eq('order_id', widget.orderId)"), isFalse);
      expect(
        body.contains("inFilter('status', ['request_sent', 'discussion_started', 'fare_agreed'])"),
        isTrue,
      );
    });

    test('increaseFare() calls the shared sync helper', () {
      final start = source.indexOf('Future<void> increaseFare(double nextFare, int boost) async {');
      final end = source.indexOf('} catch (e) {\n      debugPrint(\'BOOST ERROR', start);
      final body = source.substring(start, end);
      expect(body.contains('await _syncProposedFareToRequest(serverFare);'), isTrue);
    });

    test('retrySearchWithBoost() (previously had NO sync at all) now also calls the shared sync '
        'helper', () {
      final start = source.indexOf('Future<void> retrySearchWithBoost(double nextFare) async {');
      final end = source.indexOf('} catch (e) {\n      debugPrint(\'RETRY BOOST ERROR', start);
      expect(start, greaterThanOrEqualTo(0));
      final body = source.substring(start, end);
      expect(body.contains('await _syncProposedFareToRequest(serverFare);'), isTrue);
    });
  });

  group('travel_plan_details_screen.dart -- prefers the authoritative fresh order fare over the '
      'proposed_fare snapshot at every display site', () {
    final source = _read('lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart');

    test('both "Accept Request (₹amt)" render paths (the duplicated card + sheet variants) prefer '
        "order['final_fare']/order['current_fare'] before req['proposed_fare']", () {
      // Phase 11 (Issue 1) superseded the exact string this test originally asserted: preferring
      // final_fare/current_fare before proposed_fare was correct, but the raw, unrounded
      // proposed_fare fallback (`.toString() ?? '0'`, no parsing/rounding at all) was itself the
      // "₹65.79 before accept, ₹66.00 after" bug -- proposed_fare is only ever a display value
      // before an order has final_fare/current_fare, and must be rounded exactly like
      // accept_intercity_request() rounds it server-side the instant it's accepted. Both sites now
      // check order['final_fare']/current_fare first, falling back to
      // roundFareForDisplay(proposed_fare) -- same priority order, no longer a raw fallback.
      final occurrences =
          "roundFareForDisplay(double.tryParse(req['proposed_fare']?.toString() ?? '0') ?? 0.0).toString();"
              .allMatches(source)
              .length;
      expect(occurrences, 2);
      expect(
        source.contains("req['proposed_fare'])?.toString() ?? '0';"),
        isFalse,
        reason: 'the raw unrounded proposed_fare fallback must not reappear',
      );
    });

    test('the expected-earnings fold prefers final_fare/current_fare before proposed_fare/actual_fare', () {
      expect(
        source.contains(
          "double.tryParse(order['final_fare']?.toString() ?? order['current_fare']?.toString() ?? "
          "req?['proposed_fare']?.toString() ?? order['actual_fare']?.toString() ?? '0') ?? 0.0;",
        ),
        isTrue,
      );
    });

    test('the per-match card fare prefers final_fare, then current_fare, then proposed_fare, then '
        'actual_fare, in that order', () {
      // Two different "actualFare"/"final actualFare" locals exist in this file -- an older,
      // unrelated one (current_fare/actual_fare only) and the one this fix touched. Anchor on the
      // unique final_fare-first text this fix introduced.
      final start = source.indexOf("final actualFare = double.tryParse(order['final_fare']?.toString() ?? '') ??");
      expect(start, greaterThanOrEqualTo(0));
      final chain = source.substring(start, start + 350);
      final finalIdx = chain.indexOf("order['final_fare']");
      final currentIdx = chain.indexOf("order['current_fare']");
      final proposedIdx = chain.indexOf("req?['proposed_fare']");
      final actualIdx = chain.indexOf("order['actual_fare']");
      expect(finalIdx, greaterThanOrEqualTo(0));
      expect(currentIdx, greaterThan(finalIdx));
      expect(proposedIdx, greaterThan(currentIdx));
      expect(actualIdx, greaterThan(proposedIdx));
    });
  });

  group('intercity_bookings_screen.dart -- authoritative-fare priority fix applied to '
      'active/history tabs (already-accepted requests)', () {
    final source = _read('lib/features/rider/intercity/intercity_bookings_screen.dart');

    // PHASE 1 / ISSUE 1 CORRECTION (20260901000024/25 fix set): the pending-negotiations card
    // (_buildNegotiationsTab, status in request_sent/discussion_started/fare_agreed -- i.e. strictly
    // BEFORE acceptance) was originally included in this "prefer order fare" count too, but that
    // was wrong for that one site specifically: at pre-acceptance time the order's own
    // final_fare/current_fare is still whatever create-order estimated at Travel Request time,
    // while req['proposed_fare'] is the up-to-date negotiated figure the rider is actually about
    // to accept (accept_intercity_request() rounds exactly this field into the order's
    // authoritative fare on acceptance). Showing the stale order fare there could display a
    // completely different number than what acceptance actually produces -- exactly the
    // before/after fare mismatch Phase 1 fixes. See
    // test/phase1_fare_display_consistency_regression_test.dart for the full proof. The other 3
    // sites (plan total fold / active-trip card / history card) all cover ALREADY-accepted
    // requests, where the order's own (possibly since-boosted) fare really is the freshest source
    // -- that priority is correct and unchanged here.
    test('the 3 remaining flagged sites (plan total fold, active-trip card, history card) still '
        'check final_fare/current_fare before falling back to proposed_fare', () {
      final siteCount =
          RegExp(r"final_fare'\]\?\.toString\(\) \?\? .*?current_fare'\]\?\.toString\(\) \?\? .*?proposed_fare'\]\?\.toString\(\) \?\? '0'")
              .allMatches(source)
              .length;
      expect(siteCount, 3);
    });

    test('the pending-negotiations card no longer follows that priority -- it now rounds and '
        'prioritizes proposed_fare directly (Phase 1 fix)', () {
      expect(source.contains('final proposedFare = roundFareForDisplay('), isTrue);
    });
  });

  group('complete_intercity_parcel_delivery() is confirmed untouched by this fix', () {
    test('still reads the fresh, already-boosted order fare -- no base-fare recomputation was '
        'added or removed', () {
      final source = _read(
        'supabase/migrations/20260814000001_fix_complete_intercity_parcel_delivery_enum_cast.sql',
      );
      expect(
        source.contains('v_fare := COALESCE(v_order.final_fare, v_order.current_fare, 0);'),
        isTrue,
      );
    });
  });

  group('P3 pricing dedup is untouched', () {
    test('_inFlightPricingRequests dedup map in pricing_controller.dart is unchanged', () {
      final source = _read('lib/modules/payments/controllers/pricing_controller.dart');
      expect(
        source.contains(
          'final Map<String, Future<MapEntry<String, dynamic>?>> _inFlightPricingRequests = {};',
        ),
        isTrue,
      );
    });
  });
}
