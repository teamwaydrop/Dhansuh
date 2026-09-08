// Regression guard for the travel_plan_details_screen.dart orders-realtime narrowing (performance
// pass), UPDATED for the later egress-audit pass that migrated all 3 of this screen's realtime
// subscriptions (_subscribeMatches/_subscribeRequests/_subscribeOrders) from raw supabase.channel()
// + PostgresChangeFilter objects to RealtimeManager.instance.subscribe(filterColumn:/filterValue:).
//
// ORIGINAL CONTEXT: _subscribeOrders() previously subscribed to EVERY `orders` UPDATE
// platform-wide with no filter, relying entirely on its callback's local `matches` lookup to
// discard everything not relevant to this rider/plan. It was narrowed to a rider_id-scoped filter
// so the server stops delivering irrelevant events in the first place.
//
// EGRESS-AUDIT CONTEXT (this update): all 3 subscriptions moved to RealtimeManager so each pools
// with an identical rider-wide channel other screens already hold (matches -> shares
// 'rider-assignments-$riderId'; requests -> shares 'rider-intercity-requests-$riderId' with
// IntercityBookingsScreen; orders -> shares 'rider-active-order-$riderId'). RealtimeManager only
// ever builds an `eq` filter internally (see realtime_manager.dart's _createSupabaseChannel), so
// the eq-filter guarantee this file originally asserted is now structural rather than a per-call
// literal. RealtimeManager also requires an EXACT event match to pool a listener onto an existing
// channel, so _subscribeOrders() widened from UPDATE-only to `all` to match the channel it now
// shares -- documented as safe in-source because orders are always created with rider_id still
// null and are never deleted, so INSERT/DELETE can never actually fire for this filter in
// practice. The callback's own local filtering logic (`matches.any(...)`) is unchanged.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('TravelPlanDetailsScreen -- all 3 realtime subscriptions are rider-scoped via '
      'RealtimeManager', () {
    final source = _read(
      'lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart',
    );
    // Starts at the doc comment immediately above the function (not the signature itself) so the
    // in-source safety justification for widening the event to `all` is included in the slice.
    final ordersStart = source.indexOf("// Egress fix: pools with the rider-wide 'rider-active-order-\$riderId' channel");
    final ordersEnd = source.indexOf('Future<void> _acceptIntercityRequest(');
    final ordersBody = source.substring(ordersStart, ordersEnd);

    final matchesStart = source.indexOf('void _subscribeMatches() {');
    final matchesBody = source.substring(matchesStart, source.indexOf('void _subscribeRequests()'));

    final requestsStart = source.indexOf('void _subscribeRequests() {');
    final requestsBody = source.substring(requestsStart, source.indexOf('void _subscribeOrders()'));

    test('_subscribeOrders() subscribes through RealtimeManager, scoped to rider_id', () {
      expect(ordersBody.contains('RealtimeManager.instance.subscribe('), isTrue);
      expect(ordersBody.contains("table: 'orders'"), isTrue);
      expect(ordersBody.contains("filterColumn: 'rider_id'"), isTrue);
      expect(ordersBody.contains("final riderId = widget.plan['rider_id'].toString();"), isTrue);
      expect(ordersBody.contains('filterValue: riderId'), isTrue);
    });

    test('the filter is an eq filter by construction -- RealtimeManager never builds any other '
        'filter type, matching the sibling _subscribeMatches/_subscribeRequests shape', () {
      final managerSrc = _read('lib/core/services/realtime/realtime_manager.dart');
      expect(managerSrc.contains('type: PostgresChangeFilterType.eq'), isTrue);
      // No call site (this screen's 3 subscriptions included) constructs its own
      // PostgresChangeFilter any more -- that responsibility moved entirely into RealtimeManager.
      expect(ordersBody.contains('PostgresChangeFilter('), isFalse);
      expect(matchesBody.contains('PostgresChangeFilter('), isFalse);
      expect(requestsBody.contains('PostgresChangeFilter('), isFalse);
    });

    test('the existing local callback filtering (matches.any lookup) is unchanged', () {
      expect(ordersBody.contains("matches.any((m) => m['id']?.toString() == orderId)"), isTrue,
          reason: 'the server-side filter narrows delivery; the callback must still guard locally');
    });

    test('_subscribeOrders() now requests event=all (not update-only) -- required to pool onto '
        'the shared rider-active-order-\$riderId channel; documented as safe because INSERT/DELETE '
        'can never actually fire for a rider_id-filtered orders stream', () {
      expect(ordersBody.contains('event: PostgresChangeEvent.all'), isTrue);
      expect(ordersBody.contains("table: 'orders'"), isTrue);
      expect(
        ordersBody.contains('INSERT/DELETE can never actually fire for this filter'),
        isTrue,
        reason: 'the safety argument for widening the event must stay documented in-source',
      );
    });

    test('sibling subscriptions (_subscribeMatches/_subscribeRequests) use the identical '
        'RealtimeManager pattern and remain correctly scoped', () {
      expect(matchesBody.contains("table: 'rider_assignments'"), isTrue);
      expect(matchesBody.contains("filterColumn: 'rider_id'"), isTrue);

      expect(requestsBody.contains("table: 'intercity_requests'"), isTrue);
      expect(requestsBody.contains("filterColumn: 'traveller_id'"), isTrue);
    });

    test('each of the 3 subscriptions is unsubscribed via RealtimeManager in dispose (no leaked '
        'listener)', () {
      final disposeStart = source.indexOf('void dispose() {');
      final disposeEnd = source.indexOf('super.dispose();', disposeStart);
      final disposeBody = source.substring(disposeStart, disposeEnd);
      expect(
        disposeBody.contains('RealtimeManager.instance.unsubscribe(_matchesSubChannel!, _matchesSubId!)'),
        isTrue,
      );
      expect(
        disposeBody.contains('RealtimeManager.instance.unsubscribe(_requestsSubChannel!, _requestsSubId!)'),
        isTrue,
      );
      expect(
        disposeBody.contains('RealtimeManager.instance.unsubscribe(_ordersSubChannel!, _ordersSubId!)'),
        isTrue,
      );
    });
  });
}
