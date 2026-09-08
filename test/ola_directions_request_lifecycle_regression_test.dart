// Regression guard for Phase 10E Phase 2B -- Ola Directions request lifecycle / timeout /
// throttling fixes identified by the forensic audit.
//
// Structural (source-as-text) guard, this repo's established convention.
//
// ISSUE 1 -- OlaMapService.getDirections() had no way to cancel its underlying HTTP request. The
// rider active-order screen wrapped the call in `.timeout(8s)`, so its `await` gave up (and
// released the `fetchingRoute` in-flight guard) while the Ola request stayed alive against the
// shared Dio's 15s ceiling -- a ~7s window in which the 15s periodic timer could start a second,
// OVERLAPPING Directions request under network slowness.
//   FIX: getDirections() takes an opt-in `timeout:` Duration; when supplied it drives a per-call
//   CancelToken that actually aborts the in-flight request when the budget elapses. A cancelled
//   request is surfaced as `null` (same downstream handling as any failed fetch) but logged
//   distinctly from a genuine Ola error, and never written to the route cache. Callers that pass
//   no `timeout:` get byte-for-byte the previous behavior (single POST, shared 15s ceiling).
//   The rider screen now passes `timeout:` INTO getDirections instead of wrapping `.timeout()`
//   around it, so the guard and the request are released together -- no overlap window.
//
// ISSUE 2 -- rider_active_order_screen.dart startTimer()'s throttle was
// `optimizedGeometry == null || <interval elapsed>`. While no route geometry was held (initial
// load, or -- the real bug -- a fetch that failed/timed out) the `== null` disjunct
// short-circuited the interval check, so a persistently-failing route re-hit Ola Directions on
// EVERY 15s timer tick.
//   FIX: a route that has not resolved yet retries on a bounded
//   `_failedRouteRetryIntervalSeconds` (20s, wider than the 15s tick) instead of bypassing the
//   throttle; the interval check is now always applied. A held route keeps the adaptive near/far
//   interval, unchanged. Single-in-flight is still enforced by `fetchingRoute` + the
//   `_pendingForceRouteFetch` queued-forced-retry mechanism (untouched).
//
// Out of scope / untouched here (asserted below): Realtime wiring, polling cadence, cron, Edge
// Functions, Supabase, payments, order completion, route geometry format, pickup/drop coords,
// dispatch / rider-location DB writes, and the adaptive-throttle constants from the earlier
// egress-reduction pass.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final ola = _read('lib/core/services/maps/ola_map_service.dart');
  final activeOrderScreen =
      _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');

  group('Issue 1 -- getDirections() cancellation / timeout lifecycle', () {
    test('getDirections() still exists as a RouteModel? origin->destination call', () {
      expect(
        ola.contains('static Future<RouteModel?>\n      getDirections({'),
        isTrue,
        reason: 'getDirections signature/return type must be unchanged',
      );
    });

    test('getDirections() gained an OPT-IN timeout: parameter (existing callers unaffected)', () {
      // Optional, defaulted to null -- so every current caller that does not pass it keeps the
      // old behavior exactly.
      expect(ola.contains('Duration? timeout,'), isTrue);
    });

    test('a per-call CancelToken is created and passed to the directions POST', () {
      final idx = ola.indexOf('getDirections({');
      final body = ola.substring(idx);
      expect(body.contains('final cancelToken = CancelToken();'), isTrue);
      // The token reaches the actual directions request.
      expect(
        RegExp(r"routing/v1/directions[\s\S]{0,400}cancelToken: cancelToken,").hasMatch(body),
        isTrue,
        reason: 'the directions POST must receive the per-call CancelToken',
      );
    });

    test('the timeout, when supplied, actually cancels the in-flight request', () {
      expect(
        RegExp(
          r'if \(timeout != null\) \{\s*'
          r'timeoutTimer = Timer\(timeout, \(\) \{\s*'
          r'if \(!cancelToken\.isCancelled\) \{\s*'
          r'cancelToken\.cancel\(',
        ).hasMatch(ola),
        isTrue,
        reason: 'a supplied timeout must abort the underlying HTTP request, not just stop waiting',
      );
      // And the timer is always cleaned up.
      expect(RegExp(r'finally \{\s*timeoutTimer\?\.cancel\(\);').hasMatch(ola), isTrue);
    });

    test('a cancellation is handled DISTINCTLY from a genuine API error and never cached', () {
      expect(ola.contains('} on DioException catch (e) {'), isTrue);
      expect(
        RegExp(
          r'if \(CancelToken\.isCancel\(e\)\) \{[\s\S]{0,200}'
          r"DIRECTIONS CANCELLED[\s\S]{0,80}return null;",
        ).hasMatch(ola),
        isTrue,
        reason: 'a cancelled request must return null without the DIRECTIONS ERROR path / cache write',
      );
      // The genuine-error path is still there too.
      expect(ola.contains("log(\n        'DIRECTIONS ERROR => \$e',\n      );"), isTrue);
    });

    test('the timeout param does NOT change the shared Dio timeout for unrelated calls', () {
      // The shared Dio still declares the same 15s connect/receive/send ceiling, untouched.
      expect('seconds: 15,'.allMatches(ola).length, greaterThanOrEqualTo(3));
      // reverseGeocode / geocode / autocomplete / placeDetails do not gain a timeout knob.
      for (final other in ['reverseGeocode({', 'getCoordinatesFromAddress(', 'autocomplete(']) {
        final i = ola.indexOf(other);
        expect(i, greaterThan(0));
        final slice = ola.substring(i, i + 900);
        expect(slice.contains('Duration? timeout'), isFalse,
            reason: '$other must not gain a per-call timeout parameter');
      }
    });

    test('rider screen passes timeout INTO getDirections, not wrapped around it', () {
      expect(
        RegExp(r'OlaMapService\.getDirections\([\s\S]{0,400}timeout: const Duration\(seconds: 8\),\s*\);')
            .hasMatch(activeOrderScreen),
        isTrue,
      );
      // The old zombie-window wrapper is gone.
      expect(
        RegExp(r'OlaMapService\.getDirections\([\s\S]{0,400}\)\.timeout\(const Duration\(seconds: 8\)\)')
            .hasMatch(activeOrderScreen),
        isFalse,
        reason: 'the `.timeout()` wrapper that left the request alive after the await gave up must be removed',
      );
      // Budget unchanged at 8s -- this is a lifecycle fix, not a tuning change.
      expect(activeOrderScreen.contains('timeout: const Duration(seconds: 8),'), isTrue);
    });

    test('getMultiStopRoute still routes each leg through the plain getDirections() (no timeout arg)', () {
      expect(ola.contains('final leg = await getDirections('), isTrue);
      final i = ola.indexOf('final leg = await getDirections(');
      expect(ola.substring(i, i + 300).contains('timeout:'), isFalse,
          reason: 'the intercity multi-leg builder must keep the unbudgeted directions behavior');
    });
  });

  group('Issue 2 -- failed-route throttle bypass in startTimer()', () {
    test('a bounded retry interval exists for an unresolved/failed route', () {
      expect(
        activeOrderScreen.contains('static const int _failedRouteRetryIntervalSeconds = 20;'),
        isTrue,
      );
      // Strictly wider than the 15s periodic tick, so it can no longer fire every tick...
      expect(20, greaterThan(15));
      // ...and no wider than the "far" interval, so a broken route still recovers.
      expect(activeOrderScreen.contains('static const int _farRefreshIntervalSeconds = 40'), isTrue);
    });

    test('the `optimizedGeometry == null ||` short-circuit of the interval check is gone', () {
      expect(
        activeOrderScreen.contains(
          'final shouldFetch = optimizedGeometry == null ||\n'
          '            (_lastRouteFetch == null || now.difference(_lastRouteFetch!).inSeconds >= refreshIntervalSeconds);',
        ),
        isFalse,
        reason: 'the null-geometry disjunct must no longer bypass the throttle window',
      );
    });

    test('the interval check is now ALWAYS applied; null geometry only picks the retry interval', () {
      expect(
        activeOrderScreen.contains(
          'final int effectiveIntervalSeconds = optimizedGeometry == null\n'
          '            ? _failedRouteRetryIntervalSeconds\n'
          '            : refreshIntervalSeconds;',
        ),
        isTrue,
      );
      expect(
        activeOrderScreen.contains(
          'final shouldFetch = _lastRouteFetch == null ||\n'
          '            now.difference(_lastRouteFetch!).inSeconds >= effectiveIntervalSeconds;',
        ),
        isTrue,
      );
    });

    test('successful route refresh still uses the adaptive near/far interval (unchanged)', () {
      expect(
        activeOrderScreen.contains(
          'refreshIntervalSeconds = distanceMeters <= _nearTargetThresholdMeters\n'
          '                ? _nearRefreshIntervalSeconds\n'
          '                : _farRefreshIntervalSeconds;',
        ),
        isTrue,
      );
    });

    test('single-in-flight + queued-forced-retry mechanism is untouched', () {
      expect(
        activeOrderScreen.contains('Future<void> fetchOptimizedRoute({bool isForced = false}) async {'),
        isTrue,
      );
      expect(
        RegExp(r'if \(fetchingRoute\) \{[\s\S]{0,400}if \(isForced\) _pendingForceRouteFetch = true;[\s\S]{0,20}return;')
            .hasMatch(activeOrderScreen),
        isTrue,
      );
      expect(
        RegExp(r'finally \{\s*fetchingRoute = false;[\s\S]{0,400}_pendingForceRouteFetch\)[\s\S]{0,200}fetchOptimizedRoute\(isForced: true\);')
            .hasMatch(activeOrderScreen),
        isTrue,
      );
    });

    test('a status transition still forces an immediate refresh (not silently dropped)', () {
      expect(activeOrderScreen.contains('if (oldStatus != newStatus) {\n          optimizedGeometry = null;'), isTrue);
      expect(
        RegExp(r'oldStatus != newStatus[\s\S]{0,400}fetchOptimizedRoute\(isForced: true\)').hasMatch(activeOrderScreen),
        isTrue,
      );
    });

    test('the timer still stops scheduling once the order is completed/delivered/cancelled', () {
      expect(
        RegExp(
          r"if \(order == null \|\|\s*\n\s*currentStatus == 'completed' \|\|\s*\n\s*currentStatus == 'delivered' \|\|\s*\n\s*currentStatus == 'cancelled'\) \{\s*\n\s*return;",
        ).hasMatch(activeOrderScreen),
        isTrue,
      );
      expect(
        activeOrderScreen.contains(
          "if (status == 'completed' || status == 'delivered' || status == 'cancelled') return;",
        ),
        isTrue,
      );
    });
  });

  group('Untouched: everything outside the Directions request lifecycle', () {
    test('route geometry format + JS push into the WebView are unchanged', () {
      expect(activeOrderScreen.contains("updateRiderRoute === 'function'"), isTrue);
      expect(activeOrderScreen.contains('optimizedGeometry = jsonEncode(coords);'), isTrue);
      expect(ola.contains('_putBounded(\n          _routeCache, cacheKey, route);'), isTrue);
    });

    test('OlaMapService.getDirections is still the only Directions endpoint used by the rider screen', () {
      expect('OlaMapService.getDirections'.allMatches(activeOrderScreen).length, greaterThanOrEqualTo(1));
      expect(activeOrderScreen.contains('distanceMatrix'), isFalse);
    });

    test('Realtime / pricing / dispatch / edge-function surfaces are not introduced by this fix', () {
      for (final forbidden in [
        'calculate-order-pricing',
        'find_nearby_riders',
        'start-dispatch',
        'RealtimeManager.instance.subscribe(\n      channelName: \'active-order-2b',
      ]) {
        expect(ola.contains(forbidden), isFalse);
      }
      // The rider screen's single realtime subscription is still the same one-liner target.
      expect(activeOrderScreen.contains("channelName: 'active-order-\${widget.orderId}',"), isTrue);
    });

    test('pickup/drop coordinate resolution in fetchOptimizedRoute is unchanged', () {
      expect(
        activeOrderScreen.contains("if (status == 'accepted' || status == 'rider_arrived' || status == 'rider_at_pickup') {"),
        isTrue,
      );
      expect(
        activeOrderScreen.contains("} else if (status == 'ongoing' || status == 'picked_up' || status == 'rider_at_drop') {"),
        isTrue,
      );
    });
  });
}
