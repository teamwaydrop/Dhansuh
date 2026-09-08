// Regression guard for local city ride requests missing/mislabelling the two distances a Drop
// Partner needs before accepting: driver's current location -> pickup, and pickup -> destination.
//
// ROOT CAUSE: the incoming-request card (IncomingOrderCard, shown pre-accept via
// rider_home_tab.dart's `_showIncomingOrder`) read `widget.assignment['rider_distance_km']` for
// the "driver -> pickup" chip. That key never existed on the `rider_assignments` row this widget
// is actually built from (that table's real column is `distance_km` -- `rider_distance_km` only
// exists on the separate `order_assignment_logs` table, written by start-dispatch/index.ts but
// never read by this card). The condition was therefore always false and the driver->pickup chip
// silently never rendered -- the card effectively only ever showed the trip (pickup->drop)
// distance, ambiguously labelled "Ride: X km" with no indication of which leg it measured.
//
// FIX: read the correct existing field (`rider_assignments.distance_km`, already computed by
// find_nearby_riders' haversine calculation at dispatch time -- no new Maps/routing API call), and
// clearly label both chips ("You → Pickup" vs "Pickup → Drop") instead of one ambiguous "Distance"/
// "Ride" label. The pickup->drop distance continues to read straight from the order's own
// pricing-canonical `orders.distance_km`/`distance_meters`, never recalculated client-side.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final card = _read('lib/features/rider/orders/widgets/incoming_order_card.dart');
  final startDispatch = _read('supabase/functions/start-dispatch/index.ts');
  final findNearbyRidersRpc =
      _read('supabase/migrations/20260729000001_find_nearby_riders_security_definer_and_authz.sql');

  group('Test 12 -- Driver -> Pickup distance', () {
    test('the driver->pickup chip reads the field that actually exists on rider_assignments (distance_km), not the nonexistent rider_distance_km', () {
      expect(card.contains("widget.assignment['rider_distance_km']"), isFalse);
      expect(card.contains("widget.assignment['distance_km']"), isTrue);
    });

    test('the chip is clearly labelled "You → Pickup", not an ambiguous bare "X km away"/"Distance"', () {
      expect(card.contains('You → Pickup:'), isTrue);
    });

    test('rider_assignments.distance_km really is populated by start-dispatch at assignment-creation time (no new API call needed in the widget)', () {
      expect(startDispatch.contains('distance_km: rider.distance_km'), isTrue);
    });

    test('the underlying distance is a documented straight-line (haversine) calculation, honestly labelled -- never claimed to be road distance', () {
      expect(findNearbyRidersRpc.contains('6371 * acos('), isTrue);
      expect(card.contains('road distance'), isFalse);
    });
  });

  group('Test 13 -- Pickup -> Drop trip distance', () {
    test('the trip-distance chip is clearly labelled "Pickup → Drop", not an ambiguous "Ride: X km"', () {
      expect(card.contains('Pickup → Drop:'), isTrue);
      expect(card.contains("label: 'Ride: "), isFalse);
    });

    test('the trip distance is read from the order\'s own canonical distance_km/distance_meters field, never recalculated in Flutter', () {
      final start = card.indexOf("if (order!['distance_km'] != null || order!['distance_meters'] != null)");
      expect(start, greaterThan(-1));
      final section = card.substring(start, start + 400);
      expect(section.contains("order!['distance_km']"), isTrue);
      expect(section.contains("order!['distance_meters']"), isTrue);
      // No haversine/routing computation appears in this specific chip's expression.
      expect(section.contains('acos('), isFalse);
    });
  });

  group('Test 14 -- exact pickup/destination addresses remain visible pre-accept', () {
    test('the pickup capsule shows the full, exact pickup_address (not a truncated area name only)', () {
      final start = card.indexOf("order!['pickup_address'] ?? 'Pickup Address'");
      expect(start, greaterThan(-1));
    });

    test('the destination side now also shows the full, exact destination_address (previously only a short area-name summary)', () {
      final start = card.indexOf("_getAreaName(order!['destination_address'])");
      expect(start, greaterThan(-1));
      final section = card.substring(start, start + 1200);
      expect(section.contains("order!['destination_address'].toString()"), isTrue);
    });
  });

  group('Test 15 -- no extra distance/routing API call on every card rebuild', () {
    test('IncomingOrderCard build() does not call any HTTP/RPC/Maps distance function -- both values are read straight off already-fetched maps', () {
      final buildStart = card.indexOf('Widget build(BuildContext context)');
      expect(buildStart, greaterThan(-1));
      final buildSection = card.substring(buildStart);
      expect(buildSection.contains('supabase.functions.invoke'), isFalse);
      expect(buildSection.contains('OlaMapService'), isFalse);
      expect(buildSection.contains('.rpc('), isFalse);
    });
  });

  group('Test 16 -- existing local ride accept/minimize flow remains intact', () {
    test('Accept/Minimize callbacks and their wiring are unchanged in shape', () {
      expect(card.contains('required this.onAccepted'), isTrue);
      expect(card.contains('required this.onMinimized'), isTrue);
      expect(card.contains('processing ? null : minimizeOrder'), isTrue);
    });

    test('Minimize never calls the reject-order edge function -- it only closes the popup, the assignment stays sent', () {
      final start = card.indexOf('void minimizeOrder()');
      expect(start, greaterThan(-1));
      final section = card.substring(start, start + 300);
      expect(section.contains('reject-order'), isFalse);
      expect(section.contains('widget.onMinimized()'), isTrue);
    });

    test('no Reject button/label remains on the incoming order popup', () {
      expect(card.contains("'reject-order'"), isFalse);
      expect(card.contains('rejectOrder'), isFalse);
    });

    // UPDATE (2026-08-08, "production-grade incoming ride experience"): rider_home_tab.dart no
    // longer shows IncomingOrderCard as a blocking popup at all -- _showIncomingOrder is now
    // sound/haptic + badge only (see incoming_order_minimize_and_intercity_accept_regression_test.
    // dart's Issue 2 group). The card's own field-correctness fixes above still stand as a widget
    // in the tree, but the review/accept surface is now rider_orders_screen.dart's own inline
    // per-item card (which reads the same rider_assignments.distance_km field, asserted in the
    // fetchSearchingOrders group below), not this widget file.
    test('rider_home_tab no longer constructs IncomingOrderCard from _showIncomingOrder', () {
      final riderHomeTab = _read('lib/features/rider/home/rider_home_tab.dart');
      expect(riderHomeTab.contains('IncomingOrderCard('), isFalse);
    });

    test('the Orders tab list item (the real review/accept surface now) also reads distance_km, not the nonexistent rider_distance_km', () {
      final ordersScreen = _read('lib/features/rider/orders/rider_orders_screen.dart');
      expect(ordersScreen.contains("assignment['distance_km']"), isTrue);
    });

    test('the realtime assignment payload the Orders tab list is built from carries every rider_assignments column (REPLICA IDENTITY FULL), so distance_km is always present on INSERT', () {
      final schema = _read('supabase/migrations/20260529000000_baseline_foundational_schema.sql');
      expect(schema.contains('ALTER TABLE ONLY "public"."rider_assignments" REPLICA IDENTITY FULL;'), isTrue);
    });
  });

  group('Test 18 -- fare/GST/commission/payment code untouched by this fix', () {
    test('no fare/GST/commission/wallet/Cashfree/QR keyword appears near the edited distance-chip block', () {
      final start = card.indexOf('// Issue 4 fix: two clearly-labeled distances');
      expect(start, greaterThan(-1));
      final end = card.indexOf('const SizedBox(height: 20)', start);
      final section = card.substring(start, end > start ? end : start + 2000).toLowerCase();
      for (final term in ['gst', 'commission', 'wallet', 'cashfree', 'personal_upi', 'fare_payment_method']) {
        expect(section.contains(term), isFalse, reason: 'unexpected pricing/payment term near distance chips: $term');
      }
    });
  });
}
