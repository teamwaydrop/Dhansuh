// Regression guard for "Intercity Travel Plan must remain the canonical UX after accepting
// requests" (tests J.1-J.6).
//
// Root cause fixed: a DB trigger (20260617000001_intercity_workflow_updates.sql) automatically
// flips rider_travel_plans.status from 'active' to 'fully_booked' the instant confirmed/paid/
// in_progress bookings reach max_bookings -- for the common single-seat plan, that's the very
// first acceptance. rider_home_tab.dart's "Intercity Travel Plans" section and
// intercity_bookings_screen.dart's "Travel Plans" tab both queried status='active' only, so the
// plan card vanished from both places at exactly the moment a request was accepted, leaving only
// a disconnected, ungrouped "Upcoming" card (its own independent "Start Trip" button included) as
// the sole remaining trace of that plan -- the two-competing-concepts bug reported.
//
// This file follows the existing structural-regression pattern used by
// travel_plan_mode_switch_regression_test.dart (Dart/SQL source read as text; no live Supabase).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final riderHomeTab = _read('lib/features/rider/home/rider_home_tab.dart');
  final intercityBookings = _read('lib/features/rider/intercity/intercity_bookings_screen.dart');
  final travelPlanDetails = _read('lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart');

  group('Test 1: Travel Plan remains visible after accepting one request', () {
    test('rider_home_tab.dart fetches both active AND fully_booked plans, not active only', () {
      expect(riderHomeTab.contains("inFilter('status', ['active', 'fully_booked'])"), isTrue);
      // The old, buggy query must be gone, not merely supplemented.
      expect(riderHomeTab.contains(".eq('status', 'active')\n          .order('travel_date'"), isFalse);
    });

    test('intercity_bookings_screen.dart Travel Plans tab fetches both statuses too', () {
      expect(intercityBookings.contains("inFilter('status', ['active', 'fully_booked'])"), isTrue);
    });

    test('the Home Travel Plan card shows Accepted/Pending counts instead of just disappearing', () {
      expect(riderHomeTab.contains('_planAcceptedCounts'), isTrue);
      expect(riderHomeTab.contains('_planPendingCounts'), isTrue);
      expect(riderHomeTab.contains("'confirmed', 'paid', 'in_progress'"), isTrue);
    });
  });

  group('Test 2 & 3: accepted users are associated with, and grouped under, the correct Travel Plan', () {
    test('the Upcoming tab groups accepted intercity_requests rows by their Travel Plan (route_id)', () {
      expect(intercityBookings.contains('Map<String, List<Map<String, dynamic>>> _groupByPlan'), isTrue);
      expect(intercityBookings.contains('final grouped = _groupByPlan(_upcomingTrips);'), isTrue);
      // One card per PLAN, not one card per accepted request.
      expect(intercityBookings.contains('itemCount: planIds.length'), isTrue);
    });

    test('multiple accepted passengers/parcels on the same plan render under one "N Accepted" card', () {
      expect(intercityBookings.contains("'\$acceptedCount Accepted'"), isTrue);
      expect(intercityBookings.contains('final acceptedCount = requests.length;'), isTrue);
    });

    test('the old flat "RIDE - CONFIRMED" per-request badge text is gone', () {
      expect(intercityBookings.contains("(isRide ? 'RIDE' : 'PARCEL') + ' - ' + status!.toUpperCase()"), isFalse);
    });
  });

  group('Test 4 & 5: Start Trip lives only in the Travel Plan, and cannot double-start', () {
    test('the Upcoming tab no longer has its own independent Start Trip button/handler', () {
      expect(intercityBookings.contains('_startTrip('), isFalse);
      expect(intercityBookings.contains('_startingTripRouteId'), isFalse);
      expect(intercityBookings.contains("label: const Text('Start Trip'"), isFalse);
    });

    test('the Upcoming tab instead navigates into TravelPlanDetailsScreen ("View Trip")', () {
      expect(intercityBookings.contains("label: const Text('View Trip'"), isTrue);
      expect(intercityBookings.contains('_openPlanDetails(Map<String, dynamic>.from(plan))'), isTrue);
    });

    test('TravelPlanDetailsScreen is the sole Start Trip surface and is in-flight-guarded against double taps', () {
      expect(travelPlanDetails.contains('Future<void> _startTripForPlan()'), isTrue);
      expect(travelPlanDetails.contains('onPressed: startingTrip ? null : _startTripForPlan'), isTrue);
    });

    test('start_intercity_trip_for_plan itself is idempotent (row-locked, re-selects only not-yet-started passengers)', () {
      final sql = _read('supabase/migrations/20260721000005_start_trip_never_depends_on_payment.sql');
      expect(sql.contains('FOR UPDATE'), isTrue);
      expect(sql.contains('trip_started_at IS NULL'), isTrue);
    });
  });

  group('Test 6: realtime refresh without app restart', () {
    test('rider_home_tab.dart subscribes to rider_travel_plans changes and reloads plans', () {
      expect(riderHomeTab.contains("table: 'rider_travel_plans'"), isTrue);
    });

    test('intercity_bookings_screen.dart subscribes to intercity_requests + orders and refetches on any change', () {
      expect(intercityBookings.contains("table: 'intercity_requests'"), isTrue);
      expect(intercityBookings.contains("table: 'orders'"), isTrue);
      expect(intercityBookings.contains('_subscribeRealtime'), isTrue);
    });

    test('TravelPlanDetailsScreen subscribes to matches/requests/orders for this specific plan', () {
      expect(travelPlanDetails.contains('_subscribeMatches') || travelPlanDetails.contains('_subscription'), isTrue);
      expect(travelPlanDetails.contains("table: 'intercity_requests'"), isTrue);
      expect(travelPlanDetails.contains("table: 'orders'"), isTrue);
    });

    test('app-resume reconciliation remains as a fallback (not the only refresh path)', () {
      expect(intercityBookings.contains('didChangeAppLifecycleState'), isTrue);
      expect(intercityBookings.contains('AppLifecycleState.resumed'), isTrue);
    });
  });

  group('Trip Details screen shows the real plan status, not a hardcoded one', () {
    test('the status badge is no longer hardcoded to always show "ACTIVE"', () {
      expect(travelPlanDetails.contains("child: const Text(\n                      'ACTIVE',"), isFalse);
      expect(travelPlanDetails.contains('isFullyBooked'), isTrue);
      expect(travelPlanDetails.contains("'FULLY BOOKED'"), isTrue);
    });
  });
}
