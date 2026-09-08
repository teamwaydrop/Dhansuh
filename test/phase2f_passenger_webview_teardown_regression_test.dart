// Regression guard for Phase 10E — Phase 2F implementation B (F3).
//
// Phase 2A added an EXPLICIT Dart-side WebView teardown to rider_active_order_screen.dart's
// dispose() -- fire-and-forget runJavaScript('...destroyTrackingEngine();destroyMap()...')
// .catchError((_){}) -- because the HTML 'unload' event does not reliably fire when Flutter
// disposes a platform WebView without a navigation, leaking the MapLibre GL context + its RAF
// render loop.
//
// F3 replicates that exact pattern to the remaining map-bearing screens/widgets so their map
// resources are explicitly destroyed on dispose instead of relying only on HTML unload:
//   - ride_tracking_screen.dart      (ola_map_tracking_user.html)
//   - parcel_tracking_screen.dart    (ola_map_tracking_user.html)
//   - intercity_tracking_screen.dart (ola_map_tracking_user.html)
//   - transport_map_widget.dart      (ola_map_home.html -- the Home nearby-rider map)
//   - ride_location_screen.dart      (ola_map_location_picker.html -> ola_map_core.js)
// plus a defense-in-depth 'unload' handler in the self-contained (deprecated) ola_map.html.
//
// Structural (source-as-text) guard -- this repo's established convention for the map layer.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// The exact teardown call shape F3 (and Phase 2A) uses: a fire-and-forget runJavaScript() whose
/// body is a `try { ... } catch (e) {}` that `typeof`-guards each destroy helper, chained with
/// `.catchError((_) {})` so a dead-controller JS future can never throw out of dispose().
bool _hasTeardown(String disposeBody, {required List<String> helpers}) {
  if (!disposeBody.contains('.runJavaScript(')) return false;
  if (!disposeBody.contains('.catchError((_) {})')) return false;
  if (!disposeBody.contains('try { ')) return false;
  if (!disposeBody.contains('} catch (e) {}')) return false;
  for (final h in helpers) {
    if (!disposeBody.contains('if (typeof $h === "function") { $h(); }')) return false;
  }
  return true;
}

String _disposeBody(String src) {
  final start = src.indexOf('void dispose() {');
  expect(start, greaterThanOrEqualTo(0), reason: 'no dispose() found');
  // dispose() always ends with super.dispose(); take through the first one after the teardown.
  final superIdx = src.indexOf('super.dispose();', start);
  expect(superIdx, greaterThan(start));
  return src.substring(start, superIdx + 'super.dispose();'.length);
}

void main() {
  final rideTracking =
      _read('lib/features/local_rides/tracking/screens/ride_tracking_screen.dart');
  final parcelTracking =
      _read('lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart');
  final intercityTracking =
      _read('lib/features/intercity/shared/screens/intercity_tracking_screen.dart');
  final transportMapWidget = _read('lib/shared/widgets/maps/transport_map_widget.dart');
  final rideLocation =
      _read('lib/features/local_rides/booking/screens/ride_location_screen.dart');
  final olaMapHtml = _read('assets/map/ola_map.html');
  final olaMapCore = _read('assets/map/ola_map_core.js');
  final trackingEngine = _read('assets/map/tracking_engine.js');
  final riderScreen =
      _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');

  group('F3 -- explicit WebView teardown in dispose()', () {
    test('1. ride_tracking_screen.dart dispose tears down the map WebView '
        '(destroyNearbyRidersEngine + destroyTrackingEngine + destroyMap, fire-and-forget)', () {
      final body = _disposeBody(rideTracking);
      expect(
        _hasTeardown(body, helpers: [
          'destroyNearbyRidersEngine',
          'destroyTrackingEngine',
          'destroyMap',
        ]),
        isTrue,
      );
      // uses the screen's existing controller, guarded for null.
      expect(body.contains('final mapCtrl = mapController;'), isTrue);
      expect(body.contains('if (mapCtrl != null) {'), isTrue);
      // teardown is before super.dispose().
      expect(body.indexOf('.runJavaScript('), lessThan(body.indexOf('super.dispose();')));
      // existing tracking cleanup untouched.
      expect(body.contains('orderController.dispose();'), isTrue);
      expect(body.contains('riderLocationNotifier.removeListener(_onRiderLocationUpdate)'), isTrue);
    });

    test('2. parcel_tracking_screen.dart dispose tears down the map WebView', () {
      final body = _disposeBody(parcelTracking);
      expect(
        _hasTeardown(body, helpers: [
          'destroyNearbyRidersEngine',
          'destroyTrackingEngine',
          'destroyMap',
        ]),
        isTrue,
      );
      expect(body.contains('final mapCtrl = mapController;'), isTrue);
      expect(body.indexOf('.runJavaScript('), lessThan(body.indexOf('super.dispose();')));
      expect(body.contains('orderController.dispose();'), isTrue);
    });

    test('3. intercity_tracking_screen.dart dispose tears down the map WebView', () {
      final body = _disposeBody(intercityTracking);
      expect(
        _hasTeardown(body, helpers: [
          'destroyNearbyRidersEngine',
          'destroyTrackingEngine',
          'destroyMap',
        ]),
        isTrue,
      );
      expect(body.contains('final mapCtrl = mapController;'), isTrue);
      expect(body.indexOf('.runJavaScript('), lessThan(body.indexOf('super.dispose();')));
      expect(body.contains('orderController.dispose();'), isTrue);
    });

    test('4. transport_map_widget.dart dispose tears down the Home map WebView (still disposes the '
        'pulse controller, still mock-map guarded)', () {
      final body = _disposeBody(transportMapWidget);
      expect(body.contains('_pulseController.dispose();'), isTrue,
          reason: 'pulse animation disposal must be preserved');
      expect(body.contains('if (!_useMockMap) {'), isTrue);
      expect(body.contains('final controller = _controller;'), isTrue);
      expect(
        _hasTeardown(body, helpers: [
          'destroyNearbyRidersEngine',
          'destroyTrackingEngine',
          'destroyMap',
        ]),
        isTrue,
      );
      expect(body.indexOf('.runJavaScript('), lessThan(body.indexOf('super.dispose();')));
    });

    test('5. ride_location_screen.dart dispose tears down its map WebView (uses webController, '
        'preserves every existing controller/timer disposal)', () {
      final body = _disposeBody(rideLocation);
      expect(
        _hasTeardown(body, helpers: [
          'destroyNearbyRidersEngine',
          'destroyTrackingEngine',
          'destroyMap',
        ]),
        isTrue,
      );
      expect(body.contains('if (!_useMockMap) {'), isTrue);
      expect(body.contains('final controller = webController;'), isTrue);
      expect(body.indexOf('.runJavaScript('), lessThan(body.indexOf('super.dispose();')));
      // existing disposals untouched.
      for (final existing in [
        '_pulseController.dispose();',
        'pickupController.dispose();',
        'destinationController.dispose();',
        '_riderRefreshTimer?.cancel();',
        '_promoController.dispose();',
      ]) {
        expect(body.contains(existing), isTrue, reason: '"$existing" must remain in dispose()');
      }
    });
  });

  group('F3 -- ola_map.html defense-in-depth unload handler', () {
    test('6. ola_map.html contains a window unload handler', () {
      expect(olaMapHtml.contains("window.addEventListener('unload'"), isTrue);
    });

    test("7. the unload handler calls destroyMap()", () {
      expect(
        RegExp(r"addEventListener\('unload',[\s\S]{0,400}typeof window\.destroyMap === 'function'[\s\S]{0,60}window\.destroyMap\(\);")
            .hasMatch(olaMapHtml),
        isTrue,
      );
    });

    test("8. the unload handler calls destroyNearbyRidersEngine()", () {
      expect(
        RegExp(r"addEventListener\('unload',[\s\S]{0,400}typeof window\.destroyNearbyRidersEngine === 'function'[\s\S]{0,80}window\.destroyNearbyRidersEngine\(\);")
            .hasMatch(olaMapHtml),
        isTrue,
      );
      // both calls are typeof-guarded and wrapped in try/catch (safe no-op if absent).
      expect(
        RegExp(r"addEventListener\('unload', \(\) => \{\s*try \{[\s\S]*?\} catch \(e\) \{\}\s*\}\);")
            .hasMatch(olaMapHtml),
        isTrue,
      );
    });
  });

  group('F3 -- Phase 2A / 2F-A remain untouched', () {
    test('9. rider_active_order_screen.dart Phase 2A teardown is unchanged (two helpers, exact '
        'wording)', () {
      final body = _disposeBody(riderScreen);
      // Phase 2A used exactly destroyTrackingEngine + destroyMap (NOT destroyNearbyRidersEngine).
      expect(body.contains('if (typeof destroyTrackingEngine === "function") { destroyTrackingEngine(); }'), isTrue);
      expect(body.contains('if (typeof destroyMap === "function") { destroyMap(); }'), isTrue);
      expect(body.contains('destroyNearbyRidersEngine'), isFalse,
          reason: 'Phase 2A must not have been retrofitted with the new helper');
      expect(body.contains('if (!_useMockMap) {'), isTrue);
      expect(body.contains('final controller = mapController;'), isTrue);
    });

    test('10. Phase 2F-A F1 convergence code is still present in ola_map_core.js', () {
      expect(olaMapCore.contains('_allConverged()'), isTrue);
      expect(olaMapCore.contains('_rearm()'), isTrue);
      expect(
        RegExp(r'if \(window\.AnimationManager\._allConverged\(\)\) \{\s*window\.AnimationManager\.loopActive = false;\s*return;')
            .hasMatch(olaMapCore),
        isTrue,
      );
      // F4 guard also still present.
      expect(
        RegExp(r'window\.loadOlaMap = function\([\s\S]{0,800}if \(window\.MapState\.map\) \{\s*window\.destroyMap\(\);')
            .hasMatch(olaMapCore),
        isTrue,
      );
    });

    test('11. Phase 2F-A F1 convergence code is still present in ola_map.html', () {
      expect(olaMapHtml.contains('_allConverged()'), isTrue);
      expect(olaMapHtml.contains('_rearm()'), isTrue);
      expect(
        RegExp(r'if \(AnimationManager\._allConverged\(\)\) \{\s*AnimationManager\.loopActive = false;\s*return;')
            .hasMatch(olaMapHtml),
        isTrue,
      );
    });

    test('12. tracking_engine.js Phase G animateActiveRider is untouched', () {
      expect(trackingEngine.contains('function isRiderStateConverged()'), isTrue);
      expect(
        RegExp(r'requestAnimationFrame\(window\.animateActiveRider\)').allMatches(trackingEngine).length,
        1,
      );
      expect(trackingEngine.contains('window._resumeRiderAnimation = function() {'), isTrue);
      // F3 must not have added its comment marker or a teardown-list change here.
      expect(trackingEngine.contains('Phase 2F-B'), isFalse);
    });
  });

  group('F3 -- nothing outside the teardown was changed', () {
    // 13 / 14 / 15 -- GPS / Realtime / Directions logic in the touched screens is untouched.
    test('13. GPS: the local/rider location stream setup + Phase 2A GPS settings are unchanged', () {
      // The Phase 2A rider GPS interval cap.
      expect(riderScreen.contains('intervalDuration: const Duration(milliseconds: 1000),'), isTrue);
      // Passenger screens still consume rider location purely via the notifier listener.
      for (final s in [rideTracking, parcelTracking, intercityTracking]) {
        expect(s.contains('riderLocationNotifier.addListener(_onRiderLocationUpdate)'), isTrue);
        // no Geolocator.getPositionStream was added to a passenger tracking screen.
        expect(s.contains('Geolocator.getPositionStream('), isFalse);
      }
    });

    test('14. Realtime: RealtimeOrderController wiring in the touched screens is unchanged', () {
      for (final s in [rideTracking, parcelTracking, intercityTracking]) {
        expect(s.contains('orderController = RealtimeOrderController(orderId: widget.orderId);'), isTrue);
        expect(s.contains('orderController.dispose();'), isTrue);
      }
    });

    test('15. Directions: the Phase 2B/2D getDirections(timeout:) call sites are unchanged', () {
      for (final s in [rideTracking, parcelTracking, intercityTracking]) {
        expect(s.contains('timeout: const Duration(seconds: 8),'), isTrue);
        expect(s.contains(').timeout(const Duration(seconds: 8))'), isFalse);
      }
    });
  });
}
