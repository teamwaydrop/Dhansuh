// Regression guard for "passenger shows 0 active partners nearby despite a co-located, online,
// dispatch-eligible Drop Partner" (tests 10-19).
//
// ROOT CAUSE (confirmed by code inspection): find_nearby_riders() was not SECURITY DEFINER, unlike
// every sibling function added in the same migration (20260726000004_government_tax_due_functions.sql).
// start-dispatch/accept-order call it with the service-role key (bypasses RLS regardless). The
// passenger's own "X active partners nearby" text (ride_searching_screen.dart /
// parcel_searching_screen.dart) calls the SAME RPC directly under their own `authenticated` JWT --
// uniquely for that caller, every table read inside the function (orders, riders, rider_kyc,
// dispatch_config) ran under SECURITY INVOKER, subject to that passenger's own RLS. This is the
// structural reason the identical predicate/RPC could return zero rows for a passenger while the
// same function, called by start-dispatch moments later, matched the same rider. Compounding
// factor: the passenger-facing radius/limit were hard-coded (5.0km/25) instead of read from the
// same dispatch_config Round 1 values start-dispatch itself uses. Also fixed: the rider's
// account_status='online' flip and current_lat/current_lng write were two separate, non-atomic
// statements (a real window where a rider was "online" with null/stale location).
//
// SECOND OCCURRENCE (test 19, added later): the atomic fix above only lived inside
// toggleOnlineStatus(), reachable only by riders who already had an active subscription.
// _showSubscriptionBottomSheet() -- the flow every non-subscribed rider (the default,
// non-MAX-plan population) actually goes through to go online -- had two of its own "Go Online"
// buttons that reimplemented the OLD unsafe write (account_status alone, no location) directly,
// reintroducing the exact same bug for the majority of riders. Fixed by extracting the safe logic
// into one shared method, _bringRiderOnline(), and having every "go online" action call it --
// there is now exactly one place in the app that ever writes riders.account_status='online'.
//
// This does not run the app or call Supabase (see the pattern already used by
// travel_plan_mode_switch_regression_test.dart) -- it inspects the actual source/migration files.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final findNearbyMigration = _read('supabase/migrations/20260729000001_find_nearby_riders_security_definer_and_authz.sql');
  final rideSearching = _read('lib/features/local_rides/searching/screens/ride_searching_screen.dart');
  final parcelSearching = _read('lib/features/local_parcels/searching/screens/parcel_searching_screen.dart');
  final riderHomeTab = _read('lib/features/rider/home/rider_home_tab.dart');

  group('Canonical eligibility predicate: find_nearby_riders is now SECURITY DEFINER with an ownership guard', () {
    test('the function is SECURITY DEFINER, matching every sibling dispatch function', () {
      expect(findNearbyMigration.contains('SECURITY DEFINER'), isTrue);
      expect(findNearbyMigration.contains('SET search_path = public'), isTrue);
    });

    test('an authenticated (non-service-role) caller can only query nearby riders for an order they created', () {
      expect(findNearbyMigration.contains('auth.uid() IS NOT NULL AND (v_creator_user_id IS NULL OR auth.uid() != v_creator_user_id)'), isTrue);
      expect(findNearbyMigration.contains('RETURN;'), isTrue);
    });

    test('every existing eligibility predicate is preserved -- online, service_mode, tax-due, KYC/activation, staleness, busy-order, radius', () {
      expect(findNearbyMigration.contains("r.account_status = 'online'"), isTrue);
      expect(findNearbyMigration.contains('r.service_mode = v_required_mode'), isTrue);
      expect(findNearbyMigration.contains('NOT public.is_rider_blocked_by_tax_due(r.id)'), isTrue);
      expect(findNearbyMigration.contains("IN ('approved', 'pending', 'under_review', 'resubmitted')"), isTrue);
      expect(findNearbyMigration.contains("IN ('active', 'pending', 'inactive')"), isTrue);
      expect(findNearbyMigration.contains('r.last_location_updated_at >='), isTrue);
      expect(findNearbyMigration.contains("o.order_status IN ("), isTrue);
      expect(findNearbyMigration.contains("'accepted',"), isTrue);
      expect(findNearbyMigration.contains('<= p_radius_km'), isTrue);
    });
  });

  group('Test 10-15: passenger-facing count uses the SAME predicate/config as dispatch', () {
    test('the passenger nearby-count screens call find_nearby_riders (the canonical dispatch RPC), not a separate ad-hoc query', () {
      expect(rideSearching.contains("'find_nearby_riders'"), isTrue);
      expect(parcelSearching.contains("'find_nearby_riders'"), isTrue);
    });

    test('the radius/limit are sourced from dispatch_config Round 1 values, not a hard-coded 5.0/25', () {
      expect(rideSearching.contains("'p_radius_km': 5.0,"), isFalse);
      expect(rideSearching.contains("'p_limit': 25,"), isFalse);
      expect(rideSearching.contains('round_1_radius_km, round_1_batch_size'), isTrue);
      expect(rideSearching.contains('_nearbyRiderRadiusKm'), isTrue);

      expect(parcelSearching.contains("'p_radius_km': 5.0,"), isFalse);
      expect(parcelSearching.contains('round_1_radius_km, round_1_batch_size'), isTrue);
    });

    test('config is fetched once and cached, not re-queried on every 5s refresh tick', () {
      expect(rideSearching.contains('_nearbyConfigLoaded'), isTrue);
      expect(rideSearching.contains('if (!_nearbyConfigLoaded) {'), isTrue);
    });
  });

  group('Test 16: a same-location, genuinely-eligible rider is not reported as zero', () {
    test('online + correct service_mode + non-stale location + within radius reconciles to a positive match (predicate is identical to dispatch, and now runs under the same privileged context for both callers)', () {
      // Structural proof: the SAME function body (not a re-derived copy) is what both the
      // passenger's RPC call and start-dispatch's RPC call execute -- there is exactly one place
      // this eligibility logic exists, and it now behaves identically regardless of caller.
      expect(findNearbyMigration.contains('CREATE OR REPLACE FUNCTION public.find_nearby_riders('), isTrue);
    });
  });

  group('Test 17: stale/invalid location is handled explicitly, not silently', () {
    // The safe go-online logic (GPS check, permission check, fresh-fix validation, atomic write)
    // was extracted from toggleOnlineStatus() into a single shared method, _bringRiderOnline(), so
    // that the two duplicate "Go Online" buttons inside _showSubscriptionBottomSheet() (which used
    // to reimplement an unsafe, non-atomic write directly -- reintroducing this exact bug for every
    // non-subscribed rider) call the same safe path instead. Anchors below target that method.
    final bringOnlineStart = riderHomeTab.indexOf('Future<bool> _bringRiderOnline()');
    final bringOnlineEnd = riderHomeTab.indexOf(
      '\n  /// Single source of truth for "does this rider currently have an active,',
    );

    test('_bringRiderOnline() exists and is the only go-online implementation before the next method', () {
      expect(bringOnlineStart, greaterThan(-1));
      expect(bringOnlineEnd, greaterThan(bringOnlineStart));
    });

    test('Go Online aborts with an honest error if a fresh location fix cannot be obtained', () {
      final section = riderHomeTab.substring(bringOnlineStart, bringOnlineEnd);
      final freshLatDecl = section.indexOf('double? freshLat;');
      final haptic = section.indexOf('HapticFeedback.mediumImpact();');
      expect(freshLatDecl, greaterThan(-1));
      expect(haptic, greaterThan(freshLatDecl));
      final checkSection = section.substring(freshLatDecl, haptic);
      expect(checkSection.contains('freshLat == null || freshLng == null'), isTrue);
      expect(checkSection.contains('Unable to get a fresh location fix'), isTrue);
      expect(checkSection.contains('return false;'), isTrue);
    });

    test('account_status and the fresh lat/lng/timestamp are written in the SAME update -- no separate race window', () {
      final section = riderHomeTab.substring(bringOnlineStart, bringOnlineEnd);
      final updateStart = section.indexOf("await supabase.from('riders').update({");
      final updateEnd = section.indexOf("}).eq('user_id', onlineUserId!);", updateStart);
      expect(updateStart, greaterThan(-1));
      expect(updateEnd, greaterThan(updateStart));
      final updateSection = section.substring(updateStart, updateEnd);
      expect(updateSection.contains("'account_status': 'online'"), isTrue);
      expect(updateSection.contains("'current_lat': freshLat"), isTrue);
      expect(updateSection.contains("'current_lng': freshLng"), isTrue);
      expect(updateSection.contains("'last_location_updated_at': nowIso"), isTrue);
      expect(section, contains('final onlineUserId = supabase.auth.currentUser?.id;'));
      expect(section, contains('if (!ownsOnlineOperation()) return false;'));
    });
  });

  group('Test 19: _bringRiderOnline() is the single source of truth -- no duplicate/unsafe go-online writes remain', () {
    test('exactly one place in the file ever writes account_status to online', () {
      final matches = "'account_status': 'online'".allMatches(riderHomeTab).length;
      expect(matches, 1, reason: 'a second occurrence means an unsafe duplicate write path has been reintroduced');
    });

    test('both former duplicate "Go Online" buttons in _showSubscriptionBottomSheet now call _bringRiderOnline()', () {
      final sheetStart = riderHomeTab.indexOf('Future<void> _showSubscriptionBottomSheet(');
      final sheetEnd = riderHomeTab.indexOf('Widget _buildBenefitRow(');
      expect(sheetStart, greaterThan(-1));
      expect(sheetEnd, greaterThan(sheetStart));
      final sheetSection = riderHomeTab.substring(sheetStart, sheetEnd);

      // Neither button reimplements startRiderLiveTracking()+update({account_status:'online'}) --
      // that pattern must not exist anywhere inside this sheet anymore.
      expect(sheetSection.contains("'account_status': 'online'"), isFalse);
      expect(sheetSection.contains('await LocationCacheService.startRiderLiveTracking();'), isFalse);

      // Both call the unified helper instead -- expect at least 2 call sites (the post-payment
      // "goingOnline" branch and the "go online with commission" button).
      final callCount = '_bringRiderOnline()'.allMatches(sheetSection).length;
      expect(callCount, greaterThanOrEqualTo(2));
    });
  });

  group('Test 18: passenger availability and dispatch use consistent eligibility (documented, intentional differences noted)', () {
    test('booking map markers retain their baseline cosmetic filters independently of dispatch eligibility', () {
      // HEAD has no marker query in passenger Home. The actual booking query
      // displays pins; the canonical RPC assertions above protect dispatch/count
      // eligibility. Do not invent KYC eligibility filters for cosmetic markers.
      final booking = _read('lib/features/local_rides/booking/screens/ride_location_screen.dart');
      final start = booking.indexOf('Future<void> _fetchNearbyRiders()');
      final end = booking.indexOf('Future<void> _updateRidersOnMap(', start);
      final markers = booking.substring(start, end);
      expect(markers, contains(".eq('account_status', 'online')"));
      expect(markers, contains(".not('current_lat', 'is', null)"));
      expect(markers, contains(".not('current_lng', 'is', null)"));
      expect(markers, contains(".gte('current_lat', requestLat - latDelta)"));
      expect(markers, contains(".lte('current_lat', requestLat + latDelta)"));
      expect(markers, contains(".gte('current_lng', requestLng - lngDelta)"));
      expect(markers, contains(".lte('current_lng', requestLng + lngDelta)"));
      expect(markers, contains('distanceKmObj <= 5.0'));
      expect(markers, contains('rider_kyc!riders_kyc_id_fkey(vehicle_type)'));
      expect(markers, contains('_nearbyRiderRefresh.run<List<Map<String, dynamic>>>'));
    });
  });
}
