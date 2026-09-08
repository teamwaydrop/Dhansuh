// Regression guard for the "Option C" pricing / matching separation
// (docs/13_Business_Logic.md section 5).
//
// ROOT CAUSE this protects against: an earlier implementation pass sourced
// route_geometry/distance_km/pricing from a NON-canonical route (first the traveller's picked Ola
// alternative, and the same risk exists now for the declared Via route), so the plan's quoted
// fare changed depending on which route the traveller chose. The frozen spec forbids this: the
// declared Via route drives matching intent ONLY, never a fare field.
//
// The two route sources are independent:
//   * OlaMapService.getDirections()      -> route_geometry, distance_km, pricing   (canonical, untouched)
//   * OlaMapService.getMultiStopRoute()  -> selected_route_geometry/_meta/status   (Via / declared route, matching only)
//
// This test reads the screen's source as text -- this repo's established structural-regression
// guard convention.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final source = _read(
    'lib/features/rider/travel_plans/screens/post_travel_plan_screen.dart',
  );

  group('PRICING: canonical getDirections() drives distance_km/route_geometry/pricing', () {
    test('routeGeometryJson is assigned from directions.polylinePoints (canonical call)', () {
      expect(
        source.contains(
          "routeGeometryJson = jsonEncode(\n            directions.polylinePoints.map((pt) => [pt['lat'], pt['lng']]).toList(),\n          );",
        ),
        isTrue,
      );
    });

    test('planDistanceKm is assigned from directions.distanceMeters (canonical call)', () {
      expect(source.contains('planDistanceKm = directions.distanceMeters / 1000;'), isTrue);
    });

    test('planDistanceKm is NEVER assigned from the declared/multi-stop route', () {
      expect(source.contains('planDistanceKm = multi'), isFalse);
      expect(source.contains('planDistanceKm = totalKm'), isFalse);
      expect(source.contains('planDistanceKm = selectedRoute'), isFalse);
      // The ONLY assignments to planDistanceKm are its `= 0` initializer and the canonical
      // `= directions.distanceMeters / 1000`.
      final assigns = RegExp(r'planDistanceKm\s*=[^=]').allMatches(source).map((m) {
        final line = source.substring(m.start, source.indexOf('\n', m.start));
        return line.trim();
      }).toList();
      expect(assigns, [
        'planDistanceKm = 0;',
        'planDistanceKm = directions.distanceMeters / 1000;',
      ]);
    });

    test('routeGeometryJson is NEVER assigned from the declared/multi-stop route', () {
      expect(RegExp(r'routeGeometryJson\s*=\s*(jsonEncode\(\s*)?multi\.').hasMatch(source), isFalse);
      expect(source.contains('routeGeometryJson = selectedRouteGeometryJson'), isFalse);
    });

    test('PricingController.fetchMultiplePricing uses distanceKm: planDistanceKm, never the declared route distance', () {
      expect(source.contains('distanceKm: planDistanceKm,'), isTrue);
      expect(source.contains('distanceKm: totalKm'), isFalse);
      expect(source.contains('distanceKm: multi'), isFalse);
    });

    test('the insert payload writes route_geometry/distance_km from the canonical variables', () {
      expect(source.contains("'route_geometry': routeGeometryJson,"), isTrue);
      expect(source.contains("'distance_km': planDistanceKm,"), isTrue);
    });

    test('the declared-route build block is placed AFTER the pricing calculation', () {
      final pricingIdx = source.indexOf('pricePerSeat = farePricing.getFinalFare(selectedVehicle);');
      final multiIdx = source.indexOf('OlaMapService.getMultiStopRoute(');
      expect(pricingIdx, greaterThan(0));
      expect(multiIdx, greaterThan(pricingIdx),
          reason: 'the Via/multi-leg route must be built after pricing so it can never feed a fare field');
    });
  });

  group('MATCHING: getMultiStopRoute()/Via locations drive ONLY selected_route_* fields', () {
    test('selectedRouteGeometryJson is assigned from multi.route.polylinePoints, not directions', () {
      expect(
        source.contains(
          "selectedRouteGeometryJson = jsonEncode(\n          multi.route.polylinePoints.map((pt) => [pt['lat'], pt['lng']]).toList(),\n        );",
        ),
        isTrue,
      );
      expect(source.contains('selectedRouteGeometryJson = routeGeometryJson'), isFalse);
    });

    test('selected_route_meta.total_distance_km comes from the multi-stop route, not the canonical one', () {
      expect(source.contains("'total_distance_km': totalKm,"), isTrue);
      expect(source.contains('final totalKm = multi.route.distanceMeters / 1000;'), isTrue);
    });

    test('the insert payload writes selected_route_* fields from the independent declared-route variables', () {
      expect(source.contains("'selected_route_geometry': selectedRouteGeometryJson,"), isTrue);
      expect(source.contains("'selected_route_meta': selectedRouteMeta,"), isTrue);
      expect(source.contains("'route_selection_status': routeSelectionStatus,"), isTrue);
    });

    test('the declared route is built only when the traveller added at least one resolved Via location', () {
      expect(source.contains('if (resolvedVias.isNotEmpty) {'), isTrue);
    });

    test('route_selection_status defaults to \'none\' and is only set to \'via_declared\' inside the Via block', () {
      expect(source.contains("String routeSelectionStatus = 'none';"), isTrue);
      expect(source.contains("routeSelectionStatus = 'via_declared';"), isTrue);
    });
  });

  group('The old Ola "route alternatives" picker is fully gone', () {
    test('getRouteAlternatives / RouteOption / the picker sheet are not referenced anywhere in the screen', () {
      for (final gone in [
        'getRouteAlternatives',
        'RouteOption',
        '_showRoutePickerSheet',
        '_MiniPolylinePainter',
        'alternatives=true',
        'Choose your route',
      ]) {
        expect(source.contains(gone), isFalse, reason: 'stale reference to removed feature: $gone');
      }
    });

    test('OlaMapService.getDirections() (canonical, untouched) is still called', () {
      expect(source.contains('await OlaMapService.getDirections('), isTrue);
    });

    test('OlaMapService.getMultiStopRoute() (new, matching-only) is called', () {
      expect(source.contains('await OlaMapService.getMultiStopRoute('), isTrue);
    });
  });
}
