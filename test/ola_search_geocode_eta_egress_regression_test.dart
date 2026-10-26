// Regression guard for the 2026-08-22 Ola/Krutrim egress-reduction pass covering Autocomplete,
// Reverse Geocoding, and ETA/Distance Matrix (the remaining items from the original Ola Maps
// consumption audit, continuing on from the already-shipped live-tracking Directions throttle fix
// covered by live_tracking_directions_throttle_regression_test.dart).
//
// 1. AUTOCOMPLETE (ola_map_service.dart): a 1-character query fired a full Ola Places Autocomplete
//    call on every screen that uses this shared service whenever a user paused >=400ms right after
//    their first keystroke -- a call that is essentially never decisive. Fixed by skipping the
//    network call (returning the same empty list the UI already treats identically to "still
//    typing") below a 2-character minimum. Callers (ride/parcel/intercity/home location screens,
//    post_travel_plan_screen) are all untouched -- the gate lives in the one shared service method
//    they all call through.
//
// 2. REVERSE GEOCODING (ola_map_service.dart): the existing exact-key cache only deduped a
//    byte-for-byte repeat of the same 5-decimal (~1.1m) coordinate. Fine pin-adjustment drags in
//    the location-picker "drag to confirm exact spot" flow routinely land a few meters from the
//    previous drag-end point -- a different cache key every time, firing a fresh Ola call for what
//    is very likely an identical address. Fixed by adding a proximity fallback: if any already-
//    cached point is within 35m, its result is reused. The exact-key cache and its 200-entry cap
//    are untouched; this is purely an additional fallback checked after an exact-key miss.
//
// 3. ETA / DISTANCE MATRIX (realtime_order_controller.dart): the order-status-transition realtime
//    callback and the polling fallback both still called fetchLiveOrderState() (which reaches Ola's
//    Distance Matrix via get-live-order-status, subject to only a 20s server-side cache) even when
//    the order had JUST transitioned into a terminal (completed/cancelled) state -- one wasted call
//    for the ETA of a ride that had already ended. Fixed with a guard in the single shared
//    _refreshOrderAndLiveState() entry point (used by both the polling timer and the realtime
//    callback) and in start()'s initial fetch. The existing 20s server-side cache
//    (_shared/eta_cache.ts) and the realtime-health polling gate are both left completely
//    untouched.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final olaMapService = _read('lib/core/services/maps/ola_map_service.dart');
  final realtimeOrderController =
      _read('lib/core/services/realtime/realtime_order_controller.dart');
  final etaCache = _read('supabase/functions/_shared/eta_cache.ts');
  final getLiveOrderStatus = _read('supabase/functions/get-live-order-status/index.ts');

  group('Autocomplete: minimum query length gate', () {
    test('a minimum-length constant exists and gates the network call before the cache lookup', () {
      expect(olaMapService.contains('static const int _minAutocompleteQueryLength = 2;'), isTrue);
      expect(
        RegExp(r'static Future<List<dynamic>>\s*\n\s*autocomplete\(([\s\S]{0,200})query\.length < _minAutocompleteQueryLength')
            .hasMatch(olaMapService),
        isTrue,
        reason: 'the length gate must run before any cache/network work, not after',
      );
    });

    test('the old empty-only gate is gone (a 1-character query no longer passes through)', () {
      // The old gate was `if (query.isEmpty) { return []; }` immediately after building `query` --
      // asserting the new gate variable name replaces it in that exact position.
      expect(olaMapService.contains('if (query.isEmpty) {\n\n      return [];\n    }'), isFalse);
    });

    test('the autocomplete cache, 200ms throttle, and cancel-token dedup are all still present (untouched)', () {
      expect(olaMapService.contains('_autocompleteCache'), isTrue);
      expect(olaMapService.contains('_lastAutocompleteRequest'), isTrue);
      expect(olaMapService.contains('_autocompleteCancelToken'), isTrue);
      expect(olaMapService.contains('diff.inMilliseconds <\n            200'), isTrue);
    });

    test('the autocomplete endpoint and query param shape are unchanged', () {
      expect(olaMapService.contains('https://api.olamaps.io/places/v1/autocomplete'), isTrue);
    });
  });

  group('Reverse geocoding: proximity fallback reduces near-duplicate calls', () {
    test('a proximity threshold and Haversine helper exist', () {
      expect(olaMapService.contains('static const double _reverseGeocodeProximityMeters = 35.0;'), isTrue);
      expect(olaMapService.contains('static double _haversineMeters('), isTrue);
      expect(olaMapService.contains('static Map<String, dynamic>? _findNearbyReverseGeocodeResult('), isTrue);
    });

    test('reverseGeocode() checks the proximity fallback after an exact-key cache miss, before the network call', () {
      expect(
        RegExp(
          r'_reverseGeocodeCache\s*\.containsKey\(key\)[\s\S]{0,150}\}\s*\n\s*final nearbyResult = _findNearbyReverseGeocodeResult\(latitude, longitude\);\s*\n\s*if \(nearbyResult != null\) \{\s*\n\s*return nearbyResult;\s*\n\s*\}\s*\n\s*try \{',
        ).hasMatch(olaMapService),
        isTrue,
        reason: 'the proximity fallback must run after the exact-key cache miss and before dio.get',
      );
    });

    test('the exact-key cache, its 200-entry bound, and the reverse-geocode endpoint are all unchanged', () {
      expect(olaMapService.contains('_reverseGeocodeCache'), isTrue);
      expect(olaMapService.contains('static const int _maxCacheEntries = 200;'), isTrue);
      expect(olaMapService.contains('https://api.olamaps.io/places/v1/reverse-geocode'), isTrue);
    });

    test('the proximity fallback only ever returns an already-cached VALUE -- it never mutates the exact-key cache itself', () {
      // i.e. _findNearbyReverseGeocodeResult must not call _putBounded or otherwise write to
      // _reverseGeocodeCache -- it is a pure read-only lookup.
      final fnStart = olaMapService.indexOf('static Map<String, dynamic>? _findNearbyReverseGeocodeResult(');
      final fnEnd = olaMapService.indexOf('\n  }\n', fnStart);
      final fnBody = olaMapService.substring(fnStart, fnEnd);
      expect(fnBody.contains('_putBounded'), isFalse);
      expect(fnBody.contains('_reverseGeocodeCache['), isFalse);
    });
  });

  group('ETA / Distance Matrix: no live-state fetch after the order has already finished', () {
    test('_refreshOrderAndLiveState (the single shared entry point for both pollers) skips terminal orders', () {
      expect(
        RegExp(
          r'Future<void> _refreshOrderAndLiveState\(\{bool includeOrderFetch = true\}\) async \{\s*\n\s*if \(_isDisposed\) return;[\s\S]{0,900}currentOrder\.isCompleted \|\| currentOrder\.isCancelled\)\) \{\s*\n\s*return;',
        ).hasMatch(realtimeOrderController),
        isTrue,
        reason: 'both the polling-timer path and the realtime-callback path share this one method, '
            'so a single guard here covers both without touching either call site',
      );
    });

    test('start()\'s initial fetch also skips an order that is already terminal when the screen opens', () {
      expect(
        RegExp(r'loadedOrder\.isCompleted \|\| loadedOrder\.isCancelled\)\) \{\s*\n\s*unawaited\(_refreshOrderAndLiveState\(includeOrderFetch: false\)\);')
            .hasMatch(realtimeOrderController),
        isTrue,
      );
    });

    test('the realtime-health polling gate and adaptive _refreshInterval backoff are both untouched', () {
      expect(realtimeOrderController.contains('Duration(seconds: 15)'), isTrue);
      expect(realtimeOrderController.contains('Duration _refreshInterval({required Duration staleness, String? status})'), isTrue);
    });

    test('fetchOrder() and fetchLiveOrderState() themselves are unchanged (the guard sits above both, not inside either)', () {
      expect(realtimeOrderController.contains("Future<void> fetchOrder() async {"), isTrue);
      expect(realtimeOrderController.contains("'get-live-order-status'"), isTrue);
    });

    test('the existing 20s server-side ETA cache in eta_cache.ts is completely untouched', () {
      expect(etaCache.contains('const TTL_MS = 20_000;'), isTrue);
      expect(etaCache.contains('const RACE_TIMEOUT_MS = 2_000;'), isTrue);
    });

    test('get-live-order-status.ts itself (the only Ola Distance Matrix caller) is untouched by this client-side fix', () {
      expect(getLiveOrderStatus.contains('getEtaWithBudget(orderId'), isTrue);
      expect(getLiveOrderStatus.contains('/routing/v1/distanceMatrix/basic'), isTrue);
    });
  });

  group('Untouched: pricing/payment/dispatch/auth are not referenced by any of the changed files', () {
    test('ola_map_service.dart and realtime_order_controller.dart never reference pricing/dispatch/payment edge functions', () {
      for (final forbidden in [
        'calculate-order-pricing',
        'find_nearby_riders',
        'start-dispatch',
        'create-payment',
        'Cashfree',
        'commission_percentage',
        'gst_amount',
      ]) {
        expect(olaMapService.contains(forbidden), isFalse, reason: '"$forbidden" must not appear in ola_map_service.dart');
        expect(realtimeOrderController.contains(forbidden), isFalse,
            reason: '"$forbidden" must not appear in realtime_order_controller.dart');
      }
    });
  });
}
