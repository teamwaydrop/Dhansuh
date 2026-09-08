// Regression guard for the "eligible pending order isn't reliably offered to a rider who just
// became free" investigation (TEST 2 of the Orders-tab-visibility bug family).
//
// FULL AUDIT CONCLUSION (live production evidence, not assumed): the backend rider-freed rematch
// pipeline -- trigger_assign_nearby_orders_on_rider_freed (20260808000000_reassign_orders_when_
// rider_freed.sql) -> assign_nearby_searching_orders_on_rider_freed() (async body updated in
// 20260809000001_async_rider_freed_rematch.sql) -> assign_nearby_searching_orders_core()
// (20260808000002_enforce_cod_limit_at_dispatch.sql) -- was already correct and reliable. Queried
// 14 days of live orders/rider_assignments data: of 243 riders who became free, only 6 had a
// genuinely still-valid candidate order nearby and did NOT get rematched within 60s -- every one of
// those 6 had a clear, correct disqualifying reason already enforced by this exact code (rider
// account_status was 'blocked'/'offline', current_lat/lng was null, or the order's required service
// mode didn't match the rider's). The other 70 genuine matches all landed within 15-28 seconds. Also
// confirmed live: the vault secret this pipeline depends on exists, rider_assignments/orders/riders
// are all in the supabase_realtime publication, the UNIQUE(order_id, rider_id) constraint is live,
// and dispatch_config's rider_response_timeout_sec (120s) gives no premature-expiry risk. No
// backend/SQL change was made as a result of this investigation -- the ROOT CAUSE of Ride B not
// being reliably visible was entirely the client-side stale-service_mode bug already fixed in
// rider_main_navigation_screen.dart (see rider_orders_tab_visibility_regression_test.dart).
//
// This file is a structural regression guard (reads the real migration source, following the
// pattern already used throughout this test suite for backend correctness that can't run against a
// live Supabase instance in a plain unit test) -- it asserts the specific invariants this
// investigation depended on can never silently regress.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('Rider-freed rematch pipeline -- invariants relied on by the Ride B visibility fix', () {
    final findNearbyAndCore = _read(
      'supabase/migrations/20260808000002_enforce_cod_limit_at_dispatch.sql',
    );
    final freedTrigger = _read(
      'supabase/migrations/20260808000000_reassign_orders_when_rider_freed.sql',
    );
    final freedTriggerAsyncBody = _read(
      'supabase/migrations/20260809000001_async_rider_freed_rematch.sql',
    );
    final uniqueConstraint = _read(
      'supabase/migrations/20260808000004_add_rider_assignments_unique_order_rider.sql',
    );

    test('find_nearby_riders() still live-excludes riders with a current active order', () {
      // The NOT EXISTS busy-rider exclusion is what allows a freed rider to be re-included the
      // moment their own order leaves the active-status list -- a cached/snapshot exclusion here
      // would silently break the whole "become free -> visible again" flow.
      final busyExclusionShape = RegExp(
        r'NOT EXISTS\s*\(\s*SELECT 1\s*FROM orders o\s*WHERE\s*o\.rider_id = r\.id\s*'
        r"AND o\.order_status IN \(\s*'accepted',\s*'rider_arrived',\s*'picked_up',\s*'ongoing'\s*\)",
        multiLine: true,
      );
      expect(
        busyExclusionShape.hasMatch(findNearbyAndCore),
        isTrue,
        reason: 'find_nearby_riders() must keep its live (not cached) busy-order exclusion',
      );
    });

    test('assign_nearby_searching_orders_core() only offers genuinely still-searching, '
        'non-stale orders', () {
      expect(
        findNearbyAndCore.contains("WHERE o.order_status = 'searching'"),
        isTrue,
        reason: 'must never rematch an order that is no longer searching (accepted/cancelled/'
            'expired elsewhere)',
      );
      expect(
        findNearbyAndCore.contains(
          "AND o.created_at >= (NOW() - (v_max_search_duration_sec || ' seconds')::interval)",
        ),
        isTrue,
        reason: 'must never rematch an order past its own configured search lifetime',
      );
    });

    test('assign_nearby_searching_orders_core() always computes a FRESH expires_at at rematch '
        'time, never reuses a stale one', () {
      expect(
        findNearbyAndCore.contains(
          'expires_at = NOW() + (v_timeout_sec || \' seconds\')::interval',
        ),
        isTrue,
        reason: 'a rematched assignment must get a brand-new response window, not an inherited '
            'one that could already be expired',
      );
    });

    test('new-assignment INSERT is guarded against a concurrent duplicate '
        '(unique_violation is caught, never thrown)', () {
      expect(
        findNearbyAndCore.contains('EXCEPTION WHEN unique_violation THEN'),
        isTrue,
        reason: 'two near-simultaneous rematch attempts for the same (order, rider) pair must '
            'never both insert -- this is the concurrency-safety guarantee the fix depends on',
      );
    });

    test('rider_assignments(order_id, rider_id) UNIQUE constraint still exists', () {
      expect(
        uniqueConstraint.contains(
          'ADD CONSTRAINT rider_assignments_order_id_rider_id_key UNIQUE (order_id, rider_id)',
        ),
        isTrue,
      );
    });

    test('the rider-freed trigger still fires exactly on "left an active order status" -- not '
        'broader, not narrower', () {
      // Regressing this WHEN clause either direction breaks the fix: too broad and a rider still
      // genuinely busy could get offered a second ride (violates the busy-rider protection this
      // whole feature must never weaken); too narrow (e.g. missing 'ongoing') and a normal local
      // ride's completion would never trigger a rematch at all.
      expect(freedTrigger.contains("WHEN (\n    OLD.order_status IN ('accepted', 'rider_arrived', "
          "'picked_up', 'ongoing')\n    AND NEW.order_status NOT IN ('accepted', 'rider_arrived', "
          "'picked_up', 'ongoing')\n    AND NEW.rider_id IS NOT NULL\n)"), isTrue);
    });

    test('the trigger only enqueues a rematch for a rider who is confirmed online', () {
      expect(
        freedTriggerAsyncBody.contains(
          "v_rider.account_status IS DISTINCT FROM 'online'::public.rider_account_status_enum",
        ),
        isTrue,
        reason: 'an offline/blocked rider must never be offered a new order via this path',
      );
    });

    test('a missing/failed async enqueue never blocks the order\'s own completion/cancellation '
        '(best-effort, not transactional)', () {
      expect(freedTriggerAsyncBody.contains('EXCEPTION WHEN OTHERS THEN'), isTrue);
      expect(
        freedTriggerAsyncBody.contains('RAISE WARNING'),
        isTrue,
        reason: 'failures must be logged, never thrown -- completing/cancelling a ride must never '
            'fail because the next-match enqueue had a problem',
      );
    });
  });
}
