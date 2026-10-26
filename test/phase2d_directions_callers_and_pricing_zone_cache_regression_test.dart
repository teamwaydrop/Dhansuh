// Regression guard for Phase 10E — Phase 2D.
//
// PART A: the remaining Ola Directions `.timeout(8s)` "zombie request" callers. Phase 2B fixed
// rider_active_order_screen.dart by passing the 8s budget INTO getDirections (which then actually
// CANCELS the in-flight Dio request) instead of wrapping the call in `.timeout()` (which only
// stopped the await while the HTTP request kept running against the shared 15s Dio ceiling). 2D
// applies the same fix to the callers where an audit proved it safe:
//   * ride_tracking_screen.dart      — periodic _onRiderLocationUpdate; overlap possible via the
//   * parcel_tracking_screen.dart      50m movement trigger (floored at _minMovementGapSeconds=12s)
//   * intercity_tracking_screen.dart   firing inside the 8–15s zombie window.
//   * travel_plan_details_screen.dart — one-shot initState fetch; migrated because null and
//     timeout are already handled identically, and it cancels a request that can outlive the
//     widget.
// DEFERRED (NOT migrated): intercity_searching_screen.dart — its catch block draws a straight-line
// fallback specifically on TimeoutException, and a strong `_lastRouteRiderId` guard already makes
// its zombie window harmless (nothing re-requests the same rider's route). Migrating would require
// restructuring its failure handling, which is out of scope.
//
// PART B: calculate-order-pricing's pricing_zones read is now served by an isolate-scoped 30s
// cache (_shared/pricing_zones_cache.ts), a direct sibling of the existing pricing_config cache.
// It caches ONLY immutable zone-config rows — never a fare, never any per-user/per-order value.
//
// Structural (source-as-text) guard — this repo's established convention.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final ola = _read('lib/core/services/maps/ola_map_service.dart');

  final rideTracking =
      _read('lib/features/local_rides/tracking/screens/ride_tracking_screen.dart');
  final parcelTracking =
      _read('lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart');
  final intercityTracking =
      _read('lib/features/intercity/shared/screens/intercity_tracking_screen.dart');
  final travelPlanDetails =
      _read('lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart');
  final intercitySearching =
      _read('lib/features/intercity/shared/screens/intercity_searching_screen.dart');

  group('Part A — migrated Directions callers pass timeout: INTO getDirections (no wrapper)', () {
    final migrated = {
      'ride_tracking_screen.dart': rideTracking,
      'parcel_tracking_screen.dart': parcelTracking,
      'intercity_tracking_screen.dart': intercityTracking,
      'travel_plan_details_screen.dart': travelPlanDetails,
    };

    migrated.forEach((name, src) {
      test('$name: getDirections is called with `timeout: const Duration(seconds: 8)` and the '
          '`.timeout(...)` wrapper is gone', () {
        expect(
          RegExp(r'OlaMapService\.getDirections\([\s\S]{0,600}timeout: const Duration\(seconds: 8\),\s*\);')
              .hasMatch(src),
          isTrue,
          reason: '$name must pass the 8s budget into getDirections',
        );
        expect(
          src.contains(').timeout(const Duration(seconds: 8))'),
          isFalse,
          reason: '$name must not keep the zombie-window `.timeout()` wrapper around getDirections',
        );
        // Budget unchanged — this is a lifecycle fix, not a tuning change.
        expect(src.contains('const Duration(seconds: 8)'), isTrue);
      });
    });

    test('the three live-tracking screens keep their in-flight guard + queued-forced-retry intact', () {
      for (final src in [rideTracking, parcelTracking, intercityTracking]) {
        expect(src.contains('bool _fetchingRiderRoute = false;'), isTrue);
        expect(src.contains('if (_fetchingRiderRoute) {'), isTrue);
        expect(src.contains('if (forceFetch) _pendingForceRouteFetch = true;'), isTrue);
        expect(
          RegExp(r'finally \{\s*_fetchingRiderRoute = false;[\s\S]{0,800}if \(_pendingForceRouteFetch && mounted\) \{\s*_onRiderLocationUpdate\(\);')
              .hasMatch(src),
          isTrue,
          reason: 'the finally block must still clear the guard and retry a queued forced fetch',
        );
        // Route geometry format + JS push unchanged.
        expect(src.contains("updateRiderRoute === 'function'"), isTrue);
        expect(src.contains("route.polylinePoints.map((pt) => [pt['lng']!, pt['lat']!]).toList()"), isTrue);
      }
    });

    test('travel_plan_details_screen: null/timeout still handled identically (the else branch just '
        'clears _loading — no behaviour change, no fallback lost)', () {
      expect(
        RegExp(r'if \(route != null && route\.polylinePoints\.isNotEmpty\) \{[\s\S]{0,600}'
                r'\} else \{[\s\S]{0,200}_loading = false;')
            .hasMatch(travelPlanDetails),
        isTrue,
      );
      // One-shot fetch from initState — no periodic timer / re-trigger to guard.
      expect(
        RegExp(r'void initState\(\) \{[\s\S]{0,200}_fetchRoute\(\);').hasMatch(travelPlanDetails),
        isTrue,
      );
    });
  });

  group('Part A — intercity_searching_screen.dart is DEFERRED, not migrated', () {
    test('it still uses the `.timeout(8s)` wrapper (documented deferral)', () {
      expect(
        intercitySearching.contains(').timeout(const Duration(seconds: 8))'),
        isTrue,
        reason: 'this caller is intentionally NOT migrated in Phase 2D — see file header',
      );
      expect(
        intercitySearching.contains('timeout: const Duration(seconds: 8)'),
        isFalse,
      );
    });

    test('its TimeoutException-triggered straight-line fallback is intact (the reason it was '
        'deferred)', () {
      expect(
        RegExp(r'\} catch \(e\) \{[\s\S]{0,300}final fallback = \[\s*\[riderLng, riderLat\],\s*\[pickupLng, pickupLat\]\s*\];')
            .hasMatch(intercitySearching),
        isTrue,
      );
      // And its stronger dedup guard (route fetched at most once per accepted rider) is intact —
      // this is what makes its zombie window harmless without the 2D fix.
      expect(intercitySearching.contains('if (_lastRouteRiderId == acceptedRiderId) return;'), isTrue);
      expect(intercitySearching.contains('if (order == null || _fetchingRoute) return;'), isTrue);
    });
  });

  group('getDirections() itself is NOT touched by Phase 2D (still the Phase 2B implementation)', () {
    test('the opt-in timeout param + per-call CancelToken + cleanup are exactly as Phase 2B left them', () {
      expect(ola.contains('Duration? timeout,'), isTrue);
      expect(ola.contains('final cancelToken = CancelToken();'), isTrue);
      expect(
        RegExp(r'if \(timeout != null\) \{\s*timeoutTimer = Timer\(timeout, \(\) \{\s*if \(!cancelToken\.isCancelled\) \{\s*cancelToken\.cancel\(')
            .hasMatch(ola),
        isTrue,
      );
      expect(RegExp(r'finally \{\s*timeoutTimer\?\.cancel\(\);').hasMatch(ola), isTrue);
      expect(ola.contains('if (CancelToken.isCancel(e)) {'), isTrue);
      // No second `Duration? timeout` param crept onto another method.
      expect('Duration? timeout,'.allMatches(ola).length, 1);
    });
  });

  group('Part B — pricing_zones cache: sibling of pricing_config cache, config-only, bounded', () {
    final zonesCache = _read('supabase/functions/_shared/pricing_zones_cache.ts');
    final configCache = _read('supabase/functions/_shared/pricing_config_cache.ts');
    final pricingIndex = _read('supabase/functions/calculate-order-pricing/index.ts');
    final pricingCalc = _read('supabase/functions/calculate-order-pricing/pricing-calculations.ts');

    test('the cache exists and exports getActivePricingZones', () {
      expect(zonesCache.contains('export async function getActivePricingZones('), isTrue);
    });

    test('TTL is explicit, bounded, and identical to the pricing_config cache (30s)', () {
      expect(zonesCache.contains('const TTL_MS = 30_000;'), isTrue);
      expect(configCache.contains('const TTL_MS = 30_000;'), isTrue);
      expect(
        RegExp(r'if \(cached && now - cachedAt < TTL_MS\) \{\s*return cached;').hasMatch(zonesCache),
        isTrue,
      );
    });

    test('isolate-scoped module state + in-flight de-dup + cold start clears it', () {
      expect(zonesCache.contains('let cached: PricingZone[] | null = null;'), isTrue);
      expect(zonesCache.contains('let cachedAt = 0;'), isTrue);
      expect(zonesCache.contains('let inFlight: Promise<PricingZone[] | null> | null = null;'), isTrue);
      expect(zonesCache.contains('if (inFlight) {\n    return inFlight;'), isTrue);
    });

    test('a fetch error returns null WITHOUT serving stale/empty data (mirrors resolveZone\'s old '
        '`if (zoneError) return null`)', () {
      expect(
        RegExp(r'if \(error\) \{\s*console\.error\("Error fetching pricing zones:", error\);\s*return null;')
            .hasMatch(zonesCache),
        isTrue,
      );
    });

    test('it caches ONLY immutable zone-config columns — no fare, no per-user, no per-order data', () {
      expect(
        zonesCache.contains(
          'const SELECT =\n  "id, zone_code, zone_name, zone_type, cities, center_lat, center_lng, radius_km, zone_shape";',
        ),
        isTrue,
      );
      expect(zonesCache.contains('.from("pricing_zones")'), isTrue);
      // Never touches user/order/fare tables or a computed result.
      for (final forbidden in ['final_fare', 'base_fare', 'auth.getUser', '.from("users")', '.from("orders")', 'buildPricingResponse', 'calculateFare']) {
        expect(zonesCache.contains(forbidden), isFalse,
            reason: 'the zone cache must never touch "$forbidden"');
      }
    });

    test('calculate-order-pricing now reads zones through the cache in BOTH call sites, and no '
        'longer issues an inline pricing_zones query', () {
      expect(pricingIndex.contains('import { getActivePricingZones } from "../_shared/pricing_zones_cache.ts";'), isTrue);
      expect('getActivePricingZones(supabase)'.allMatches(pricingIndex).length, 3,
          reason: 'the eager normal-path read, resolver default, and fallback retry all use the cache');
      expect(pricingIndex.contains('.from("pricing_zones")'), isFalse,
          reason: 'the inline pricing_zones SELECT (both shapes) must be gone from index.ts');
      // resolveZone still returns null on a null cache result — same short-circuit as before.
      expect(
        RegExp(r'const activeZones = await \(activeZonesPromise \?\? getActivePricingZones\(supabase\)\);\s*\n\s*if \(activeZones === null\) \{\s*\n\s*return null;')
            .hasMatch(pricingIndex),
        isTrue,
      );
    });

    test('zone MATCHING logic (geofence / city / address) is unchanged — cache only changed the '
        'fetch', () {
      expect(pricingIndex.contains('Matched pricing zone via geofencing:'), isTrue);
      expect(pricingIndex.contains('Matched pricing zone via city name fallback:'), isTrue);
      expect(pricingIndex.contains('Matched pricing zone via address fallback:'), isTrue);
      expect(pricingIndex.contains('for (const zone of activeZones || [])'), isTrue);
    });

    test('fare formulas / rates / distance / tax / discount / boost math untouched', () {
      // pricing-calculations.ts (the pure math) is not referenced or modified by this phase.
      expect(pricingCalc.contains('export function calculateFare('), isTrue);
      expect(pricingCalc.contains('export function buildPricingResponse('), isTrue);
      expect(pricingIndex.contains('const { baseFare, extraData } = calculateFare(rules, rawDistance, weight_kg, weight_category);'), isTrue);
      expect(pricingIndex.contains('const result = buildPricingResponse('), isTrue);
      // The pricing_config (rate) cache is also untouched.
      expect(pricingIndex.contains(
        'const allConfigs = await (activeConfigsPromise ?? getActivePricingConfigs(supabase));',
      ), isTrue);
    });
  });
}
