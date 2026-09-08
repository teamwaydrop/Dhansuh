// Regression guard for Phase 12, Part C: the traveller's (rider's) OWN live-tracking marker and
// completion-screen vehicle image must reflect the vehicle actually used for THIS trip/order,
// never the rider's primary KYC-registered vehicle -- and, for intercity orders, never
// orders.vehicle_type either.
//
// ROOT CAUSE #1 (audited): rider_active_order_screen.dart sourced `vehicleType` from
// riderProfile.rider_kyc.vehicle_type first in two places -- the live tracking-marker JS call
// (_onLocalLocationUpdate) and the completion-screen vehicle image. A rider whose KYC primary
// vehicle is 'bike' but who is driving THIS trip on an approved 'auto'/'cab' would see the wrong
// marker/image on their own screen.
//
// ROOT CAUSE #2 (found while verifying the #1 fix, before shipping): a first-pass fix simply
// promoted orders.vehicle_type ahead of the KYC vehicle. For an INTERCITY order, orders.vehicle_type
// is the PASSENGER's own booking-time preference (can even be null for an "any" request) -- NOT
// the traveller's actual vehicle -- exactly the "CAR shown as BIKE" bug class already fixed once
// on the passenger-side screen (see intercity_traveller_cancellation_and_vehicle_regression_test.dart,
// tests C17-C20b) via rider_travel_plans.vehicle_type (joined through intercity_requests.route_id),
// never orders.vehicle_type. Confirmed live: create-order/index.ts's normalizedVehicleType comes
// straight from the client request body, and dbVehicleType is null when the passenger picks "any".
//
// FIX (final): _loadIntercityRequestMeta() (already querying intercity_requests for THIS order,
// scoped to parcel_id + traveller_id -- the exact same scoping realtime_order_controller.dart's
// _fetchRider() uses) is extended to also select the joined
// rider_travel_plans!intercity_requests_route_id_fkey(vehicle_type) and cache it in
// _intercityPlanVehicleType. Both vehicleType resolutions now try, in order:
//   1. _intercityPlanVehicleType (intercity only -- the travel plan's own vehicle, authoritative)
//   2. order?['vehicle_type'] (local ride/parcel -- authoritative there; harmless intercity fallback
//      while _loadIntercityRequestMeta is still in flight)
//   3. the KYC vehicle (last resort)
//   4. 'bike'
// No change to tracking_engine.js, no change to realtime/location/heading/bearing plumbing, no
// change to the already-correct passenger-side screen.
//
// This is a source-level structural guard (reads files as text), consistent with this repo's
// other regression tests.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final activeOrderScreen =
      _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');
  final trackingEngine = _read('assets/map/tracking_engine.js');
  final passengerTrackingScreen =
      _read('lib/features/intercity/shared/screens/intercity_tracking_screen.dart');

  group('1/2/3. Live tracking marker sources the CURRENT trip vehicle -- plan first, then order, then KYC', () {
    test('_onLocalLocationUpdate reads _intercityPlanVehicleType, then order, then KYC, in that order', () {
      expect(
        activeOrderScreen.contains(
          "final vehicleType = _intercityPlanVehicleType ??\n"
          "        order?['vehicle_type']?.toString().toLowerCase() ??\n"
          "        (kyc is Map ? kyc['vehicle_type']?.toString() : null) ??\n"
          "        'bike';",
        ),
        isTrue,
      );
    });

    test('the old KYC-first formula is gone from _onLocalLocationUpdate', () {
      final s = activeOrderScreen.indexOf('void _onLocalLocationUpdate(Position position)');
      final e = activeOrderScreen.indexOf('Future<void> _triggerInitialLocation', s);
      final body = activeOrderScreen.substring(s, e);
      expect(body.contains("kyc['vehicle_type']?.toString() ?? 'bike' : 'bike'"), isFalse);
    });

    test('_intercityPlanVehicleType, order, and kyc appear in strictly that order in the assignment statement', () {
      // Anchor at the assignment itself (not the method body) so an explanatory comment mentioning
      // "kyc['vehicle_type']" earlier in the method does not skew the ordering check.
      final anchor = activeOrderScreen.indexOf('final vehicleType = _intercityPlanVehicleType ??');
      expect(anchor, greaterThan(-1));
      final stmt = activeOrderScreen.substring(anchor, anchor + 220);
      final planIdx = stmt.indexOf('_intercityPlanVehicleType');
      final orderIdx = stmt.indexOf("order?['vehicle_type']");
      final kycIdx = stmt.indexOf("kyc['vehicle_type']");
      expect(planIdx, greaterThan(-1));
      expect(orderIdx, greaterThan(planIdx));
      expect(kycIdx, greaterThan(orderIdx));
    });
  });

  group('1b. _intercityPlanVehicleType is resolved from the travel plan, scoped to THIS order', () {
    test('_loadIntercityRequestMeta selects the joined rider_travel_plans vehicle_type', () {
      expect(
        activeOrderScreen.contains(
          "rider_travel_plans!intercity_requests_route_id_fkey(vehicle_type)",
        ),
        isTrue,
      );
    });
    test('the query is scoped to parcel_id = widget.orderId AND traveller_id = riderId -- never a global lookup', () {
      final s = activeOrderScreen.indexOf('Future<void> _loadIntercityRequestMeta()');
      final e = activeOrderScreen.indexOf('// ==', s + 50);
      final body = activeOrderScreen.substring(s, e < s ? activeOrderScreen.length : e);
      expect(body.contains(".eq('parcel_id', widget.orderId)"), isTrue);
      expect(body.contains(".eq('traveller_id', riderId)"), isTrue);
      expect(body.contains("_intercityPlanVehicleType ="), isTrue);
    });
    test('never orders.vehicle_type used as the authoritative intercity source (matches the already-fixed passenger-side pattern)', () {
      // The exact pattern already proven correct in realtime_order_controller.dart's _fetchRider().
      expect(activeOrderScreen.contains("(row?['rider_travel_plans'] as Map?)?['vehicle_type']?.toString()"), isTrue);
    });
  });

  group('4/5. Realtime location / heading / bearing plumbing unchanged', () {
    test('updateRiderLocation is still called with the same 7 arguments in the same order', () {
      expect(
        activeOrderScreen.contains(
          "if (typeof updateRiderLocation === 'function') { updateRiderLocation(\$lat, \$lng, \${jsonEncode(name)}, \${jsonEncode(image)}, \${jsonEncode(vehicleType)}, \$heading, \${jsonEncode(status)}); }",
        ),
        isTrue,
      );
    });
    test('heading is still read from position.heading, untouched', () {
      expect(
        activeOrderScreen.contains('final heading = position.heading.isNaN ? 0.0 : position.heading;'),
        isTrue,
      );
    });
    test('the same Geolocator location stream configuration (accuracy/distanceFilter) is untouched', () {
      expect(activeOrderScreen.contains('accuracy: LocationAccuracy.bestForNavigation,'), isTrue);
      expect(activeOrderScreen.contains('distanceFilter: 3,'), isTrue);
    });
  });

  group('6. tracking_engine.js is completely untouched by this fix', () {
    test('the vehicle-marker config lookup (bike/auto/cab dispatch) is unchanged', () {
      expect(trackingEngine.contains('const config = MODEL_CONFIGS[currentType] || MODEL_CONFIGS.bike;'), isTrue);
    });
    test('the updateRiderLocation JS function signature is unchanged (7 params)', () {
      expect(
        trackingEngine.contains(
          'window.updateRiderLocation = function(lat, lng, name, image, vehicleType, heading, status, retryCount) {',
        ),
        isTrue,
      );
    });
  });

  group('7. Passenger-side intercity tracking screen is untouched (already correct)', () {
    test('still sources vehicleType from the rider row, never from a KYC lookup added by this fix', () {
      expect(
        passengerTrackingScreen.contains(
          "final vehicleType = orderController.riderNotifier.value?['vehicle_type']?.toString() ?? 'cab';",
        ),
        isTrue,
      );
      // this fix must not introduce any KYC-vehicle-type read into the passenger-side screen
      expect(passengerTrackingScreen.contains("kyc['vehicle_type']"), isFalse);
      expect(passengerTrackingScreen.contains("kyc?['vehicle_type']"), isFalse);
    });
  });

  group('8/9. Completion-screen vehicle image: same root cause, same isolated fix', () {
    test('vehicleType (completion screen) reads _intercityPlanVehicleType, then order, then rawKyc', () {
      expect(
        activeOrderScreen.contains(
          "final vehicleType = _intercityPlanVehicleType\n"
          "        ?? order?['vehicle_type']?.toString().toLowerCase()\n"
          "        ?? (rawKyc is Map ? rawKyc['vehicle_type'] : null)?.toString().toLowerCase()\n"
          "        ?? 'bike';",
        ),
        isTrue,
      );
    });
    test('bike/auto/cab -> vehicleImg mapping itself is untouched (no business-logic change)', () {
      expect(activeOrderScreen.contains("vehicleImg = 'auto';"), isTrue);
      expect(activeOrderScreen.contains("vehicleImg = 'cab';"), isTrue);
      expect(activeOrderScreen.contains("vehicleImg = 'bike';"), isTrue);
    });
  });

  group('10. Vehicle values are the project\'s real enum values only (bike/auto/cab)', () {
    test('no invented vehicle_type value (e.g. "car") is introduced as an authoritative source value', () {
      // 'car' legitimately appears only in the pre-existing vehicleImg string-matching heuristic
      // (vehicleType.contains('car')) further below -- never as a literal assigned to vehicleType.
      expect(activeOrderScreen.contains("vehicleType = 'car'"), isFalse);
      expect(activeOrderScreen.contains('vehicleType = "car"'), isFalse);
    });
  });
}
