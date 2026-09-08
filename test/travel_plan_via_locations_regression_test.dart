// Regression guard for the Intercity "Via Locations / declared route" feature
// (docs/13_Business_Logic.md section 5).
//
// Structural (source-as-text) guard, this repo's established convention. Protects:
//   * the Via-locations UI on Post Travel Plan (optional, ordered, capped, removable, reuses the
//     existing Ola autocomplete/geocode),
//   * the multi-leg route builder (N-1 sequential getDirections() legs; null on any leg failure;
//     a failed build ABORTS plan creation -- never persists a partial route),
//   * getDirections() itself staying byte-for-byte a plain origin->destination call.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final screen = _read(
    'lib/features/rider/travel_plans/screens/post_travel_plan_screen.dart',
  );
  final ola = _read('lib/core/services/maps/ola_map_service.dart');

  group('Via-locations UI', () {
    test('there is a configurable maximum (a named const, not a magic number hardcoded to 3)', () {
      final m = RegExp(r'static const int maxViaStops = (\d+);').firstMatch(screen);
      expect(m, isNotNull, reason: 'maxViaStops const missing');
      final value = int.parse(m!.group(1)!);
      expect(value, greaterThanOrEqualTo(1));
      expect(value, lessThanOrEqualTo(10), reason: 'sanity: worst-case = value getDirections() legs');
    });

    test('an ordered, mutable Via list backs the UI', () {
      expect(screen.contains('final List<_ViaStop> viaStops = [];'), isTrue);
      expect(screen.contains('class _ViaStop {'), isTrue);
    });

    test('add / remove / build helpers exist', () {
      for (final fn in [
        'void _addViaStop()',
        'void _removeViaStop(int index)',
        'Widget _buildYourRouteSection()',
        'Widget _buildViaField(int index)',
        'String? _validateViaStops()',
      ]) {
        expect(screen.contains(fn), isTrue, reason: 'missing $fn');
      }
    });

    test('the "Add Via Location" affordance and "Your Route" section header are present', () {
      expect(screen.contains("'Add Via Location'"), isTrue);
      expect(screen.contains("'Your Route'"), isTrue);
    });

    test('Via locations are MANDATORY: a named minimum const of at least 2, no "Optional" copy', () {
      final m = RegExp(r'static const int minViaStops = (\d+);').firstMatch(screen);
      expect(m, isNotNull, reason: 'minViaStops const missing');
      expect(int.parse(m!.group(1)!), greaterThanOrEqualTo(2));
      // The old "Optional." lead-in must be gone.
      expect(screen.contains('Optional. Add the towns'), isFalse);
      expect(RegExp(r"'Optional\.").hasMatch(screen), isFalse);
    });

    test('the section shows a mandatory indicator + professional rationale copy', () {
      expect(screen.contains("'REQUIRED'"), isTrue);
      // Copy communicates: order, matching purpose, filtering out off-route requests, minimum.
      expect(screen.contains('in the order you will pass through them'), isTrue);
      expect(screen.contains('match passengers travelling your way'), isTrue);
      expect(screen.contains('keep out requests that are not actually on your path'), isTrue);
      expect(screen.contains(r'At least $minViaStops via stops'), isTrue);
    });

    test('_validateViaStops enforces the minimum for 0 and 1 resolved via locations', () {
      final v = screen.substring(
        screen.indexOf('String? _validateViaStops()'),
        screen.indexOf('String? _validateViaStops()') + 1900,
      );
      expect(v.contains('_resolvedViaStops.length'), isTrue);
      expect(v.contains('resolved < minViaStops'), isTrue);
      expect(v.contains('Add at least \$minViaStops via locations to create an Intercity travel plan.'), isTrue);
      expect(v.contains('Add \$needed more via location'), isTrue);
    });

    test('the section only renders after BOTH From and To are chosen (From/To UI itself untouched)', () {
      expect(
        screen.contains('if (selectedDepartureLat != null &&\n'
            '                  selectedDepartureLng != null &&\n'
            '                  selectedArrivalLat != null &&\n'
            '                  selectedArrivalLng != null) ...['),
        isTrue,
      );
    });

    test('the "Add Via Location" button is hidden once the cap is reached', () {
      expect(screen.contains('if (viaStops.length < maxViaStops)'), isTrue);
      expect(screen.contains('_addViaStop'), isTrue);
      expect(screen.contains('if (viaStops.length >= maxViaStops) return;'), isTrue);
    });

    test('Via search reuses the existing Ola autocomplete + place/address geocoders (no new SDK)', () {
      expect(screen.contains('OlaMapService.autocomplete(value)'), isTrue);
      expect(screen.contains('OlaMapService.getCoordinatesFromPlaceId(placeId)'), isTrue);
      expect(screen.contains('OlaMapService.getCoordinatesFromAddress(desc)'), isTrue);
      // No map SDK / google_maps / mapbox import was added.
      expect(RegExp(r"import .*(google_maps|mapbox|flutter_map)").hasMatch(screen), isFalse);
    });

    test('a removable Via row invokes _removeViaStop with its index', () {
      expect(screen.contains('onPressed: () => _removeViaStop(index)'), isTrue);
    });
  });

  group('Via-locations validation', () {
    test('_validateViaStops rejects: unresolved row, invalid coords, Via == origin, Via == destination, duplicate Via', () {
      final v = screen.substring(
        screen.indexOf('String? _validateViaStops()'),
        screen.indexOf('String? _validateViaStops()') + 1600,
      );
      expect(v.contains('Finish selecting Via location'), isTrue); // unresolved row
      expect(v.contains('has an invalid location'), isTrue); // invalid coords
      expect(v.contains('is the same as your departure location'), isTrue);
      expect(v.contains('is the same as your arrival location'), isTrue);
      expect(v.contains('are the same place'), isTrue); // duplicate via
      expect(v.contains('_validLatLng('), isTrue);
      expect(v.contains('_sameSpot('), isTrue);
    });

    test('_submitTravelPlan calls _validateViaStops and aborts on any error', () {
      expect(screen.contains('final viaError = _validateViaStops();'), isTrue);
      final idx = screen.indexOf('final viaError = _validateViaStops();');
      final window = screen.substring(idx, idx + 300);
      expect(window.contains('if (viaError != null) {'), isTrue);
      expect(window.contains('return;'), isTrue);
    });
  });

  group('Multi-leg declared-route build (post_travel_plan_screen)', () {
    test('stops are assembled in order: origin, then each resolved Via in list order, then destination', () {
      expect(
        screen.contains("{'lat': selectedDepartureLat!, 'lng': selectedDepartureLng!},\n"
            "          for (final v in resolvedVias) {'lat': v.lat!, 'lng': v.lng!},\n"
            "          {'lat': selectedArrivalLat!, 'lng': selectedArrivalLng!},"),
        isTrue,
      );
    });

    test('a failed multi-leg build shows an error and ABORTS -- no insert, no partial route saved', () {
      final idx = screen.indexOf('final multi = await OlaMapService.getMultiStopRoute(stops: stops);');
      expect(idx, greaterThan(0));
      final window = screen.substring(idx, idx + 500);
      expect(window.contains('if (multi == null) {'), isTrue);
      expect(window.contains('setState(() => submitting = false);'), isTrue);
      expect(window.contains('return;'), isTrue);
      // The insert call must appear only AFTER this abort block.
      expect(screen.indexOf("supabase.from('rider_travel_plans').insert("), greaterThan(idx));
    });

    test('each stored waypoint records order + type (origin/via/destination) + along_track_km', () {
      final idx = screen.indexOf('final waypoints = <Map<String, dynamic>>[];');
      final window = screen.substring(idx, idx + 500);
      expect(window.contains("'order': i,"), isTrue);
      expect(window.contains("'type': i == 0"), isTrue);
      expect(window.contains("? 'origin'"), isTrue);
      expect(window.contains("'destination'"), isTrue);
      expect(window.contains("'via'"), isTrue);
      expect(window.contains("'along_track_km': i < cum.length ? cum[i] : totalKm,"), isTrue);
    });
  });

  group('OlaMapService: getMultiStopRoute added, getDirections untouched', () {
    test('MultiStopRoute result type and getMultiStopRoute method exist', () {
      expect(ola.contains('class MultiStopRoute {'), isTrue);
      expect(ola.contains('static Future<MultiStopRoute?> getMultiStopRoute({'), isTrue);
      expect(ola.contains('required List<Map<String, double>> stops,'), isTrue);
    });

    test('getMultiStopRoute routes each consecutive pair through the existing getDirections()', () {
      final idx = ola.indexOf('static Future<MultiStopRoute?> getMultiStopRoute({');
      final body = ola.substring(idx, idx + 2200);
      expect(body.contains('for (var i = 0; i < stops.length - 1; i++)'), isTrue);
      expect(body.contains('final leg = await getDirections('), isTrue);
      // Any failed / empty leg invalidates the whole route.
      expect(body.contains('if (leg == null || leg.polylinePoints.isEmpty) {\n        return null;'), isTrue);
      expect(body.contains('if (stops.length < 2) return null;'), isTrue);
    });

    test('getMultiStopRoute does NOT use any Ola multi-waypoint request parameter (multi-leg only)', () {
      final idx = ola.indexOf('static Future<MultiStopRoute?> getMultiStopRoute({');
      final body = ola.substring(idx, idx + 2200);
      for (final banned in ['waypoints', 'alternatives', 'via=', 'stops=']) {
        expect(body.contains(banned), isFalse, reason: 'unexpected raw Ola param "$banned"');
      }
    });

    test('getDirections() is still a plain origin->destination directions call', () {
      final idx = ola.indexOf('static Future<RouteModel?>\n      getDirections({');
      expect(idx, greaterThan(0), reason: 'getDirections signature changed');
      final body = ola.substring(idx, idx + 1400);
      expect(body.contains("'origin':\n              '\$originLat,\$originLng',"), isTrue);
      expect(body.contains("'destination':\n\n              '\$destinationLat,\$destinationLng',"), isTrue);
      expect(body.contains("'alternatives'"), isFalse);
      expect(body.contains("'waypoints'"), isFalse);
    });

    test('the removed route-alternatives API surface is gone from OlaMapService', () {
      for (final gone in ['getRouteAlternatives', 'parseRouteAlternatives', 'class RouteOption', 'alternatives=true']) {
        expect(ola.contains(gone), isFalse, reason: 'stale: $gone');
      }
    });
  });
}
