// Regression guard for Issue 1 follow-up: real-device testing after the payment_pending fix and
// redispatch_freed_riders backstop (both live in production) still showed Ride B not appearing for
// Rider A after Ride A completed.
//
// LIVE FORENSIC FINDING (not assumed): traced the reporter's own real-device test data. Ride B
// (order a22a1ef7) was created while Rider A was busy on Ride A (payment_pending) and correctly
// rejected by the busy guard -- one order_assignment_logs row, zero rider_assignments rows, exactly
// as intended. Ride A completed at 22:00:46. The rider's own push-notification history shows ZERO
// "New Order Request" notifications (sent on every genuine new rider_assignments 'sent' row, per
// on_rider_assignment_change()) for a ~110 second window afterward, during which the 20s
// redispatch_freed_riders backstop should have ticked ~5 times. The next successful match (110s
// later) was for a DIFFERENT, intercity_parcel order -- proving the rider's own service_mode had
// already changed to 'intercity' by then (assign_nearby_searching_orders_core's own service_mode
// equality check would otherwise reject it), consistent with the tester switching modes mid-session
// to move on to testing other reported issues -- a legitimate mode change once Ride A is completed,
// not a bug. No other structural defect was found in the deployed trigger/guard/find_nearby_riders
// chain (all three re-verified live, matching 20260825000000 byte-for-byte).
//
// This investigation could not fully rule out a real race in the first 20-40 seconds after a rider
// is freed purely from historical data (riders.service_mode has no per-event audit trail). Two
// changes ship in 20260826000000_rider_self_rematch_and_backstop_hardening.sql as a result:
//   1. rider_self_rematch() -- a new, auth.uid()-scoped RPC the rider's own client calls the
//      instant it detects its own busy->free transition (RiderOrdersScreen's existing
//      wasBusy && !hasActiveOrder check -- no new timer). Runs the same, unmodified
//      assign_nearby_searching_orders_core() synchronously for that one rider, giving a same-
//      request guarantee instead of waiting on the async trigger's pg_net hop or the next cron
//      tick. It can only ever act on the caller's own rider profile.
//   2. redispatch_freed_riders() gets per-rider exception isolation (previously flagged as
//      optional in the prior safety review; promoted here as cheap, safe hardening) so one rider's
//      unexpected failure can never abort the rest of that tick's batch.
//
// This file is a structural regression guard (reads the real migration/Dart source, following the
// pattern already used throughout this test suite for backend correctness that can't run against a
// live Supabase instance in a plain unit test).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read(
    'supabase/migrations/20260826000000_rider_self_rematch_and_backstop_hardening.sql',
  );
  final riderOrdersScreen = _read(
    'lib/features/rider/orders/rider_orders_screen.dart',
  );

  group('Issue 1 follow-up -- rider_self_rematch() immediate busy->free rematch', () {
    test('rider_self_rematch() is scoped strictly to the calling rider via auth.uid()', () {
      expect(
        migration.contains('FROM public.riders\n    WHERE user_id = auth.uid()'),
        isTrue,
        reason: 'must resolve the rider from the JWT, never from a client-supplied rider_id -- '
            'this is what makes it safe to grant to `authenticated` without letting one rider '
            'force-rematch another',
      );
      expect(
        migration.contains('GRANT EXECUTE ON FUNCTION public.rider_self_rematch() TO authenticated;'),
        isTrue,
      );
    });

    test('rider_self_rematch() reuses assign_nearby_searching_orders_core() as-is -- no '
        'duplicated or diverging matching rules', () {
      final selfRematchBody = migration.substring(
        migration.indexOf('CREATE OR REPLACE FUNCTION public.rider_self_rematch()'),
        migration.indexOf('GRANT EXECUTE ON FUNCTION public.rider_self_rematch()'),
      );
      expect(
        selfRematchBody.contains('PERFORM public.assign_nearby_searching_orders_core('),
        isTrue,
        reason: 'radius/service-mode/vehicle/weight matching, tax-due and COD-limit gating, '
            'assignment uniqueness, expires_at, and the busy-rider guard on the resulting INSERT '
            'must all come from the single existing pipeline, never a reimplementation',
      );
    });

    test('RiderOrdersScreen calls rider_self_rematch() on its own busy->free transition, before '
        're-fetching, without adding a new polling timer', () {
      final start = riderOrdersScreen.indexOf('if (wasBusy && !hasActiveOrder) {');
      expect(start, greaterThan(-1));
      // P8 FIX #6.4-B: _pollActiveOrderFallback() now ends with `} catch (_) {} finally {...}`
      // instead of a bare `} catch (_) {}` immediately closing the function (added a re-entrancy
      // guard's cleanup/follow-up logic) -- the exact multi-line end-of-function marker this test
      // used no longer matches. Switched to the next function's signature as the end boundary,
      // the same pattern already used successfully by test/rider_orders_busy_to_free_refetch_
      // regression_test.dart and test/rider_pending_ride_after_completion_regression_test.dart for
      // this identical span. No assertion below changed -- only where `body` stops.
      final end = riderOrdersScreen.indexOf('void startActiveOrderPollTimer() {', start);
      final body = riderOrdersScreen.substring(start, end > start ? end : start + 600);
      expect(body.contains("supabase.rpc('rider_self_rematch')"), isTrue);
      final rpcIndex = body.indexOf("supabase.rpc('rider_self_rematch')");
      final fetchIndex = body.indexOf('fetchSearchingOrders();');
      expect(rpcIndex, greaterThan(-1));
      expect(fetchIndex, greaterThan(rpcIndex),
          reason: 'must call the self-rematch RPC before re-fetching, so the freshly-created '
              'assignment (if any) is actually there to find');
      // No new Timer.periodic was introduced by this change -- this remains purely event-driven
      // off the existing realtime-triggered busy->free detection.
      expect(
        riderOrdersScreen.contains('Timer.periodic(const Duration(seconds: 30)'),
        isTrue,
        reason: 'the existing 30s active-order safety-net timer is the only periodic timer -- no '
            'second timer should be added for this fix',
      );
    });

    test('a failed self-rematch RPC call is non-fatal -- async trigger and cron backstop remain '
        'as fallback', () {
      final start = riderOrdersScreen.indexOf('if (wasBusy && !hasActiveOrder) {');
      // P8 FIX #6.4-B: _pollActiveOrderFallback() now ends with `} catch (_) {} finally {...}`
      // instead of a bare `} catch (_) {}` immediately closing the function (added a re-entrancy
      // guard's cleanup/follow-up logic) -- the exact multi-line end-of-function marker this test
      // used no longer matches. Switched to the next function's signature as the end boundary,
      // the same pattern already used successfully by test/rider_orders_busy_to_free_refetch_
      // regression_test.dart and test/rider_pending_ride_after_completion_regression_test.dart for
      // this identical span. No assertion below changed -- only where `body` stops.
      final end = riderOrdersScreen.indexOf('void startActiveOrderPollTimer() {', start);
      final body = riderOrdersScreen.substring(start, end > start ? end : start + 600);
      expect(body.contains('try {'), isTrue);
      expect(body.contains('} catch (e) {'), isTrue);
    });
  });

  group('Issue 1 follow-up -- redispatch_freed_riders() per-rider exception isolation', () {
    test('each rider PERFORM is wrapped in its own BEGIN/EXCEPTION so one failure cannot abort '
        "the rest of the tick's batch", () {
      final shape = RegExp(
        r'\) LOOP\s*'
        r'BEGIN\s*'
        r'PERFORM public\.assign_nearby_searching_orders_core\([\s\S]*?\);\s*'
        r'EXCEPTION WHEN OTHERS THEN',
      );
      expect(shape.hasMatch(migration), isTrue);
    });

    test('busy-rider protection and the 5-minute bounded scan are unchanged by this hardening',
        () {
      expect(
        migration.contains(
          "AND bo.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing', "
          "'payment_pending')",
        ),
        isTrue,
      );
      expect(migration.contains("o.updated_at >= NOW() - INTERVAL '5 minutes'"), isTrue);
    });
  });
}
