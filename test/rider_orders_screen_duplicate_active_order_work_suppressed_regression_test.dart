// Regression guard for the RiderOrdersScreen duplicate active-order-tracking fix
// (WayDrop Phase J performance pass).
//
// ROOT CAUSE (confirmed via a full-chain audit, not assumed): RiderOrdersScreen lives inside
// RiderMainNavigationScreen's IndexedStack and never unmounts -- the exact same class of bug
// Phase H already fixed for RiderHomeTab, but present here too, undiscovered until this phase:
//
// 1. _activeOrderPollTimer (30s) and listenActiveOrder()'s realtime subscription (a *separate*
//    subscription to the same `orders` row RiderActiveOrderScreen already tracks, filtered by
//    rider_id instead of id) both call _pollActiveOrderFallback() -- a DB query -- on every order
//    event/tick, duplicating work RiderActiveOrderScreen's own realtime subscription is already
//    doing for the visible screen, for the entire time it's open.
// 2. Two OTHER realtime callbacks in this same file (_ordersSubId on rider_assignments,
//    _ordersUpdateSubId on orders) call fetchSearchingOrders() (2 DB queries) on every event --
//    but, unlike the sibling startLocationTimer(), neither checked the already-established
//    `hasActiveOrder` invariant ("a busy rider can never be assigned new dispatch work") before
//    doing so, so a fresh searching-orders query ran on every single status change during an
//    active ride even though it could never find anything new.
//
// FIX: reuses the exact ActiveOrderScreenState.isOpen flag Phase H introduced (no new
// architecture). While RiderActiveOrderScreen is open, hasActiveOrder is set synchronously (true
// by construction -- that screen is only ever open for an active order) instead of re-verified via
// query; _pollActiveOrderFallback() calls are skipped from both the timer and the realtime
// callback. The moment the covering screen closes, _onActiveOrderScreenVisibilityChanged() polls
// once immediately -- this is what actually detects a busy->free transition and fires
// rider_self_rematch(), so that dispatch-critical behavior fires at the same or an earlier point
// than it possibly could have while the rider's own active-order screen was still open for it.
// The two fetchSearchingOrders() call sites are now gated on `!hasActiveOrder`, mirroring
// startLocationTimer()'s own pre-existing guard exactly.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final source = _read('lib/features/rider/orders/rider_orders_screen.dart');

  group('RiderOrdersScreen -- wired to ActiveOrderScreenState (Phase H\'s shared flag reused)', () {
    test('imports active_order_screen_state.dart', () {
      expect(
          source.contains(
              "import 'package:waydrop/core/services/session/active_order_screen_state.dart';"),
          isTrue);
    });

    test('the listener is registered in initState() and removed in dispose() (no leak)', () {
      expect(
          source.contains(
              'ActiveOrderScreenState.isOpen.addListener(_onActiveOrderScreenVisibilityChanged);'),
          isTrue);
      expect(
          source.contains(
              'ActiveOrderScreenState.isOpen.removeListener(_onActiveOrderScreenVisibilityChanged);'),
          isTrue);
    });
  });

  group('_onActiveOrderScreenVisibilityChanged -- reconciliation', () {
    final fnStart = source.indexOf('void _onActiveOrderScreenVisibilityChanged() {');
    final fnEnd = source.indexOf('void startActiveOrderPollTimer() {');
    final fnBody = fnStart >= 0 && fnEnd > fnStart ? source.substring(fnStart, fnEnd) : '';

    test('exists, and sets hasActiveOrder=true synchronously while covered (no DB call)', () {
      expect(fnStart, greaterThan(0));
      expect(fnBody.contains('if (ActiveOrderScreenState.isOpen.value) {'), isTrue);
      expect(fnBody.contains('setState(() => hasActiveOrder = true);'), isTrue);
    });

    test('polls once (the real dispatch-critical path) the moment the screen closes', () {
      expect(fnBody.contains('_pollActiveOrderFallback();'), isTrue);
      final ifOpenIdx = fnBody.indexOf('if (ActiveOrderScreenState.isOpen.value) {');
      final pollIdx = fnBody.indexOf('_pollActiveOrderFallback();');
      expect(pollIdx, greaterThan(ifOpenIdx),
          reason: 'the poll call must be reachable only after the isOpen branch returns, i.e. '
              'only when the screen has actually closed');
    });
  });

  group('startActiveOrderPollTimer() -- 30s timer skips its DB call while covered', () {
    test('the timer\'s own start/stop lifecycle is unchanged; only its body gates on isOpen', () {
      final fnStart = source.indexOf('void startActiveOrderPollTimer() {');
      final fnEnd = source.indexOf('Future<void> listenActiveOrder() async {');
      expect(fnStart, greaterThan(0));
      expect(fnEnd, greaterThan(fnStart));
      final fnBody = source.substring(fnStart, fnEnd);
      expect(fnBody.contains('Timer.periodic(const Duration(seconds: 30)'), isTrue);
      expect(fnBody.contains('if (ActiveOrderScreenState.isOpen.value) return;'), isTrue);
      expect(fnBody.contains('_pollActiveOrderFallback();'), isTrue);
    });
  });

  group('listenActiveOrder() -- realtime callback skips its DB call while covered, '
      'subscription itself untouched', () {
    final fnStart = source.indexOf('Future<void> listenActiveOrder() async {');
    final fnEnd = source.indexOf('// =========================================================\n'
        '  // FILTERING BY RADIUS & VEHICLE TYPE');
    final fnBody = fnStart >= 0 && fnEnd > fnStart ? source.substring(fnStart, fnEnd) : '';

    test('the realtime subscription is still established unconditionally', () {
      expect(fnStart, greaterThan(0));
      expect(fnBody.contains('RealtimeManager.instance.subscribe('), isTrue);
      expect(fnBody.contains("table: 'orders',"), isTrue);
      expect(fnBody.contains("filterColumn: 'rider_id',"), isTrue);
    });

    test('the initial snapshot poll at setup is NOT gated (must always run once)', () {
      final initialPollIdx = fnBody.indexOf('await _pollActiveOrderFallback();');
      final subscribeIdx = fnBody.indexOf('RealtimeManager.instance.subscribe(');
      expect(initialPollIdx, greaterThan(0));
      expect(initialPollIdx, lessThan(subscribeIdx),
          reason: 'the one-time initial snapshot must run before the subscription is even set up, '
              'and is unconditional');
    });

    test('the realtime callback\'s own poll call is gated on isOpen', () {
      final callbackIdx = fnBody.indexOf('callback: (payload) {');
      final callbackBody = fnBody.substring(callbackIdx);
      expect(callbackBody.contains('if (ActiveOrderScreenState.isOpen.value) return;'), isTrue);
      final gateIdx = callbackBody.indexOf('if (ActiveOrderScreenState.isOpen.value) return;');
      final pollIdx = callbackBody.indexOf('_pollActiveOrderFallback();');
      expect(pollIdx, greaterThan(gateIdx));
    });
  });

  group('fetchSearchingOrders() call sites -- now gated on hasActiveOrder, matching the '
      'pre-existing startLocationTimer() invariant', () {
    test('startLocationTimer()\'s pre-existing hasActiveOrder guard is untouched (baseline '
        'invariant this fix reuses)', () {
      final start = source.indexOf('void startLocationTimer() {');
      final end = source.indexOf('// =========================================================\n'
          '  // REAL-TIME LOCAL EXPIRY TIMER');
      final body = source.substring(start, end);
      expect(body.contains('if (hasActiveOrder) {'), isTrue);
    });

    test('the rider_assignments channel (_ordersSubId) now checks !hasActiveOrder before '
        'fetchSearchingOrders()', () {
      final start = source.indexOf("_ordersSubChannel = 'rider-assignments-\$riderId';");
      final end = source.indexOf("_ordersUpdateSubChannel = 'rider-active-order-\$riderId';");
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);
      expect(body.contains('if (mounted && !hasActiveOrder) {'), isTrue);
      expect(body.contains('fetchSearchingOrders();'), isTrue);
    });

    test('the orders-update channel (_ordersUpdateSubId) now checks !hasActiveOrder before '
        'fetchSearchingOrders()', () {
      final start = source.indexOf("_ordersUpdateSubChannel = 'rider-active-order-\$riderId';");
      final end = source.indexOf('// =========================================================\n'
          '  // FILTERING BY RADIUS & VEHICLE TYPE');
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);
      expect(body.contains('if (mounted && !hasActiveOrder) {'), isTrue);
      expect(body.contains('fetchSearchingOrders();'), isTrue);
      // The unrelated bookkeeping in this same callback (_announcedOrders cleanup) must remain
      // unconditional -- cheap, in-memory, and must run regardless of hasActiveOrder.
      final bookkeepingIdx = body.indexOf(
          "if (orderId != null && ['accepted', 'rejected', 'expired', 'completed', 'cancelled'].contains(orderStatus)) {");
      final gateIdx = body.indexOf('if (mounted && !hasActiveOrder) {');
      expect(bookkeepingIdx, greaterThan(0));
      expect(gateIdx, greaterThan(bookkeepingIdx));
    });
  });

  group('Untouched: assignment-expiry, rider status, and dispatch-critical rematch semantics', () {
    test('rider_self_rematch() is still called synchronously on the busy->free transition, '
        'inside _pollActiveOrderFallback() itself -- untouched by this fix', () {
      final start = source.indexOf('Future<void> _pollActiveOrderFallback() async {');
      final end = source.indexOf('void _onActiveOrderScreenVisibilityChanged() {');
      final body = source.substring(start, end);
      expect(body.contains("await supabase.rpc('rider_self_rematch');"), isTrue);
      expect(body.contains('if (wasBusy && !hasActiveOrder) {'), isTrue);
    });

    test('startExpiryTimer() (assignment expiry) is completely unmodified by this fix', () {
      final start = source.indexOf('void startExpiryTimer() {');
      final end = source.indexOf('void _filterExpiredAssignmentsFromState() {');
      final body = source.substring(start, end);
      expect(body.contains('ActiveOrderScreenState'), isFalse,
          reason: 'assignment expiry must keep working identically regardless of whether Active '
              'Order is open');
    });

    test('listenRiderStatus() (rider online/offline) is completely unmodified by this fix', () {
      final start = source.indexOf('void listenRiderStatus() {');
      final end = source.indexOf('// =========================================================\n'
          '  // LOCATION TRACKING TIMER');
      final body = source.substring(start, end);
      expect(body.contains('ActiveOrderScreenState'), isFalse,
          reason: 'rider online/offline state must keep updating identically');
    });
  });
}
