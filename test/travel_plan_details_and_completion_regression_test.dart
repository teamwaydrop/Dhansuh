// Structural regression guards for the post-real-device-testing fixes:
//  * Travel Plan Info shows the declared Via route (item 3)
//  * "EXPECTED EARNING" removed from Travel Plan Info (item 4)
//  * a completed intercity trip's travel plan actually leaves the traveller's Home (item 5) --
//    the client- and server-side plan-completion writes must cover 'fully_booked' plans and key
//    off the plan's own id (route_id), not the order's pickup/destination city.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final details = _read('lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart');
  final activeOrder = _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');
  final updateOrderStatus = _read('supabase/functions/update-order-status/index.ts');
  final homeTab = _read('lib/features/rider/home/rider_home_tab.dart');

  group('Item 3 -- Travel Plan Info shows the declared Via route', () {
    test('_buildRouteTimeline + _declaredRouteWaypoints exist and are rendered in the info sheet', () {
      expect(details.contains('Widget _buildRouteTimeline()'), isTrue);
      expect(details.contains('List<Map<String, dynamic>> _declaredRouteWaypoints()'), isTrue);
      // wired into the same sheet that shows FROM CITY / TO CITY.
      final sheet = details.substring(details.indexOf("_buildDetailRow('FROM CITY'"));
      expect(sheet.contains('_buildRouteTimeline(),'), isTrue);
    });

    test('the route is read from selected_route_meta.waypoints (the saved metadata), preserving order', () {
      final fn = details.substring(
        details.indexOf('List<Map<String, dynamic>> _declaredRouteWaypoints()'),
        details.indexOf('List<Map<String, dynamic>> _declaredRouteWaypoints()') + 1200,
      );
      expect(fn.contains("widget.plan['selected_route_meta']"), isTrue);
      expect(fn.contains("meta['waypoints']"), isTrue);
      expect(fn.contains(".sort((a, b) =>"), isTrue); // defensive order preservation
      expect(fn.contains("(a['order'] as num?)"), isTrue);
    });

    test('old plans without Via metadata do not crash: null-safe, returns empty, renders nothing', () {
      final fn = details.substring(
        details.indexOf('List<Map<String, dynamic>> _declaredRouteWaypoints()'),
        details.indexOf('Widget _buildRouteTimeline()') + 400,
      );
      expect(fn.contains('if (rawMeta == null) return const [];'), isTrue);
      expect(fn.contains('} catch (_) {'), isTrue);
      expect(fn.contains('if (wps.length < 2) return const SizedBox.shrink();'), isTrue);
    });

    test('the timeline shows labels, not raw JSON / coordinates', () {
      final fn = details.substring(
        details.indexOf('Widget _buildRouteTimeline()'),
        details.indexOf('Widget _buildRouteTimeline()') + 2500,
      );
      expect(fn.contains("wps[i]['label']"), isTrue);
      expect(fn.contains("wps[i]['lat']"), isFalse, reason: 'must not print coordinates');
      expect(fn.contains("jsonEncode"), isFalse);
      expect(fn.contains("'ROUTE'"), isTrue);
    });
  });

  group('Item 4 -- "EXPECTED EARNING" removed from Travel Plan Info', () {
    test('the EXPECTED EARNING stat badge and its label/amount are gone from the info sheet', () {
      expect(details.contains("'EXPECTED EARNING'"), isFalse);
      expect(details.contains('expectedEarning > 0 ? expectedEarning.toStringAsFixed(0)'), isFalse);
    });

    test('STATUS and BOOKED badges remain and the row no longer uses 3-way spaceBetween', () {
      final sheet = details.substring(details.indexOf("_buildStatBadge('STATUS'"));
      expect(sheet.contains("_buildStatBadge('STATUS', statusStr"), isTrue);
      expect(sheet.contains("_buildStatBadge('BOOKED', '\$bookedCount / \$totalSlots'"), isTrue);
    });

    test('the underlying earnings computations elsewhere are untouched (bookedCount loop stays)', () {
      // The matches loop still computes bookedCount / readyToStartCount (only the *display* of
      // expectedEarning was removed).
      expect(details.contains('bookedCount++;'), isTrue);
      expect(details.contains('readyToStartCount++;'), isTrue);
    });
  });

  group('Item 5 -- completed intercity trip removes the plan from Home', () {
    test('Home still lists plans by status IN (active, fully_booked) -- unchanged', () {
      expect(homeTab.contains("inFilter('status', ['active', 'fully_booked'])"), isTrue);
    });

    test('client _deleteMatchingTravelPlan covers fully_booked and keys off the plan route_id', () {
      final fn = activeOrder.substring(
        activeOrder.indexOf('Future<void> _deleteMatchingTravelPlan() async {'),
        activeOrder.indexOf('Future<void> _deleteMatchingTravelPlan() async {') + 3500,
      );
      // no longer restricted to status == 'active'
      expect(fn.contains(".eq('status', 'active')"), isFalse);
      expect(fn.contains(".inFilter('status', ['active', 'fully_booked'])"), isTrue);
      // resolves the plan via intercity_requests.route_id (Via passengers board mid-route, so the
      // order's pickup_city != the plan's pickup_city and a city match would silently miss).
      expect(fn.contains('_intercityRouteId'), isTrue);
      expect(fn.contains("from('intercity_requests')"), isTrue);
      expect(fn.contains(".eq('id', routeId)"), isTrue);
      // multi-seat plans stay until the last passenger trip ends.
      expect(fn.contains('another passenger trip is still active'), isTrue);
    });

    test('server update-order-status plan-completion covers fully_booked and keys off route_id', () {
      final block = updateOrderStatus.substring(
        updateOrderStatus.indexOf('UPDATE TRAVEL PLANS STATUS ON COMPLETED INTERCITY'),
        updateOrderStatus.indexOf('SYNC THE LINKED intercity_requests NEGOTIATION ROW'),
      );
      expect(block.contains('.eq("status", "active")'), isFalse);
      expect(block.contains('.in("status", ["active", "fully_booked"])'), isTrue);
      expect(block.contains('from("intercity_requests")'), isTrue);
      expect(block.contains('.in("id", routeIds)'), isTrue);
    });
  });
}
