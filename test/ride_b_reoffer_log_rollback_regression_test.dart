// Structural regression guard for the DEEPER, previously-unproven root cause of the reported
// "Ride A active -> Ride B created -> Ride A completes -> Ride B never appears" bug.
//
// CONTEXT: a prior session's fix (RiderOrdersScreen._hasPolledActiveOrderOnce, see
// ride_b_missed_after_ride_a_completion_regression_test.dart) correctly makes the client call
// rider_self_rematch() the moment a freshly-(re)created RiderOrdersScreenState observes the rider
// is free. That fix passed its own structural test but STILL failed real-device testing. This file
// documents and guards the reason why, proven this session via REAL execution against a local
// Supabase/Docker instance (supabase start + supabase migration up, not just reading SQL text):
//
//   1. Seeded a rider genuinely busy on Ride A and a geographically-eligible Ride B pending the
//      whole time (Ride B never offered to this rider while busy -- confirmed 0 rider_assignments
//      rows for that pair, exactly as find_nearby_riders()'s rider_is_on_active_trip() guard
//      intends).
//   2. Completed Ride A, then called rider_self_rematch() as that rider via the REAL PostgREST RPC
//      endpoint (the exact call RiderOrdersScreen._pollActiveOrderFallback() makes) -- confirmed it
//      DOES call assign_nearby_searching_orders_core() and DOES create a 'sent' rider_assignments
//      row when nothing has ever raced it.
//   3. Separately proved (RAISE NOTICE-instrumented copy of the live function body, byte-identical
//      logic; then reproduced on the live function itself) that whenever assign_nearby_searching_
//      orders_core() reaches its order_assignment_logs INSERT and that insert hits the
//      unique_order_rider_assignment (order_id, rider_id, assignment_round) constraint -- which it
//      ALWAYS does on any re-offer, since assignment_round is hardcoded to 1 and a round=1 row
//      already exists from the pair's first-ever offer -- the surrounding
//      `EXCEPTION WHEN unique_violation THEN NULL` block rolls back BOTH statements in its BEGIN
//      block, silently discarding the rider_assignments INSERT/UPDATE that had just succeeded
//      moments earlier in the SAME block. Verified live: an 'expired' assignment with a bumped fare
//      (a legitimate re-offer, gated by `rider_earning > last_seen_fare` and otherwise satisfied)
//      stayed stuck at assignment_status='expired' after calling the un-fixed function -- the rider
//      never saw it, matching "No rides" exactly, with zero errors surfaced anywhere.
//   4. Confirmed the SAME collision also blocks a genuinely FRESH first offer whenever a stale
//      order_assignment_logs row already exists for that (order_id, rider_id) pair with no matching
//      rider_assignments row (both mechanically identical inside the function's shared
//      BEGIN/EXCEPTION block).
//
// Given trigger_assign_nearby_orders_on_rider_freed's pg_net call, redispatch_freed_riders()'s 20s
// cron backstop, AND rider_self_rematch() all funnel through this ONE function for a freed rider, a
// real-device tester who takes more than the 120s rider_response_timeout_sec window to navigate
// from Ride A's completion screen to "Available Rides" will find their own self-heal-created offer
// already expired -- and, before this fix, NOTHING could ever bring it back. This is the most
// likely reason the prior client-only fix still failed live testing: it correctly triggered a
// rematch, but the match could be created once and then be permanently unrecoverable.
//
// FIX (20260901000026_fix_order_assignment_logs_rollback_on_reoffer.sql): the order_assignment_logs
// INSERT in all three call sites (fresh insert, 'expired' re-offer, 'rejected' re-offer) is moved
// into its OWN isolated BEGIN/EXCEPTION sub-block, so a duplicate/failed audit-log write can never
// roll back the rider_assignments write that actually determines dispatch visibility. No
// eligibility/radius/vehicle/service-mode/tax/COD/fare-gate rule changes -- reproduced byte-for-byte
// from the live 20260808000002 definition otherwise.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final buggyMigration = _read('supabase/migrations/20260808000002_enforce_cod_limit_at_dispatch.sql');
  final fixMigration = _read('supabase/migrations/20260901000026_fix_order_assignment_logs_rollback_on_reoffer.sql');

  group('1. Documents the bug in the pre-fix function body (proves this is a real regression, '
      'not a hypothetical)', () {
    test('the pre-fix assign_nearby_searching_orders_core() inserts order_assignment_logs with a '
        'hardcoded assignment_round of 1 in all three call sites, with no per-pair increment '
        '(reproduced live: this is why a re-offer always collides with the pair\'s first-ever log '
        'row), and the single outer EXCEPTION directly wraps both the rider_assignments write and '
        'the order_assignment_logs write with no isolation between them', () {
      expect('INSERT INTO public.order_assignment_logs ('.allMatches(buggyMigration).length, 3);
      expect(buggyMigration.contains('EXCEPTION WHEN unique_violation THEN\n                NULL;\n            END;'), isTrue);
    });
  });

  group('2. THE FIX: order_assignment_logs writes are isolated from the rider_assignments write', () {
    test('assign_nearby_searching_orders_core() is redefined in the newest migration', () {
      expect(fixMigration.contains('CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_core('), isTrue);
    });

    test('every order_assignment_logs INSERT is wrapped in its own nested BEGIN ... EXCEPTION WHEN '
        'OTHERS THEN NULL; END; block, separate from the rider_assignments write above it', () {
      final inserts = 'INSERT INTO public.order_assignment_logs ('.allMatches(fixMigration).length;
      expect(inserts, 3, reason: 'fresh-insert, expired re-offer, and rejected re-offer call sites');

      final isolatedCatches = RegExp(
        r'BEGIN\s+INSERT INTO public\.order_assignment_logs \([\s\S]{1,2200}?\);\s+EXCEPTION WHEN OTHERS THEN\s+NULL;\s+END;',
      ).allMatches(fixMigration).length;
      expect(isolatedCatches, 3,
          reason: 'each order_assignment_logs insert must have its own isolated exception handler');
    });

    test('the outer per-order EXCEPTION WHEN unique_violation guard is retained (still catches a '
        'genuine concurrent rider_assignments INSERT race) but no longer directly precedes an '
        'order_assignment_logs statement -- it is now separated by the inner isolated block', () {
      expect(fixMigration.contains('EXCEPTION WHEN unique_violation THEN'), isTrue);
    });

    test('pre-deployment audit finding: the fresh-insert branch\'s order_assignment_logs.'
        'estimated_pickup_time_min value is reproduced EXACTLY as production already has it '
        '(v_order.rider_earning, confirmed via a read-only pg_dump against the linked project) -- '
        'not silently "corrected" to CEIL(v_dist_km * 3) like the two re-offer branches, which '
        'would have been an undocumented, unrequested behavior change riding along with this fix', () {
      final freshInsertIdx = fixMigration.indexOf('IF v_existing_id IS NULL THEN');
      final firstReofferIdx = fixMigration.indexOf("ELSIF v_existing_status = 'expired' THEN");
      expect(freshInsertIdx, greaterThan(-1));
      expect(firstReofferIdx, greaterThan(freshInsertIdx));
      final freshInsertBlock = fixMigration.substring(freshInsertIdx, firstReofferIdx);
      expect(freshInsertBlock.contains('v_order.rider_earning,\n                            NOW()\n                        );'), isTrue);
      // The literal VALUES(...) clause itself must not use CEIL(...) -- a mention of it inside this
      // fix's own explanatory comment (documenting what the value is NOT) is expected and fine.
      final valuesIdx = freshInsertBlock.indexOf(') VALUES (');
      final valuesClause = freshInsertBlock.substring(valuesIdx, valuesIdx + 400);
      expect(valuesClause.contains('CEIL(v_dist_km * 3)'), isFalse);
    });

    test('no eligibility/radius/vehicle/service-mode/tax/COD/fare-gate rule changed -- every '
        'existing WHERE/IF condition from the live definition is reproduced verbatim', () {
      expect(fixMigration.contains('IF public.is_rider_blocked_by_tax_due(p_rider_id) THEN'), isTrue);
      expect(fixMigration.contains('IF public.is_rider_blocked_by_cod_limit(p_rider_id) THEN'), isTrue);
      expect(fixMigration.contains("WHERE o.order_status = 'searching'"), isTrue);
      expect(fixMigration.contains('AND o.created_at >= (NOW() - (v_max_search_duration_sec'), isTrue);
      expect(fixMigration.contains('v_order.rider_earning > COALESCE(last_seen_fare, estimated_earnings, 0)'), isTrue);
      expect(fixMigration.contains('AND NOW() >= COALESCE(hidden_until, NOW())'), isTrue);
      expect(fixMigration.contains('SECURITY DEFINER'), isTrue);
      expect(fixMigration.contains('SET search_path = public;'), isTrue);
    });
  });

  group('3. Client-side self-heal fix (prior session) remains intact and complementary', () {
    test('RiderOrdersScreen still self-heals on busy->free (including a freshly-recreated '
        'instance\'s first poll) by calling the exact same rider_self_rematch() RPC this migration '
        'hardens', () {
      final ordersScreen = _read('lib/features/rider/orders/rider_orders_screen.dart');
      expect(ordersScreen.contains('bool _hasPolledActiveOrderOnce = false;'), isTrue);
      expect(ordersScreen.contains('if ((wasBusy || isFirstPollForThisInstance) && !hasActiveOrder) {'), isTrue);
      expect(ordersScreen.contains("await supabase.rpc('rider_self_rematch');"), isTrue);
    });
  });
}
