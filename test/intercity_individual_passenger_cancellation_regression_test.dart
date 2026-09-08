// Regression guard for Issue 4: a traveller with two accepted passengers on the same travel plan
// had no way to cancel just one of them -- the only cancel-like action in the app
// (_deleteTravelPlan) always cancels the ENTIRE travel plan, correctly refusing with "Cannot
// cancel this travel plan while a trip is already in progress" once any accepted trip had started
// -- the right response to the wrong request. A direct client-side attempt to cancel one order
// would separately (and correctly) be rejected by protect_order_state_columns_trigger, since no
// server-side function for this existed at all.
//
// FIX: two distinct cancellation concepts, kept separate as required:
//   A) cancel_intercity_request_by_traveller() -- a NEW RPC that cancels exactly ONE accepted
//      request/order, never the travel plan, never any other passenger. Scoped to 'confirmed'/
//      'paid' requests only (not yet in_progress, mirroring guard_travel_plan_cancellation's own
//      philosophy). Requires a reason. Reuses two ALREADY-EXISTING triggers for the rest:
//      on_intercity_request_change() (passenger notification) and
//      sync_travel_plan_status_after() (revives a fully_booked plan back to active) -- no new
//      notification or plan-status logic was added.
//   B) _deleteTravelPlan (intercity_bookings_screen.dart) remains the full-plan cancellation path,
//      completely untouched by this fix.
//
// This file is a structural regression guard (reads the real migration/Dart source, following the
// pattern already used throughout this test suite for backend correctness that can't run against a
// live Supabase instance in a plain unit test).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read(
    'supabase/migrations/20260829000000_cancel_individual_accepted_intercity_request.sql',
  );
  final detailsScreen = _read(
    'lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart',
  );
  final matchingService = _read(
    'lib/features/intercity/shared/services/intercity_matching_service.dart',
  );
  final bookingsScreen = _read(
    'lib/features/rider/intercity/intercity_bookings_screen.dart',
  );

  group('Issue 4 -- cancel_intercity_request_by_traveller() (individual passenger cancellation)',
      () {
    test('1. only ever targets the one request passed in -- never rider_travel_plans, never '
        'another request/order', () {
      expect(migration.contains('UPDATE public.rider_travel_plans'), isFalse,
          reason: 'must never write to the travel plan itself -- that is a completely separate '
              'operation');
      expect(
        migration.contains('WHERE id = p_request_id'),
        isTrue,
      );
      expect(
        migration.contains('WHERE id = v_order.id'),
        isTrue,
        reason: 'the order UPDATE must be scoped to this one request\'s own linked order',
      );
    });

    test('is scoped to confirmed/paid requests only, never in_progress', () {
      expect(
        migration.contains("IF v_request.status NOT IN ('confirmed', 'paid') THEN"),
        isTrue,
        reason: 'an already-in_progress trip is a different, riskier operation this function '
            'must not attempt -- matches guard_travel_plan_cancellation\'s own philosophy',
      );
    });

    test('6. requires a non-empty cancellation reason', () {
      expect(
        migration.contains("IF p_cancel_reason IS NULL OR btrim(p_cancel_reason) = '' THEN"),
        isTrue,
      );
      expect(
        migration.contains("'cancelled_reason', p_cancel_reason"),
        isTrue,
        reason: 'the reason must be persisted on the request',
      );
      expect(
        migration.contains('cancel_reason = p_cancel_reason'),
        isTrue,
        reason: 'the reason must also be persisted on the order, matching every other '
            'cancellation path in this schema',
      );
    });

    test('uses the authorized bypass pattern for the protected order_status column, never a raw '
        'client-side UPDATE', () {
      expect(
        migration.contains("PERFORM set_config('app.bypass_order_state_guard', 'true', true);"),
        isTrue,
        reason: 'must use the same authorized pattern every other legitimate status-changing '
            'function uses, not work around protect_order_state_columns_trigger',
      );
    });

    test('4. is restricted to the calling traveller\'s own request via auth.uid()', () {
      expect(
        migration.contains('FROM public.riders WHERE user_id = auth.uid()'),
        isTrue,
      );
      expect(
        migration.contains('IF v_request.traveller_id != v_rider.id THEN'),
        isTrue,
        reason: 'a traveller must never be able to cancel another traveller\'s request',
      );
    });

    test('3. reuses on_intercity_request_change() and sync_travel_plan_status_after() for '
        'notification and plan-status effects -- no duplicated logic', () {
      // This migration must not define its own notification call or its own travel-plan revival
      // logic -- both already fire automatically from the intercity_requests UPDATE via existing
      // triggers (trigger_intercity_request_change, trigger_sync_travel_plan_status).
      expect(migration.contains('send_push_notification_fnc'), isFalse,
          reason: 'notification must come from the existing on_intercity_request_change() '
              "trigger's unconditional 'cancelled' branch, not a new call here");
      expect(migration.contains("status = 'active'"), isFalse,
          reason: 'plan revival must come from the existing sync_travel_plan_status_after() '
              'trigger, not new logic here');
    });

    test('2. other accepted passengers on the same plan are structurally unaffected (no '
        'route_id-scoped UPDATE exists in this function)', () {
      expect(migration.contains('WHERE route_id ='), isFalse,
          reason: 'unlike the whole-plan cascade (cascade_cancel_travel_plan_dependents), this '
              'function must never touch other requests on the same plan');
    });

    test('is granted to authenticated', () {
      expect(
        migration.contains(
          'GRANT EXECUTE ON FUNCTION public.cancel_intercity_request_by_traveller(uuid, text) TO authenticated;',
        ),
        isTrue,
      );
    });
  });

  group('Issue 4 -- client wiring', () {
    test('IntercityMatchingService exposes a dedicated wrapper for the new RPC', () {
      expect(
        matchingService.contains('static Future<Map<String, dynamic>> cancelAcceptedPassengerRequest('),
        isTrue,
      );
      expect(
        matchingService.contains("_supabase.rpc('cancel_intercity_request_by_traveller'"),
        isTrue,
      );
    });

    test('travel_plan_details_screen shows a "Cancel This Passenger" action only for '
        'confirmed/paid requests, alongside (not replacing) the primary status button', () {
      expect(
        detailsScreen.contains(
          "final canCancelAccepted = reqStatus == 'confirmed' || reqStatus == 'paid';",
        ),
        isTrue,
      );
      expect(detailsScreen.contains("label: 'Cancel This Passenger'"), isTrue);
      expect(detailsScreen.contains('_cancelAcceptedPassenger(req'), isTrue);
    });

    test('the cancel dialog requires a reason and calls the service before refreshing', () {
      final start = detailsScreen.indexOf('Future<void> _cancelAcceptedPassenger(');
      expect(start, greaterThan(-1));
      final body = detailsScreen.substring(start, start + 3000);
      expect(body.contains('if (reason == null || reason.isEmpty) return;'), isTrue,
          reason: 'must not call the RPC with an empty/cancelled reason');
      expect(body.contains('IntercityMatchingService.cancelAcceptedPassengerRequest('), isTrue);
      expect(body.contains('_loadIntercityRequests();'), isTrue,
          reason: 'must refresh the list after a successful cancellation');
    });

    test('5. the dialog text makes clear only this one passenger is affected, not the whole plan',
        () {
      final start = detailsScreen.indexOf('Future<void> _cancelAcceptedPassenger(');
      final body = detailsScreen.substring(start, start + 1500);
      expect(
        body.contains('travel plan and any other accepted passengers stay active'),
        isTrue,
      );
    });
  });

  group('Issue 4 -- full travel-plan cancellation path is untouched', () {
    // UPDATED (Phase 9, Issue 2): the whole-plan cancellation write itself was deliberately moved
    // server-side into the new cancel_travel_plan_by_traveller() RPC (one canonical path,
    // replacing three separate direct client updates -- see
    // 20260901000002_cancel_travel_plan_by_traveller.sql). This individual-passenger-cancellation
    // migration still never touches that whole-plan path itself -- confirmed below by asserting
    // this migration's own SQL contains no whole-plan RPC/trigger redefinition, and that the
    // client's whole-plan entry point still exists and still results in nothing but a
    // rider_travel_plans.status transition (now via the RPC, not a direct client update).
    test('_deleteTravelPlan still results in nothing but a rider_travel_plans.status transition, '
        'now via the canonical cancel_travel_plan_by_traveller RPC instead of a direct client '
        'update', () {
      expect(
        bookingsScreen.contains(
          "await supabase.from('rider_travel_plans').update({'status': 'cancelled'}).eq('id', planId);",
        ),
        isFalse,
      );
      expect(bookingsScreen.contains('IntercityMatchingService.cancelTravelPlan('), isTrue);
      final rpcMigration = File(
        'supabase/migrations/20260901000002_cancel_travel_plan_by_traveller.sql',
      ).readAsStringSync();
      expect(
        rpcMigration.contains(
          "UPDATE public.rider_travel_plans\n    SET status = 'cancelled'::public.travel_plan_status_enum,",
        ),
        isTrue,
      );
    });

    test('the whole-plan cancellation guard and cascade (20260729000003) are not redefined by '
        'this migration', () {
      // The header comment mentions both functions by name for context, but this migration must
      // never CREATE OR REPLACE either one -- that would mean silently redefining a different,
      // already-deployed function as an unintended side effect of this fix.
      expect(
        migration.contains('CREATE OR REPLACE FUNCTION public.guard_travel_plan_cancellation'),
        isFalse,
      );
      expect(
        migration.contains(
          'CREATE OR REPLACE FUNCTION public.cascade_cancel_travel_plan_dependents',
        ),
        isFalse,
      );
    });
  });
}
