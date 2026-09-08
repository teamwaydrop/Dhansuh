// Regression guard for PHASE 10E / Phase 2A -- rider GPS -> WebView / MapLibre camera performance.
//
// FORENSIC ROOT CAUSE (positive-feedback render loop):
//   rider_active_order_screen.dart's local GPS stream used bare
//     LocationSettings(accuracy: bestForNavigation, distanceFilter: 3)   // no intervalDuration
//   so on Android the fused provider delivered a fix as fast as the GPS produced one (multiple per
//   second for a moving rider). Every fix ran _onLocalLocationUpdate() -> mapController.runJavaScript
//   (updateRiderLocation(...)) with NO throttle, NO in-flight guard. In tracking_engine.js,
//   updateRiderLocation() then called map.easeTo({center, zoom, duration: 1000, essential: true})
//   UNCONDITIONALLY on every fix -- so each easeTo interrupted and restarted the previous one, the
//   MapLibre camera animation never completed, and its per-frame render loop ran continuously
//   (WebView compositing + GPU churn, and a more likely renderer-process kill under memory
//   pressure).
//
// THE FIX (this guard asserts it stays fixed):
//   1. GPS stream: AndroidSettings.intervalDuration caps OS delivery at ~1/s; distanceFilter 3 and
//      bestForNavigation accuracy preserved.
//   2. _onLocalLocationUpdate(): now a throttle/coalesce gate -- <=1 runJavaScript per 1000ms,
//      <=1 eval in flight, latest-value-wins, bounded footprint (one pending Position, one Timer).
//   3. tracking_engine.js camera: only re-centres when the rider leaves a ~45m dead-zone around the
//      map centre, never starts a new ease while one is running (isEasing/isMoving guard), 600ms
//      ease. The rider MARKER still glides on every fix via the (already-fixed, untouched)
//      animateActiveRider() loop.
//   4. dispose(): sets _disposed first, cancels the throttle Timer + location sub, and explicitly
//      tears the map/engine down (destroyTrackingEngine + destroyMap) instead of relying on the
//      WebView document 'unload' event that does not reliably fire on Flutter platform-view dispose.
//   5. rider tracking map only: bounded maxTileCacheSize + fadeDuration:0 (other map screens
//      untouched -- ola_map_core.js applies them only when the caller passes them).
//   6. onWebResourceError: one-shot reload of the map document on a main-frame failure.
//
// Structural guards (read the real source text) -- these assets/screens have no widget/JS test
// runner of their own; this matches the pattern used across this suite for non-unit-testable code.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final engine = _read('assets/map/tracking_engine.js');
  final core = _read('assets/map/ola_map_core.js');
  final riderHtml = _read('assets/map/ola_map_tracking_rider.html');
  final userHtml = _read('assets/map/ola_map_tracking_user.html');
  final screen =
      _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');

  // Slice of updateRiderLocation() from its declaration to the next top-level window.* function.
  String updateRiderLocationBody() {
    final start = engine.indexOf('window.updateRiderLocation = function(');
    expect(start, greaterThanOrEqualTo(0));
    final end = engine.indexOf('window.recenterToRider = function()', start);
    expect(end, greaterThan(start));
    return engine.substring(start, end);
  }

  group('1. GPS stream is rate-limited (no uncontrolled high-frequency fixes)', () {
    test('the tracking-screen local stream now uses AndroidSettings with an intervalDuration', () {
      final startTracking = screen.indexOf('void _startLocalLocationTracking()');
      final endTracking = screen.indexOf('void _onLocalLocationUpdate(');
      expect(startTracking, greaterThan(0));
      expect(endTracking, greaterThan(startTracking));
      final body = screen.substring(startTracking, endTracking);

      expect(body.contains('AndroidSettings('), isTrue,
          reason: 'Android must use AndroidSettings so intervalDuration can be set');
      expect(body.contains('intervalDuration:'), isTrue,
          reason: 'an explicit OS delivery interval is the whole point of the fix');
      // A bare const LocationSettings with only accuracy+distanceFilter (no interval) must no longer
      // be what the stream is started with.
      expect(
        RegExp(r'getPositionStream\(\s*locationSettings:\s*const LocationSettings\(')
            .hasMatch(body),
        isFalse,
        reason: 'the stream must not be started with a bare const LocationSettings any more',
      );
    });

    test('navigation accuracy and the 3m distance filter are preserved', () {
      final startTracking = screen.indexOf('void _startLocalLocationTracking()');
      final endTracking = screen.indexOf('void _onLocalLocationUpdate(');
      final body = screen.substring(startTracking, endTracking);
      expect(body.contains('LocationAccuracy.bestForNavigation'), isTrue);
      expect(body.contains('distanceFilter: 3'), isTrue);
    });

    test('the interval is ~1s (not so infrequent it harms tracking/safety)', () {
      final startTracking = screen.indexOf('void _startLocalLocationTracking()');
      final endTracking = screen.indexOf('void _onLocalLocationUpdate(');
      final body = screen.substring(startTracking, endTracking);
      expect(
        body.contains('intervalDuration: const Duration(milliseconds: 1000)') ||
            body.contains('intervalDuration: const Duration(seconds: 1)'),
        isTrue,
        reason: 'a ~1s interval keeps the map responsive while killing the multi-fix-per-second flood',
      );
    });

    test('only ONE geolocator position stream is created in this screen (no second stream added)',
        () {
      expect('Geolocator.getPositionStream('.allMatches(screen).length, 1);
    });
  });

  group('2. _onLocalLocationUpdate() throttles + coalesces the WebView push', () {
    test('it no longer calls runJavaScript directly -- it delegates to the throttle gate', () {
      final start = screen.indexOf('void _onLocalLocationUpdate(Position position) {');
      final end = screen.indexOf('void _maybeFlushRiderLocationToMap()');
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      final body = screen.substring(start, end);
      expect(body.contains('runJavaScript'), isFalse,
          reason: '_onLocalLocationUpdate must not push to the WebView itself any more');
      expect(body.contains('_pendingMapPosition = position'), isTrue,
          reason: 'latest-value-wins: the newest fix is always recorded');
      expect(body.contains('_maybeFlushRiderLocationToMap()'), isTrue);
    });

    test('a minimum inter-push gap of ~1s is enforced', () {
      expect(
        screen.contains('static const Duration _mapPushMinGap = Duration(milliseconds: 1000)') ||
            screen.contains('static const Duration _mapPushMinGap = Duration(seconds: 1)'),
        isTrue,
      );
      final flushStart = screen.indexOf('void _maybeFlushRiderLocationToMap()');
      final flushEnd = screen.indexOf('void _pushRiderLocationToMap(');
      final flush = screen.substring(flushStart, flushEnd);
      expect(flush.contains('sinceLast < _mapPushMinGap'), isTrue,
          reason: 'the gate must compare elapsed time against the min gap');
    });

    test('an in-flight guard prevents overlapping / queued JS evals', () {
      expect(screen.contains('bool _mapPushInFlight = false;'), isTrue);
      final flushStart = screen.indexOf('void _maybeFlushRiderLocationToMap()');
      final flushEnd = screen.indexOf('void _pushRiderLocationToMap(');
      final flush = screen.substring(flushStart, flushEnd);
      expect(flush.contains('if (_mapPushInFlight)'), isTrue,
          reason: 'while an eval is in flight the gate must not start another');
      // The push sets the flag, and whenComplete() clears it + re-drives the gate.
      final pushStart = screen.indexOf('void _pushRiderLocationToMap(');
      final pushEnd = screen.indexOf('Future<void> _triggerInitialLocation()');
      final push = screen.substring(pushStart, pushEnd);
      expect(push.contains('_mapPushInFlight = true;'), isTrue);
      expect(
        RegExp(r'\.whenComplete\(\(\)\s*\{\s*_mapPushInFlight = false;').hasMatch(push),
        isTrue,
        reason: 'the in-flight flag is released only when the previous eval actually resolves',
      );
      expect(push.contains('_maybeFlushRiderLocationToMap()'), isTrue,
          reason: 'a fix that arrived during the eval is flushed the moment it completes');
    });

    test('the JS update queue is bounded: one pending Position, one Timer, one runJavaScript site',
        () {
      expect(screen.contains('Position? _pendingMapPosition;'), isTrue);
      expect(screen.contains('Timer? _mapPushTimer;'), isTrue);
      // Exactly one place that actually evaluates updateRiderLocation in the WebView.
      expect(
        "updateRiderLocation(\$lat, \$lng,".allMatches(screen).length,
        1,
        reason: 'there must be a single updateRiderLocation runJavaScript call site, not a fan-out',
      );
      // The throttle path constructs exactly one Timer (the single trailing gap-boundary flush),
      // and only when one isn't already active -- never a growing set of scheduled JS calls.
      final flushStart = screen.indexOf('void _maybeFlushRiderLocationToMap()');
      final flushEnd = screen.indexOf('void _pushRiderLocationToMap(');
      final flush = screen.substring(flushStart, flushEnd);
      expect('_mapPushTimer = Timer('.allMatches(flush).length, 1,
          reason: 'exactly one Timer construction in the throttle gate');
      expect(flush.contains('_mapPushTimer == null || !_mapPushTimer!.isActive'), isTrue,
          reason: 'a new trailing timer is only armed when none is already pending (no stacking)');
      // _pushRiderLocationToMap never schedules a timer or a recursive JS call of its own.
      final pushStart = screen.indexOf('void _pushRiderLocationToMap(');
      final pushEnd = screen.indexOf('Future<void> _triggerInitialLocation()');
      expect(screen.substring(pushStart, pushEnd).contains('Timer('), isFalse);
    });

    test('the updateRiderLocation JS contract (7 ordered args) is unchanged', () {
      expect(
        screen.contains(
          "updateRiderLocation(\$lat, \$lng, \${jsonEncode(name)}, \${jsonEncode(image)}, "
          "\${jsonEncode(vehicleType)}, \$heading, \${jsonEncode(status)}); }",
        ),
        isTrue,
      );
    });
  });

  group('3. tracking_engine.js -- camera is not eased on every GPS fix', () {
    test('the unconditional easeTo({duration: 1000}) on every update is gone', () {
      final body = updateRiderLocationBody();
      expect(body.contains('duration: 1000'), isFalse,
          reason: 'the 1s ease-on-every-fix is exactly the loop being removed');
    });

    test('the camera only moves when the rider leaves a dead-zone around the map centre', () {
      final body = updateRiderLocationBody();
      expect(body.contains('CAMERA_DEADZONE_M'), isTrue);
      expect(body.contains('getCenter()'), isTrue,
          reason: 'displacement is measured against the current map centre');
      expect(
        RegExp(r'followDistM\s*>\s*CAMERA_DEADZONE_M').hasMatch(body),
        isTrue,
        reason: 'the ease is gated on meaningful displacement past the dead-zone',
      );
    });

    test('a new ease is never started while one is already running', () {
      final body = updateRiderLocationBody();
      expect(body.contains('.isEasing()'), isTrue);
      expect(body.contains('.isMoving()'), isTrue);
      // The follow block must check these before easing.
      final followIdx = body.indexOf('window.isFollowingRider &&');
      final easeIdx = body.indexOf('.easeTo({');
      expect(followIdx, greaterThan(0));
      expect(easeIdx, greaterThan(followIdx));
      expect(body.substring(followIdx, easeIdx).contains('.isEasing()'), isTrue);
    });

    test('the ease itself is shorter (600ms) and still essential', () {
      final body = updateRiderLocationBody();
      expect(body.contains('duration: 600'), isTrue);
      expect(body.contains('essential: true'), isTrue);
      expect(body.contains('zoom: 15.5'), isTrue,
          reason: 'follow zoom level is unchanged');
    });

    test('follow-mode gating (window.isFollowingRider) is preserved exactly', () {
      final body = updateRiderLocationBody();
      expect(body.contains('if (window.isFollowingRider'), isTrue);
    });

    test('there is exactly one easeTo in the whole tracking engine (the follow camera)', () {
      expect('.easeTo({'.allMatches(engine).length, 1);
    });

    test('the rider MARKER animation path is untouched (still smooth every fix)', () {
      // Covered in depth by tracking_engine_animation_stop_regression_test.dart; a couple of local
      // anchors so a careless camera edit that also disturbs the marker loop fails here too.
      final body = updateRiderLocationBody();
      expect(body.contains('window._resumeRiderAnimation();'), isTrue);
      expect(engine.contains('const factor = 0.08;'), isTrue);
      expect(engine.contains('if (dist < 1.5) {'), isTrue);
      expect(engine.contains('} else if (dist >= 20) {'), isTrue);
    });

    test('recenterToRider / focusOnRider still fly to the rider and re-enable follow', () {
      final recenter = engine.substring(
        engine.indexOf('window.recenterToRider = function()'),
        engine.indexOf('window.focusOnRider = function()'),
      );
      expect(recenter.contains('window.isFollowingRider = true;'), isTrue);
      expect(recenter.contains('.flyTo({'), isTrue);
      final focus = engine.substring(
        engine.indexOf('window.focusOnRider = function()'),
        engine.indexOf('window.showRoute = function()'),
      );
      expect(focus.contains('window.isFollowingRider = true;'), isTrue);
      expect(focus.contains('.flyTo({'), isTrue);
    });
  });

  group('4. Lifecycle cleanup is safe and explicit', () {
    test('dispose() sets _disposed first, then cancels the throttle timer + location sub', () {
      final disposeStart = screen.indexOf('  void dispose() {');
      final disposeEnd = screen.indexOf('super.dispose();', disposeStart);
      expect(disposeStart, greaterThan(0));
      final body = screen.substring(disposeStart, disposeEnd);
      expect(body.indexOf('_disposed = true;'), greaterThanOrEqualTo(0));
      expect(body.indexOf('_disposed = true;') < body.indexOf('_mapPushTimer?.cancel()'), isTrue,
          reason: '_disposed must be set before anything that a late async callback could observe');
      expect(body.contains('_mapPushTimer?.cancel();'), isTrue);
      expect(body.contains('_localLocationSubscription?.cancel();'), isTrue);
    });

    test('dispose() explicitly tears down the tracking engine AND the map', () {
      final disposeStart = screen.indexOf('  void dispose() {');
      final disposeEnd = screen.indexOf('super.dispose();', disposeStart);
      final body = screen.substring(disposeStart, disposeEnd);
      expect(body.contains('destroyTrackingEngine()'), isTrue);
      expect(body.contains('destroyMap()'), isTrue);
      // Guarded: JS try/catch + Dart catchError, and skipped on the mock/desktop path.
      expect(body.contains('} catch (e) {}'), isTrue);
      expect(body.contains('.catchError((_) {})'), isTrue);
      expect(body.contains('if (!_useMockMap)'), isTrue);
    });

    test('destroyTrackingEngine and destroyMap are idempotent (guard before touching state)', () {
      final dte = engine.substring(engine.indexOf('window.destroyTrackingEngine = function()'));
      expect(dte.contains('if (window.riderMarker)'), isTrue);
      expect(dte.contains('cancelAnimationFrame'), isTrue);
      final dm = core.substring(core.indexOf('window.destroyMap = function()'));
      expect(dm.contains('if (window.MapState.map)'), isTrue);
    });

    test('every throttle entry point short-circuits once disposed', () {
      for (final fn in [
        'void _onLocalLocationUpdate(Position position) {',
        'void _maybeFlushRiderLocationToMap() {',
        'void _pushRiderLocationToMap(Position position) {',
      ]) {
        final i = screen.indexOf(fn);
        expect(i, greaterThan(0), reason: 'missing $fn');
        final head = screen.substring(i, i + 260);
        expect(head.contains('_disposed'), isTrue,
            reason: '$fn must bail if _disposed');
      }
    });
  });

  group('5. Map resource settings -- rider tracking map only', () {
    test('the rider tracking HTML passes a bounded tile cache and fadeDuration:0', () {
      final init = riderHtml.substring(
        riderHtml.indexOf('window.initializeMap('),
        riderHtml.indexOf('if (window.MapState.map)'),
      );
      expect(RegExp(r'maxTileCacheSize:\s*\d+').hasMatch(init), isTrue);
      expect(init.contains('fadeDuration: 0'), isTrue);
    });

    test('ola_map_core.js applies them ONLY when the caller passes them (opt-in)', () {
      expect(core.contains("typeof options.maxTileCacheSize === 'number'"), isTrue);
      expect(core.contains("typeof options.fadeDuration === 'number'"), isTrue);
    });

    test('the passenger tracking map is unchanged (does not pass these options)', () {
      expect(userHtml.contains('maxTileCacheSize'), isFalse);
      expect(userHtml.contains('fadeDuration'), isFalse);
    });
  });

  group('6. WebView main-frame failure recovery (one-shot)', () {
    test('an onWebResourceError handler exists, is main-frame-gated and one-shot', () {
      final initStart = screen.indexOf('void _initMapController()');
      final initEnd = screen.indexOf('void _startLocalLocationTracking()');
      final body = screen.substring(initStart, initEnd);
      expect(body.contains('onWebResourceError:'), isTrue);
      expect(body.contains('error.isForMainFrame != true'), isTrue,
          reason: 'transient sub-resource (tile/font) errors must be ignored');
      expect(body.contains('_mapReloadAttempts'), isTrue);
      expect(body.contains('_mapReloadAttempts >= 1'), isTrue,
          reason: 'a reload storm must be impossible');
      expect(body.contains("loadFlutterAsset('assets/map/ola_map_tracking_rider.html')"), isTrue);
    });
  });

  group('7. Out of scope stays out of scope', () {
    test('no Realtime / polling / cron / payment / edge-function changes in the touched files', () {
      for (final needle in [
        'supabase_realtime',
        'REALTIME',
        'Broadcast',
        'pg_cron',
        'calculate-order-pricing',
        'start-dispatch',
      ]) {
        expect(engine.contains(needle), isFalse, reason: '"$needle" in tracking_engine.js');
        expect(core.contains(needle), isFalse, reason: '"$needle" in ola_map_core.js');
      }
    });

    test('the DB/dispatch GPS path (LocationCacheService) is not touched by this screen edit', () {
      // rider_active_order_screen.dart still only READS LocationCacheService (cached position for
      // the mock map + initial location seed); it never starts/alters the dispatch location stream.
      expect(screen.contains('LocationCacheService.startRiderLiveTracking'), isFalse);
      expect(screen.contains("'current_lat'"), isFalse);
      expect(screen.contains("'current_heading'"), isFalse);
    });

    test('the passenger tracking screens were not modified for Phase 2A', () {
      // They share tracking_engine.js (and therefore benefit from the camera fix) but their Dart
      // files must be untouched by this change set.
      for (final f in [
        'lib/features/local_rides/tracking/screens/ride_tracking_screen.dart',
        'lib/features/intercity/shared/screens/intercity_tracking_screen.dart',
        'lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart',
      ]) {
        final src = _read(f);
        expect(src.contains('_mapPushMinGap'), isFalse,
            reason: '$f must not have picked up the Phase 2A throttle');
      }
    });
  });
}
