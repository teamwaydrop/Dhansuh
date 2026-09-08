// Regression guard for Phase 10E -- Phase 2F implementation E (C3).
//
// Phase 2A gave rider_active_order_screen.dart a minimal WebView renderer-recovery: an
// onWebResourceError handler that, on a MAIN-FRAME load failure (essentially only the Android
// renderer process being killed under memory pressure), reloads the bundled map asset ONCE so the
// screen recovers instead of sitting permanently blank.
//
// The three PASSENGER tracking screens had no such handler -- a killed renderer left the map blank
// for the rest of the ride ("blank map, can't finish the ride"). Phase 2F-E ports the Phase 2A
// pattern to them, plus an explicit guarded JS teardown before the reload (loadOlaMap's re-entry
// guard only calls destroyMap(), not destroyTrackingEngine(), so a bare reload could stack a second
// tracking engine):
//   - ride_tracking_screen.dart
//   - parcel_tracking_screen.dart
//   - intercity_tracking_screen.dart
// All three load assets/map/ola_map_tracking_user.html.
//
// Structural (source-as-text) guard -- this repo's established convention for the map layer.
// Whitespace-tolerant: handler / dispose bodies are normalised before matching.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// Collapse every run of whitespace to a single space so guards do not depend on formatter wrapping.
String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// The `onWebResourceError: (error) { ... }` handler body, from the callback open to the reload
/// call that ends it. Returns the raw (un-normalised) slice so callers can also assert ordering.
String _errorHandler(String src) {
  final start = src.indexOf('onWebResourceError: (error) {');
  expect(start, greaterThanOrEqualTo(0), reason: 'no onWebResourceError handler found');
  final end = src.indexOf(
    "loadFlutterAsset('assets/map/ola_map_tracking_user.html');",
    start,
  );
  expect(end, greaterThan(start), reason: 'handler does not reload the tracking asset');
  return src.substring(start, end + 80);
}

/// dispose() body, from `void dispose() {` through the first `super.dispose();`.
String _disposeBody(String src) {
  final start = src.indexOf('void dispose() {');
  expect(start, greaterThanOrEqualTo(0), reason: 'no dispose() found');
  final superIdx = src.indexOf('super.dispose();', start);
  expect(superIdx, greaterThan(start));
  return src.substring(start, superIdx + 'super.dispose();'.length);
}

void main() {
  const screens = <String, String>{
    'ride_tracking_screen.dart':
        'lib/features/local_rides/tracking/screens/ride_tracking_screen.dart',
    'parcel_tracking_screen.dart':
        'lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart',
    'intercity_tracking_screen.dart':
        'lib/features/intercity/shared/screens/intercity_tracking_screen.dart',
  };

  screens.forEach((name, path) {
    group('Phase 2F-E (C3) -- $name renderer recovery', () {
      final src = _read(path);

      test('A. NavigationDelegate has an onWebResourceError handler', () {
        expect(src.contains('setNavigationDelegate(NavigationDelegate('), isTrue);
        expect(src.contains('onWebResourceError: (error) {'), isTrue);
        // one-shot counter field is declared.
        expect(src.contains('int _mapReloadAttempts = 0;'), isTrue);
      });

      test('B. handler has the mounted / main-frame / one-shot guards and increments', () {
        final h = _norm(_errorHandler(src));
        expect(h.contains('if (!mounted) return;'), isTrue, reason: 'missing mounted guard');
        expect(h.contains('if (error.isForMainFrame != true) return;'), isTrue,
            reason: 'missing main-frame guard');
        expect(h.contains('if (_mapReloadAttempts >= 1) return;'), isTrue,
            reason: 'missing one-shot guard');
        expect(h.contains('_mapReloadAttempts++;'), isTrue, reason: 'counter never incremented');
      });

      test('C. before the reload it runs a guarded, fire-and-forget JS teardown', () {
        final h = _norm(_errorHandler(src));
        expect(h.contains('.runJavaScript('), isTrue);
        expect(h.contains('.catchError((_) {})'), isTrue, reason: 'teardown not fire-and-forget');
        expect(h.contains('try { '), isTrue);
        expect(h.contains('} catch (e) {}'), isTrue);
        for (final helper in const [
          'destroyTrackingEngine',
          'destroyNearbyRidersEngine',
          'destroyMap',
        ]) {
          expect(
            h.contains('if (typeof $helper === "function") { $helper(); }'),
            isTrue,
            reason: '$helper not typeof-guarded in the pre-reload teardown',
          );
        }
      });

      test('D. the reload targets the bundled tracking asset', () {
        final h = _errorHandler(src);
        expect(
          h.contains("mapController?.loadFlutterAsset('assets/map/ola_map_tracking_user.html');"),
          isTrue,
        );
      });

      test('E. the teardown runs BEFORE the reload', () {
        final h = _errorHandler(src);
        final jsIdx = h.indexOf('.runJavaScript(');
        final reloadIdx = h.indexOf("loadFlutterAsset('assets/map/ola_map_tracking_user.html');");
        expect(jsIdx, greaterThanOrEqualTo(0));
        expect(reloadIdx, greaterThan(jsIdx),
            reason: 'reload must come after the destroy* teardown');
      });

      test('F. onPageFinished still reinitialises the tracking map + rider-location flow', () {
        expect(src.contains('onPageFinished: (_) async {'), isTrue);
        expect(src.contains('window.initTrackingMap('), isTrue);
        expect(src.contains('_onRiderLocationUpdate();'), isTrue);
        // the trailing initial asset load in the map-setup method is unchanged.
        expect(
          src.contains(
              "await mapController!.loadFlutterAsset('assets/map/ola_map_tracking_user.html');"),
          isTrue,
        );
      });

      test('G. the Phase 2F-B / 2F-C1 dispose() teardown is still intact', () {
        final body = _norm(_disposeBody(src));
        expect(body.contains('final mapCtrl = mapController;'), isTrue);
        expect(body.contains('if (mapCtrl != null) {'), isTrue);
        for (final helper in const [
          'destroyNearbyRidersEngine',
          'destroyTrackingEngine',
          'destroyMap',
        ]) {
          expect(body.contains('if (typeof $helper === "function") { $helper(); }'), isTrue);
        }
        expect(body.contains('.catchError((_) {})'), isTrue);
        expect(body.contains('orderController.dispose();'), isTrue);
        expect(
          body.indexOf('.runJavaScript('),
          lessThan(body.indexOf('super.dispose();')),
          reason: 'dispose teardown must stay before super.dispose()',
        );
      });

      test('H. no onHttpError was added (C3 is main-frame / renderer recovery only)', () {
        expect(src.contains('onHttpError:'), isFalse);
      });
    });
  });

  group('Phase 2F-E (C3) -- protected files untouched', () {
    test('rider_active_order_screen.dart keeps its Phase 2A renderer-recovery block, unmarked', () {
      final rider =
          _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');
      expect(rider.contains('onWebResourceError: (error) {'), isTrue);
      // Phase 2A reloads the RIDER asset and uses its own _mapReloadAttempts.
      expect(
        rider.contains("mapController?.loadFlutterAsset('assets/map/ola_map_tracking_rider.html');"),
        isTrue,
      );
      expect(rider.contains('_mapReloadAttempts'), isTrue);
      expect(rider.contains('Phase 2F-E'), isFalse,
          reason: 'Phase 2A rider screen must not have been edited by C3');
    });

    test('map JS / HTML assets are not modified by C3', () {
      final core = _read('assets/map/ola_map_core.js');
      final engine = _read('assets/map/tracking_engine.js');
      final trackingHtml = _read('assets/map/ola_map_tracking_user.html');
      for (final asset in [core, engine, trackingHtml]) {
        expect(asset.contains('Phase 2F-E'), isFalse);
      }
      // F1 / F4 (Phase 2F-A) still present in core.
      expect(core.contains('_allConverged()'), isTrue);
      expect(core.contains('_rearm()'), isTrue);
      // destroyNearbyRidersEngine still lives only in core and still lacks a clearTimeout
      // (C7 is a separate, deferred item -- documented here so a future fix updates this guard).
      expect(core.contains('window.destroyNearbyRidersEngine = function() {'), isTrue);
      // tracking asset still tears down on unload and still pulls in the shared scripts.
      expect(trackingHtml.contains("window.addEventListener('unload'"), isTrue);
      expect(trackingHtml.contains('<script src="ola_map_core.js">'), isTrue);
      expect(trackingHtml.contains('<script src="tracking_engine.js">'), isTrue);
    });
  });
}
