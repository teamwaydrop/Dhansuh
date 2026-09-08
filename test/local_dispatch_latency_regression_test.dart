// Regression guard for the ">15s local ride dispatch delay" fix.
//
// ROOT CAUSE (confirmed by code inspection, not guessed): create-order/index.ts previously
// triggered start-dispatch only AFTER several sequential `await`ed bookkeeping writes that have no
// bearing on dispatch eligibility (promo usage recording, OTP attempt logging x2, device-token
// linking, parcel/compliance security logs, order_status_history) -- widening the "order created ->
// dispatch begins" gap by however long that chain of round trips took. The LOCAL dispatch branch
// also `await`ed the full `supabase.functions.invoke("start-dispatch", ...)` round trip (a second,
// avoidable self-invocation hop through start-dispatch's own fork-and-return branch), unlike the
// intercity branch's already fire-and-forget `fetch` + `EdgeRuntime.waitUntil` pattern.
// start-dispatch itself also re-fetched the order row a second time for iteration 1 of its retry
// loop, immediately after already fetching it once before lock acquisition.
//
// Fix: trigger dispatch immediately after the order INSERT commits (before all bookkeeping),
// fire-and-forget via `fetch` + `EdgeRuntime.waitUntil` with `is_background: true` sent directly
// (skipping start-dispatch's own client-trigger fork branch entirely), and reuse the
// already-fetched order row for dispatch loop iteration 1 instead of re-fetching it.
//
// This does not run the app or call Supabase (see the pattern already used by
// travel_plan_mode_switch_regression_test.dart and cashfree_qr_regression_test.dart) -- it inspects
// the actual source files so a future edit that reintroduces the bookkeeping-before-dispatch
// ordering, the blocking `.invoke()` call, the redundant order re-fetch, or a flat first-round
// sleep fails CI immediately instead of only being caught on a real device.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final createOrder = _read('supabase/functions/create-order/index.ts');
  final startDispatch = _read('supabase/functions/start-dispatch/index.ts');

  group('Test 1: newly created local order invokes dispatch immediately', () {
    test('the dispatch trigger sits directly after the order INSERT, before all other bookkeeping', () {
      final orderInsertIdx = createOrder.indexOf('if (orderError) {');
      final dispatchTriggerIdx = createOrder.indexOf('START DISPATCH OR INTERCITY MATCHING');
      final promoUsageIdx = createOrder.indexOf('PROMO CODE USAGE RECORDING');
      final otpLogIdx = createOrder.indexOf('LOG INITIAL OTP REQUEST');
      final deviceInfoIdx = createOrder.indexOf('UPDATE DEVICE INFO & COMPLIANCE LOGS');

      expect(orderInsertIdx, greaterThan(-1));
      expect(dispatchTriggerIdx, greaterThan(orderInsertIdx));
      // Dispatch trigger comes BEFORE every non-critical bookkeeping write, not after.
      expect(dispatchTriggerIdx, lessThan(promoUsageIdx));
      expect(dispatchTriggerIdx, lessThan(otpLogIdx));
      expect(dispatchTriggerIdx, lessThan(deviceInfoIdx));
    });

    test('the local-order dispatch trigger is fire-and-forget (fetch + waitUntil), never a blocking .invoke()', () {
      final start = createOrder.indexOf('START DISPATCH OR INTERCITY MATCHING');
      final end = createOrder.indexOf('PROMO CODE USAGE RECORDING');
      final section = createOrder.substring(start, end);
      expect(section.contains('supabase.functions\n          .invoke('), isFalse);
      expect(section.contains('await supabase.functions.invoke("start-dispatch"'), isFalse);
      expect(section.contains('EdgeRuntime.waitUntil(dispatchPromise)'), isTrue);
    });

    test('dispatch is invoked with is_background:true directly, skipping the redundant self-fork hop', () {
      final start = createOrder.indexOf('START DISPATCH OR INTERCITY MATCHING');
      final end = createOrder.indexOf('PROMO CODE USAGE RECORDING');
      final section = createOrder.substring(start, end);
      expect(section.contains('order_id: order.id, is_background: true'), isTrue);
    });

    test('there is only ONE dispatch-trigger call site left (the old duplicate before RESPONSE is gone)', () {
      expect('EdgeRuntime.waitUntil(dispatchPromise)'.allMatches(createOrder).length, equals(1));
      expect(createOrder.contains('DISPATCH =>'), isFalse);
      // The old duplicate site called supabase.functions.invoke("start-dispatch", ...) directly --
      // that quoted-string call form is gone entirely; the only remaining "start-dispatch"
      // reference is the fire-and-forget fetch URL added above (a template-literal URL, not a
      // quoted function name). .invoke("calculate-order-pricing", ...) for fare recalculation
      // earlier in the file is unrelated and untouched.
      expect(createOrder.contains('"start-dispatch"'), isFalse);
    });
  });

  group('Test 2: the first dispatch iteration has no artificial sleep before it', () {
    test('Round 1 is always included with no delay/sleep gating it', () {
      final roundsStart = startDispatch.indexOf('const rounds = [];');
      final round1End = startDispatch.indexOf('// Round 2');
      final round1Section = startDispatch.substring(roundsStart, round1End);
      expect(round1Section.contains('setTimeout'), isFalse);
      expect(round1Section.contains('Round 1 always'), isTrue);
    });

    test('the sleep/backoff only happens AFTER a full round pass, never before the first find_nearby_riders call', () {
      final firstFindNearby = startDispatch.indexOf('find_nearby_riders');
      final firstSleep = startDispatch.indexOf('sleepTimeMs');
      expect(firstFindNearby, greaterThan(-1));
      expect(firstSleep, greaterThan(firstFindNearby));
    });

    test('iteration 1 reuses the already-fetched order instead of an extra DB round trip', () {
      final loopStart = startDispatch.indexOf('while (Date.now() - executionStartTime');
      final loopBodyEnd = startDispatch.indexOf('Stop if order is no longer searching');
      final section = startDispatch.substring(loopStart, loopBodyEnd);
      expect(section.contains('let currentOrder = order;'), isTrue);
      expect(section.contains('if (iteration > 1)'), isTrue);
    });
  });

  group('Test 3: an eligible nearby rider can receive an assignment on the first iteration', () {
    test('Round 1 config (radius/batch size) is unconditional, not gated on iteration count', () {
      expect(startDispatch.contains('// Round 1 always'), isTrue);
      expect(startDispatch.contains('round: 1,'), isTrue);
      // Round 1's push() is not wrapped in any "if (...)" gate the way Round 2/3 are.
      final round1Idx = startDispatch.indexOf('// Round 1 always');
      final round2Idx = startDispatch.indexOf('// Round 2');
      final between = startDispatch.substring(round1Idx, round2Idx);
      expect(between.contains('if ('), isFalse);
    });

    test('find_nearby_riders is called with the order pickup coordinates on every round including round 1', () {
      expect(startDispatch.contains('p_pickup_lat: currentOrder.pickup_lat'), isTrue);
      expect(startDispatch.contains('p_pickup_lng: currentOrder.pickup_lng'), isTrue);
    });
  });

  group('Test 4 & 5: early retry stays fast after a genuine no-match; later backoff stays bounded', () {
    test('the first 3 no-match iterations retry after only 2s, not 15s', () {
      expect(startDispatch.contains('earlyRetryIterationLimit = 3'), isTrue);
      expect(startDispatch.contains('sleepTimeMs = 2000;'), isTrue);
    });

    test('only after several quick attempts does it fall back to the slower 15s cadence (bounded, not infinite/aggressive)', () {
      expect(startDispatch.contains('sleepTimeMs = 15000;'), isTrue);
      // The overall loop itself is time-boxed (safeTimeoutMs) and re-chains rather than looping
      // forever in a single invocation -- scalable, not an unbounded busy-loop.
      expect(startDispatch.contains('safeTimeoutMs = 100 * 1000'), isTrue);
      expect(startDispatch.contains('Re-triggered dispatch asynchronously due to execution limit'), isTrue);
    });

    test('a round that DID send assignments cools down at a different (5s) cadence than a genuine no-match', () {
      expect(startDispatch.contains('if (anyAssignmentsSent) {'), isTrue);
      expect(startDispatch.contains('sleepTimeMs = 5000;'), isTrue);
      final ifIdx = startDispatch.indexOf('if (anyAssignmentsSent) {');
      final elseIfIdx = startDispatch.indexOf('else if (iteration <= earlyRetryIterationLimit)');
      expect(elseIfIdx, greaterThan(ifIdx));
      final between = startDispatch.substring(ifIdx, elseIfIdx);
      expect(between.contains('5000'), isTrue);
    });
  });

  group('Test 6: rider_assignment INSERT remains deduplicated', () {
    test('assignments are upserted on the (order_id, rider_id) conflict target, never a plain insert', () {
      expect(startDispatch.contains('.upsert(dispatchRows, { onConflict: "order_id,rider_id" })'), isTrue);
    });

    test('riders already sent/accepted for this order are excluded from being re-matched in a later round', () {
      expect(startDispatch.contains("case \"sent\":"), isTrue);
      expect(startDispatch.contains("case \"accepted\":"), isTrue);
      expect(startDispatch.contains('excludedRiderIds.add(assignment.rider_id)'), isTrue);
    });
  });

  group('Test 7 & 8: Realtime, not the polling fallback, delivers the assignment', () {
    final riderOrdersScreen = _read('lib/features/rider/orders/rider_orders_screen.dart');

    test('a realtime subscription on rider_assignments (filtered to this rider) refetches on INSERT', () {
      expect(riderOrdersScreen.contains("table: 'rider_assignments'"), isTrue);
      expect(riderOrdersScreen.contains("filterColumn: 'rider_id'"), isTrue);
      expect(riderOrdersScreen.contains('fetchSearchingOrders()'), isTrue);
    });

    test('rider_assignments is registered in the supabase_realtime publication with REPLICA IDENTITY FULL', () {
      final migration = _read('supabase/migrations/20260530000002_enable_realtime.sql');
      expect(migration.contains("'rider_assignments'"), isTrue);
      expect(migration.contains('REPLICA IDENTITY FULL'), isTrue);
    });

    test('the 10s timer is a distance/fallback refresh, established alongside (not instead of) the realtime subscription', () {
      final start = riderOrdersScreen.indexOf('if (riderId != null) {');
      final end = riderOrdersScreen.indexOf('} else {', start);
      final section = riderOrdersScreen.substring(start, end);
      expect(section.contains('listenSearchingOrders();'), isTrue);
      expect(section.contains('startLocationTimer();'), isTrue);
      // Both are wired up together as soon as the rider resolves -- the timer is a fallback layered
      // under realtime, not a replacement for it (Timer.periodic(seconds: 10) is a bounded,
      // non-aggressive cadence, not a tight busy-poll).
      final timerSection = riderOrdersScreen.substring(
        riderOrdersScreen.indexOf('void startLocationTimer()'),
        riderOrdersScreen.indexOf('void startExpiryTimer()'),
      );
      expect(timerSection.contains('Duration(seconds: 10)'), isTrue);
    });
  });

  group('Test 9: resume reconciliation recovers a missed assignment', () {
    final rideSearchingLike = _read('lib/features/rider/orders/rider_orders_screen.dart');
    test('going from offline to online (a realtime riders-row update) triggers an immediate refetch', () {
      expect(rideSearchingLike.contains('listenRiderStatus'), isTrue);
      expect(rideSearchingLike.contains('if (wasOffline && online) {'), isTrue);
      expect(rideSearchingLike.contains('fetchSearchingOrders();'), isTrue);
    });

    test('RealtimeManager reconnects with backoff and re-subscribes on channel error/timeout (app resume/reconnect)', () {
      final realtimeManager = _read('lib/core/services/realtime/realtime_manager.dart');
      expect(realtimeManager.contains('_reconnectChannel'), isTrue);
      expect(realtimeManager.contains('RealtimeSubscribeStatus.channelError'), isTrue);
      expect(realtimeManager.contains('_startHeartbeatChecker'), isTrue);
    });
  });
}
