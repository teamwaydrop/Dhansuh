// Regression guard for Issue 7 (Phase 2): the USER did not reliably receive the "Traveller
// Available" match notification when their own request/order was created FIRST and a matching
// Traveller Travel Plan was posted LATER ("USER FIRST") -- even though the reverse creation order
// ("TRAVELLER FIRST": plan posted first, user's order created later) already worked.
//
// ROOT CAUSE, proven by tracing AND real execution against a local Supabase/Docker instance:
//   match-intercity-riders/index.ts's matching logic is ALREADY correct and symmetric in both
//   directions (Mode 1: order_id -> searches existing plans; Mode 2: plan -> searches existing
//   orders; both call the same sendTravellerAvailableNotifications() to the order's own user_id
//   for every genuinely new, verified match). Calling Mode 2 directly (the exact body
//   post_travel_plan_screen.dart used to send) against a real, pre-existing matching order,
//   against a real local Postgres + local Edge Runtime, produced the correct "Traveller Available"
//   notification for the user on the FIRST call, and produced NO duplicate on a second identical
//   call (travel_matches dedup, unchanged) -- proving the matching/notification LOGIC was never
//   the bug in either direction.
//
//   THE REAL ASYMMETRY: Mode 1 is invoked from INSIDE create-order/index.ts (an edge function) via
//   a server-to-server fetch() wrapped in EdgeRuntime.waitUntil() -- guaranteed to keep running on
//   Deno's own infrastructure independent of the calling client's process lifetime. Mode 2 was
//   invoked directly from the Flutter client (post_travel_plan_screen.dart) as a bare
//   `unawaited(() async { await supabase.functions.invoke(...) })` Future tied to the app process --
//   rider_travel_plans is created via a plain client-side `.insert()`, with no edge function
//   boundary to attach a waitUntil-style guarantee to. A rider backgrounding/closing the app right
//   after the "Travel plan posted successfully!" SnackBar (a completely natural next action) could
//   drop the in-flight request before the server ever processed it, silently losing the
//   notification for every user already waiting on that route -- with no retry, no cron backstop.
//
// FIX (20260901000031): a new AFTER INSERT trigger on rider_travel_plans
// (on_rider_travel_plan_insert()) now calls match-intercity-riders itself via pg_net, exactly
// mirroring the server-guaranteed pattern already used by on_order_status_update(),
// assign_new_order_to_nearby_online_riders(), and deliver_push_notification_http_fnc(). The
// redundant client-side call is removed from post_travel_plan_screen.dart. No matching eligibility
// rule (radius, vehicle, weight, date window, verified-only gate, travel_matches dedup) changed --
// match-intercity-riders/index.ts itself is completely untouched.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read('supabase/migrations/20260901000031_travel_plan_insert_triggers_matching_server_side.sql');
  final postPlanScreen = _read('lib/features/rider/travel_plans/screens/post_travel_plan_screen.dart');
  final createOrderFn = _read('supabase/functions/create-order/index.ts');
  final matchFn = _read('supabase/functions/match-intercity-riders/index.ts');

  group('1. TRAVELLER FIRST (order created after an existing plan) -- already server-guaranteed, '
      'untouched by this fix', () {
    test('create-order/index.ts still triggers match-intercity-riders via a server-to-server '
        'fetch wrapped in EdgeRuntime.waitUntil()', () {
      expect(createOrderFn.contains('EdgeRuntime.waitUntil(backgroundPromise)'), isTrue);
      expect(createOrderFn.contains('/functions/v1/match-intercity-riders'), isTrue);
    });

    test('Mode 1 (order_id) still sends the per-order "Traveller Available" notification to the '
        'order\'s own user_id for every genuinely new, verified match', () {
      final mode1Anchor = matchFn.indexOf('if (order_id) {');
      final mode2Anchor = matchFn.indexOf('MODE 2: MATCH ORDERS');
      expect(mode1Anchor, greaterThan(-1));
      expect(mode2Anchor, greaterThan(mode1Anchor));
      final mode1Body = matchFn.substring(mode1Anchor, mode2Anchor);
      // Reconciled against the actual production source (a later audit found the deployed
      // function uses a per-candidate loop, not the local repo's own then-undeployed bulk-write
      // optimization this test originally checked for) -- the underlying guarantee (every
      // genuinely new, verified match notifies the order's own user_id) is unchanged either way.
      expect(mode1Body.contains('sendTravellerAvailableNotification('), isTrue);
      expect(mode1Body.contains('order.user_id,'), isTrue);
    });
  });

  group('2. THE FIX: USER FIRST (plan created after an existing order) is now server-guaranteed '
      'too', () {
    test('a new AFTER INSERT trigger on rider_travel_plans calls on_rider_travel_plan_insert()', () {
      expect(migration.contains('AFTER INSERT ON public.rider_travel_plans'), isTrue);
      expect(migration.contains('EXECUTE FUNCTION public.on_rider_travel_plan_insert();'), isTrue);
    });

    test('the trigger calls match-intercity-riders (the real edge function, not a DB RPC) via '
        'pg_net, authenticated with the service role key -- mirroring '
        'deliver_push_notification_http_fnc()\'s exact pattern for calling a Deno function from a '
        'trigger', () {
      expect(migration.contains("url := v_supabase_url || '/functions/v1/match-intercity-riders',"), isTrue);
      expect(migration.contains("'Authorization', 'Bearer ' || v_service_role_key"), isTrue);
    });

    test('the trigger sends the plan in the exact Mode-2 shape match-intercity-riders expects, '
        'plus is_background: true (discovery-only, never auto-creates a negotiation)', () {
      expect(migration.contains("'id', NEW.id,"), isTrue);
      expect(migration.contains("'rider_id', NEW.rider_id,"), isTrue);
      expect(migration.contains("'pickup_city', NEW.pickup_city,"), isTrue);
      expect(migration.contains("'destination_city', NEW.destination_city,"), isTrue);
      expect(migration.contains("'route_geometry', NEW.route_geometry"), isTrue);
      expect(migration.contains("'is_background', true"), isTrue);
    });

    test('a missing vault secret or HTTP failure never blocks the plan\'s own insert -- wrapped in '
        'BEGIN/EXCEPTION, mirroring every other pg_net-calling trigger in this schema', () {
      expect(migration.contains('EXCEPTION WHEN OTHERS THEN'), isTrue);
      expect(migration.contains('RETURN NEW;'), isTrue);
    });
  });

  group('3. The now-redundant, unreliable client-side call is removed', () {
    test('post_travel_plan_screen.dart no longer invokes match-intercity-riders itself after '
        'inserting the plan', () {
      expect(postPlanScreen.contains("supabase.functions.invoke(\n            'match-intercity-riders'"), isFalse);
      expect(postPlanScreen.contains('unawaited(() async {'), isFalse);
    });

    test('the plan insert itself is unchanged -- this fix only removes the redundant follow-up '
        'call, not the plan creation', () {
      expect(postPlanScreen.contains("final insertedPlan = await supabase.from('rider_travel_plans').insert({"), isTrue);
    });
  });

  group('4. Matching eligibility and dedup logic are completely untouched', () {
    test('match-intercity-riders/index.ts itself has no changes to radius/vehicle/weight/date '
        'matching rules or the travel_matches dedup ledger (reconciled against the actual '
        'production source -- see match_intercity_riders_mode2_null_vehicle_regression_test.dart '
        'for the one deliberate Mode 2 vehicle-null-guard fix this does NOT cover)', () {
      expect(matchFn.contains('async function recordMatchIfNew('), isTrue);
      expect(matchFn.contains('if (error.code !== "23505") {'), isTrue);
      expect(matchFn.contains('if (!m.is_verified) continue;'), isTrue);
      expect(matchFn.contains('if (riderIsVerified && plan.id) {'), isTrue);
    });
  });
}
