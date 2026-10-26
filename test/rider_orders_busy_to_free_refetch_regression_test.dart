// Regression guard for "eligible pending order isn't reliably shown after a rider completes their
// current ride" (PHASE 1, Issue 1).
//
// CONTEXT: test/rider_freed_rematch_regression_test.dart already proved (14 days of live
// orders/rider_assignments data) that the backend rider-freed rematch pipeline itself is reliable
// (typical rematch lands in 15-28s). This file guards the one remaining client-side gap found by
// re-reading the current rider_orders_screen.dart: _pollActiveOrderFallback() -- the single source
// of truth for hasActiveOrder, invoked by both the 30s active-order poll and listenActiveOrder()'s
// realtime callback -- never proactively re-fetched the pending-orders list the moment a rider's
// busy state cleared. It only relied on the existing realtime channel / 10s poll eventually noticing
// on their own timelines. This mirrors the already-proven wasOffline->online pattern in
// listenRiderStatus() (same file), which DOES force a refetch on that analogous transition.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite for
// invariants that can't be exercised against a live Supabase instance in a plain unit test.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('RiderOrdersScreen -- busy->free transition forces a pending-orders refetch', () {
    final source = _read('lib/features/rider/orders/rider_orders_screen.dart');
    final pollStart = source.indexOf('Future<void> _pollActiveOrderFallback() async {');
    final pollEnd = source.indexOf('void startActiveOrderPollTimer() {');
    final pollBody = source.substring(pollStart, pollEnd);
    final ifIndex = pollBody.indexOf('if ((wasBusy || isFirstPollForThisInstance) && !hasActiveOrder)');
    final catchIndex = pollBody.indexOf('\n    } catch (_) {');

    test('_pollActiveOrderFallback() captures hasActiveOrder before overwriting it '
        '(wasBusy snapshot)', () {
      expect(
        pollBody.contains('final wasBusy = hasActiveOrder;'),
        isTrue,
        reason: 'must snapshot the pre-update busy state to detect the busy->free transition, the '
            'same way listenRiderStatus() snapshots wasOffline before its own setState',
      );
    });

    test('_pollActiveOrderFallback() branches on the busy->free transition, mirroring '
        'listenRiderStatus()\'s wasOffline->online forced refetch', () {
      expect(
        ifIndex,
        greaterThanOrEqualTo(0),
        reason: 'a rider who just finished their active order must get an immediate proactive '
            'refetch, not only the next passive realtime event / 10s poll tick',
      );
      expect(catchIndex, greaterThan(ifIndex));
      expect(pollBody, contains('final isFirstPollForThisInstance = !_hasPolledActiveOrderOnce;'));
      expect(pollBody, contains('_hasPolledActiveOrderOnce = true;'));
    });

    test('the busy->free branch calls fetchSearchingOrders()', () {
      final ifBlock = pollBody.substring(ifIndex, catchIndex);
      expect(ifBlock.indexOf("await supabase.rpc('rider_self_rematch');"),
          lessThan(ifBlock.indexOf('fetchSearchingOrders();')));
      expect(
        ifBlock.contains('fetchSearchingOrders();'),
        isTrue,
        reason: 'the transition branch must actually trigger a fresh pending-orders fetch',
      );
    });

    test('the forced refetch is scoped to the busy->free transition only, not fired '
        'unconditionally elsewhere in this method (would reintroduce excessive polling)', () {
      final beforeIf = pollBody.substring(0, ifIndex);
      expect(
        beforeIf.contains('fetchSearchingOrders();'),
        isFalse,
        reason: '_pollActiveOrderFallback() must not call fetchSearchingOrders() outside the '
            'wasBusy->free guard',
      );
    });

    test('the pre-existing busy-rider UI gate (hasActiveOrder hides the pending-orders list) is '
        'unchanged -- a still-busy rider must never see another order', () {
      final buildSource = source.substring(
        source.indexOf('Widget buildOrdersList('),
        source.indexOf('Widget buildOrderCard('),
      );
      expect(buildSource.contains('if (hasActiveOrder) {'), isTrue);
      expect(buildSource.contains('Active Ride in Progress'), isTrue);
    });
  });
}
