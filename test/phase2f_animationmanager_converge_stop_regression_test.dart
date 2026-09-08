// Regression guard for Phase 10E — Phase 2F implementation A.
//
// F1: AnimationManager (the nearby-rider marker animation loop, present in BOTH ola_map_core.js
//     and the self-contained ola_map.html) used to call requestAnimationFrame(itself)
//     unconditionally at the end of every frame while `loopActive` -- and `loopActive` is true
//     whenever >=1 marker is registered. So once nearby riders appeared on the home/booking map,
//     the loop ran at full frame rate forever, redrawing stationary markers, including for the
//     whole duration of an active ride while that map sits covered by the tracking screen.
//     FIX: stop scheduling frames once every registered marker has visually converged onto its
//     target (same 0.000005 deg / 1 deg epsilons animate() already uses), and re-arm the loop
//     when a new marker is registered OR an existing marker gets a new target after the loop
//     stopped. This mirrors the already-shipped animateActiveRider()/isRiderStateConverged() fix
//     in tracking_engine.js (Phase G).
//
// F4: loadOlaMap() in ola_map_core.js unconditionally assigns `MapState.map = new maplibregl.Map`
//     -- a duplicate call would orphan the previous map's WebGL context with no .remove().
//     FIX: defensively call the existing destroyMap() first when MapState.map is already set.
//
// Structural (source-as-text) guard -- this repo's established convention for the map JS assets
// (see tracking_engine_animation_stop_regression_test.dart).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final core = _read('assets/map/ola_map_core.js');
  final html = _read('assets/map/ola_map.html');
  final trackingEngine = _read('assets/map/tracking_engine.js');
  final riderScreen =
      _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');

  // ---------------------------------------------------------------------------
  // F1 -- applied to BOTH files (requirement 7)
  // ---------------------------------------------------------------------------
  for (final entry in {
    'ola_map_core.js': core,
    'ola_map.html': html,
  }.entries) {
    final name = entry.key;
    final src = entry.value;

    group('F1 [$name] -- AnimationManager stops the rAF loop once all markers converge', () {
      test('a convergence predicate (_allConverged) and an idempotent re-arm (_rearm) exist', () {
        expect(src.contains('_allConverged('), isTrue,
            reason: '$name: expected a named per-marker convergence check');
        expect(src.contains('_rearm('), isTrue,
            reason: '$name: expected a named idempotent loop re-arm helper');
        // Convergence reuses animate()'s own epsilons -- interpolation thresholds are NOT changed.
        expect(src.contains('> 0.000005'), isTrue);
        expect(src.contains('m.targetHeading - m.currentHeading) > 1'), isTrue);
      });

      test('requirement 1+2: the converged branch stops the loop and returns BEFORE the tail '
          'requestAnimationFrame', () {
        final animateStart = src.indexOf('animate() {');
        expect(animateStart, greaterThan(0));
        // end of the animate() method == the closing of the AnimationManager object literal.
        final animateBody = src.substring(animateStart);

        final convergedIdx = animateBody.indexOf('_allConverged())');
        // the first rAF *inside animate()* is the loop's own self-reschedule tail.
        final tailRafIdx = animateBody.indexOf('requestAnimationFrame(');
        expect(convergedIdx, greaterThan(0), reason: '$name: no convergence check inside animate()');
        expect(tailRafIdx, greaterThan(0));
        expect(convergedIdx, lessThan(tailRafIdx),
            reason: '$name: the converged-stop must be evaluated before the reschedule, so a '
                'converged frame returns before reaching it');

        // The stop branch sets loopActive=false and returns, and does NOT itself schedule a frame.
        final stopBlock = animateBody.substring(
            convergedIdx, tailRafIdx > convergedIdx ? tailRafIdx : convergedIdx + 200);
        expect(stopBlock.contains('loopActive = false'), isTrue);
        expect(stopBlock.contains('return;'), isTrue);
        expect(stopBlock.contains('requestAnimationFrame('), isFalse,
            reason: '$name: the stop branch must not reschedule');
      });

      test('requirement 3: a NEW marker registration re-arms the loop', () {
        // register() already starts the loop when it is not active -- unchanged by this fix.
        expect(
          RegExp(r'register\(id, marker, data\) \{[\s\S]*?if \(!this\.loopActive\) \{\s*this\.loopActive = true;\s*this\.animate\(\);')
              .hasMatch(src),
          isTrue,
          reason: '$name: register() must still start the loop for a new marker',
        );
      });

      test('requirement 4: an existing marker getting a new target re-arms the loop after it '
          'stopped (applyBufferedUpdates calls _rearm after updating targets)', () {
        final abu = src.indexOf('applyBufferedUpdates');
        expect(abu, greaterThan(0));
        final abuBody = src.substring(abu);
        // the target writes...
        final targetWriteIdx = abuBody.indexOf('.targetLat = lat;');
        // ...then the re-arm, before applyBufferedUpdates returns / the next function starts.
        final rearmIdx = abuBody.indexOf('_rearm();');
        expect(targetWriteIdx, greaterThan(0));
        expect(rearmIdx, greaterThan(targetWriteIdx),
            reason: '$name: _rearm() must be called after the target updates in applyBufferedUpdates');
      });

      test('requirement 5: no duplicate animation loop -- _rearm is guarded, and there is still '
          'exactly one self-rescheduling rAF call site inside animate()', () {
        // _rearm bails if a loop is already running.
        expect(
          RegExp(r'_rearm\(\) \{[\s\S]{0,120}(am\.loopActive|this\.loopActive)\) return;').hasMatch(src),
          isTrue,
          reason: '$name: _rearm() must no-op while a loop is already active',
        );
        // and if nothing is left to animate.
        expect(
          RegExp(r'_rearm\(\) \{[\s\S]{0,260}_allConverged\(\)\) return;').hasMatch(src),
          isTrue,
        );
        // Exactly two textual rAF(...animate) occurrences: the fpsInterval>0 setTimeout branch and
        // the else branch -- both are the loop's own single self-reschedule tail. No new scheduler.
        final rafName = name == 'ola_map.html'
            ? 'requestAnimationFrame(AnimationManager.animate)'
            : 'requestAnimationFrame(window.AnimationManager.animate)';
        expect(rafName.allMatches(src).length, 2,
            reason: '$name: exactly the two pre-existing tail call sites, no extra scheduler');
      });

      test('requirement 6 behaviours preserved: interpolation factor, cull/snap, heading step '
          'unchanged; unregister still clears loopActive at zero markers', () {
        expect(src.contains("performanceMode === 'HIGH' ? 0.08"), isTrue);
        expect(src.contains('const maxRotate = 8;'), isTrue);
        expect(src.contains('Math.abs(headingDiff) > 1'), isTrue);
        expect(
          RegExp(r'unregister\(id\) \{[\s\S]*?length === 0\) \{\s*this\.loopActive = false;').hasMatch(src),
          isTrue,
        );
      });
    });
  }

  // ---------------------------------------------------------------------------
  // F4 -- ola_map_core.js only (ola_map.html has no destroyMap() to call)
  // ---------------------------------------------------------------------------
  group('F4 [ola_map_core.js] -- loadOlaMap defensively destroys an existing map first', () {
    test('requirement 6: loadOlaMap calls destroyMap() when MapState.map is set, BEFORE the new '
        'maplibregl.Map', () {
      final lom = core.indexOf('window.loadOlaMap = function(');
      expect(lom, greaterThan(0));
      final body = core.substring(lom);
      final guardIdx = body.indexOf('if (window.MapState.map) {');
      final destroyIdx = body.indexOf('window.destroyMap();');
      final newMapIdx = body.indexOf('new maplibregl.Map(');
      expect(guardIdx, greaterThan(0), reason: 'no MapState.map re-entry guard in loadOlaMap');
      expect(destroyIdx, greaterThan(guardIdx));
      expect(newMapIdx, greaterThan(destroyIdx),
          reason: 'the destroyMap() guard must run before the new map is constructed');
    });

    test('destroyMap() itself is unchanged (still removes markers, route, map, resets flags)', () {
      expect(core.contains('window.destroyMap = function() {'), isTrue);
      expect(
        RegExp(r'window\.destroyMap = function\(\) \{\s*window\.removeAllMarkers\(\);\s*window\.clearRoute\(\);[\s\S]*?window\.MapState\.map\.remove\(\);\s*window\.MapState\.map = null;')
            .hasMatch(core),
        isTrue,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // requirement 8 -- tracking_engine.js Phase G is untouched
  // ---------------------------------------------------------------------------
  group('requirement 8 -- tracking_engine.js animateActiveRider (Phase G) is unchanged', () {
    test('isRiderStateConverged + the single self-reschedule rAF + _resumeRiderAnimation are intact', () {
      expect(trackingEngine.contains('function isRiderStateConverged()'), isTrue);
      expect(
        RegExp(r'requestAnimationFrame\(window\.animateActiveRider\)').allMatches(trackingEngine).length,
        1,
      );
      expect(trackingEngine.contains('window._resumeRiderAnimation = function() {'), isTrue);
      expect(trackingEngine.contains('if (window._riderAnimationActive) return;'), isTrue);
      expect(trackingEngine.contains('const POSITION_CONVERGENCE_DEG = 0.3 / 111000;'), isTrue);
      expect(trackingEngine.contains('const HEADING_CONVERGENCE_DEG = 0.5;'), isTrue);
      // Phase 2F must not have leaked its AnimationManager helper names into this file.
      expect(trackingEngine.contains('_allConverged'), isFalse);
      expect(trackingEngine.contains('_rearm'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // requirement 9 -- Phase 2A rider-map throttle/dispose code is unchanged
  // ---------------------------------------------------------------------------
  group('requirement 9 -- Phase 2A rider active-order map throttle + dispose are unchanged', () {
    test('the _mapPushInFlight throttle, 4s watchdog, and single trailing timer are intact', () {
      expect(riderScreen.contains('bool _mapPushInFlight = false;'), isTrue);
      expect(riderScreen.contains('if (_mapPushInFlight) {'), isTrue);
      expect(riderScreen.contains("DateTime.now().difference(startedAt) < const Duration(seconds: 4)"), isTrue);
      expect(riderScreen.contains('void _maybeFlushRiderLocationToMap() {'), isTrue);
      expect(riderScreen.contains('void _pushRiderLocationToMap(Position position) {'), isTrue);
    });

    test('the explicit dispose() WebView teardown (Phase 2A) is intact', () {
      expect(
        RegExp(r'if \(typeof destroyTrackingEngine === "function"\) \{ destroyTrackingEngine\(\); \}[\s\S]{0,80}if \(typeof destroyMap === "function"\) \{ destroyMap\(\); \}')
            .hasMatch(riderScreen),
        isTrue,
      );
    });

    test('this phase did not touch tracking_engine.js camera dead-zone or the getDirections timeout', () {
      expect(trackingEngine.contains('const CAMERA_DEADZONE_M = 45;'), isTrue);
      expect(riderScreen.contains('timeout: const Duration(seconds: 8),'), isTrue);
    });
  });
}
