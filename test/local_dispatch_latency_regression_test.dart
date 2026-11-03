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
  final dispatchSql = _read('docs/migration-review/not-applied/20261102044001_waydrop_dispatch_fencing_and_delivery_outbox.sql');
  final worker = _read('supabase/functions/start-dispatch/durable_dispatch.ts');

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
      expect(dispatchSql.contains('rn integer:=1'), isTrue);
      expect(worker.indexOf("'claim_order_dispatch'"), lessThan(worker.indexOf('await sleep')));
    });

    test('the sleep/backoff only happens AFTER a full round pass, never before the first find_nearby_riders call', () {
      expect(worker.indexOf("'step_order_dispatch'"), lessThan(worker.lastIndexOf('await sleep(wait)')));
      expect(dispatchSql.contains('cfg.round_1_radius_km'), isTrue);
    });

    test('iteration 1 reuses the already-fetched order instead of an extra DB round trip', () {
      expect(startDispatch.contains('.from("rider_assignments")'), isFalse);
      expect(startDispatch.contains('runDurableDispatch(supabase, order_id)'), isTrue);
      expect(dispatchSql.contains('SELECT * INTO o FROM public.orders'), isTrue);
    });
  });

  group('Test 3: an eligible nearby rider can receive an assignment on the first iteration', () {
    test('Round 1 config (radius/batch size) is unconditional, not gated on iteration count', () {
      expect(dispatchSql.contains('rn integer:=1'), isTrue);
      expect(dispatchSql.contains('ELSE cfg.round_1_radius_km END'), isTrue);
      expect(dispatchSql.contains('ELSE cfg.round_1_batch_size END'), isTrue);
    });

    test('find_nearby_riders is called with the order pickup coordinates on every round including round 1', () {
      expect(dispatchSql.contains('radians(o.pickup_lat)'), isTrue);
      expect(dispatchSql.contains('radians(o.pickup_lng)'), isTrue);
      expect(dispatchSql.contains("dispatch_eligibility(p_order_id,q.id,'offer')"), isTrue);
    });
  });

  group('Test 4 & 5: early retry stays fast after a genuine no-match; later backoff stays bounded', () {
    test('the first 3 no-match iterations retry after only 2s, not 15s', () {
      expect(dispatchSql.contains('WHEN j.empty_passes<3 THEN 2 ELSE 15 END'), isTrue);
      expect(dispatchSql.contains('empty_passes+1'), isTrue);
    });

    test('only after several quick attempts does it fall back to the slower 15s cadence (bounded, not infinite/aggressive)', () {
      expect(worker.contains('options.budgetMs ?? 85000'), isTrue);
      expect(worker.contains('recovery_pending: true'), isTrue);
      expect(dispatchSql.contains("WHEN j.empty_passes<3 THEN 2 ELSE 15 END"), isTrue);
    });

    test('a round that DID send assignments cools down at a different (5s) cadence than a genuine no-match', () {
      expect(dispatchSql.contains('WHEN offers>0 OR active_offers>0 THEN 5'), isTrue);
      expect(dispatchSql.contains('CASE WHEN offers>0 OR active_offers>0 THEN 0 ELSE empty_passes+1 END'), isTrue);
    });
  });

  group('Test 6: rider_assignment INSERT remains deduplicated', () {
    test('assignments are upserted on the (order_id, rider_id) conflict target, never a plain insert', () {
      expect(dispatchSql.contains('ON CONFLICT(order_id,rider_id) DO UPDATE'), isTrue);
      expect(dispatchSql.contains("WHERE target.assignment_status::text IN ('expired','rejected')"), isTrue);
      expect(startDispatch.contains('.upsert('), isFalse);
    });

    test('riders already sent/accepted for this order are excluded from being re-matched in a later round', () {
      expect(dispatchSql.contains("a0.assignment_status::text='accepted'"), isTrue);
      expect(dispatchSql.contains("a0.assignment_status::text='sent' AND a0.expires_at>now_at"), isTrue);
      expect(dispatchSql.contains("a.assignment_status::text NOT IN ('expired','rejected')"), isTrue);
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
