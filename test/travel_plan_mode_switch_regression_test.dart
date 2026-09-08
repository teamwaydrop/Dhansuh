// Regression guard for the "Travel Plan creation locks Drop Partner out of Local Service" bug.
//
// Business rule: creating/scheduling an intercity Travel Plan must never block switching back to
// Local Service -- only an actually STARTED/ACTIVE trip may do that. The enforcement for this
// lives entirely server-side (supabase/migrations), so -- following the pattern already used by
// test/payment_flow_regression_test.dart and test/chat_regression_test.dart -- this file can't
// exercise it against a live Supabase instance. Instead it verifies the guarantee structurally:
// it finds the *latest* migration that (re)defines each function under test (migrations are
// additive/CREATE OR REPLACE in this codebase, never edited in place) and asserts on that
// canonical body, so a later migration reintroducing the bug fails this file immediately.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Returns just the SQL body of the function whose `CREATE OR REPLACE FUNCTION <header>` exactly
/// matches [header], taken from the *last* (by filename, which is date-ordered) migration that
/// defines it -- i.e. the current, live definition after every migration has applied. Migrations
/// are additive (CREATE OR REPLACE, never edited in place) in this codebase, so the last file
/// wins. Deliberately returns only the function body (up to its closing `$$ LANGUAGE`), not the
/// whole migration file, so prose comments elsewhere in that file (which legitimately reference
/// things the function body itself must NOT reference) can't cause false positives/negatives.
String _latestFunctionBody(String header) {
  final needle = 'CREATE OR REPLACE FUNCTION public.$header';
  final dir = Directory('supabase/migrations');
  final matches = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  String? latestBody;
  for (final f in matches) {
    final content = f.readAsStringSync();
    final start = content.indexOf(needle);
    if (start == -1) continue;
    final end = content.indexOf(r'$$ LANGUAGE', start);
    latestBody = end == -1 ? content.substring(start) : content.substring(start, end);
  }
  if (latestBody == null) {
    throw StateError('No migration defines $needle');
  }
  return latestBody;
}

void main() {
  group('prevent_service_mode_switch_during_active_order (Service Mode <-> Travel Plan lock)', () {
    final triggerFnSql = _latestFunctionBody('prevent_service_mode_switch_during_active_order()');

    test('does NOT gate on rider_travel_plans existing/active at all', () {
      // The bug: a second, independent block counted ANY rider_travel_plans row with
      // status = 'active' -- true from the moment a plan is created, since creation always
      // inserts status: 'active' (see post_travel_plan_screen.dart) and nothing ever flips it
      // to a distinct "started" state. That block must be gone, not merely narrowed.
      expect(triggerFnSql.contains('rider_travel_plans'), isFalse,
          reason: 'Service Mode switch must never be gated on a Travel Plan row existing/being active');
    });

    test('still gates on the canonical "actually busy" predicate', () {
      expect(triggerFnSql.contains('rider_is_on_active_trip(NEW.id)'), isTrue);
    });

    test('rejection message refers to an active trip, not a travel plan', () {
      expect(triggerFnSql.contains('a trip is active'), isTrue);
      expect(triggerFnSql.contains('Travel Plan'), isFalse);
    });
  });

  group('rider_is_on_active_trip (canonical busy predicate, scenarios 4/5/6/10)', () {
    final busyFnSql = _latestFunctionBody('rider_is_on_active_trip(p_rider_id uuid)');

    test('an intercity/long-distance order is only busy once trip_started_at is set (Start Trip pressed)', () {
      // Scenarios 1-3, 6: accepted-but-not-started (or cancelled) intercity bookings must not
      // count as busy.
      expect(busyFnSql.contains('trip_started_at IS NOT NULL'), isTrue);
    });

    test('mid-trip statuses always count as busy regardless of order type', () {
      // Scenario 4: once actually started/active, blocking must hold.
      expect(busyFnSql.contains("'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing'"), isTrue);
    });

    test('a local order is busy from the moment it is accepted (existing conflict protection, scenario 10)', () {
      expect(busyFnSql.contains("get_required_service_mode(o.order_type::text, o.distance_meters) = 'local'"), isTrue);
    });
  });

  group('Start Trip never touches rider_travel_plans.status', () {
    test('start_intercity_trip_for_plan only sets orders.trip_started_at / intercity_requests.status', () {
      final sql = File('supabase/migrations/20260721000003_start_intercity_trip_for_plan.sql').readAsStringSync();
      expect(sql.contains('UPDATE public.rider_travel_plans'), isFalse,
          reason: 'Travel plan status must stay "active" through Start Trip -- trip_started_at on '
              'individual orders is the only started/active signal, per rider_is_on_active_trip()');
      expect(sql.contains('SET trip_started_at = now()'), isTrue);
    });
  });

  group('Service Mode change sheet surfaces the active-trip rejection with correct copy', () {
    final screenSrc =
        File('lib/features/rider/onboarding/screens/service_mode_selection_screen.dart').readAsStringSync();

    test('matches on the actual current trigger message ("trip is active"), not a stale one', () {
      expect(screenSrc.contains("raw.contains('trip is active')"), isTrue);
    });

    test('shows the requested Local Service wording, not a raw exception dump', () {
      expect(screenSrc.contains('Complete or end your active trip before switching to Local Service.'), isTrue);
    });
  });
}
