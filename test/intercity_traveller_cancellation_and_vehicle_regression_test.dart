// Regression guard for the Phase 9 intercity TRAVELLER fixes:
//   Issue 1 -- individual accepted-passenger cancellation (professional upgrade: predefined
//             reason chips, cancelled_reason column, cancelled_scope tagging, differentiated
//             notification wording).
//   Issue 2 -- whole travel-plan cancellation, which previously failed silently for ANY plan
//             with at least one accepted passenger because cascade_cancel_travel_plan_dependents()
//             was missing the app.bypass_order_state_guard bypass before writing orders.order_status
//             -- root-caused via live pg_get_functiondef inspection, not assumption.
//   Issue 3 -- CAR-shown-as-BIKE mismatch, traced to rider_kyc.vehicle_type (plus hardcoded
//             'bike'/"BIKE" fallbacks) being used instead of the authoritative
//             rider_travel_plans.vehicle_type for the specific booked trip.
//
// Structural guard (reads the real source + migration SQL as text), matching the pattern used
// throughout this suite for backend correctness that can't run against a live Supabase instance
// in this environment. Numbered per the 20-point test spec: A1-8 (individual cancellation),
// B9-16 (whole travel-plan cancellation), C17-20 (vehicle-type correctness).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final reasonColumnsMigration =
      _read('supabase/migrations/20260901000000_intercity_cancellation_reason_columns.sql');
  final cascadeFixMigration = _read(
    'supabase/migrations/20260901000001_fix_cascade_cancel_travel_plan_dependents.sql',
  );
  final cancelPlanRpcMigration =
      _read('supabase/migrations/20260901000002_cancel_travel_plan_by_traveller.sql');
  final individualScopeMigration = _read(
    'supabase/migrations/20260901000003_cancel_intercity_request_reason_column_and_scope.sql',
  );
  final notificationWordingMigration = _read(
    'supabase/migrations/20260901000004_intercity_cancellation_notification_wording.sql',
  );
  final matchingService =
      _read('lib/features/intercity/shared/services/intercity_matching_service.dart');
  final travelPlanDetailsScreen =
      _read('lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart');
  final intercityBookingsScreen =
      _read('lib/features/rider/intercity/intercity_bookings_screen.dart');
  final riderHomeTab = _read('lib/features/rider/home/rider_home_tab.dart');
  final notificationService =
      _read('lib/modules/notifications/services/notification_service.dart');
  final getLiveOrderStatus = _read('supabase/functions/get-live-order-status/index.ts');
  final realtimeOrderController =
      _read('lib/core/services/realtime/realtime_order_controller.dart');
  final intercityTrackingScreen =
      _read('lib/features/intercity/shared/screens/intercity_tracking_screen.dart');
  final intercitySearchingScreen =
      _read('lib/features/intercity/shared/screens/intercity_searching_screen.dart');
  final cancellationReasonDialog =
      _read('lib/shared/widgets/cancellation_reason_dialog.dart');

  group('A -- Individual accepted-passenger cancellation', () {
    test('A1: cancel_intercity_request_by_traveller requires a non-empty reason', () {
      expect(
        individualScopeMigration.contains(
          "IF p_cancel_reason IS NULL OR btrim(p_cancel_reason) = '' THEN",
        ),
        isTrue,
      );
    });

    test('A2: only the traveller who owns the request can cancel it', () {
      expect(
        individualScopeMigration.contains('IF v_request.traveller_id != v_rider.id THEN'),
        isTrue,
      );
      expect(individualScopeMigration.contains("'code', 'UNAUTHORIZED'"), isTrue);
    });

    test('A3: only an already-accepted, not-yet-started request can be cancelled this way '
        '(never a trip already in_progress)', () {
      expect(
        individualScopeMigration.contains("IF v_request.status NOT IN ('confirmed', 'paid') THEN"),
        isTrue,
      );
    });

    test('A4: the cancellation reason is written to the new cancelled_reason column, not only '
        'jsonb metadata', () {
      expect(reasonColumnsMigration.contains('ADD COLUMN IF NOT EXISTS cancelled_reason text;'),
          isTrue);
      expect(individualScopeMigration.contains('cancelled_reason = p_cancel_reason,'), isTrue);
    });

    test('A5: the request is tagged cancelled_scope = individual_request so the notification '
        'trigger can distinguish it from a whole-plan cancellation', () {
      expect(individualScopeMigration.contains("'cancelled_scope', 'individual_request'"), isTrue);
    });

    test('A6: the linked order is cancelled via the authorized bypass, and never touches another '
        "passenger's order", () {
      expect(
        individualScopeMigration
            .contains("PERFORM set_config('app.bypass_order_state_guard', 'true', true);"),
        isTrue,
      );
      expect(
        individualScopeMigration.contains(
          "IF v_order.id IS NOT NULL AND v_order.order_status = 'accepted' AND v_order.rider_id = v_rider.id THEN",
        ),
        isTrue,
      );
    });

    test('A7: the passenger notification is route-aware and matches the specified wording, '
        'without exposing the internal cancellation reason', () {
      expect(
        notificationWordingMigration.contains(
          "ELSIF NEW.metadata->>'cancelled_scope' = 'individual_request' THEN",
        ),
        isTrue,
      );
      expect(
        notificationWordingMigration.contains(
          "' was cancelled by the traveller. You can search for another available traveller.'",
        ),
        isTrue,
      );
    });

    test('A8: the traveller-facing UI now uses a predefined reason picker (not free text only) '
        'covering every specified reason', () {
      expect(
        travelPlanDetailsScreen.contains('_individualCancelReasons'),
        isTrue,
      );
      for (final reason in [
        'Passenger was rude',
        'Passenger was uncooperative',
        'Passenger changed plans',
        'Did not follow instructions',
        'Safety concern',
        'Other',
      ]) {
        expect(
          travelPlanDetailsScreen.contains("'$reason'"),
          isTrue,
          reason: 'missing predefined reason: $reason',
        );
      }
      expect(travelPlanDetailsScreen.contains('CancellationReasonDialog.show('), isTrue);
    });
  });

  group('B -- Whole travel-plan cancellation', () {
    test('B9: cancel_travel_plan_by_traveller requires a non-empty reason and exists as a '
        'SECURITY DEFINER RPC granted to authenticated', () {
      expect(
        cancelPlanRpcMigration.contains(
          "IF p_cancel_reason IS NULL OR btrim(p_cancel_reason) = '' THEN",
        ),
        isTrue,
      );
      expect(cancelPlanRpcMigration.contains('SECURITY DEFINER'), isTrue);
      expect(
        cancelPlanRpcMigration.contains(
          'GRANT EXECUTE ON FUNCTION public.cancel_travel_plan_by_traveller(uuid, text) TO authenticated;',
        ),
        isTrue,
      );
    });

    test('B10: only the traveller who owns the plan can cancel it', () {
      expect(
        cancelPlanRpcMigration.contains('IF v_plan.rider_id IS DISTINCT FROM v_rider.id THEN'),
        isTrue,
      );
      expect(cancelPlanRpcMigration.contains("'code', 'UNAUTHORIZED'"), isTrue);
    });

    test('B11 (root cause fix): a pre-trip plan cancellation with an accepted passenger no '
        'longer rolls back -- cascade_cancel_travel_plan_dependents now bypasses the order-state '
        'guard before writing orders.order_status', () {
      expect(
        cascadeFixMigration
            .contains("PERFORM set_config('app.bypass_order_state_guard', 'true', true);"),
        isTrue,
      );
      // The bypass must come BEFORE the orders UPDATE it protects.
      final bypassIndex = cascadeFixMigration
          .indexOf("PERFORM set_config('app.bypass_order_state_guard', 'true', true);");
      final ordersUpdateIndex = cascadeFixMigration.indexOf('UPDATE public.orders o');
      expect(bypassIndex, greaterThan(0));
      expect(ordersUpdateIndex, greaterThan(bypassIndex));
    });

    test('B12: a trip that has genuinely started (orders.trip_started_at IS NOT NULL) is still '
        'refused -- the authoritative signal, not a superficial status-label check', () {
      expect(
        cancelPlanRpcMigration.contains('o.trip_started_at IS NOT NULL'),
        isTrue,
      );
      expect(cancelPlanRpcMigration.contains("'code', 'TRIP_ALREADY_STARTED'"), isTrue);
      expect(
        cancelPlanRpcMigration
            .contains('Cannot cancel this travel plan while a trip is already in progress.'),
        isTrue,
      );
    });

    test('B13: cancelling the plan cascades to every still-open request/order on it (full '
        'cleanup), not just the plan row itself', () {
      expect(
        cascadeFixMigration.contains(
          "WHERE route_id = NEW.id\n          AND status IN ('request_sent', 'discussion_started', 'fare_agreed', 'confirmed', 'paid');",
        ),
        isTrue,
      );
    });

    test('B14: each cancelled passenger gets a distinct, route-aware, reason-aware notification '
        '-- explicitly not the generic per-request cancellation copy', () {
      expect(
        notificationWordingMigration
            .contains("IF NEW.metadata->>'cancelled_scope' = 'travel_plan' THEN"),
        isTrue,
      );
      expect(
        notificationWordingMigration.contains(
          "v_body := 'Your traveller has cancelled the travel plan from ' || v_plan_pickup || ' to ' || v_plan_dest",
        ),
        isTrue,
      );
      expect(
        notificationWordingMigration.contains('Please search for another available traveller.'),
        isTrue,
      );
    });

    test('B15: the traveller sees the exact required success message on a successful cancel, '
        'from every call site', () {
      expect(intercityBookingsScreen.contains('Travel plan cancelled successfully.'), isTrue);
      expect(riderHomeTab.contains('Travel plan cancelled successfully.'), isTrue);
    });

    test('B16: exactly one canonical cancellation path is used everywhere -- no remaining '
        "direct client write to rider_travel_plans.status = 'cancelled'", () {
      for (final source in [
        intercityBookingsScreen,
        riderHomeTab,
        notificationService,
        travelPlanDetailsScreen,
      ]) {
        expect(
          source.contains("from('rider_travel_plans').update({'status': 'cancelled'})"),
          isFalse,
        );
      }
      expect(matchingService.contains("_supabase.rpc('cancel_travel_plan_by_traveller'"), isTrue);
      expect(intercityBookingsScreen.contains('IntercityMatchingService.cancelTravelPlan('),
          isTrue);
      expect(riderHomeTab.contains('IntercityMatchingService.cancelTravelPlan('), isTrue);
      expect(
        notificationService.contains('IntercityMatchingService.cancelTravelPlan('),
        isTrue,
      );
      // Both cancellation flows share one reusable reason-picker widget (not 3+ bespoke dialogs).
      expect(cancellationReasonDialog.contains('class CancellationReasonDialog'), isTrue);
    });
  });

  group('C -- Vehicle-type correctness (CAR shown as BIKE)', () {
    test('C17: get-live-order-status resolves vehicle_type from the traveller\'s travel plan '
        '(via intercity_requests), not just rider_kyc, for intercity order types', () {
      expect(
        getLiveOrderStatus.contains(
          'order.order_type === "intercity_ride" || order.order_type === "intercity_parcel"',
        ),
        isTrue,
      );
      expect(
        getLiveOrderStatus
            .contains("rider_travel_plans!intercity_requests_route_id_fkey(vehicle_type)"),
        isTrue,
      );
      expect(getLiveOrderStatus.contains('intercityPlanVehicleType ?? order.vehicle_type'), isTrue);
      expect(
        getLiveOrderStatus.contains('intercityPlanVehicleType ?? rider.rider_kyc?.vehicle_type ?? null'),
        isTrue,
      );
    });

    test('C18: no hardcoded "bike" default masks a missing/wrong vehicle_type value on the '
        'client-side live-state poll', () {
      expect(realtimeOrderController.contains("'vehicle_type': riderData['vehicle_type'] ?? 'bike'"),
          isFalse);
      expect(realtimeOrderController.contains("'vehicle_type': riderData['vehicle_type'],"), isTrue);
    });

    test('C19: the client-side rider fetch is durable across realtime rider-row-change events -- '
        'it re-resolves the authoritative travel-plan vehicle_type on every call, not only the '
        'first, so a later realtime update cannot clobber a correct value back to the KYC vehicle',
        () {
      expect(
        RegExp(
          r"currentOrderType == 'intercity_ride'\s*\|\|\s*"
          r"currentOrderType == 'intercity_parcel'",
        ).hasMatch(realtimeOrderController),
        isTrue,
      );
      expect(
        realtimeOrderController
            .contains("rider_travel_plans!intercity_requests_route_id_fkey(vehicle_type)"),
        isTrue,
      );
      // Must run inside _fetchRider (called from realtime subscription callbacks), not only
      // fetchLiveOrderState (the periodic-poll-only path).
      final fetchRiderStart = realtimeOrderController.indexOf('Future<void> _fetchRider(');
      final fetchRiderBody =
          realtimeOrderController.substring(fetchRiderStart, fetchRiderStart + 5000);
      expect(fetchRiderBody.contains('intercity_requests'), isTrue);
    });

    test('C20: local ride/parcel vehicle_type resolution is completely untouched by the '
        'intercity-only fix (scoping guard present, no unconditional override)', () {
      // The edge function's intercity lookup is strictly gated to intercity order types.
      final gateIndex = getLiveOrderStatus.indexOf(
        'order.order_type === "intercity_ride" || order.order_type === "intercity_parcel"',
      );
      expect(gateIndex, greaterThan(0));
      // The manual-offer match-merge path in the searching screen now prefers the plan's own
      // vehicle_type (already fetched into planRes) over rider_kyc, matching
      // match-intercity-riders/index.ts's own planVehicle-first precedence -- intercity-only.
      expect(
        intercitySearchingScreen
            .contains("'vehicle_type': planRes['vehicle_type'] ?? kycRes?['vehicle_type'] ?? 'delivery',"),
        isTrue,
      );
      // The tracking screen's display fallback no longer asserts a specific vehicle type when
      // the value is legitimately unavailable.
      expect(intercityTrackingScreen.contains('?? "VEHICLE"'), isTrue);
      expect(intercityTrackingScreen.contains('?? "BIKE"'), isFalse);
    });

    test('C20b (audit follow-up): neither of the tracking screen\'s other two vehicle_type '
        'fallback chains (map marker icon, in-screen label) ever falls back to '
        'order.vehicleType -- that field is the PASSENGER\'s own booking-time preference for an '
        'intercity order, not the traveller\'s actual vehicle, and using it as a fallback '
        're-introduces the same CAR-shown-as-BIKE bug class', () {
      expect(
        intercityTrackingScreen.contains(
          "orderController.riderNotifier.value?['vehicle_type']?.toString() ?? orderController.orderNotifier.value?.vehicleType",
        ),
        isFalse,
      );
      expect(
        intercityTrackingScreen.contains(
          "orderController.riderNotifier.value?['vehicle_type']?.toString() ?? 'cab';",
        ),
        isTrue,
      );
      expect(
        intercityTrackingScreen.contains("rider?['vehicle_type']?.toString() ?? orderObj.vehicleType"),
        isFalse,
      );
      expect(
        intercityTrackingScreen.contains("rider?['vehicle_type']?.toString() ?? 'vehicle';"),
        isTrue,
      );
    });
  });
}
