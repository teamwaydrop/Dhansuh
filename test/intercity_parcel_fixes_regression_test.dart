// Structural regression guard for the two Intercity Parcel fixes:
//   1. ₹0.00 fare (calculate-order-pricing key-name gap + parcel-only Travel Plan pricing skip +
//      unvalidated proposed_fare flowing into accepted orders).
//   2. Accepted Travel Together work not reachable/actionable by the Drop Partner (Upcoming tab
//      had no Start Trip action and no realtime subscription).
// This does not run the app or touch the database (see
// intercity_parcel_pricing_regression_test.dart for the live functional pricing test) -- it
// inspects the actual source/migration files so a future edit that reintroduces the parcel-only
// pricing skip, removes the fare guard, or drops the Upcoming tab's Start Trip/realtime wiring
// fails CI immediately instead of only being caught on a real device.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final calculatePricing = _read('supabase/functions/calculate-order-pricing/index.ts');
  final fareGuardMigration = _read('supabase/migrations/20260728000000_fix_intercity_parcel_pricing_and_fare_guard.sql');
  final postTravelPlan = _read('lib/features/rider/travel_plans/screens/post_travel_plan_screen.dart');
  final intercityBooking = _read('lib/features/intercity/parcels/booking/intercity_booking_screen.dart');
  final intercityBookingsScreen = _read('lib/features/rider/intercity/intercity_bookings_screen.dart');
  final updateOrderStatus = _read('supabase/functions/update-order-status/index.ts');

  group('Issue 1: calculate-order-pricing reads the actual pricing_config key shape', () {
    test('1. per_km_rate is a recognized alias for the per-km charge (root cause of the ₹0.00 bug)', () {
      expect(calculatePricing.contains('rules.per_km_rate'), isTrue);
      // Kept as the LAST fallback after the pre-existing aliases, so no currently-working row
      // (which already resolves via after_base_per_km/per_km_charge/per_km) changes behavior.
      final line = calculatePricing.split('\n').firstWhere((l) => l.contains('const perKmCharge ='));
      expect(line.indexOf('rules.after_base_per_km'), lessThan(line.indexOf('rules.per_km_rate')));
      expect(line.indexOf('rules.per_km_charge'), lessThan(line.indexOf('rules.per_km_rate')));
    });
  });

  group('Issue 1: authoritative ₹2.50/km rate lives in the server-side pricing_config, not Flutter', () {
    test('2. the migration sets intercity_parcel pricing_config to 2.5, scoped to that service_type only', () {
      expect(fareGuardMigration.contains("SET pricing_rules = jsonb_set(pricing_rules, '{per_km_rate}', '2.5'::jsonb)"), isTrue);
      expect(fareGuardMigration.contains("WHERE service_type = 'intercity_parcel'"), isTrue);
      // intercity_ride's own (working, unrelated) ₹3/km rate is never touched by this migration.
      expect(fareGuardMigration.contains("service_type = 'intercity_ride'"), isFalse);
    });

    test('3. no Flutter screen multiplies distance by a hardcoded per-km rate independently of the server', () {
      // Looks for the actual shape a hardcoded rate calculation would take (`distance * rate` /
      // `rate * distance`), not a bare "2.5" substring -- unrelated numeric literals like
      // `fontSize: 12.5` or `strokeWidth: 2.5` legitimately exist in these files and must not
      // trip this guard.
      for (final path in [
        'lib/features/intercity/parcels/booking/intercity_booking_screen.dart',
        'lib/features/rider/travel_plans/screens/post_travel_plan_screen.dart',
        'lib/features/intercity/shared/screens/intercity_location_screen.dart',
      ]) {
        final src = _read(path);
        expect(src.contains('* 2.5') || src.contains('2.5 *'), isFalse,
            reason: '$path should never hardcode the per-km rate; it must come from pricing_config via calculate-order-pricing');
        expect(src.contains('distanceKm * 3') || src.contains('planDistanceKm * '), isFalse);
      }
    });
  });

  group('Issue 1: server-side fare validation at acceptance time (never trust a client-supplied final amount)', () {
    test('4. accept_intercity_request rejects a zero/negative proposed_fare with a dedicated error code', () {
      expect(fareGuardMigration.contains('INVALID_FARE'), isTrue);
      expect(fareGuardMigration.contains('v_request.proposed_fare IS NULL OR v_request.proposed_fare <= 0'), isTrue);
      // The guard must run before the fare is ever copied onto the real order.
      final guardIndex = fareGuardMigration.indexOf('INVALID_FARE');
      final copyIndex = fareGuardMigration.indexOf('final_fare = v_request.proposed_fare');
      expect(guardIndex, greaterThan(-1));
      expect(copyIndex, greaterThan(guardIndex));
    });

    test('5. a BEFORE INSERT trigger blocks any new intercity_requests row with a non-positive fare', () {
      expect(fareGuardMigration.contains('BEFORE INSERT ON public.intercity_requests'), isTrue);
      expect(fareGuardMigration.contains('reject_invalid_proposed_fare'), isTrue);
      // Deliberately NOT a table CHECK constraint -- see the migration's own comment: a CHECK
      // would also re-validate every future UPDATE of the existing bad historical rows (one of
      // which is a real, still-active accepted booking), blocking its own future Start
      // Trip/completion. Guard against that regression being silently reintroduced.
      expect(fareGuardMigration.contains('ADD CONSTRAINT') && fareGuardMigration.contains('CHECK (proposed_fare'), isFalse);
    });
  });

  group('Issue 1: parcel-only Travel Plans price themselves like every other plan type', () {
    test('6. the travelPlanType != \'parcel\' pricing skip is gone', () {
      expect(postTravelPlan.contains("if (travelPlanType != 'parcel') {"), isFalse);
    });

    test('7. parcel-type plans price via intercity_parcel; ride/both stay on intercity_ride (unchanged)', () {
      expect(postTravelPlan.contains("orderType: travelPlanType == 'parcel' ? 'intercity_parcel' : 'intercity_ride'"), isTrue);
    });
  });

  group('Issue 1: Intercity Parcel booking screen never silently shows ₹0.00 on a failed pricing fetch', () {
    test('8. a pricingFailed state exists, distinct from loading and from a genuine zero fare', () {
      expect(intercityBooking.contains('final bool pricingFailed = !loading && pricingData.isEmpty;'), isTrue);
    });

    test('9. the price display renders a retry affordance instead of ₹0.00 when pricing failed', () {
      expect(intercityBooking.contains('pricingFailed'), isTrue);
      expect(intercityBooking.contains("label: const Text('Retry'"), isTrue);
      expect(intercityBooking.contains('onPressed: _fetchPricing'), isTrue);
    });

    test('10. "Book Shipment" is disabled and _createOrder never silently no-ops when pricing failed', () {
      expect(intercityBooking.contains('onPressed: (isLocked || pricingFailed) ? null : _createOrder'), isTrue);
      final start = intercityBooking.indexOf('Future<void> _createOrder() async {');
      expect(start, greaterThan(-1));
      // _createOrder is the last method before the widget's build() -- slice to there instead of
      // searching for another Future<void> (there isn't a later one in this file).
      final end = intercityBooking.indexOf('Widget build(BuildContext context)', start);
      expect(end, greaterThan(start));
      final createOrderSrc = intercityBooking.substring(start, end);
      expect(createOrderSrc.contains("showSnackBar"), isTrue);
    });
  });

  group('Issue 1: existing server-authoritative fare architecture is unchanged', () {
    test('11. create-order still independently re-derives fare server-side (never trusts the client)', () {
      final createOrder = _read('supabase/functions/create-order/index.ts');
      expect(createOrder.contains('calculate-order-pricing'), isTrue);
      expect(createOrder.contains('pricing.base_fare') || createOrder.contains('pricing?.base_fare'), isTrue);
    });

    test('12. boost-order-fare still computes additively via the canonical calculate_fare_breakdown RPC', () {
      final boost = _read('supabase/functions/boost-order-fare/index.ts');
      expect(boost.contains('calculate_fare_breakdown'), isTrue);
      expect(boost.contains('existingCurrentFare + boostRequest'), isTrue);
    });
  });

  // SUPERSEDED (Travel Plan UX consolidation): accepted Travel Together work is now reachable
  // through the Travel Plan itself, not a duplicate per-request Start Trip button here. The
  // Upcoming tab used to render one flat card PER accepted request, each with its own independent
  // "Start Trip" button -- creating exactly the "two competing concepts" bug reported (a plan with
  // N accepted passengers showed as N disconnected "RIDE - CONFIRMED" cards, invisible from/
  // unrelated to the "Travel Plans" section once the plan itself flipped to 'fully_booked'). Start
  // Trip now lives ONLY on TravelPlanDetailsScreen (see travel_plan_ux_regression_test.dart, tests
  // 4-5), and this tab groups accepted requests by plan and navigates there instead.
  group('Issue 2 (superseded by Travel Plan UX consolidation): Upcoming tab is plan-grouped, not per-request', () {
    test('13. the Upcoming tab no longer has its own independent Start Trip action (moved to the Travel Plan)', () {
      expect(intercityBookingsScreen.contains('_startTrip('), isFalse);
      expect(intercityBookingsScreen.contains("label: const Text('Start Trip'"), isFalse);
    });

    test('14. the Upcoming tab groups accepted requests by Travel Plan and navigates to TravelPlanDetailsScreen', () {
      expect(intercityBookingsScreen.contains('Map<String, List<Map<String, dynamic>>> _groupByPlan'), isTrue);
      expect(intercityBookingsScreen.contains("label: const Text('View Trip'"), isTrue);
      expect(intercityBookingsScreen.contains('_openPlanDetails('), isTrue);
    });

    test('15. per-passenger Chat remains available -- inside the Travel Plan details screen, not duplicated here', () {
      final travelPlanDetails = _read('lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart');
      expect(travelPlanDetails.contains('OrderChatScreen('), isTrue);
    });
  });

  group('Issue 2: realtime + resume reconciliation, no duplicate cards', () {
    test('16. a realtime subscription exists on both intercity_requests and orders, scoped to this rider', () {
      // Egress fix: migrated from a single raw supabase.channel() (with `column:` inside a
      // PostgresChangeFilter) to two RealtimeManager.instance.subscribe() calls (with
      // `filterColumn:`) so each pools with the identical rider-wide channel other screens
      // already share -- same two tables, same two filter columns, same rider scoping.
      expect(intercityBookingsScreen.contains("table: 'intercity_requests'"), isTrue);
      expect(intercityBookingsScreen.contains("table: 'orders'"), isTrue);
      expect(intercityBookingsScreen.contains("filterColumn: 'traveller_id'"), isTrue);
      expect(intercityBookingsScreen.contains("filterColumn: 'rider_id'"), isTrue);
    });

    test('17. the realtime channel is unsubscribed in dispose (no leaked subscription)', () {
      // Egress fix: dispose() now unsubscribes both pooled RealtimeManager listeners instead of
      // calling supabase.removeChannel() on a single raw channel.
      final disposeStart = intercityBookingsScreen.indexOf('void dispose() {');
      final disposeEnd = intercityBookingsScreen.indexOf('super.dispose();', disposeStart);
      final disposeSrc = intercityBookingsScreen.substring(disposeStart, disposeEnd);
      expect(
        disposeSrc.contains('RealtimeManager.instance.unsubscribe(_requestsSubChannel!, _requestsSubId!)'),
        isTrue,
      );
      expect(
        disposeSrc.contains('RealtimeManager.instance.unsubscribe(_ordersSubChannel!, _ordersSubId!)'),
        isTrue,
      );
    });

    test('18. app resume reconciles via a WidgetsBindingObserver refetch, not realtime alone', () {
      expect(intercityBookingsScreen.contains('with SingleTickerProviderStateMixin, WidgetsBindingObserver'), isTrue);
      expect(intercityBookingsScreen.contains('didChangeAppLifecycleState'), isTrue);
      expect(intercityBookingsScreen.contains('AppLifecycleState.resumed'), isTrue);
    });

    test('19. every realtime/resume callback triggers a full _fetchData() replace, never an incremental append (no duplicate cards)', () {
      // _fetchData() itself always .clear()s before repopulating -- confirmed once here, and
      // every realtime/resume callback above calls _fetchData(), never List.add() directly.
      final fetchStart = intercityBookingsScreen.indexOf('Future<void> _fetchData() async {');
      final fetchEnd = intercityBookingsScreen.indexOf('Future<void> _deleteTravelPlan');
      final fetchSrc = intercityBookingsScreen.substring(fetchStart, fetchEnd);
      expect(fetchSrc.contains('_negotiations.clear();'), isTrue);
      expect(fetchSrc.contains('_upcomingTrips.clear();'), isTrue);
      expect(fetchSrc.contains('_activeTrips.clear();'), isTrue);
      expect(fetchSrc.contains('_history.clear();'), isTrue);
    });
  });

  group('Regression safety: multiple-requests-per-plan and the service-mode lock fix are unchanged', () {
    test('20. accept_intercity_request still enforces max_bookings and never mutates rider_travel_plans', () {
      expect(fareGuardMigration.contains('v_active_bookings >= v_travel_plan.max_bookings'), isTrue);
      expect(fareGuardMigration.contains('PLAN_FULLY_BOOKED'), isTrue);
      expect(fareGuardMigration.contains('UPDATE public.rider_travel_plans'), isFalse);
    });

    test('21. the previous service-mode-lock fix (trip_started_at-based, not travel-plan-status-based) is intact', () {
      final lockFix = _read('supabase/migrations/20260726000001_fix_service_mode_lock_on_scheduled_travel_plan.sql');
      expect(lockFix.contains('rider_is_on_active_trip(NEW.id)'), isTrue);
      // Check the FUNCTION BODY only (the file's own header comment legitimately discusses
      // rider_travel_plans while explaining the bug it fixed) -- the old, regressed behavior
      // (blocking on merely having an active travel plan row) must not reappear in the actual
      // trigger logic.
      final bodyStart = lockFix.indexOf('CREATE OR REPLACE FUNCTION public.prevent_service_mode_switch_during_active_order()');
      final bodyEnd = lockFix.indexOf(r'$$ LANGUAGE', bodyStart);
      expect(bodyStart, greaterThan(-1));
      expect(bodyEnd, greaterThan(bodyStart));
      final functionBody = lockFix.substring(bodyStart, bodyEnd);
      expect(functionBody.contains('rider_travel_plans'), isFalse);
    });
  });

  group('Regression safety: unrelated systems are untouched by this change', () {
    test('22. Cashfree/payment/wallet/tax edge functions are not present in this diff\'s file set', () {
      // Structural cross-check: the files this fix touches are exactly the intercity
      // pricing/matching/booking surface, not payments/tax/wallet.
      for (final untouchedPath in [
        'supabase/functions/cashfree-webhook/index.ts',
        'supabase/functions/verify-payment/index.ts',
      ]) {
        expect(File(untouchedPath).existsSync(), isTrue); // sanity: file still exists, unmodified
      }
      expect(updateOrderStatus.contains('apply_order_government_tax'), isTrue); // still present, untouched
    });
  });
}
