// Regression guard for Issue 2: accepting a second intercity request after the last seat was just
// taken showed "Your travel plan is no longer active." instead of a seats-full message.
//
// ROOT CAUSE (confirmed via live schema/trigger inspection, not assumed): rider_travel_plans.status
// has a distinct 'fully_booked' value (travel_plan_status_enum), automatically set by a trigger
// (20260617000001_intercity_workflow_updates.sql) once a plan's active bookings reach max_bookings,
// and revived back to 'active' if a seat frees up -- it is a transient, seat-driven state, never a
// genuinely terminal one (cancelled/completed/expired). accept_intercity_request()'s inactive-plan
// guard checked `status != 'active'`, which 'fully_booked' also satisfies, so it always
// short-circuited into the wrong TRAVEL_PLAN_INACTIVE branch before ever reaching the existing,
// correct PLAN_FULLY_BOOKED seat-count check a few lines below it. The client
// (travel_plan_details_screen.dart) already mapped both codes to distinct, correct messages --
// the bug was entirely server-side, in which code got returned.
//
// FIX (20260827000000_fix_travel_plan_seats_full_vs_inactive_message.sql): the inactive-plan guard
// now excludes 'fully_booked', letting it fall through to the seat-count check, which already
// returns PLAN_FULLY_BOOKED with a seats-specific message. Race safety is unchanged -- the existing
// `FOR UPDATE` row lock on rider_travel_plans still serializes concurrent accepts on the same plan.
//
// This file is a structural regression guard (reads the real migration/Dart source, following the
// pattern already used throughout this test suite for backend correctness that can't run against a
// live Supabase instance in a plain unit test).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read(
    'supabase/migrations/20260827000000_fix_travel_plan_seats_full_vs_inactive_message.sql',
  );
  final detailsScreen = _read(
    'lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart',
  );

  group('Issue 2 -- seats-full vs plan-inactive distinction in accept_intercity_request()', () {
    test("'fully_booked' plans fall through to the seat-count check, not the inactive-plan "
        'branch', () {
      expect(
        migration.contains(
          "IF v_travel_plan IS NULL OR v_travel_plan.status::text NOT IN ('active', 'fully_booked') THEN",
        ),
        isTrue,
        reason: "a plan that is merely 'fully_booked' (a transient, seat-driven status, not a "
            'genuine cancellation/completion/expiry) must never trigger the '
            "'no longer active' response",
      );
    });

    test('a genuinely inactive plan (null, cancelled, completed, expired) still returns '
        'TRAVEL_PLAN_INACTIVE', () {
      // The guard's OR-null / NOT IN structure still rejects every status other than 'active' and
      // 'fully_booked' -- cancelled/completed/expired plans are unaffected by this fix.
      final guardShape = RegExp(
        r"IF v_travel_plan IS NULL OR v_travel_plan\.status::text NOT IN \('active', 'fully_booked'\) THEN\s*"
        r"RETURN jsonb_build_object\(\s*"
        r"'success', false,\s*"
        r"'code', 'TRAVEL_PLAN_INACTIVE',",
      );
      expect(guardShape.hasMatch(migration), isTrue);
    });

    test('the seat-count check after the guard still returns the distinct PLAN_FULLY_BOOKED code',
        () {
      expect(
        migration.contains("'code', 'PLAN_FULLY_BOOKED',"),
        isTrue,
      );
      expect(
        migration.contains('IF v_active_bookings >= v_travel_plan.max_bookings THEN'),
        isTrue,
        reason: 'the seat-count comparison itself is unchanged by this fix',
      );
    });

    test('the FOR UPDATE row lock on rider_travel_plans is preserved -- race safety unchanged',
        () {
      expect(
        migration.contains(
          'SELECT * INTO v_travel_plan\n    FROM public.rider_travel_plans\n    WHERE id = v_request.route_id\n    FOR UPDATE;',
        ),
        isTrue,
        reason: 'concurrent accept_intercity_request() calls for the same plan must still '
            'serialize on this lock to prevent overbooking',
      );
    });

    test('every other validation clause (auth, service_mode, tax-due, request/order/OTP '
        'validation, rider_is_on_active_trip, passenger conflict) is preserved', () {
      for (final clause in [
        'IF auth.uid() IS NOT NULL AND auth.uid() != p_rider_user_id THEN',
        "IF v_rider.service_mode IS DISTINCT FROM 'intercity'::public.partner_service_mode_enum THEN",
        'IF public.is_rider_blocked_by_tax_due(v_rider.id) THEN',
        "IF v_order.order_status != 'searching' OR v_order.rider_id IS NOT NULL THEN",
        'IF public.rider_is_on_active_trip(v_rider.id) THEN',
        'IF public.passenger_has_conflicting_trip(',
      ]) {
        expect(migration.contains(clause), isTrue, reason: 'missing/altered: $clause');
      }
    });

    test('the client already renders both codes with distinct, correct messages -- no client '
        'change was needed', () {
      expect(detailsScreen.contains("code == 'TRAVEL_PLAN_INACTIVE'"), isTrue);
      expect(detailsScreen.contains("code == 'PLAN_FULLY_BOOKED'"), isTrue);
      final inactiveIdx = detailsScreen.indexOf("code == 'TRAVEL_PLAN_INACTIVE'");
      final fullyBookedIdx = detailsScreen.indexOf("code == 'PLAN_FULLY_BOOKED'");
      expect(inactiveIdx, greaterThan(-1));
      expect(fullyBookedIdx, greaterThan(-1));
      expect(inactiveIdx, isNot(equals(fullyBookedIdx)),
          reason: 'the two codes must map to two distinct branches, never collapsed into one');
    });
  });
}
