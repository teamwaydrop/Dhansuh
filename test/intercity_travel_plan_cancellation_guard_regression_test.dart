// Regression guard for PHASE 3, Issue 6: a traveller must be able to cancel their Travel Plan
// after accepting a user request, without hitting "Direct modification of order status/OTP/
// assignment columns is not permitted."
//
// ROOT CAUSE: not a client bug and not disallowed client code -- _deleteTravelPlan only ever
// writes rider_travel_plans.status. cascade_cancel_travel_plan_dependents() (the correct, intended
// server-side cascade, SECURITY DEFINER) itself writes orders.order_status when cancelling a plan
// with an accepted request, but -- unlike every sibling function that legitimately writes those
// same guarded columns -- was never updated to set_config('app.bypass_order_state_guard','true',
// true) before that write. protect_order_state_columns_trigger correctly rejected it (SECURITY
// DEFINER does not change auth.role()), aborting the whole cascade and surfacing its generic error
// text to the user.
//
// FIX: add the one missing bypass call, matching the exact pattern already used by every other
// legitimate writer of these columns. No RLS/guard weakening -- the guard itself, and the
// rider_travel_plans UPDATE RLS policy that already scopes cancellation to the plan's own rider,
// are both untouched.
//
// Structural guard (reads the real source + migration SQL), matching the pattern used throughout
// this suite for backend correctness that can't run against a live Supabase instance here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read('supabase/migrations/20260823000000_phase3_intercity_fixes.sql');
  final cascadeStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.cascade_cancel_travel_plan_dependents()');
  final cascadeBody = migration.substring(cascadeStart);

  group('cascade_cancel_travel_plan_dependents() -- the missing bypass is now set before its own '
      'guarded orders write', () {
    test('sets app.bypass_order_state_guard before the orders UPDATE (matching the established '
        'pattern used by mark_intercity_trip_at_dropoff / regenerate_intercity_delivery_otp / '
        'complete_intercity_parcel_delivery)', () {
      final bypassIndex = cascadeBody.indexOf(
        "PERFORM set_config('app.bypass_order_state_guard', 'true', true);",
      );
      final ordersUpdateIndex = cascadeBody.indexOf('UPDATE public.orders o');
      expect(bypassIndex, greaterThanOrEqualTo(0));
      expect(ordersUpdateIndex, greaterThan(bypassIndex));
    });

    test('the orders UPDATE itself is preserved byte-for-byte from 20260822000000 (same columns, '
        'same WHERE scope, cancelled_by="rider" still tagged) -- only the bypass call was added', () {
      expect(
        cascadeBody.contains(
          "SET order_status = 'cancelled'::public.order_status_enum,\n"
          '            cancelled_at = v_now,\n'
          "            cancel_reason = 'Traveller cancelled the travel plan.',\n"
          "            cancelled_by = 'rider',\n"
          '            updated_at = v_now',
        ),
        isTrue,
      );
      expect(
        cascadeBody.contains(
          'WHERE ir.route_id = NEW.id\n'
          '          AND ir.parcel_id = o.id\n'
          "          AND ir.status = 'cancelled'\n"
          "          AND o.order_status = 'accepted'\n"
          '          AND o.rider_id = NEW.rider_id;',
        ),
        isTrue,
      );
    });

    test('the intercity_requests cascade (still-open negotiations marked cancelled) and the '
        'order_status_history audit insert are both preserved unchanged', () {
      expect(
        cascadeBody.contains(
          "status IN ('request_sent', 'discussion_started', 'fare_agreed', 'confirmed', 'paid');",
        ),
        isTrue,
      );
      expect(
        cascadeBody.contains("'system_travel_plan_cancelled',"),
        isTrue,
      );
    });

    test('the guard trigger that was rejecting this write, and its exact error text, are both '
        'unchanged -- security is not weakened, only the legitimate cascade caller now bypasses '
        'it correctly, exactly like its siblings', () {
      final guardSource = _read(
        'supabase/migrations/20260730000008_lock_order_status_and_otp_columns.sql',
      );
      expect(
        guardSource.contains(
          'Direct modification of order status/OTP/assignment columns is not permitted. Use the appropriate server-side function.',
        ),
        isTrue,
      );
      expect(guardSource.contains("auth.role() <> 'service_role'"), isTrue);
    });
  });

  group('client cancellation entry points are confirmed not the source of the disallowed write', () {
    // UPDATED (Phase 9, Issue 2): _deleteTravelPlan no longer writes to rider_travel_plans (or
    // orders) directly at all -- the write moved server-side into the canonical
    // cancel_travel_plan_by_traveller() RPC (see 20260901000002_cancel_travel_plan_by_traveller.sql),
    // which is itself still nothing but a rider_travel_plans.status transition (confirmed there).
    // The guard this group protects -- the client is never the source of a disallowed direct
    // orders write -- holds even more strongly now: the client makes no direct table write here
    // at all.
    test('rider_home_tab.dart _deleteTravelPlan writes neither rider_travel_plans nor orders '
        'directly -- it only calls the canonical cancel_travel_plan_by_traveller RPC', () {
      final source = _read('lib/features/rider/home/rider_home_tab.dart');
      final start = source.indexOf('_deleteTravelPlan');
      expect(start, greaterThanOrEqualTo(0));
      final nearby = source.substring(start, start + 700);
      expect(nearby.contains("from('rider_travel_plans')"), isFalse);
      expect(nearby.contains("from('orders')"), isFalse);
      expect(nearby.contains('IntercityMatchingService.cancelTravelPlan('), isTrue);
    });
  });

  group('unauthorized cancellation of another traveller\'s plan remains blocked (RLS untouched)', () {
    test('the rider_travel_plans UPDATE policy is still scoped to the plan\'s own rider via '
        'riders.user_id = auth.uid()', () {
      final source = _read(
        'supabase/migrations/20260718000012_restrict_travel_plans_and_intercity_requests_to_intercity_mode.sql',
      );
      expect(source.contains('Allow riders to update their own travel plans'), isTrue);
      expect(source.contains('r.id = rider_travel_plans.rider_id'), isTrue);
    });
  });
}
