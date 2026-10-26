// Structural regression guard for the local-ride "~17 second delay before an eligible Drop
// Partner sees a new request" fix. This does not run the app or the Edge Function -- it inspects
// the dispatch/discovery source files themselves so a future edit that reintroduces the old flat
// 15s no-match cooldown, or that regresses the realtime-first / dedup / reconciliation behavior on
// the rider side, fails CI immediately instead of only being caught on a real device.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('start-dispatch: no-match retry no longer flatly waits 15s on the very first attempts', () {
    final dispatch = _read('supabase/functions/start-dispatch/index.ts');

    test('early iterations retry with a short cooldown instead of the old flat 15000ms', () {
      // The literal `anyAssignmentsSent ? 5000 : 15000` line was the single dominant contributor
      // to the reported ~17s gap (a Round 1 miss on iteration 1 -- even for a genuinely eligible,
      // already-online rider just inside the matching radius -- forced a full 15s wait before
      // iteration 2 tried again). It must be gone, replaced by a short cooldown for the first few
      // iterations.
      expect(dispatch.contains('anyAssignmentsSent ? 5000 : 15000'), isFalse);
      expect(dispatch.contains('earlyRetryIterationLimit'), isTrue);
      expect(dispatch.contains('sleepTimeMs = 2000'), isTrue);
    });

    test('the slower 15s cooldown still exists as the eventual fallback for a genuinely empty area', () {
      // Must not be removed outright -- orders with no nearby riders at all still need to back off
      // to avoid hammering the DB indefinitely.
      expect(dispatch.contains('sleepTimeMs = 15000'), isTrue);
      // The successful-round cooldown (5s before checking for more riders after a send) is
      // untouched.
      expect(dispatch.contains('sleepTimeMs = 5000'), isTrue);
    });

    test('matching/eligibility rules are untouched by the timing fix', () {
      // Radius, vehicle/service-mode, KYC, and active-order exclusion all still flow through
      // find_nearby_riders with the same round configuration -- only retry cadence changed.
      expect(dispatch.contains('find_nearby_riders'), isTrue);
      expect(dispatch.contains('p_radius_km: roundConfig.radius'), isTrue);
      expect(dispatch.contains('radius: config.round_1_radius_km'), isTrue);
      expect(dispatch.contains('radius: config.round_2_radius_km'), isTrue);
    });

    test('assignments are still upserted (never plain inserted) so re-matching cannot duplicate a row', () {
      // onConflict: order_id,rider_id is what prevents the faster retry cadence from ever
      // creating two "sent" rows for the same order+rider pair.
      expect(dispatch.contains("onConflict: \"order_id,rider_id\""), isTrue);
    });
  });

  group('Rider-side discovery is realtime-driven, not a long poll', () {
    final homeTab = _read('lib/features/rider/home/rider_home_tab.dart');
    final ordersScreen = _read('lib/features/rider/orders/rider_orders_screen.dart');

    test('RiderHomeTab shows an incoming order from the rider_assignments INSERT event itself', () {
      expect(homeTab.contains("table: 'rider_assignments'"), isTrue);
      expect(homeTab.contains('PostgresChangeEvent.insert'), isTrue);
      // WayDrop bug-fix pass (intercity match must not play the local incoming-ride sound): the
      // INSERT handler now resolves order_type before announcing, via
      // _resolveOrderTypeAndShowIncomingOrder(assignment), which itself calls
      // _showIncomingOrder(assignment, orderType: orderType) -- see
      // intercity_match_no_local_sound_regression_test.dart for the full chain.
      expect(homeTab.contains('_resolveOrderTypeAndShowIncomingOrder(assignment)'), isTrue);
    });

    test('RiderOrdersScreen re-fetches immediately off the same realtime INSERT/UPDATE event', () {
      expect(ordersScreen.contains("table: 'rider_assignments'"), isTrue);
      expect(ordersScreen.contains('fetchSearchingOrders()'), isTrue);
    });

    test('the 10s timer on Orders Nearby is a fallback alongside realtime, not the sole path', () {
      // Both listenSearchingOrders() (realtime) and the periodic timer call the same
      // fetchSearchingOrders(); the timer existing is fine as a fallback, but realtime delivery
      // must not have been removed in favor of it.
      expect(ordersScreen.contains('listenSearchingOrders()'), isTrue);
      expect(ordersScreen.contains('Timer.periodic(const Duration(seconds: 10)'), isTrue);
    });
  });

  group('Duplicate delivery and stale/expired requests are handled correctly', () {
    final homeTab = _read('lib/features/rider/home/rider_home_tab.dart');
    final ordersScreen = _read('lib/features/rider/orders/rider_orders_screen.dart');

    test('RiderHomeTab never shows two sheets for the same order id', () {
      expect(homeTab.contains('_announcedOrders.contains(orderId)'), isTrue);
      expect(homeTab.contains('alreadyAnnounced'), isTrue);
    });

    test('RiderOrdersScreen merges assignments by order id (map keyed by orderId), not a growing list', () {
      // mergedMap[orderIdStr] = a naturally collapses a realtime-triggered fetch and a
      // timer-triggered fetch of the same order into a single card -- no duplicate accumulation.
      expect(ordersScreen.contains('mergedMap[orderIdStr] = a'), isTrue);
    });

    test('a responded/cancelled/expired assignment is un-announced so it can be re-shown only if legitimately re-sent', () {
      const terminalStates = "['accepted', 'rejected', 'expired', 'completed', 'cancelled']";
      expect(homeTab.contains(terminalStates), isTrue);
      expect(homeTab.contains('_announcedOrders.remove(orderId)'), isTrue);
    });

    test('reconciliation never re-shows an order the passenger cancelled or another rider took', () {
      expect(homeTab.contains("orderStatus != 'searching' && orderStatus != 'created'"), isTrue);
    });

    test('reconciliation never re-shows an already-expired assignment', () {
      expect(homeTab.contains('now.isAfter(expiresAt)'), isTrue);
    });
  });

  group('Foreground resume reconciles pending requests instead of waiting for the next poll', () {
    final homeTab = _read('lib/features/rider/home/rider_home_tab.dart');

    test('didChangeAppLifecycleState(resumed) triggers loadRider(), which reconciles', () {
      expect(homeTab.contains('AppLifecycleState.resumed'), isTrue);
      final resumeStart = homeTab.indexOf('void didChangeAppLifecycleState');
      final resumeEnd = homeTab.indexOf('@override', resumeStart + 1);
      expect(resumeStart, greaterThan(-1));
      final resumeSource = homeTab.substring(resumeStart, resumeEnd);
      expect(resumeSource.contains('loadRider();'), isTrue);
    });

    test('loadRider() calls _reconcilePendingAssignments, not just the realtime subscribe calls', () {
      final loadRiderStart = homeTab.indexOf('Future<void> loadRider({');
      final loadRiderEnd = homeTab.indexOf('Future<void> loadActiveOrder');
      expect(loadRiderStart, greaterThan(-1));
      expect(loadRiderEnd, greaterThan(loadRiderStart));
      final loadRiderSource = homeTab.substring(loadRiderStart, loadRiderEnd);
      expect(loadRiderSource.contains('_reconcilePendingAssignments(rider!['), isTrue);
    });

    test('_reconcilePendingAssignments queries sent assignments directly, not a cached/stale list', () {
      expect(homeTab.contains("Future<void> _reconcilePendingAssignments(String riderId)"), isTrue);
      expect(homeTab.contains(".eq('assignment_status', 'sent')"), isTrue);
    });
  });
}
