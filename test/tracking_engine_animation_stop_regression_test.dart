// Regression guard for the tracking_engine.js rider-marker animation loop fix
// (WayDrop Phase G performance pass).
//
// CONTEXT: animateActiveRider() used to call requestAnimationFrame(itself) unconditionally at the
// end of every invocation, so once the first GPS fix arrived it ran forever at ~60fps for the rest
// of the trip -- redrawing the marker every single frame even while the rider was stationary and
// current already equalled target. It must now stop scheduling further frames once the marker has
// visually converged onto its target, and resume (without ever double-scheduling) the moment
// updateRiderLocation() sets a genuinely new target.
//
// Structural guard (reads the real JS source) -- this asset has no Dart/Deno test runner of its
// own, so, matching the pattern used throughout this suite for non-Dart source, the checks below
// assert on the actual text of the fix rather than executing the JS.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final source = _read('assets/map/tracking_engine.js');

  group('tracking_engine.js -- animateActiveRider() stops once converged', () {
    test('a convergence check exists and is evaluated before rescheduling the next frame', () {
      expect(source.contains('isRiderStateConverged'), isTrue,
          reason: 'expected a named convergence check the animation loop consults every frame');
      final animateStart = source.indexOf('window.animateActiveRider = function()');
      final animateEnd = source.indexOf('window._resumeRiderAnimation = function()');
      expect(animateStart, greaterThanOrEqualTo(0));
      expect(animateEnd, greaterThan(animateStart));
      final animateBody = source.substring(animateStart, animateEnd);
      expect(animateBody.contains('isRiderStateConverged()'), isTrue);
      // The convergence branch must return before scheduling another frame -- i.e. it must appear
      // textually before the loop's own requestAnimationFrame call, not after.
      final convergedIdx = animateBody.indexOf('if (isRiderStateConverged())');
      final rafIdx = animateBody.indexOf('requestAnimationFrame(window.animateActiveRider)');
      expect(convergedIdx, greaterThan(0));
      expect(rafIdx, greaterThan(convergedIdx),
          reason: 'the reschedule call must come after the convergence check, so a converged frame '
              'can return before reaching it');
    });

    test('the converged branch stops scheduling further frames and clears the active flag', () {
      final convergedStart = source.indexOf('if (isRiderStateConverged())');
      final convergedEnd = source.indexOf(
          'window._riderAnimationFrameId = requestAnimationFrame(window.animateActiveRider);');
      expect(convergedStart, greaterThan(0));
      expect(convergedEnd, greaterThan(convergedStart));
      final convergedBlock = source.substring(convergedStart, convergedEnd);
      expect(convergedBlock.contains('window._riderAnimationActive = false'), isTrue);
      expect(convergedBlock.contains('return;'), isTrue,
          reason: 'must return before reaching the reschedule call below it');
      // Must not itself call requestAnimationFrame again.
      expect(convergedBlock.contains('requestAnimationFrame('), isFalse);
    });

    test('the guard clause for a missing marker/state also stops the loop (no orphaned reschedule)',
        () {
      final guardIdx = source.indexOf('if (!window.activeRiderState || !window.riderMarker)');
      expect(guardIdx, greaterThan(0));
      final guardBlock = source.substring(guardIdx, guardIdx + 220);
      expect(guardBlock.contains('window._riderAnimationActive = false'), isTrue);
      expect(guardBlock.contains('return;'), isTrue);
    });
  });

  group('tracking_engine.js -- resume is idempotent (no duplicate concurrent loops)', () {
    test('window._resumeRiderAnimation exists and no-ops while already active', () {
      final resumeStart = source.indexOf('window._resumeRiderAnimation = function()');
      expect(resumeStart, greaterThanOrEqualTo(0));
      final resumeBody = source.substring(resumeStart, resumeStart + 400);
      expect(resumeBody.contains('if (window._riderAnimationActive) return;'), isTrue,
          reason: 'must bail out if a loop is already scheduled, so it can never create a second '
              'concurrent requestAnimationFrame chain');
      expect(resumeBody.contains('if (isRiderStateConverged()) return;'), isTrue,
          reason: 'must not start a loop when there is nothing to animate');
    });

    test('there is exactly one requestAnimationFrame(window.animateActiveRider) call site '
        '(the loop\'s own self-reschedule) -- no second independent scheduler exists', () {
      final matches =
          RegExp(r'requestAnimationFrame\(window\.animateActiveRider\)').allMatches(source);
      expect(matches.length, 1);
    });

    test('marker creation and marker-update paths both route through the resume entry point, '
        'not a direct animateActiveRider() call', () {
      // Both the marker-creation path and the target-update path must call the idempotent resume
      // entry point.
      final resumeCallSites =
          RegExp(r'window\._resumeRiderAnimation\(\);').allMatches(source).length;
      expect(resumeCallSites, 2,
          reason: 'expected exactly two call sites: marker creation and the target-update branch');
      // The bare, direct call must exist exactly once -- inside _resumeRiderAnimation() itself
      // (the one legitimate place it's invoked directly, after the idempotency guard above it has
      // already confirmed it's safe to). It must not exist at the old marker-creation call site or
      // anywhere else, which the exactly-2-resume-call-sites check above already establishes.
      final bareCallSites =
          'window.animateActiveRider();'.allMatches(source).length;
      expect(bareCallSites, 1,
          reason: 'the only direct call should be inside _resumeRiderAnimation()');
    });
  });

  group('tracking_engine.js -- cleanup on destroy', () {
    test('destroyTrackingEngine cancels any in-flight animation frame and resets loop state', () {
      final destroyStart = source.indexOf('window.destroyTrackingEngine = function()');
      expect(destroyStart, greaterThanOrEqualTo(0));
      final destroyBody = source.substring(destroyStart);
      expect(destroyBody.contains('cancelAnimationFrame'), isTrue);
      expect(destroyBody.contains('window._riderAnimationFrameId'), isTrue);
      expect(destroyBody.contains('window._riderAnimationActive = false'), isTrue);
      // Still tears down the marker/state exactly as before.
      expect(destroyBody.contains('window.riderMarker.remove();'), isTrue);
      expect(destroyBody.contains('window.activeRiderState = null;'), isTrue);
    });
  });

  group('tracking_engine.js -- existing interpolation/movement behavior preserved', () {
    test('the lerp factor, max rotation step, and heading threshold are unchanged', () {
      expect(source.contains('const factor = 0.08;'), isTrue);
      expect(source.contains('const maxRotate = 8;'), isTrue);
      expect(source.contains('Math.abs(headingDiff) > 0.5'), isTrue);
    });

    test('trackingLerp and trackingLerpAngle helpers are untouched', () {
      expect(source.contains('function trackingLerp(start, end, t)'), isTrue);
      expect(source.contains('function trackingLerpAngle(a, b, t)'), isTrue);
    });

    test('GPS-jitter/snap/large-jump distance branches in updateRiderLocation are untouched', () {
      expect(source.contains('if (dist < 1.5) {'), isTrue);
      expect(source.contains('if (dist > 1000) {'), isTrue);
      expect(source.contains('} else if (dist > 100) {'), isTrue);
      expect(source.contains('} else if (dist >= 20) {'), isTrue);
    });
  });
}
