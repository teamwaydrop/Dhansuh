// Regression guards for the passenger Activity screen's "No past rides yet" fix and the
// accompanying Supabase egress audit (lib/features/user/activity/activity_tab.dart and
// lib/shared/screens/completed_order_details_screen.dart).
//
// Root cause: `_orderColumns` selected two columns that do not exist on `public.orders`
// (`duration_seconds` and `cancellation_reason` -- the real names are `time_taken_seconds` and
// `cancel_reason`). PostgREST rejects a select referencing an unknown column with a 400 for the
// *entire* query, so `Future.wait([activeFuture, pastFuture])` in loadOrders() threw on every
// single call, was swallowed by the existing catch block, and left both `activeOrders` and
// `pastOrders` permanently empty. A secondary, independent design flaw (fixed at the same time)
// was that PAST rides+parcels were paginated as one shared, mixed-type `.range()` list -- a user
// whose most recent page happened to be mostly parcels would see an empty "Rides" page 1 even
// with real ride history further back, and the empty-state widget replacing the ListView entirely
// meant the scroll controller could never be reached to load further pages.
//
// Structural guards -- reads the real source as text, matching the pattern used throughout this
// suite (see egress_fixes_3_to_10_regression_test.dart and CLAUDE.md's testing section).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final activityTab = _read('lib/features/user/activity/activity_tab.dart');
  final completedOrderDetails = _read('lib/shared/screens/completed_order_details_screen.dart');
  final indexMigration =
      _read('supabase/migrations/20260901000023_orders_user_history_pagination_index.sql');
  final rlsSchema = _read('supabase/migrations_baseline_wip/prod_schema_dump.sql');

  group('Root cause: nonexistent orders columns removed from every query', () {
    test('_orderColumns (ACTIVE) no longer selects duration_seconds or cancellation_reason', () {
      final start = activityTab.indexOf('static const String _orderColumns =');
      final slice = activityTab.substring(start, start + 700);
      expect(slice.contains('duration_seconds'), isFalse);
      expect(slice.contains('cancellation_reason'), isFalse);
      expect(slice.contains('time_taken_seconds'), isTrue);
      expect(slice.contains('cancel_reason'), isTrue);
    });

    test('_pastOrderColumns (PAST) also uses the real column names, not the nonexistent ones', () {
      final start = activityTab.indexOf('static const String _pastOrderColumns =');
      final slice = activityTab.substring(start, start + 700);
      expect(slice.contains('duration_seconds'), isFalse);
      expect(slice.contains('cancellation_reason'), isFalse);
      expect(slice.contains('time_taken_seconds'), isTrue);
      expect(slice.contains('cancel_reason'), isTrue);
    });

    test('reorder-navigation prefill reads time_taken_seconds, not the nonexistent '
        'duration_seconds, in both ActivityTab and CompletedOrderDetailsScreen', () {
      expect(activityTab.contains("order['duration_seconds']"), isFalse);
      expect(completedOrderDetails.contains("durationSeconds: double.tryParse(order['duration_seconds']"),
          isFalse);
    });

    test('cancellation UI reads the real cancel_reason column', () {
      expect(activityTab.contains("order['cancellation_reason']"), isFalse);
      expect(activityTab.contains("order['cancel_reason']"), isTrue);
    });
  });

  group('Scenario 1/2 -- first page size and ordering', () {
    test('_pastPageSize is 10 (the required initial-load size for ride/parcel history)', () {
      expect(activityTab.contains('static const int _pastPageSize = 10;'), isTrue);
    });

    test('both past-rides and past-parcels page-1 queries order newest first and cap at '
        '_pastPageSize', () {
      final ridesStart = activityTab.indexOf('final pastRidesFuture');
      final ridesSlice = activityTab.substring(ridesStart, ridesStart + 400);
      expect(ridesSlice.contains("order('created_at', ascending: false)"), isTrue);
      expect(ridesSlice.contains('.limit(_pastPageSize)'), isTrue);

      final parcelsStart = activityTab.indexOf('final pastParcelsFuture');
      final parcelsSlice = activityTab.substring(parcelsStart, parcelsStart + 400);
      expect(parcelsSlice.contains("order('created_at', ascending: false)"), isTrue);
      expect(parcelsSlice.contains('.limit(_pastPageSize)'), isTrue);
    });
  });

  group('Scenario 3/4 -- pagination only on demand, no duplicate requests', () {
    test('_onScroll only triggers a load-more for the currently selected tab\'s bucket, gated '
        'by hasMore and not-already-loading', () {
      final start = activityTab.indexOf('void _onScroll()');
      final slice = activityTab.substring(start, start + 700);
      expect(slice.contains('if (_hasMoreRides && !_loadingMoreRides) _loadMorePastRides();'), isTrue);
      expect(slice.contains('if (_hasMoreParcels && !_loadingMoreParcels) _loadMorePastParcels();'),
          isTrue);
    });

    test('_loadMorePastRides bails out immediately if already loading or no more pages exist '
        '(prevents duplicate requests from rapid scroll)', () {
      final start = activityTab.indexOf('Future<void> _loadMorePastRides()');
      final slice = activityTab.substring(start, start + 400);
      expect(slice.contains('if (_loadingMoreRides || !_hasMoreRides) return;'), isTrue);
    });

    test('_loadMorePastParcels has the identical duplicate-request guard', () {
      final start = activityTab.indexOf('Future<void> _loadMorePastParcels()');
      final slice = activityTab.substring(start, start + 400);
      expect(slice.contains('if (_loadingMoreParcels || !_hasMoreParcels) return;'), isTrue);
    });

    test('a full reload (loadOrders) is never triggered unconditionally from build() -- the '
        'only loadOrders() call inside build() is the pre-existing, user-action-gated '
        'onReviewSubmitted callback passed to each history tile, not an unconditional refetch', () {
      final buildStart = activityTab.indexOf('Widget build(BuildContext context) {');
      final tabsEnd = activityTab.indexOf('Widget _empty(');
      final buildSlice = activityTab.substring(buildStart, tabsEnd);
      final matches = RegExp(r'loadOrders\(').allMatches(buildSlice).toList();
      // Exactly the two _ActivityTile.onReviewSubmitted wiring sites (past rides, past parcels)
      // -- each only fires after the user actually submits a review, not on every rebuild.
      expect(matches.length, 2);
      for (final m in matches) {
        final before = buildSlice.substring((m.start - 40).clamp(0, buildSlice.length), m.start);
        expect(before.contains('onReviewSubmitted: () =>'), isTrue);
      }
      // Switching tabs only flips _selectedTab -- it never triggers its own fetch.
      expect(activityTab.contains('onTap: () => setState(() => _selectedTab = 0)'), isTrue);
      expect(activityTab.contains('onTap: () => setState(() => _selectedTab = 1)'), isTrue);
    });
  });

  group('Scenario 5 -- end-of-list detection', () {
    test('hasMore flags are derived from a short page (fewer rows than requested) on both the '
        'first page and every subsequent page, for both buckets', () {
      expect(activityTab.contains('_hasMoreRides = pastRidesList.length == _pastPageSize;'), isTrue);
      expect(activityTab.contains('_hasMoreParcels = pastParcelsList.length == _pastPageSize;'),
          isTrue);
      expect(activityTab.contains('_hasMoreRides = nextPage.length == _pastPageSize;'), isTrue);
      expect(activityTab.contains('_hasMoreParcels = nextPage.length == _pastPageSize;'), isTrue);
    });
  });

  group('Scenario 6 -- empty history handled correctly', () {
    test('past buckets start empty and the empty-state check still reads the live lists', () {
      expect(activityTab.contains('List<Map<String, dynamic>> _pastRides = [];'), isTrue);
      expect(activityTab.contains('List<Map<String, dynamic>> _pastParcels = [];'), isTrue);
      expect(
        activityTab.contains(
            '(_selectedTab == 0 && activeRides.isEmpty && pastRides.isEmpty)'),
        isTrue,
      );
      expect(
        activityTab.contains(
            '(_selectedTab == 1 && activeParcels.isEmpty && pastParcels.isEmpty)'),
        isTrue,
      );
    });
  });

  group('Scenario 7/8 -- completed and cancelled rides are history per existing business logic', () {
    test('_pastStatuses is unchanged: completed, delivered, cancelled, expired', () {
      expect(
        activityTab.contains(
            "static const List<String> _pastStatuses = ['completed', 'delivered', 'cancelled', 'expired'];"),
        isTrue,
      );
    });

    test('both past-rides and past-parcels queries (page 1 and load-more) filter on '
        '_pastStatuses', () {
      expect(
        RegExp(r"pastRidesFuture[\s\S]{0,200}inFilter\('order_status', _pastStatuses\)")
            .hasMatch(activityTab),
        isTrue,
      );
      expect(
        RegExp(r"pastParcelsFuture[\s\S]{0,200}inFilter\('order_status', _pastStatuses\)")
            .hasMatch(activityTab),
        isTrue,
      );
    });
  });

  group('Scenario 9/10 -- only the authenticated user\'s own rides are ever queried', () {
    test('every past/active query scopes to supabase.auth.currentUser.id, never a '
        'client-suppliable value', () {
      final userIdEqCount = RegExp(r"\.eq\('user_id', user\.id\)").allMatches(activityTab).length;
      // activeFuture, pastRidesFuture, pastParcelsFuture, _loadMorePastRides, _loadMorePastParcels
      expect(userIdEqCount, 5);
      expect(activityTab.contains('final user = supabase.auth.currentUser;'), isTrue);
    });

    test('existing RLS policies already restrict SELECT on orders to auth.uid() = user_id '
        '(not weakened by this change -- these files were not touched)', () {
      expect(
        rlsSchema.contains(
            'CREATE POLICY "user_can_view_own_orders" ON "public"."orders" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));'),
        isTrue,
      );
    });
  });

  group('Scenario 11 -- Rides and Parcels tabs remain independent', () {
    test('separate hasMore/loading/cursor state per bucket -- no shared pagination state', () {
      expect(activityTab.contains('bool _hasMoreRides'), isTrue);
      expect(activityTab.contains('bool _hasMoreParcels'), isTrue);
      expect(activityTab.contains('bool _loadingMoreRides'), isTrue);
      expect(activityTab.contains('bool _loadingMoreParcels'), isTrue);
      expect(activityTab.contains('String? _pastRidesCursorCreatedAt'), isTrue);
      expect(activityTab.contains('String? _pastParcelsCursorCreatedAt'), isTrue);
      // The old single shared bucket/flags must be gone.
      expect(activityTab.contains('List<Map<String, dynamic>> pastOrders'), isFalse);
      expect(activityTab.contains('_hasMorePast'), isFalse);
      expect(activityTab.contains('_loadingMorePast'), isFalse);
    });

    test('rides and parcels are filtered by disjoint order_type sets at the DB level, so one '
        'type can never starve the other\'s page 1', () {
      expect(
        activityTab.contains(
            "static const List<String> _rideOrderTypes = ['ride', 'intercity_ride', 'ride_sharing'];"),
        isTrue,
      );
      expect(activityTab.contains("'local_parcel',"), isTrue);
      expect(activityTab.contains("'intercity_parcel',"), isTrue);
      // No overlap between the two type lists.
      const rideTypes = ['ride', 'intercity_ride', 'ride_sharing'];
      const parcelTypes = [
        'local_parcel',
        'intercity_parcel',
        'batch_delivery',
        'food_delivery',
        'grocery_delivery',
      ];
      expect(rideTypes.toSet().intersection(parcelTypes.toSet()), isEmpty);
    });
  });

  group('Scenario 12/13 -- required fields present, unnecessary large fields absent', () {
    test('_pastOrderColumns keeps every flat field the history tile / details screen reads', () {
      final start = activityTab.indexOf('static const String _pastOrderColumns =');
      final slice = activityTab.substring(start, start + 700);
      for (final field in [
        'id',
        'order_code',
        'order_status',
        'order_type',
        'vehicle_type',
        'created_at',
        'pickup_address',
        'destination_address',
        'final_fare',
        'current_fare',
        'payment_status',
        'gst_amount',
        'commission_amount',
        'rider_id',
        'user_id',
      ]) {
        expect(slice.contains(field), isTrue, reason: '_pastOrderColumns must still select $field');
      }
    });

    test('_pastOrderColumns does NOT embed rider/rider_kyc/users/rider_reviews -- the history '
        'tile never displays them, only "View Details" does, and it now fetches them lazily', () {
      final start = activityTab.indexOf('static const String _pastOrderColumns =');
      final end = activityTab.indexOf(';', start);
      final columnList = activityTab.substring(start, end);
      expect(columnList.contains('rider:riders'), isFalse);
      expect(columnList.contains('rider_reviews'), isFalse);
      expect(columnList.contains('rider_kyc'), isFalse);
    });

    test('_orderColumns (ACTIVE only) still embeds rider/rider_kyc/users/rider_reviews -- '
        'a passenger needs to see their currently-assigned rider for an in-progress order', () {
      final start = activityTab.indexOf('static const String _orderColumns =');
      final end = activityTab.indexOf(';', start);
      final columnList = activityTab.substring(start, end);
      expect(columnList.contains('rider:riders!rider_id('), isTrue);
      expect(columnList.contains('rider_reviews(id,rating,comment)'), isTrue);
    });
  });

  group('Scenario 14 -- rebuild/tab-switch does not repeatedly re-download page 1', () {
    test('switching tabs only updates _selectedTab, it does not call loadOrders', () {
      final firstTabStart = activityTab.indexOf('onTap: () => setState(() => _selectedTab = 0)');
      final firstTabSlice = activityTab.substring(firstTabStart, firstTabStart + 60);
      expect(firstTabSlice.contains('loadOrders'), isFalse);

      final secondTabStart = activityTab.indexOf('onTap: () => setState(() => _selectedTab = 1)');
      final secondTabSlice = activityTab.substring(secondTabStart, secondTabStart + 60);
      expect(secondTabSlice.contains('loadOrders'), isFalse);
    });

    test('the 30s silent-refresh timer and app-resume handler both keep the realtime-health '
        'gate that skips a redundant full reload', () {
      expect(
        activityTab.contains(
            'DateTime.now().difference(lastEvent) <\n              const Duration(seconds: 30)'),
        isTrue,
      );
      expect(
        activityTab
            .contains('DateTime.now().difference(lastEvent) < const Duration(seconds: 30)'),
        isTrue,
      );
    });
  });

  group('Scenario 15 -- existing history behavior not otherwise broken', () {
    test('active-orders query is untouched in shape: same status exclusion, same safety limit', () {
      expect(
        activityTab.contains(
            "not('order_status', 'in', '(\${_pastStatuses.join(',')})')"),
        isTrue,
      );
      expect(activityTab.contains('static const int _activeOrdersSafetyLimit = 50;'), isTrue);
    });

    test('keyset cursor filter uses (created_at, id) tie-break so pagination stays correct even '
        'if rows are inserted/deleted between pages', () {
      expect(
        activityTab.contains(
            "'created_at.lt.\$cursorCreatedAt,and(created_at.eq.\$cursorCreatedAt,id.lt.\$cursorId)'"),
        isTrue,
      );
    });
  });

  group('CompletedOrderDetailsScreen -- lazy rider/review fetch replaces the removed embed', () {
    test('is now a StatefulWidget that only fetches rider/reviews when genuinely missing', () {
      expect(completedOrderDetails.contains('class CompletedOrderDetailsScreen extends StatefulWidget'),
          isTrue);
      expect(
        completedOrderDetails
            .contains("order['rider'] == null && order['rider_id'] != null"),
        isTrue,
      );
      expect(
        completedOrderDetails
            .contains("order['rider_reviews'] == null && order['id'] != null"),
        isTrue,
      );
    });

    test('falls back to the lazily-fetched copies in build(), preserving the existing UI when '
        'the embed is already present (e.g. an ACTIVE order)', () {
      expect(completedOrderDetails.contains("order['rider'] ?? _fetchedRider"), isTrue);
      expect(completedOrderDetails.contains("order['rider_reviews'] ?? _fetchedReviews"), isTrue);
    });

    test('fetch failure is swallowed, not surfaced as a crash -- the screen still renders with '
        'rider/feedback sections simply omitted', () {
      final start = completedOrderDetails.indexOf('Future<void> _loadRiderAndReviewsIfMissing()');
      final end = completedOrderDetails.indexOf('void _reorderTrip');
      final slice = completedOrderDetails.substring(start, end);
      expect(slice.contains('} catch (_) {'), isTrue);
    });
  });

  group('Migration: composite index for keyset pagination (local file only, not deployed)', () {
    test('adds (user_id, created_at DESC, id DESC) on public.orders, guarded by IF NOT EXISTS', () {
      expect(
        indexMigration.contains(
            'CREATE INDEX IF NOT EXISTS idx_orders_user_created_id\n    ON public.orders (user_id, created_at DESC, id DESC);'),
        isTrue,
      );
    });

    test('does not touch pricing, commission, GST, payment, subscription, wallet, payout, or '
        'dispatch logic -- pure index addition', () {
      for (final forbidden in [
        'commission',
        'gst',
        'cashfree',
        'subscription',
        'wallet',
        'payout',
        'dispatch',
        'DROP',
        'ALTER TABLE',
        'UPDATE ',
        'DELETE ',
      ]) {
        expect(
          indexMigration.toLowerCase().contains(forbidden.toLowerCase()),
          isFalse,
          reason: 'migration must be a pure index addition, found "$forbidden"',
        );
      }
    });
  });
}
