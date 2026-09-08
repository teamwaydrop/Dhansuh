// Regression guard for the RiderHomeTab / RiderActiveOrderScreen duplicate-work fix
// (WayDrop Phase H performance pass).
//
// ROOT CAUSE (confirmed via a full-chain audit, not assumed): RiderHomeTab lives inside
// RiderMainNavigationScreen's IndexedStack and never unmounts. When RiderActiveOrderScreen is
// pushed on top of it, RiderHomeTab's own subscribeActiveOrder() (a *separate* realtime
// subscription to the same `orders` row, filtered by rider_id instead of id) keeps firing on every
// status/fare change and, on every single event, re-runs loadActiveOrder() + loadRider() (three DB
// queries) and rebuilds this off-screen tab -- duplicating work RiderActiveOrderScreen's own
// realtime subscription is already doing for the visible screen. The 30s silent refresh timer
// (loadRider() every 30s) also kept running the whole time, unrelated to any actual order event.
//
// FIX: ActiveOrderScreenState.isOpen (a ValueNotifier, mirroring the existing PipService static-
// flag pattern) is set true/false by RiderActiveOrderScreen's initState()/dispose(). While it's
// true, subscribeActiveOrder()'s callback and the silent refresh timer's body skip their DB
// queries -- the realtime SUBSCRIPTION itself is never removed, only the resulting duplicate work.
// The moment the flag flips back to false, RiderHomeTab reconciles once via
// _onActiveOrderScreenVisibilityChanged() so activeOrders/rider are never left stale.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final homeSource = _read('lib/features/rider/home/rider_home_tab.dart');
  final activeOrderSource =
      _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');
  final flagSource =
      _read('lib/core/services/session/active_order_screen_state.dart');

  group('ActiveOrderScreenState -- the shared flag', () {
    test('is a ValueNotifier<bool>, defaulting to false (matches "not open" for every screen '
        'that never opens RiderActiveOrderScreen)', () {
      expect(flagSource.contains('static final ValueNotifier<bool> isOpen = ValueNotifier<bool>(false);'),
          isTrue);
    });
  });

  group('RiderActiveOrderScreen -- sets the flag around its own lifecycle', () {
    test('initState() sets isOpen = true, alongside the existing PipService.setPipEnabled(true)',
        () {
      final initStart = activeOrderSource.indexOf('void initState() {');
      final initEnd = activeOrderSource.indexOf('void dispose() {');
      expect(initStart, greaterThan(0));
      expect(initEnd, greaterThan(initStart));
      final initBody = activeOrderSource.substring(initStart, initEnd);
      expect(initBody.contains('ActiveOrderScreenState.isOpen.value = true;'), isTrue);
      expect(initBody.contains('PipService.setPipEnabled(true);'), isTrue,
          reason: 'the existing PipService wiring must remain untouched');
    });

    test('dispose() sets isOpen = false, alongside the existing PipService.setPipEnabled(false)',
        () {
      final disposeStart = activeOrderSource.indexOf('void dispose() {');
      expect(disposeStart, greaterThan(0));
      final disposeBody = activeOrderSource.substring(disposeStart, disposeStart + 600);
      expect(disposeBody.contains('ActiveOrderScreenState.isOpen.value = false;'), isTrue);
      expect(disposeBody.contains('PipService.setPipEnabled(false);'), isTrue,
          reason: 'the existing PipService wiring must remain untouched');
      // Every existing cleanup step must still be present -- this fix must not have replaced or
      // removed any of them.
      expect(disposeBody.contains("RealtimeManager.instance.unsubscribe('active-order-\${widget.orderId}', realtimeSubId!);"),
          isTrue);
      expect(disposeBody.contains('timer?.cancel();'), isTrue);
      expect(disposeBody.contains('_localLocationSubscription?.cancel();'), isTrue);
    });
  });

  group('RiderHomeTab.subscribeActiveOrder() -- duplicate DB work suppressed while covered, '
      'subscription itself untouched', () {
    final subStart = homeSource.indexOf('void subscribeActiveOrder(String riderId) {');
    final subEnd = homeSource.indexOf('void subscribeTravelPlans(String riderId) {');
    final subBody = homeSource.substring(subStart, subEnd);

    test('the realtime subscription is still established unconditionally -- only the callback\'s '
        'DB calls are gated, never the subscription itself', () {
      expect(subStart, greaterThan(0));
      expect(subBody.contains('RealtimeManager.instance.subscribe('), isTrue);
      expect(subBody.contains("table: 'orders',"), isTrue);
      expect(subBody.contains("filterColumn: 'rider_id',"), isTrue);
      expect(subBody.contains('event: PostgresChangeEvent.all,'), isTrue);
    });

    test('loadActiveOrder()/loadRider() are now gated on ActiveOrderScreenState.isOpen being '
        'false', () {
      // Callback is now `async` (a later fix awaits loadActiveOrder() here to close a race with
      // pending-assignment reconciliation -- see rider_earnings_and_dispatch_fixes_regression_test)
      // and the orderStatusChanged branch calls loadRider(skipActiveOrderReload: true) rather than
      // a bare loadRider() -- both still gated behind the same isOpen check this test guards.
      final callbackStart = subBody.indexOf('callback: (payload) async {');
      expect(callbackStart, greaterThan(0));
      final callbackBody = subBody.substring(callbackStart);
      expect(callbackBody.contains('if (!ActiveOrderScreenState.isOpen.value) {'), isTrue);
      final gateIdx = callbackBody.indexOf('if (!ActiveOrderScreenState.isOpen.value) {');
      final loadActiveOrderIdx = callbackBody.indexOf('loadActiveOrder(riderId);');
      final loadRiderIdx = callbackBody.indexOf('loadRider(skipActiveOrderReload: true);');
      expect(loadActiveOrderIdx, greaterThan(gateIdx));
      expect(loadRiderIdx, greaterThan(gateIdx));
    });

    test('the _announcedOrders bookkeeping on terminal status stays unconditional (cheap, '
        'in-memory, must run regardless of which screen is open)', () {
      final bookkeepingIdx = subBody.indexOf(
          "if (orderId != null && ['completed', 'delivered', 'cancelled'].contains(orderStatus)) {");
      final gateIdx = subBody.indexOf('if (!ActiveOrderScreenState.isOpen.value) {');
      expect(bookkeepingIdx, greaterThan(0));
      expect(gateIdx, greaterThan(bookkeepingIdx),
          reason: '_announcedOrders cleanup must run before (i.e. outside) the new gate');
    });
  });

  group('RiderHomeTab -- reconciliation when the covering screen closes', () {
    test('_onActiveOrderScreenVisibilityChanged exists and refreshes exactly what '
        'subscribeActiveOrder\'s callback would have', () {
      final fnStart =
          homeSource.indexOf('void _onActiveOrderScreenVisibilityChanged() {');
      expect(fnStart, greaterThan(0));
      final fnBody = homeSource.substring(fnStart, fnStart + 500);
      expect(fnBody.contains('if (ActiveOrderScreenState.isOpen.value) return;'), isTrue,
          reason: 'must only reconcile once the screen has actually closed');
      expect(fnBody.contains('loadActiveOrder('), isTrue);
      expect(fnBody.contains('loadRider();'), isTrue);
    });

    test('the listener is registered in initState() and removed in dispose() (no leak)', () {
      expect(
          homeSource.contains(
              'ActiveOrderScreenState.isOpen.addListener(_onActiveOrderScreenVisibilityChanged);'),
          isTrue);
      expect(
          homeSource.contains(
              'ActiveOrderScreenState.isOpen.removeListener(_onActiveOrderScreenVisibilityChanged);'),
          isTrue);
    });
  });

  group('RiderHomeTab -- 30s silent refresh timer skips its DB call while covered', () {
    test('_startSilentRefreshTimer\'s periodic callback now also checks isOpen, without changing '
        'the timer\'s own start/stop lifecycle', () {
      final fnStart = homeSource.indexOf('void _startSilentRefreshTimer() {');
      final fnEnd = homeSource.indexOf('void _onActiveOrderScreenVisibilityChanged() {');
      expect(fnStart, greaterThan(0));
      expect(fnEnd, greaterThan(fnStart));
      final fnBody = homeSource.substring(fnStart, fnEnd);
      expect(fnBody.contains('if (!widget.isActive) return;'), isTrue,
          reason: 'the existing tab-visibility gate must remain untouched');
      expect(fnBody.contains('Timer.periodic(const Duration(seconds: 30)'), isTrue);
      expect(fnBody.contains('if (mounted && !ActiveOrderScreenState.isOpen.value) {'), isTrue);
    });
  });

  group('Untouched: incoming-order detection, assignment notifications, rider online/offline, '
      'service mode, intercity -- none of these were gated by this fix', () {
    test('subscribeAssignments() is completely unmodified by this fix (no isOpen reference)', () {
      final start = homeSource.indexOf('void subscribeAssignments(String riderId) {');
      final end = homeSource.indexOf('void subscribeActiveOrder(String riderId) {');
      final body = homeSource.substring(start, end);
      expect(body.contains('ActiveOrderScreenState'), isFalse,
          reason: 'assignment notifications must keep working identically regardless of whether '
              'Active Order is open');
    });

    test('subscribeRider() is completely unmodified by this fix (no isOpen reference)', () {
      final start = homeSource.indexOf('void subscribeRider(String riderId) {');
      final end = homeSource.indexOf(
          'Future<void> _updateActiveAssignmentsBadge(String rId) async {');
      final body = homeSource.substring(start, end);
      expect(body.contains('ActiveOrderScreenState'), isFalse,
          reason: 'rider online/offline state must keep updating identically');
    });

    test('subscribeTravelPlans() is completely unmodified by this fix (no isOpen reference)', () {
      final start = homeSource.indexOf('void subscribeTravelPlans(String riderId) {');
      final end = homeSource.indexOf('void _unsubscribeTravelPlans() {');
      final body = homeSource.substring(start, end);
      expect(body.contains('ActiveOrderScreenState'), isFalse,
          reason: 'intercity travel plan functionality must keep working identically');
    });

    test('_showIncomingOrder\'s pre-existing busy-rider guard is untouched -- incoming-order '
        'suppression while busy already comes from this path, not from this fix', () {
      expect(
          homeSource.contains(
              'if (activeOrders.isNotEmpty) {'),
          isTrue);
    });
  });
}
