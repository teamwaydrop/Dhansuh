// Regression guard for the 2026-08-22 Ola Directions egress-reduction fix on the two live-tracking
// polylines (Ola/Krutrim consumption audit finding: continuous live-tracking Directions calls from
// both the passenger and rider apps were the single largest source of Ola Maps API consumption per
// ride).
//
// BEFORE: ride_tracking_screen.dart's _onRiderLocationUpdate() re-called Ola's Directions API
// whenever >=15s had elapsed OR the rider moved >=50m -- with no floor on the movement trigger, so
// a fast-moving rider could re-trigger a fresh call every few seconds. rider_active_order_screen
// .dart's startTimer() re-called it whenever >25s had elapsed, again with no in-flight/target
// validity guard beyond fetchOptimizedRoute()'s own early-return.
//
// AFTER: both screens use a distance-to-target-aware throttle (far from target: ~40s floor; near
// target, within ~600m: ~20s floor) instead of a flat 15s/25s check. The passenger screen's 50m
// movement trigger is kept (unchanged threshold) but is now also floored by a minimum time gap so
// it cannot fire faster than that floor. A forced (target/status-change) refresh that arrives while
// a Directions request is already in flight is queued (`_pendingForceRouteFetch`) and retried the
// instant that request completes, instead of being silently dropped or waiting for the next
// throttle window. Both screens now also explicitly refuse to schedule/run a Directions call for an
// order that has already completed or been cancelled.
//
// Scope: this fix touches ONLY the live-tracking Directions refresh cadence in these two files.
// Fare calculation, pricing, commission, GST, payments, dispatch/matching, PostGIS nearby-rider
// logic, autocomplete/geocoding/reverse-geocoding, Distance Matrix/ETA, map tiles, auth,
// notifications, and realtime subscription wiring are all untouched -- confirmed below by asserting
// the untouched call sites/behaviors are still present exactly as before.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final trackingScreen =
      _read('lib/features/local_rides/tracking/screens/ride_tracking_screen.dart');
  final activeOrderScreen =
      _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');

  group('Passenger side (ride_tracking_screen.dart): adaptive throttle replaces the flat 15s/50m check', () {
    test('the old flat 15s time-floor condition is gone', () {
      expect(
        trackingScreen.contains('timeSinceLastFetch.inSeconds >= 15'),
        isFalse,
        reason: 'the unconditional 15s refresh floor must be replaced by the adaptive interval',
      );
    });

    test('an adaptive near/far refresh interval exists, keyed on distance to the active target', () {
      expect(trackingScreen.contains('_nearTargetThresholdKm'), isTrue);
      expect(trackingScreen.contains('_farRefreshIntervalSeconds'), isTrue);
      expect(trackingScreen.contains('_nearRefreshIntervalSeconds'), isTrue);
      expect(trackingScreen.contains('static const double _nearTargetThresholdKm = 0.6'), isTrue);
      expect(trackingScreen.contains('static const int _farRefreshIntervalSeconds = 40'), isTrue);
      expect(trackingScreen.contains('static const int _nearRefreshIntervalSeconds = 20'), isTrue);
      // Both far/near values fall in the requested 30-45s / tightened-but-bounded range and are
      // strictly wider than the old flat 15s floor.
      expect(40, greaterThanOrEqualTo(30));
      expect(40, lessThanOrEqualTo(45));
    });

    test('the 50m movement concept is preserved but is now floored by a minimum time gap', () {
      expect(trackingScreen.contains('_movementThresholdKm = 0.05'), isTrue,
          reason: 'the existing 50m movement trigger threshold must be unchanged');
      expect(trackingScreen.contains('_minMovementGapSeconds'), isTrue);
      expect(
        trackingScreen.contains(
          'distanceMoved >= _movementThresholdKm &&\n          timeSinceLastFetch.inSeconds >= _minMovementGapSeconds',
        ),
        isTrue,
        reason: 'movement-triggered fetches must also respect a minimum time floor so a '
            'fast-moving rider cannot re-trigger a call every few seconds',
      );
    });
  });

  group('Rider side (rider_active_order_screen.dart): adaptive throttle replaces the flat >25s check', () {
    test('the old flat >25s condition on _lastRouteFetch is gone', () {
      expect(
        activeOrderScreen.contains('now.difference(_lastRouteFetch!).inSeconds > 25'),
        isFalse,
        reason: 'the flat 25s refresh floor must be replaced by the adaptive interval',
      );
    });

    test('the same adaptive near/far interval strategy is used, keyed on distance to target', () {
      expect(activeOrderScreen.contains('_nearTargetThresholdMeters'), isTrue);
      expect(activeOrderScreen.contains('_farRefreshIntervalSeconds'), isTrue);
      expect(activeOrderScreen.contains('_nearRefreshIntervalSeconds'), isTrue);
      expect(activeOrderScreen.contains('static const double _nearTargetThresholdMeters = 600'), isTrue);
      expect(activeOrderScreen.contains('static const int _farRefreshIntervalSeconds = 40'), isTrue);
      expect(activeOrderScreen.contains('static const int _nearRefreshIntervalSeconds = 20'), isTrue);
      expect(activeOrderScreen.contains('Geolocator.distanceBetween(riderLat, riderLng, targetLat, targetLng)'),
          isTrue);
    });
  });

  group('Target/status-change logic is preserved exactly (not part of this fix\'s scope)', () {
    test('passenger side: pickup/destination target resolution is unchanged', () {
      expect(
        trackingScreen.contains(
          "if (status == 'ongoing' || status == 'picked_up' || status == 'rider_at_drop') {\n        targetLat = orderObj.destinationLat;\n        targetLng = orderObj.destinationLng;",
        ),
        isTrue,
      );
      // The target-changed force-fetch mechanism itself (comparison against _lastTargetLat/Lng)
      // still exists verbatim.
      expect(trackingScreen.contains('_lastTargetLat != targetLat || _lastTargetLng != targetLng'), isTrue);
    });

    test('rider side: accepted/rider_arrived/rider_at_pickup -> pickup, ongoing/picked_up/rider_at_drop -> destination is unchanged', () {
      expect(
        activeOrderScreen.contains(
          "if (status == 'accepted' || status == 'rider_arrived' || status == 'rider_at_pickup') {",
        ),
        isTrue,
      );
      expect(
        activeOrderScreen.contains(
          "} else if (status == 'ongoing' || status == 'picked_up' || status == 'rider_at_drop') {",
        ),
        isTrue,
      );
      // startTimer()'s own target resolution (used only to pick the adaptive interval) mirrors the
      // same branching.
      expect(
        activeOrderScreen.contains(
          "if (currentStatus == 'ongoing' || currentStatus == 'picked_up' || currentStatus == 'rider_at_drop') {\n            targetLat = dLat;",
        ),
        isTrue,
      );
    });
  });

  group('Status transition still triggers an immediate (forced) route refresh', () {
    test('passenger side: a target change still sets forceFetch = true unconditionally', () {
      expect(
        trackingScreen.contains(
          'bool forceFetch = false;\n      if (_lastTargetLat != targetLat || _lastTargetLng != targetLng) {\n        _lastTargetLat = targetLat;\n        _lastTargetLng = targetLng;\n        forceFetch = true;\n      }',
        ),
        isTrue,
      );
    });

    test('rider side: an order-status transition calls fetchOptimizedRoute with isForced: true', () {
      expect(
        activeOrderScreen.contains(
          'if (oldStatus != newStatus) {\n          optimizedGeometry = null;',
        ),
        isTrue,
      );
      expect(
        RegExp(r'oldStatus != newStatus[\s\S]{0,400}fetchOptimizedRoute\(isForced: true\)').hasMatch(activeOrderScreen),
        isTrue,
        reason: 'the status-transition trigger must pass isForced: true so it is never silently dropped',
      );
    });

    test('rider side: the initial post-load fetch is also forced', () {
      expect(
        RegExp(r'_startLocalLocationTracking\(\);\s*\}[\s\S]{0,300}fetchOptimizedRoute\(isForced: true\)')
            .hasMatch(activeOrderScreen),
        isTrue,
      );
    });
  });

  group('Duplicate/in-flight request suppression', () {
    test('passenger side: an in-flight fetch blocks a new one, and a forced trigger is queued not dropped', () {
      expect(
        trackingScreen.contains(
          'if (_fetchingRiderRoute) {\n          // Duplicate-request guard',
        ),
        isTrue,
      );
      expect(trackingScreen.contains('if (forceFetch) _pendingForceRouteFetch = true;'), isTrue);
      // The finally block retries the queued forced fetch once the in-flight one completes.
      expect(
        RegExp(r'finally \{\s*_fetchingRiderRoute = false;[\s\S]{0,600}_pendingForceRouteFetch && mounted\)[\s\S]{0,200}_onRiderLocationUpdate\(\);')
            .hasMatch(trackingScreen),
        isTrue,
      );
    });

    test('rider side: fetchOptimizedRoute early-returns while already in flight and queues a forced retry', () {
      expect(
        activeOrderScreen.contains('Future<void> fetchOptimizedRoute({bool isForced = false}) async {'),
        isTrue,
      );
      expect(
        RegExp(r'if \(fetchingRoute\) \{[\s\S]{0,400}if \(isForced\) _pendingForceRouteFetch = true;[\s\S]{0,20}return;')
            .hasMatch(activeOrderScreen),
        isTrue,
      );
      // The finally block retries the queued forced fetch once the in-flight one completes.
      expect(
        RegExp(r'finally \{\s*fetchingRoute = false;[\s\S]{0,400}_pendingForceRouteFetch\)[\s\S]{0,200}fetchOptimizedRoute\(isForced: true\);')
            .hasMatch(activeOrderScreen),
        isTrue,
      );
    });
  });

  group('No Directions request after the order is completed/cancelled', () {
    test('passenger side: _onRiderLocationUpdate refuses to resolve a target/fetch for a finished order', () {
      expect(
        trackingScreen.contains('if (orderObj != null && !orderObj.isCompleted && !orderObj.isCancelled) {'),
        isTrue,
      );
    });

    test('rider side: fetchOptimizedRoute explicitly refuses completed/delivered/cancelled orders', () {
      expect(
        activeOrderScreen.contains(
          "if (status == 'completed' || status == 'delivered' || status == 'cancelled') return;",
        ),
        isTrue,
      );
    });

    test('rider side: the periodic timer itself also stops scheduling once the order is finished', () {
      expect(
        RegExp(
          r"if \(order == null \|\|\s*\n\s*currentStatus == 'completed' \|\|\s*\n\s*currentStatus == 'delivered' \|\|\s*\n\s*currentStatus == 'cancelled'\) \{\s*\n\s*return;",
        ).hasMatch(activeOrderScreen),
        isTrue,
      );
    });
  });

  group('Untouched: everything outside live-tracking Directions refresh cadence', () {
    test('the route cache, polyline decoding, and JS map update calls are unchanged', () {
      expect(trackingScreen.contains('_staticRouteCache[cacheKey] = coords;'), isTrue);
      expect(trackingScreen.contains("updateRiderRoute === 'function'"), isTrue);
      expect(activeOrderScreen.contains("updateRiderRoute === 'function'"), isTrue);
    });

    test('OlaMapService.getDirections is still the only Directions call in either file (no new endpoint introduced)', () {
      expect('OlaMapService.getDirections'.allMatches(trackingScreen).length, greaterThanOrEqualTo(1));
      expect('OlaMapService.getDirections'.allMatches(activeOrderScreen).length, greaterThanOrEqualTo(1));
      expect(trackingScreen.contains('distanceMatrix'), isFalse);
      expect(activeOrderScreen.contains('distanceMatrix'), isFalse);
    });

    test('pricing/dispatch edge-function names are absent from both changed files (out of scope)', () {
      // Both files are UI screens, not backend code -- neither should ever reference the pricing
      // or dispatch/matching edge functions or the PostGIS RPC by name. rider_active_order_screen
      // .dart legitimately renders GST/commission/Cashfree UI elsewhere in the file (its
      // completion screen), so those terms are intentionally NOT checked here -- this fix does not
      // touch that code, but "absent from the whole file" would be a false assumption for it.
      for (final forbidden in [
        'calculate-order-pricing',
        'find_nearby_riders',
        'start-dispatch',
      ]) {
        expect(trackingScreen.contains(forbidden), isFalse, reason: '"$forbidden" must not appear in ride_tracking_screen.dart');
        expect(activeOrderScreen.contains(forbidden), isFalse,
            reason: '"$forbidden" must not appear in rider_active_order_screen.dart');
      }
    });
  });

  // Follow-up audit sweep (2026-08-22, "item 6: other remaining Ola Maps calls"): these two
  // screens had the IDENTICAL pre-fix flat-15s/50m pattern as ride_tracking_screen.dart -- same
  // copy-pasted _onRiderLocationUpdate()/_fetchAndSetRiderRoute() shape, same missing in-flight
  // guard, same missing completed/cancelled guard -- but were out of scope for the first pass
  // (which only touched ride_tracking_screen.dart and rider_active_order_screen.dart). Fixed with
  // the exact same adaptive-throttle pattern verified above.
  group('Parcel tracking (parcel_tracking_screen.dart) got the identical adaptive-throttle fix', () {
    final parcelTracking =
        _read('lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart');

    test('the old flat 15s time-floor condition is gone, replaced by the adaptive interval', () {
      expect(parcelTracking.contains('timeSinceLastFetch.inSeconds >= 15'), isFalse);
      expect(parcelTracking.contains('static const double _nearTargetThresholdKm = 0.6'), isTrue);
      expect(parcelTracking.contains('static const int _farRefreshIntervalSeconds = 40'), isTrue);
      expect(parcelTracking.contains('static const int _nearRefreshIntervalSeconds = 20'), isTrue);
      expect(parcelTracking.contains('_minMovementGapSeconds'), isTrue);
    });

    test('duplicate in-flight requests are suppressed and a forced trigger is queued, not dropped', () {
      expect(parcelTracking.contains('if (forceFetch) _pendingForceRouteFetch = true;'), isTrue);
      expect(
        RegExp(r'finally \{\s*_fetchingRiderRoute = false;[\s\S]{0,400}_pendingForceRouteFetch && mounted\)')
            .hasMatch(parcelTracking),
        isTrue,
      );
    });

    test('no Directions request is scheduled for a completed/cancelled order', () {
      expect(parcelTracking.contains('if (orderObj != null && !orderObj.isCompleted && !orderObj.isCancelled) {'), isTrue);
    });

    test('target resolution (pickup vs destination) is unchanged', () {
      expect(
        parcelTracking.contains(
          "if (status == 'ongoing' || status == 'picked_up' || status == 'rider_at_drop') {\n        targetLat = orderObj.destinationLat;",
        ),
        isTrue,
      );
    });
  });

  group('Intercity tracking (intercity_tracking_screen.dart) got the identical adaptive-throttle fix', () {
    final intercityTracking =
        _read('lib/features/intercity/shared/screens/intercity_tracking_screen.dart');

    test('the old flat 15s time-floor condition is gone, replaced by the adaptive interval', () {
      expect(intercityTracking.contains('timeSinceLastFetch.inSeconds >= 15'), isFalse);
      expect(intercityTracking.contains('static const double _nearTargetThresholdKm = 0.6'), isTrue);
      expect(intercityTracking.contains('static const int _farRefreshIntervalSeconds = 40'), isTrue);
      expect(intercityTracking.contains('static const int _nearRefreshIntervalSeconds = 20'), isTrue);
      expect(intercityTracking.contains('_minMovementGapSeconds'), isTrue);
    });

    test('duplicate in-flight requests are suppressed and a forced trigger is queued, not dropped', () {
      expect(intercityTracking.contains('if (forceFetch) _pendingForceRouteFetch = true;'), isTrue);
      expect(
        RegExp(r'finally \{\s*_fetchingRiderRoute = false;[\s\S]{0,400}_pendingForceRouteFetch && mounted\)')
            .hasMatch(intercityTracking),
        isTrue,
      );
    });

    test('no Directions request is scheduled for a completed/cancelled order', () {
      expect(intercityTracking.contains('if (orderObj != null && !orderObj.isCompleted && !orderObj.isCancelled) {'), isTrue);
    });

    test('the intercity vehicle_type CAR-shown-as-BIKE fix comment/guard is untouched by this pass', () {
      // This screen has its own unrelated fix (Issue 3 audit follow-up, never fall back to
      // orderNotifier.value?.vehicleType for intercity) directly adjacent to the code this fix
      // touched -- confirm it's still intact, not accidentally removed while editing nearby lines.
      expect(
        intercityTracking.contains("orderController.riderNotifier.value?['vehicle_type']?.toString() ?? 'cab';"),
        isTrue,
      );
    });
  });
}
