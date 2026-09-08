// Regression guard for Issue 1 (user-first intercity match notification missing): Mode 2 of
// match-intercity-riders/index.ts (fired by rider_travel_plans' AFTER INSERT trigger,
// on_rider_travel_plan_insert(), migration 20260901000031) incorrectly rejected an order with no
// vehicle preference (order.vehicle_type === null) against a Travel Plan with a specific vehicle
// (e.g. 'cab'), because vehicleMatches() coerces null to "" which can never equal a real vehicle
// type. Mode 1 already had the correct guard (`order.vehicle_type &&`); Mode 2 lacked it.
//
// ROOT CAUSE, PROVEN two ways:
//   1. Live production forensics (prior audit): a real `net._http_response` row for the exact
//      migration-31-triggered pg_net call, ~200ms after a matching plan's insert, returned
//      `{"success":true,...,"matches":[]}` for a case where cities/dates were compatible and the
//      only disqualifying factor was order.vehicle_type=null vs plan.vehicle_type='cab'. Zero
//      `travel_matches` rows with matched_direction='plan_first' existed anywhere in production,
//      before or after migration 31's deployment.
//   2. Local Supabase/Docker reproduction of the exact same scenario, both BEFORE and AFTER this
//      fix, calling the real Edge Function over HTTP (the same request shape
//      on_rider_travel_plan_insert() sends):
//        BEFORE: order.vehicle_type=null, plan.vehicle_type='cab' -> matches: [] (bug reproduced).
//        AFTER:  same inputs -> matches: [<the null-vehicle order>], travel_matches row created
//                (matched_direction='plan_first'), and a "Traveller Available" notification
//                inserted for the order's own user_id with the unchanged existing title/body/
//                payload shape. A second identical call created no duplicate notification. A
//                genuinely mismatched order (vehicle_type='bike' vs plan 'cab') remained correctly
//                excluded. An order whose travel_date had already passed remained correctly
//                excluded from both Mode 1 and Mode 2 (the production expiry hotfix, untouched).
//
// FIX: this migration/deploy is Edge-Function-only. The change is a single added guard
// (`order.vehicle_type &&`) on Mode 2's vehicle-matching condition, mirroring Mode 1's existing
// guard exactly, applied to the ACTUAL PRODUCTION SOURCE (downloaded and diffed against the local
// repo before editing) -- not the local repo's older/newer-but-undeployed version -- so the
// production-only travel_date expiry hotfix and the production per-candidate implementation are
// both preserved untouched. No matching eligibility rule, KYC/reliability/capacity check, route/
// corridor check, weight check, or notification payload shape was changed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final fn = _read('supabase/functions/match-intercity-riders/index.ts');

  group('1. THE FIX: Mode 2 vehicle check gains the same null-guard Mode 1 already has', () {
    test('Mode 1\'s existing guard is reproduced unchanged (the pattern this fix mirrors)', () {
      expect(
        fn.contains('if (isRideOrder && order.vehicle_type && !vehicleMatches(planVehicle, order.vehicle_type)) {'),
        isTrue,
      );
    });

    test('Mode 2\'s vehicle-matching condition now includes order.vehicle_type in its guard, '
        'exactly mirroring Mode 1', () {
      expect(
        fn.contains(
          'if (isRideOrder && order.vehicle_type && planVehicle !== "both" && planVehicle !== "all" && planVehicle !== null && planVehicle !== "") {',
        ),
        isTrue,
      );
      // The pre-fix condition (missing the order.vehicle_type guard) must no longer be present --
      // this is the exact string that would make this test fail against the pre-fix source.
      expect(
        fn.contains(
          'if (isRideOrder && planVehicle !== "both" && planVehicle !== "all" && planVehicle !== null && planVehicle !== "") {',
        ),
        isFalse,
      );
    });

    test('the inner vehicleMatches() call and mismatch logging are otherwise unchanged', () {
      final anchor = fn.indexOf('if (isRideOrder && order.vehicle_type && planVehicle !== "both"');
      expect(anchor, greaterThan(-1));
      final block = fn.substring(anchor, anchor + 500);
      expect(block.contains('if (!vehicleMatches(planVehicle, order.vehicle_type)) {'), isTrue);
      expect(block.contains('vehicle mismatch. planVehicle=\${planVehicle}, orderVehicle=\${order.vehicle_type}'), isTrue);
    });
  });

  group('2. Production-only fixes are preserved (verified against the actual downloaded '
      'production source before this edit, not the local repo\'s prior version)', () {
    test('the travel_date expiry hotfix is present in Mode 1', () {
      expect(
        fn.contains('if (orderTravelDate && new Date(orderTravelDate).getTime() < Date.now()) {'),
        isTrue,
      );
    });

    test('the travel_date expiry hotfix is present in Mode 2\'s candidate query', () {
      expect(fn.contains('.or(`travel_date.is.null,travel_date.gte.\${now}`);'), isTrue);
    });

    test('production\'s per-candidate matching implementation is preserved -- the local repo\'s '
        'undeployed bulk-write optimization (recordNewMatches/sendTravellerAvailableNotifications, '
        'plural) was NOT reintroduced', () {
      expect(fn.contains('async function recordMatchIfNew('), isTrue);
      expect(fn.contains('async function sendTravellerAvailableNotification('), isTrue);
      expect(fn.contains('async function recordNewMatches('), isFalse);
      expect(fn.contains('async function sendTravellerAvailableNotifications('), isFalse);
    });
  });

  group('3. Notification payload shape is completely unchanged', () {
    test('sendTravellerAvailableNotification still inserts the same title/body/type/payload keys', () {
      final anchor = fn.indexOf('async function sendTravellerAvailableNotification(');
      final blockEnd = fn.indexOf('async function getIntercitySettings', anchor);
      final block = fn.substring(anchor, blockEnd);
      expect(block.contains("title: \"Traveller Available\","), isTrue);
      expect(block.contains('body: "A verified traveller is available for your trip. Tap to view traveller details.",'), isTrue);
      expect(block.contains('notification_type: "traveller_available",'), isTrue);
      expect(block.contains("type: \"traveller_available\","), isTrue);
      expect(block.contains('order_id: orderId,'), isTrue);
      expect(block.contains('plan_id: planId,'), isTrue);
      expect(block.contains('rider_id: riderId,'), isTrue);
    });

    test('travel_matches dedup (recordMatchIfNew, unique_violation 23505 handling) is unchanged', () {
      expect(fn.contains('if (!error) return true;'), isTrue);
      expect(fn.contains('if (error.code !== "23505") {'), isTrue);
    });
  });

  group('4. Unrelated eligibility rules are untouched', () {
    test('KYC/reliability/capacity checks, route corridor, and weight rules are all still present', () {
      expect(fn.contains('rider_kyc'), isTrue);
      expect(fn.contains('rider_reliability_view'), isTrue);
      expect(fn.contains('travel_plan_capacity_view'), isTrue);
      expect(fn.contains('corridorRadiusKm'), isTrue);
      expect(fn.contains("parcelWeight >= 10.0 && planVehicle === \"bike\""), isTrue);
    });
  });
}
