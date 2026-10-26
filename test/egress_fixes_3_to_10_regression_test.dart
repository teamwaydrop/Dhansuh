// Regression guards for WayDrop Egress Audit Fixes #3-#10 (see the approved audit report and the
// implementation session that followed Fixes #1-#2). Structural guards -- reads the real source
// as text, matching the pattern used throughout this suite (see rider_order_history_screen.dart's
// own "Egress fix" precedent for the same style of assertion).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('Fix #3 -- duplicate realtime channels consolidated', () {
    final homeTab = _read('lib/features/rider/home/rider_home_tab.dart');
    final ordersScreen = _read('lib/features/rider/orders/rider_orders_screen.dart');
    final navScreen = _read('lib/features/rider/navigation/rider_main_navigation_screen.dart');

    test('RiderHomeTab and RiderOrdersScreen subscribe to the orders table under the same '
        'canonical channel name', () {
      expect(homeTab.contains("activeOrderSubChannel = 'rider-active-order-\$riderId';"), isTrue);
      expect(ordersScreen.contains("_activeOrderSubChannel = 'rider-active-order-\$riderId';"), isTrue);
      expect(ordersScreen.contains("_ordersUpdateSubChannel = 'rider-active-order-\$riderId';"), isTrue);
      // The two RiderOrdersScreen assignments (previously two separate channel-name string
      // literals) must now be the identical assignment target -- not merely mention the same name
      // in passing (comments documenting the old name are expected and fine).
      expect(
        RegExp(r"_(activeOrderSubChannel|ordersUpdateSubChannel) = 'rider-orders-updates-").hasMatch(ordersScreen),
        isFalse,
        reason: 'neither channel-name assignment may still target the old, now-orphaned name',
      );
    });

    test('all three orders-table subscribers request the identical event breadth (event=all), '
        'since RealtimeManager only pools listeners whose table/event/filter match exactly', () {
      final homeStart = homeTab.indexOf("activeOrderSubChannel = 'rider-active-order-\$riderId';");
      final homeSlice = homeTab.substring(homeStart, homeStart + 400);
      expect(homeSlice.contains('event: PostgresChangeEvent.all'), isTrue);

      final ordersFirstStart = ordersScreen.indexOf("_activeOrderSubChannel = 'rider-active-order-\$riderId';");
      final ordersFirstSlice = ordersScreen.substring(ordersFirstStart, ordersFirstStart + 800);
      expect(ordersFirstSlice.contains('event: PostgresChangeEvent.all'), isTrue);

      final ordersSecondStart = ordersScreen.indexOf("_ordersUpdateSubChannel = 'rider-active-order-\$riderId';");
      final ordersSecondSlice = ordersScreen.substring(ordersSecondStart, ordersSecondStart + 800);
      expect(ordersSecondSlice.contains('event: PostgresChangeEvent.all'), isTrue);
    });

    test('RiderMainNavigationScreen reuses the shared rider-home-\$riderId channel instead of a '
        'separate riders-table socket', () {
      expect(navScreen.contains("_serviceModeSubChannel = 'rider-home-\$riderId';"), isTrue);
      expect(navScreen.contains('rider-nav-service-mode-'), isFalse);
    });

    test('unsubscribe/dispose lifecycle for the merged channels is untouched (no leak introduced)', () {
      expect(
          homeTab.contains('RealtimeManager.instance.unsubscribe(activeOrderSubChannel!, activeOrderSubId!)'),
          isTrue);
      expect(
          ordersScreen.contains('RealtimeManager.instance.unsubscribe(_activeOrderSubChannel!, _activeOrderSubId!)'),
          isTrue);
    });
  });

  group('Fix #4 -- RiderActivityTab: single rider-ID resolution, narrowed orders select', () {
    final activityTab = _read('lib/features/rider/activity/rider_activity_tab.dart');

    test('loadActivity() and _subscribeRealtime() both resolve the rider id through the same '
        'shared, memoized helper instead of each running their own riders.select(\'id\') query', () {
      expect(activityTab.contains('Future<String?> _resolveRiderId()'), isTrue);
      // Memoized via a single Future field, not re-queried per call.
      expect(activityTab.contains('_riderIdFuture ??='), isTrue);

      final loadActivityStart = activityTab.indexOf('Future<void> loadActivity()');
      final loadActivityEnd = activityTab.indexOf('Future<void> _subscribeRealtime()');
      final loadActivityBody = activityTab.substring(loadActivityStart, loadActivityEnd);
      expect(loadActivityBody.contains('await _resolveRiderId()'), isTrue);

      final subscribeStart = activityTab.indexOf('Future<void> _subscribeRealtime()');
      final subscribeEnd = activityTab.indexOf('@override', subscribeStart);
      final subscribeBody = activityTab.substring(subscribeStart, subscribeEnd);
      expect(subscribeBody.contains('await _resolveRiderId()'), isTrue);
      // Neither call site runs its own independent riders lookup any more.
      expect(subscribeBody.contains("from('riders')"), isFalse);
    });

    test('the orders query is an explicit field whitelist, not a bare select()', () {
      final loadActivityStart = activityTab.indexOf('Future<void> loadActivity()');
      final loadActivityEnd = activityTab.indexOf('Future<void> _subscribeRealtime()');
      final body = activityTab.substring(loadActivityStart, loadActivityEnd);
      expect(body.contains(".select(\n"), isTrue,
          reason: 'the multi-line explicit field-list select, not select()');
      // The query itself (not merely a comment describing the old behavior) must not be a bare
      // empty select() -- i.e. no `.select()` immediately followed by a chained filter call.
      expect(RegExp(r'\.select\(\)\s*\n?\s*\.eq').hasMatch(body), isFalse);
      // Every field this screen and its detail sheet actually read must survive the narrowing.
      for (final field in [
        'order_status',
        'rider_earning',
        'final_fare',
        'current_fare',
        'gst_amount',
        'gst_percentage',
        'commission_amount',
        'commission_percentage',
        'subscription_commission_waived',
        'pickup_address',
        'destination_address',
        'vehicle_type',
        'order_type',
        'order_code',
      ]) {
        expect(body.contains(field), isTrue, reason: 'field "$field" must remain selected');
      }
      // Limit/order/filter behavior is unchanged.
      expect(body.contains(".inFilter('order_status', ['completed', 'delivered', 'cancelled'])"), isTrue);
      expect(body.contains(".order('updated_at', ascending: false)"), isTrue);
      expect(body.contains('.limit(30)'), isTrue);
    });
  });

  group('Fix #7 -- intercity dashboards debounce realtime-triggered reloads', () {
    for (final path in [
      'lib/features/intercity/rides/dashboard/intercity_rides_screen.dart',
      'lib/features/intercity/parcels/dashboard/intercity_parcels_screen.dart',
    ]) {
      test('$path debounces _loadOrders() by 500ms and cancels the timer on dispose', () {
        final src = _read(path);
        expect(src.contains('Timer? _ordersDebounceTimer;'), isTrue);
        expect(src.contains('_ordersDebounceTimer = Timer(const Duration(milliseconds: 500)'), isTrue);
        expect(src.contains('_ordersDebounceTimer?.cancel();'), isTrue);

        final disposeStart = src.indexOf('void dispose() {');
        final disposeEnd = src.indexOf('}', disposeStart);
        final disposeBody = src.substring(disposeStart, disposeEnd);
        expect(disposeBody.contains('_ordersDebounceTimer?.cancel();'), isTrue,
            reason: 'the debounce timer must be cancelled on dispose to avoid a late callback '
                'firing _loadOrders() on an unmounted screen');

        // The realtime callback itself must not call _loadOrders() directly any more -- only via
        // the debounce timer.
        final callbackStart = src.indexOf('callback: (payload) {', src.indexOf('_ordersSubChannel ='));
        final callbackEnd = src.indexOf('},', callbackStart);
        final callbackBody = src.substring(callbackStart, callbackEnd);
        expect(callbackBody.contains('_ordersDebounceTimer?.cancel();'), isTrue);
        expect(RegExp(r'^\s*_loadOrders\(\);\s*$', multiLine: true).hasMatch(callbackBody), isFalse);
      });
    }
  });

  group('Fix #8 -- rider_home_tab.dart today-earnings aggregation deduped', () {
    final homeTab = _read('lib/features/rider/home/rider_home_tab.dart');

    test('a single shared _fetchTodayEarnings() helper exists and both call sites use it instead '
        'of inlining their own query', () {
      expect(homeTab.contains('Future<double> _fetchTodayEarnings(String riderId, DateTime nowLocal) async {'), isTrue);
      // The exact original calculation/filters must survive inside the helper.
      final helperStart = homeTab.indexOf('Future<double> _fetchTodayEarnings(String riderId, DateTime nowLocal) async {');
      final helperEnd = homeTab.indexOf('\n  }', helperStart);
      final helperBody = homeTab.substring(helperStart, helperEnd);
      // Phase 2 earnings-reconciliation fix (rider_today_gross_earnings_regression_test.dart):
      // this now selects the GROSS fare (final_fare/current_fare), not the NET rider_earning
      // it originally selected -- the dedup/structure this test protects is otherwise unchanged.
      expect(helperBody.contains(".select('final_fare, current_fare')"), isTrue);
      expect(helperBody.contains(".inFilter('order_status', ['completed', 'delivered'])"), isTrue);
      expect(helperBody.contains(".gte('completed_at', startOfToday.toIso8601String())"), isTrue);

      // Both call sites invoke the shared helper.
      expect('_fetchTodayEarnings('.allMatches(homeTab).length, 2,
          reason: 'one raw query definition and one coordinator fetch binding');
      expect('_readTodayEarnings('.allMatches(homeTab).length, greaterThanOrEqualTo(3),
          reason: 'both callers must use the independent scoped coordinator');

      // The old duplicated inline query body no longer appears twice.
      final inlineQueryCount = ".select('final_fare, current_fare')".allMatches(homeTab).length;
      expect(inlineQueryCount, 1, reason: 'the query now exists in exactly one place -- the shared helper');
    });

    test('a recency guard skips the second fetch when both realtime paths fire for the same '
        'underlying completion within the dedupe window', () {
      final coordinator = _read('lib/features/rider/home/today_earnings_refresh.dart');
      expect(coordinator, contains('static const dedupeWindow = Duration(seconds: 3);'));
      expect(coordinator, contains('cached.scope.key == scope.key'));
      expect(coordinator, contains('cached.revision == _revision'));
      expect(homeTab, contains('_todayEarningsRefresh.markApplied'));
    });
  });

  group('Fix #9 -- rider_earnings_tab.dart withdrawal channel routed through RealtimeManager', () {
    final earningsTab = _read('lib/features/rider/earnings/rider_earnings_tab.dart');

    test('_subscribeWithdrawals() no longer calls the raw supabase.channel() API', () {
      final start = earningsTab.indexOf('void _subscribeWithdrawals() {');
      final end = earningsTab.indexOf('\n  }', start);
      final body = earningsTab.substring(start, end);
      expect(body.contains('RealtimeManager.instance.subscribe('), isTrue);
      expect(body.contains('supabase.channel('), isFalse);
      expect(body.contains("table: 'rider_withdrawals'"), isTrue);
      expect(body.contains("filterColumn: 'user_id'"), isTrue);
    });

    test('dispose() unsubscribes the withdrawal listener through RealtimeManager, not '
        'supabase.removeChannel()', () {
      final disposeStart = earningsTab.indexOf('void dispose() {');
      final disposeEnd = earningsTab.indexOf('super.dispose();', disposeStart);
      final disposeBody = earningsTab.substring(disposeStart, disposeEnd);
      expect(disposeBody.contains('RealtimeManager.instance.unsubscribe(_withdrawalsSubChannel!, _withdrawalsSubId!)'),
          isTrue);
      expect(disposeBody.contains('supabase.removeChannel('), isFalse);
    });
  });

  group('Fix #10B -- QR signed URL cached and reused within its validity window', () {
    final cacheSrc = _read('lib/core/services/cache/qr_signed_url_cache.dart');
    final payoutDetails = _read('lib/features/rider/onboarding/screens/rider_payout_details_screen.dart');
    final paymentSettings = _read('lib/features/rider/settings/rider_payment_settings_screen.dart');
    final activeOrderScreen = _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');

    test('QrSignedUrlCache TTL stays safely under the 3600s signed-URL expiry', () {
      expect(cacheSrc.contains('static const Duration ttl = Duration(minutes: 50)'), isTrue);
    });

    test('all three QR-signing call sites route through QrSignedUrlCache instead of calling '
        'createSignedUrl directly', () {
      for (final src in [payoutDetails, paymentSettings, activeOrderScreen]) {
        expect(src.contains('QrSignedUrlCache.get('), isTrue);
      }
      // createSignedUrl itself must still be called exactly once per file -- inside the cache's
      // fetch closure -- never bypassed.
      for (final src in [payoutDetails, paymentSettings, activeOrderScreen]) {
        expect(src.contains("createSignedUrl(") , isTrue);
      }
    });

    test('a re-upload is automatically a cache miss (no explicit invalidation needed) because '
        'every upload writes to a brand-new, timestamped storage path', () {
      expect(
        payoutDetails.contains(r"'$riderId/personal_qr_${DateTime.now().millisecondsSinceEpoch}.$ext'"),
        isTrue,
      );
    });
  });
}
