// Regression guard for Phase 10E -- Phase 2F implementation C1.
//
// Phase 2F-B (F3, commit c1ccf56) added an EXPLICIT Dart-side WebView teardown to the passenger
// tracking screens + the Home map widget + ride_location_screen, mirroring the Phase 2A
// rider_active_order_screen pattern: a fire-and-forget
//   runJavaScript('try { ...typeof-guarded destroy*()... } catch (e) {}').catchError((_) {})
// in dispose(), because the HTML 'unload' event does not reliably fire when Flutter disposes a
// platform WebView without a navigation -- leaking the MapLibre GL context + its RAF render loop.
//
// Phase 2F-C1 completes that work for the 9 remaining map-bearing screens that still relied only
// on HTML 'unload':
//
//   searching screens  (asset: ola_map_searching.html  -> ola_map_core.js; uses startSearchingAnimation)
//     - ride_searching_screen.dart
//     - parcel_searching_screen.dart
//     - intercity_searching_screen.dart
//
//   location pickers   (asset: ola_map_location_picker.html -> ola_map_core.js; NO searching animation)
//     - home_location_screen.dart        (has _useMockMap -> teardown is !_useMockMap-guarded)
//     - parcel_location_screen.dart
//     - intercity_location_screen.dart
//
//   booking screens    (late final WebViewController -> outer try/catch guards LateInitializationError)
//     - parcel_booking_screen.dart           (asset: ola_map_booking.html -> ola_map_core.js)
//     - intercity_ride_booking_screen.dart   (asset: ola_map_booking.html -> ola_map_core.js)
//     - intercity_booking_screen.dart        (asset: ola_map.html -- DEPRECATED, self-contained;
//                                             guarded no-op today, kept for consistency)
//
// Structural (source-as-text) guard -- this repo's established convention for the map layer.
// Whitespace-tolerant: dispose bodies are normalised before matching.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// Collapse all runs of whitespace to a single space so the guards do not depend on formatter
/// line-wrapping / indentation.
String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// dispose() body, from `void dispose() {` through the first `super.dispose();`.
String _disposeBody(String src) {
  final start = src.indexOf('void dispose() {');
  expect(start, greaterThanOrEqualTo(0), reason: 'no dispose() found');
  final superIdx = src.indexOf('super.dispose();', start);
  expect(superIdx, greaterThan(start), reason: 'no super.dispose() after dispose()');
  return src.substring(start, superIdx + 'super.dispose();'.length);
}

/// The teardown call shape Phase 2F-C1 uses: a fire-and-forget runJavaScript() whose body is a
/// `try { ... } catch (e) {}` that typeof-guards each destroy helper, chained with
/// `.catchError((_) {})` so a dead-controller JS future can never throw out of dispose().
void _expectTeardown(String disposeBody, {required List<String> helpers}) {
  final n = _norm(disposeBody);
  expect(n.contains('.runJavaScript('), isTrue, reason: 'no runJavaScript in dispose()');
  expect(n.contains('.catchError((_) {})'), isTrue, reason: 'teardown not fire-and-forget');
  expect(n.contains('try { '), isTrue, reason: 'JS body not try-wrapped');
  expect(n.contains('} catch (e) {}'), isTrue, reason: 'JS body not catch-wrapped');
  for (final h in helpers) {
    expect(
      n.contains('if (typeof $h === "function") { $h(); }'),
      isTrue,
      reason: '$h not typeof-guarded / called',
    );
  }
  // teardown must run before super.dispose().
  expect(
    disposeBody.indexOf('.runJavaScript('),
    lessThan(disposeBody.indexOf('super.dispose();')),
    reason: 'teardown must be before super.dispose()',
  );
}

void main() {
  const searchingHelpers = [
    'stopSearchingAnimation',
    'destroyNearbyRidersEngine',
    'destroyTrackingEngine',
    'destroyMap',
  ];
  const nonSearchingHelpers = [
    'destroyNearbyRidersEngine',
    'destroyTrackingEngine',
    'destroyMap',
  ];

  final rideSearching =
      _read('lib/features/local_rides/searching/screens/ride_searching_screen.dart');
  final parcelSearching =
      _read('lib/features/local_parcels/searching/screens/parcel_searching_screen.dart');
  final intercitySearching =
      _read('lib/features/intercity/shared/screens/intercity_searching_screen.dart');

  final homeLocation = _read('lib/features/user/home/home_location_screen.dart');
  final parcelLocation =
      _read('lib/features/local_parcels/booking/screens/parcel_location_screen.dart');
  final intercityLocation =
      _read('lib/features/intercity/shared/screens/intercity_location_screen.dart');

  final parcelBooking =
      _read('lib/features/local_parcels/booking/screens/parcel_booking_screen.dart');
  final intercityRideBooking =
      _read('lib/features/intercity/rides/booking/intercity_ride_booking_screen.dart');
  final intercityBooking =
      _read('lib/features/intercity/parcels/booking/intercity_booking_screen.dart');

  group('Phase 2F-C1 -- searching screens tear down the map WebView in dispose()', () {
    test('1. ride_searching_screen.dart', () {
      final body = _disposeBody(rideSearching);
      _expectTeardown(body, helpers: searchingHelpers);
      expect(_norm(body).contains('final mapCtrl = mapController;'), isTrue);
      expect(_norm(body).contains('if (mapCtrl != null) {'), isTrue);
      // existing disposals preserved.
      expect(body.contains('pulseController.dispose();'), isTrue);
      expect(body.contains('orderController.dispose();'), isTrue);
      expect(body.contains('orderController.orderNotifier.removeListener(_onOrderUpdate);'), isTrue);
    });

    test('2. parcel_searching_screen.dart', () {
      final body = _disposeBody(parcelSearching);
      _expectTeardown(body, helpers: searchingHelpers);
      expect(_norm(body).contains('final mapCtrl = mapController;'), isTrue);
      // existing disposals preserved.
      expect(body.contains('riderRefreshTimer?.cancel();'), isTrue);
      expect(body.contains('orderController.dispose();'), isTrue);
    });

    test('3. intercity_searching_screen.dart', () {
      final body = _disposeBody(intercitySearching);
      _expectTeardown(body, helpers: searchingHelpers);
      expect(_norm(body).contains('final mapCtrl = mapController;'), isTrue);
      expect(body.contains('orderController.dispose();'), isTrue);
    });
  });

  group('Phase 2F-C1 -- location pickers tear down the map WebView in dispose()', () {
    test('4. home_location_screen.dart (mock-map guarded, still disposes pulse + controllers)', () {
      final body = _disposeBody(homeLocation);
      _expectTeardown(body, helpers: nonSearchingHelpers);
      expect(_norm(body).contains('if (!_useMockMap) {'), isTrue,
          reason: 'desktop/mock path has no WebView');
      expect(_norm(body).contains('final controller = webController;'), isTrue);
      // location pickers must NOT call the searching-only helper.
      expect(body.contains('stopSearchingAnimation'), isFalse);
      for (final existing in [
        '_pulseController.dispose();',
        'locationController.dispose();',
        'locationFocus.dispose();',
        'searchDebounce?.cancel();',
        '_debounceGeocode?.cancel();',
      ]) {
        expect(body.contains(existing), isTrue, reason: '"$existing" must remain in dispose()');
      }
    });

    test('5. parcel_location_screen.dart', () {
      final body = _disposeBody(parcelLocation);
      _expectTeardown(body, helpers: nonSearchingHelpers);
      expect(_norm(body).contains('final controller = webController;'), isTrue);
      expect(body.contains('stopSearchingAnimation'), isFalse);
      for (final existing in [
        '_pulseController.dispose();',
        'pickupController.dispose();',
        'destinationController.dispose();',
        'pickupDebounce?.cancel();',
        '_debounceGeocode?.cancel();',
      ]) {
        expect(body.contains(existing), isTrue, reason: '"$existing" must remain in dispose()');
      }
    });

    test('6. intercity_location_screen.dart', () {
      final body = _disposeBody(intercityLocation);
      _expectTeardown(body, helpers: nonSearchingHelpers);
      expect(_norm(body).contains('final controller = webController;'), isTrue);
      expect(body.contains('stopSearchingAnimation'), isFalse);
      for (final existing in [
        '_pulseController.dispose();',
        'pickupController.dispose();',
        'destinationController.dispose();',
        'pickupDebounce?.cancel();',
        '_debounceGeocode?.cancel();',
      ]) {
        expect(body.contains(existing), isTrue, reason: '"$existing" must remain in dispose()');
      }
    });
  });

  group('Phase 2F-C1 -- booking screens tear down the map WebView in dispose()', () {
    test('7. parcel_booking_screen.dart (late final -> outer try/catch, keeps timer + promo)', () {
      final body = _disposeBody(parcelBooking);
      _expectTeardown(body, helpers: nonSearchingHelpers);
      expect(body.contains('stopSearchingAnimation'), isFalse);
      // late final controller: an outer try/catch guards LateInitializationError.
      expect(_norm(body).contains('try { webController .runJavaScript('),
          isTrue, reason: 'teardown must be wrapped in an outer try {}');
      expect(_norm(body).contains('} catch (_) {}'), isTrue,
          reason: 'outer catch for LateInitializationError missing');
      expect(body.contains('_riderRefreshTimer?.cancel();'), isTrue);
      expect(body.contains('_promoController.dispose();'), isTrue);
    });

    test('8. intercity_ride_booking_screen.dart (late final -> outer try/catch, keeps promo)', () {
      final body = _disposeBody(intercityRideBooking);
      _expectTeardown(body, helpers: nonSearchingHelpers);
      expect(body.contains('stopSearchingAnimation'), isFalse);
      expect(_norm(body).contains('try { webController .runJavaScript('), isTrue);
      expect(_norm(body).contains('} catch (_) {}'), isTrue);
      expect(body.contains('_promoController.dispose();'), isTrue);
    });

    test('9. intercity_booking_screen.dart (DEPRECATED ola_map.html; guarded no-op, still valid)', () {
      final body = _disposeBody(intercityBooking);
      _expectTeardown(body, helpers: nonSearchingHelpers);
      expect(body.contains('stopSearchingAnimation'), isFalse);
      expect(_norm(body).contains('try { webController .runJavaScript('), isTrue);
      expect(_norm(body).contains('} catch (_) {}'), isTrue);
      expect(body.contains('_promoController.dispose();'), isTrue);
    });
  });

  group('Phase 2F-C1 -- assets each screen loads are unchanged and only touched on the Dart side',
      () {
    test('10. searching screens still load ola_map_searching.html, which still uses '
        'startSearchingAnimation and its unload handler', () {
      for (final s in [rideSearching, parcelSearching, intercitySearching]) {
        expect(s.contains("loadFlutterAsset('assets/map/ola_map_searching.html')"), isTrue);
      }
      final html = _read('assets/map/ola_map_searching.html');
      expect(html.contains('window.startSearchingAnimation('), isTrue);
      expect(html.contains('<script src="ola_map_core.js">'), isTrue);
      expect(html.contains("window.addEventListener('unload'"), isTrue);
      // Phase 2F-C1 is a Dart-only change: no marker was added to any asset.
      expect(html.contains('Phase 2F-C1'), isFalse);
    });

    test('11. location pickers still load ola_map_location_picker.html (unchanged)', () {
      for (final s in [homeLocation, parcelLocation, intercityLocation]) {
        expect(s.contains("loadFlutterAsset('assets/map/ola_map_location_picker.html')"), isTrue);
      }
      final html = _read('assets/map/ola_map_location_picker.html');
      expect(html.contains('<script src="ola_map_core.js">'), isTrue);
      expect(html.contains("window.addEventListener('unload'"), isTrue);
      expect(html.contains('Phase 2F-C1'), isFalse);
    });

    test('12. booking screens still load their existing assets (unchanged)', () {
      expect(parcelBooking.contains("loadFlutterAsset('assets/map/ola_map_booking.html')"), isTrue);
      expect(intercityRideBooking.contains("loadFlutterAsset('assets/map/ola_map_booking.html')"),
          isTrue);
      expect(intercityBooking.contains("loadFlutterAsset('assets/map/ola_map.html')"), isTrue);
      final booking = _read('assets/map/ola_map_booking.html');
      final deprecated = _read('assets/map/ola_map.html');
      expect(booking.contains("window.addEventListener('unload'"), isTrue);
      expect(booking.contains('Phase 2F-C1'), isFalse);
      // ola_map.html keeps its c1ccf56 defense-in-depth unload handler and nothing more.
      expect(deprecated.contains("window.addEventListener('unload'"), isTrue);
      expect(deprecated.contains('Phase 2F-C1'), isFalse);
    });
  });

  group('Phase 2F-C1 -- earlier phases remain untouched', () {
    test('13. Phase 2F-B teardown screens are unchanged (still C1-marker-free, still torn down)',
        () {
      for (final path in [
        'lib/features/local_rides/tracking/screens/ride_tracking_screen.dart',
        'lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart',
        'lib/features/intercity/shared/screens/intercity_tracking_screen.dart',
        'lib/shared/widgets/maps/transport_map_widget.dart',
        'lib/features/local_rides/booking/screens/ride_location_screen.dart',
      ]) {
        final src = _read(path);
        expect(src.contains('Phase 2F-C1'), isFalse, reason: '$path must not be a C1 target');
        expect(_disposeBody(src).contains('.runJavaScript('), isTrue,
            reason: '$path Phase 2F-B teardown lost');
      }
    });

    test('14. Phase 2A rider_active_order_screen teardown is unchanged', () {
      final body = _disposeBody(
          _read('lib/features/rider/orders/screens/rider_active_order_screen.dart'));
      expect(body.contains('if (typeof destroyTrackingEngine === "function") { destroyTrackingEngine(); }'),
          isTrue);
      expect(body.contains('if (typeof destroyMap === "function") { destroyMap(); }'), isTrue);
      expect(body.contains('destroyNearbyRidersEngine'), isFalse);
      expect(body.contains('Phase 2F-C1'), isFalse);
    });

    test('15. Phase 2F-A F1 convergence code still present in ola_map_core.js + ola_map.html', () {
      final core = _read('assets/map/ola_map_core.js');
      final html = _read('assets/map/ola_map.html');
      expect(core.contains('_allConverged()'), isTrue);
      expect(core.contains('_rearm()'), isTrue);
      expect(html.contains('_allConverged()'), isTrue);
    });
  });
}
