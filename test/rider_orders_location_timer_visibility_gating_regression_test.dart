// Regression guard for the RiderOrdersScreen background-timer visibility gating (performance
// pass).
//
// CONTEXT: RiderMainNavigationScreen keeps RiderOrdersScreen mounted at all times via IndexedStack
// (so state survives switching to Home/Earnings/Profile and back). Of its three Timer.periodic
// instances, only startLocationTimer() (10s fallback poll for fetchSearchingOrders(), itself
// already gated by a realtime-health check) is safe to pause while the tab is off-screen: the
// realtime subscription that actually delivers incoming-order sound/badge stays live regardless
// (see listenSearchingOrders()), so pausing this pure duplicate-detection fallback cannot break
// that path. The other two must NEVER be gated:
//   - startExpiryTimer() (1s) writes rider_assignments.assignment_status = 'expired' to the DB --
//     an audited "assignment expiry write behavior" that must run regardless of tab visibility.
//   - startActiveOrderPollTimer() (30s) drives _pollActiveOrderFallback(), which on a busy->free
//     transition calls rider_self_rematch() (see
//     rider_orders_busy_to_free_refetch_regression_test.dart) -- part of the redispatch/matching
//     pipeline, which must also run regardless of tab visibility.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('RiderOrdersScreen -- only startLocationTimer() is gated by isActive', () {
    final source = _read('lib/features/rider/orders/rider_orders_screen.dart');

    test('the widget exposes an isActive flag defaulting to true (safe for any caller that '
        'does not pass it)', () {
      expect(source.contains('final bool isActive;'), isTrue);
      expect(source.contains('this.isActive = true,'), isTrue);
    });

    test('startLocationTimer() returns early when the tab is not active', () {
      final start = source.indexOf('void startLocationTimer() {');
      final end = source.indexOf('void startExpiryTimer() {');
      final body = source.substring(start, end);
      expect(body.contains('if (!widget.isActive) return;'), isTrue);
    });

    test('startExpiryTimer() is NOT gated by isActive (must keep writing expiry regardless of '
        'visibility)', () {
      final start = source.indexOf('void startExpiryTimer() {');
      final end = source.indexOf('void _filterExpiredAssignmentsFromState()');
      final body = source.substring(start, end);
      expect(body.contains('widget.isActive'), isFalse);
    });

    test('startActiveOrderPollTimer() is NOT gated by isActive (must keep triggering the '
        'busy->free rematch regardless of visibility)', () {
      final start = source.indexOf('void startActiveOrderPollTimer() {');
      final end = source.indexOf('Future<void> listenActiveOrder()');
      final body = source.substring(start, end);
      expect(body.contains('widget.isActive'), isFalse);
    });

    test('realtime subscriptions (listenSearchingOrders/listenActiveOrder/listenRiderStatus) are '
        'not gated by isActive', () {
      expect(source.indexOf('void listenSearchingOrders() {'), greaterThanOrEqualTo(0));
      final listenSearchingBody = source.substring(
        source.indexOf('void listenSearchingOrders() {'),
        source.indexOf('void _processAndFilterAssignments('),
      );
      expect(listenSearchingBody.contains('widget.isActive'), isFalse);
    });

    test('didUpdateWidget refreshes immediately and resumes startLocationTimer() when the tab '
        'becomes active again, and cancels the timer when it becomes inactive', () {
      final start = source.indexOf('void didUpdateWidget(covariant RiderOrdersScreen oldWidget)');
      final end = source.indexOf('void dispose() {');
      final body = source.substring(start, end);
      expect(body.contains('widget.isActive != oldWidget.isActive'), isTrue);
      expect(body.contains('fetchSearchingOrders();'), isTrue);
      expect(body.contains('startLocationTimer();'), isTrue);
      expect(body.contains('_locationTimer?.cancel();'), isTrue);
    });
  });

  group('RiderMainNavigationScreen -- wires isActive to the Orders tab position', () {
    final source = _read('lib/features/rider/navigation/rider_main_navigation_screen.dart');

    test('RiderOrdersScreen receives isActive: _index == 1 (Orders is always index 1 when '
        'present)', () {
      expect(source.contains("RiderOrdersScreen(key: const ValueKey('orders'), isActive: _index == 1)"),
          isTrue);
    });
  });
}
