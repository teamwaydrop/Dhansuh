import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/core/services/network/poll_backoff.dart';

import 'package:waydrop/features/local_rides/searching/screens/ride_searching_screen.dart';
import 'package:waydrop/features/local_rides/tracking/screens/ride_tracking_screen.dart';
import 'package:waydrop/features/local_parcels/searching/screens/parcel_searching_screen.dart';
import 'package:waydrop/features/local_parcels/tracking/screens/parcel_tracking_screen.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_searching_screen.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_tracking_screen.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:waydrop/features/local_rides/booking/screens/ride_location_screen.dart';
import 'package:waydrop/features/local_parcels/booking/screens/parcel_details_screen.dart';
import 'package:waydrop/features/intercity/parcels/booking/intercity_details_screen.dart';
import 'package:waydrop/shared/screens/completed_order_details_screen.dart';
import 'package:waydrop/core/theme/responsive_layout.dart';
import 'package:waydrop/modules/support/screens/customer_support_screen.dart';
import 'package:waydrop/shared/helpers/insets.dart';


class ActivityTab extends StatefulWidget {
  const ActivityTab({super.key});

  @override
  State<ActivityTab> createState() => ActivityTabState();
}

class ActivityTabState extends State<ActivityTab> with WidgetsBindingObserver {
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> activeOrders = [];
  // Cached active-orders by-type split, recomputed only when activeOrders changes (not on every
  // build()) -- see _recomputeTypeSplits. _pastRides/_pastParcels below are populated directly
  // from their own per-type DB queries, not split from a shared list.
  List<Map<String, dynamic>> _activeRides = [];
  List<Map<String, dynamic>> _activeParcels = [];
  List<Map<String, dynamic>> _pastRides = [];
  List<Map<String, dynamic>> _pastParcels = [];
  bool loading = true;
  String? _activitySubId;
  String? _activityChannelName;
  Timer? _debounceTimer;
  Timer? _activitySilentRefreshTimer;
  // Timestamp of the last realtime delivery for this tab (orders channel). Used
  // to skip the redundant 30s silent refresh while realtime is healthy -- the
  // timer stays as the pure fallback when realtime is quiet or stale.
  DateTime? _lastRealtimeEventAt;
  int _selectedTab = 0; // 0 = Rides, 1 = Parcels

  // Egress fix: past orders (completed/delivered/cancelled/expired -- the bucket that actually
  // grows without bound over a user's lifetime) are paginated per-type (see _loadMorePastRides/
  // _loadMorePastParcels below) instead of pulled many-rows-at-once on every load. activeOrders is
  // left unpaginated -- a user realistically never has more than a handful of concurrent orders,
  // so it's fetched in full every time (capped at _activeOrdersSafetyLimit purely as an abuse/
  // edge-case guard, not a real UX limit) and is NOT touched by either _loadMorePast* function.
  // Every full reload (loadOrders(), triggered by initState, the 30s silent-refresh timer, resume,
  // and the realtime debounce) resets pagination back to page 1 for both past buckets -- correct,
  // since any of those firing means the accumulated "loaded more" pages are stale anyway.
  static const int _pastPageSize = 10;
  static const int _activeOrdersSafetyLimit = 50;

  // Keyset (cursor) pagination state, independent per bucket -- see _rideOrderTypes/
  // _parcelOrderTypes above for why these can no longer share a single cursor. The cursor is
  // the (created_at, id) of the last row of the most recently loaded page for that bucket;
  // `null` means "no page has loaded yet" (page 1 needs none) or "no rows exist for this
  // bucket" (nothing further to cursor from).
  bool _hasMoreRides = true;
  bool _hasMoreParcels = true;
  bool _loadingMoreRides = false;
  bool _loadingMoreParcels = false;
  String? _pastRidesCursorCreatedAt;
  String? _pastRidesCursorId;
  String? _pastParcelsCursorCreatedAt;
  String? _pastParcelsCursorId;
  final ScrollController _scrollController = ScrollController();

  // Egress fix: loadOrders() swallows its own errors internally (existing
  // try/catch/debugPrint, never rethrows), so recorded directly from inside its own
  // catch/success paths. Consulted by the 30s silent-refresh timer only -- initState,
  // resume, and the realtime debounce all call loadOrders() unconditionally (a user
  // action / foreground event should never be silently skipped), so this only slows
  // the passive background poll, never a user-visible refresh trigger.
  final PollBackoff _refreshBackoff = PollBackoff();

  @override
  // Lifecycle method called once when the stateful widget initialized for the first time
  void initState() {
    // Lifecycle method called once when the stateful widget initialized for the first time
    super.initState();
    // Register this widget state class to listen to application lifecycle updates (resumed, paused)
    WidgetsBinding.instance.addObserver(this);
    loadOrders(showLoading: true);
    _subscribeRealtime();
    _startSilentRefreshTimer();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (loading) return;
    if (_scrollController.position.pixels < _scrollController.position.maxScrollExtent - 300) {
      return;
    }
    // Only the currently-viewed tab's bucket loads more -- switching tabs never triggers a
    // fetch on its own (both buckets' page 1 are already loaded together by loadOrders()), and
    // scrolling one tab never touches the other tab's pagination state.
    if (_selectedTab == 0) {
      if (_hasMoreRides && !_loadingMoreRides) _loadMorePastRides();
    } else {
      if (_hasMoreParcels && !_loadingMoreParcels) _loadMorePastParcels();
    }
  }

  void _startSilentRefreshTimer() {
    _activitySilentRefreshTimer?.cancel();
    // Setup a timer instance for delayed execution or polling intervals
    _activitySilentRefreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (!mounted) return;
      // Realtime-health gate: realtime already refreshed orders within the
      // last period, so the heavy loadOrders() would be a duplicate. Falls
      // back to the full refresh when realtime is quiet or stale.
      final lastEvent = _lastRealtimeEventAt;
      if (lastEvent != null &&
          DateTime.now().difference(lastEvent) <
              const Duration(seconds: 30)) {
        return;
      }
      // Egress fix: skip this background refresh if recent attempts have been
      // failing (Supabase throttle/outage) -- doesn't affect initState/resume/
      // realtime-debounce calls to loadOrders(), only this passive timer.
      if (!_refreshBackoff.shouldAttempt()) return;
      loadOrders(showLoading: false);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // R16 perf fix: same realtime-health gate _startSilentRefreshTimer() already uses (see its
      // comment above) -- if realtime delivered an order update within the last 30s, that event's
      // own debounced loadOrders() call already refreshed this exact data, so a resume-triggered
      // reload here would just be a duplicate of the same 150-row, multi-join query. Falls back to
      // the unconditional reload (unchanged) whenever realtime is quiet or stale.
      final lastEvent = _lastRealtimeEventAt;
      if (lastEvent != null &&
          DateTime.now().difference(lastEvent) < const Duration(seconds: 30)) {
        return;
      }
      loadOrders(showLoading: false);
    }
  }

  @override
  // Lifecycle method called before the widget is removed permanently from the tree to clean resources
  void dispose() {
    // Unregister lifecycle observers to prevent callbacks when the widget is dead
    WidgetsBinding.instance.removeObserver(this);
    _debounceTimer?.cancel();
    _activitySilentRefreshTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    if (_activitySubId != null && _activityChannelName != null) {
      // Remove the real-time Postgres subscription to release memory resources.
      // Uses the channel name captured at subscribe time (not the current auth
      // user) so this still unsubscribes correctly even if the user has already
      // signed out by the time this widget is disposed.
      RealtimeManager.instance.unsubscribe(_activityChannelName!, _activitySubId!);
      _activitySubId = null;
      _activityChannelName = null;
    }
    // Lifecycle method called before the widget is removed permanently from the tree to clean resources
    super.dispose();
  }

  // Only splits ACTIVE orders now -- _pastRides/_pastParcels are fetched directly from their own
  // DB-filtered queries (see loadOrders()/_loadMorePastRides()/_loadMorePastParcels()) and never
  // need a client-side split.
  void _recomputeTypeSplits() {
    bool isParcelType(Map<String, dynamic> o) {
      final type = o['order_type']?.toString() ?? '';
      return type.contains('parcel') || type.contains('delivery');
    }

    _activeRides = activeOrders.where((o) => !isParcelType(o)).toList();
    _activeParcels = activeOrders.where(isParcelType).toList();
  }

  // Records the (created_at, id) of the last row of a freshly loaded past-orders page as that
  // bucket's next keyset cursor. A short page (fewer than _pastPageSize rows) means this was the
  // last page, so the cursor is left untouched (harmless -- _hasMore* already gates any further
  // fetch and the corresponding _loadMorePast* also bails out early without a cursor).
  void _updatePastCursor({required bool isRides, required List<Map<String, dynamic>> page}) {
    if (page.isEmpty) return;
    final last = page.last;
    final createdAt = last['created_at']?.toString();
    final id = last['id']?.toString();
    if (createdAt == null || id == null) return;
    if (isRides) {
      _pastRidesCursorCreatedAt = createdAt;
      _pastRidesCursorId = id;
    } else {
      _pastParcelsCursorCreatedAt = createdAt;
      _pastParcelsCursorId = id;
    }
  }

  // Column list for the ACTIVE query only. `orders` has no `duration_seconds` or
  // `cancellation_reason` column (the real names are `time_taken_seconds` and
  // `cancel_reason` -- see the other 6 screens that read them correctly); selecting
  // a nonexistent column makes PostgREST reject the *entire* select with a 400, which is
  // why this Future.wait([activeFuture, pastFuture]) call -- and therefore both Active AND
  // Past -- has been failing and silently swallowed by loadOrders()'s catch block. Fixed
  // here. Rider/rider_reviews stay embedded for ACTIVE only -- a passenger needs to see
  // their currently-assigned rider; PAST rows use _pastOrderColumns below instead, which
  // drops this embed since the history tile/card never displays it (only
  // CompletedOrderDetailsScreen does, and it now fetches it lazily on demand).
  static const String _orderColumns =
      'id,order_code,order_status,order_type,vehicle_type,created_at,completed_at,cancelled_at,pickup_address,destination_address,destination_city,pickup_lat,pickup_lng,destination_lat,destination_lng,distance_meters,time_taken_seconds,receiver_name,receiver_phone,parcel_type,weight_category,special_instructions,final_fare,current_fare,boost_amount,fare_payment_method,payment_mode,payment_status,cancel_reason,gst_amount,gst_percentage,commission_amount,commission_percentage,rider_earning,subscription_commission_waived,rider_id,user_id,rider:riders!rider_id(id,rating,rider_kyc!riders_kyc_id_fkey(full_name,vehicle_number,vehicle_type,rider_image),users!riders_user_id_fkey(full_name,phone,user_code)),rider_reviews(id,rating,comment)';

  // Egress fix: same flat columns as _orderColumns, minus the rider/rider_kyc/users/
  // rider_reviews embed -- a history row is never displayed with rider details inline, only
  // "View Details" (CompletedOrderDetailsScreen) needs them, and now fetches them itself for
  // just the one order actually opened instead of every row in every page ever loaded.
  static const String _pastOrderColumns =
      'id,order_code,order_status,order_type,vehicle_type,created_at,completed_at,cancelled_at,pickup_address,destination_address,destination_city,pickup_lat,pickup_lng,destination_lat,destination_lng,distance_meters,time_taken_seconds,receiver_name,receiver_phone,parcel_type,weight_category,special_instructions,final_fare,current_fare,boost_amount,fare_payment_method,payment_mode,payment_status,cancel_reason,gst_amount,gst_percentage,commission_amount,commission_percentage,rider_earning,subscription_commission_waived,rider_id,user_id';

  // 'expired' orders (abandoned searches the backend cron already gave up on -- see
  // expire_stale_searching_orders()) are a terminal state, not an active one -- excluding
  // them from "active" keeps them out of ACTIVE RIDES so they stop being permanently
  // relabeled back to "SEARCHING" by _ActiveOrderCard. Kept as a shared constant so the
  // active query's exclusion list and the past query's inclusion list can never drift
  // out of sync with each other.
  static const List<String> _pastStatuses = ['completed', 'delivered', 'cancelled', 'expired'];

  // Root-cause fix for cross-type starvation: the old design paginated ONE shared
  // rides+parcels list with a single `.range()` cursor, then split it client-side. A user
  // whose most recent N past orders happened to be mostly/all parcels would see an empty
  // "Rides" page 1 even with plenty of real ride history further back -- and since the empty
  // state replaces the ListView entirely (see build()), the scroll controller was never
  // attached, so they could never scroll to reach it. Filtering by order_type at the DB level
  // per bucket makes this impossible by construction: each bucket's page 1 reflects that
  // type's own true latest rows.
  static const List<String> _rideOrderTypes = ['ride', 'intercity_ride', 'ride_sharing'];
  static const List<String> _parcelOrderTypes = [
    'local_parcel',
    'intercity_parcel',
    'batch_delivery',
    'food_delivery',
    'grocery_delivery',
  ];

  /// Full reload: resets all three buckets (active, past rides, past parcels) to page 1. This
  /// is the entry point every existing trigger already calls (initState, the 30s silent-refresh
  /// timer, app resume, and the realtime debounce) -- none of those call sites change. Egress
  /// fix: activeOrders (status-unbounded, capped at _activeOrdersSafetyLimit as a pure abuse/
  /// edge-case guard since a user realistically never has that many concurrent orders) plus one
  /// page-1 keyset query per past bucket (_pastPageSize wide each, newest first) -- replacing the
  /// old single mixed-type `.range()` past query, which both starved whichever type wasn't in the
  /// most recent page and (before that) was failing outright on every call (see _orderColumns).
  Future<void> loadOrders({bool showLoading = false}) async {
    if (showLoading) {
      // Update the widget state to trigger a UI rebuild with the new variables
      if (mounted) setState(() => loading = true);
    }
    try {
      // Perform an asynchronous database operation using the Supabase client wrapper
      final user = supabase.auth.currentUser;
      if (user == null) return;

      final activeFuture = supabase
          .from('orders')
          .select(_orderColumns)
          .eq('user_id', user.id)
          .not('order_status', 'in', '(${_pastStatuses.join(',')})')
          .order('created_at', ascending: false)
          .limit(_activeOrdersSafetyLimit);

      final pastRidesFuture = supabase
          .from('orders')
          .select(_pastOrderColumns)
          .eq('user_id', user.id)
          .inFilter('order_status', _pastStatuses)
          .inFilter('order_type', _rideOrderTypes)
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(_pastPageSize);

      final pastParcelsFuture = supabase
          .from('orders')
          .select(_pastOrderColumns)
          .eq('user_id', user.id)
          .inFilter('order_status', _pastStatuses)
          .inFilter('order_type', _parcelOrderTypes)
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(_pastPageSize);

      final results = await Future.wait([activeFuture, pastRidesFuture, pastParcelsFuture]);
      if (!mounted) return;

      final activeList = List<Map<String, dynamic>>.from(results[0]);
      final pastRidesList = List<Map<String, dynamic>>.from(results[1]);
      final pastParcelsList = List<Map<String, dynamic>>.from(results[2]);

      // Update the widget state to trigger a UI rebuild with the new variables
      setState(() {
        activeOrders = activeList;
        _pastRides = pastRidesList;
        _pastParcels = pastParcelsList;
        _hasMoreRides = pastRidesList.length == _pastPageSize;
        _hasMoreParcels = pastParcelsList.length == _pastPageSize;
        _pastRidesCursorCreatedAt = null;
        _pastRidesCursorId = null;
        _pastParcelsCursorCreatedAt = null;
        _pastParcelsCursorId = null;
        _updatePastCursor(isRides: true, page: pastRidesList);
        _updatePastCursor(isRides: false, page: pastParcelsList);

        _recomputeTypeSplits();

        loading = false;
      });
      _refreshBackoff.recordSuccess();
    } catch (e, s) {
      debugPrint('ACTIVITY LOAD ERROR => $e');
      try {
        File('activity_error.txt').writeAsStringSync('ACTIVITY LOAD ERROR => $e\n\nSTACKTRACE =>\n$s');
      } catch (err) {
        debugPrint('FAILED TO WRITE ERROR TO FILE: $err');
      }
      _refreshBackoff.recordFailure();
      // Update the widget state to trigger a UI rebuild with the new variables
      if (mounted) setState(() => loading = false);
    }
  }

  /// Appends the next page of PAST RIDES only -- activeOrders and past parcels are never
  /// touched here. Triggered by _onScroll() when the outer ListView nears its bottom while the
  /// Rides tab is selected. Does NOT reset on its own; any concurrent full reload (realtime/
  /// timer/resume) still wins and resets pagination back to page 1 via loadOrders() above,
  /// which is correct since a real change means these accumulated pages are stale anyway.
  /// Keyset (not offset) pagination: filters strictly older than the last row of the previous
  /// page by (created_at, id), so results stay correct even if rows are inserted/deleted between
  /// pages -- unlike `.range()`, which shifts on any such change.
  Future<void> _loadMorePastRides() async {
    final user = supabase.auth.currentUser;
    if (user == null) return;
    if (_loadingMoreRides || !_hasMoreRides) return;
    final cursorCreatedAt = _pastRidesCursorCreatedAt;
    final cursorId = _pastRidesCursorId;
    if (cursorCreatedAt == null || cursorId == null) return;

    setState(() => _loadingMoreRides = true);
    try {
      final data = await supabase
          .from('orders')
          .select(_pastOrderColumns)
          .eq('user_id', user.id)
          .inFilter('order_status', _pastStatuses)
          .inFilter('order_type', _rideOrderTypes)
          .or('created_at.lt.$cursorCreatedAt,and(created_at.eq.$cursorCreatedAt,id.lt.$cursorId)')
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(_pastPageSize);

      if (!mounted) return;
      final nextPage = List<Map<String, dynamic>>.from(data);
      setState(() {
        _pastRides = [..._pastRides, ...nextPage];
        _hasMoreRides = nextPage.length == _pastPageSize;
        _updatePastCursor(isRides: true, page: nextPage);
        _loadingMoreRides = false;
      });
    } catch (e) {
      debugPrint('ACTIVITY LOAD MORE RIDES ERROR => $e');
      if (mounted) setState(() => _loadingMoreRides = false);
    }
  }

  /// Mirror of _loadMorePastRides() for the Parcels tab's past bucket -- same keyset pagination,
  /// same guards, independent cursor/hasMore/loading state.
  Future<void> _loadMorePastParcels() async {
    final user = supabase.auth.currentUser;
    if (user == null) return;
    if (_loadingMoreParcels || !_hasMoreParcels) return;
    final cursorCreatedAt = _pastParcelsCursorCreatedAt;
    final cursorId = _pastParcelsCursorId;
    if (cursorCreatedAt == null || cursorId == null) return;

    setState(() => _loadingMoreParcels = true);
    try {
      final data = await supabase
          .from('orders')
          .select(_pastOrderColumns)
          .eq('user_id', user.id)
          .inFilter('order_status', _pastStatuses)
          .inFilter('order_type', _parcelOrderTypes)
          .or('created_at.lt.$cursorCreatedAt,and(created_at.eq.$cursorCreatedAt,id.lt.$cursorId)')
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(_pastPageSize);

      if (!mounted) return;
      final nextPage = List<Map<String, dynamic>>.from(data);
      setState(() {
        _pastParcels = [..._pastParcels, ...nextPage];
        _hasMoreParcels = nextPage.length == _pastPageSize;
        _updatePastCursor(isRides: false, page: nextPage);
        _loadingMoreParcels = false;
      });
    } catch (e) {
      debugPrint('ACTIVITY LOAD MORE PARCELS ERROR => $e');
      if (mounted) setState(() => _loadingMoreParcels = false);
    }
  }

  void _subscribeRealtime() {
    // Perform an asynchronous database operation using the Supabase client wrapper
    final user = supabase.auth.currentUser;
    if (user == null) return;

    if (_activitySubId != null && _activityChannelName != null) {
      // Remove the real-time Postgres subscription to release memory resources
      RealtimeManager.instance.unsubscribe(_activityChannelName!, _activitySubId!);
      _activitySubId = null;
      _activityChannelName = null;
    }

    // Subscribe to Postgres database updates in real-time to auto-sync layout data
    _activityChannelName = 'activity-realtime-channel-${user.id}';
    _activitySubId = RealtimeManager.instance.subscribe(
      channelName: _activityChannelName!,
      table: 'orders',
      owner: 'ActivityTab',
      event: PostgresChangeEvent.all,
      filterColumn: 'user_id',
      filterValue: user.id,
      callback: (payload) {
        _lastRealtimeEventAt = DateTime.now();
        debugPrint('REALTIME ORDER EVENT RECEIVED => DEBOUNCING SYNC');
        _debounceTimer?.cancel();
        // Setup a timer instance for delayed execution or polling intervals
        _debounceTimer = Timer(const Duration(milliseconds: 500), () {
          if (mounted) loadOrders(showLoading: false);
        });
      },
    );
  }

  @override
  // Build method responsible for rendering the entire widget layout hierarchy on the viewport
  Widget build(BuildContext context) {
    if (loading) return const SkeletonLoader();

    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtitleColor = isDark ? const Color(0xFF94A3B8) : Colors.grey.shade700;

    // Active/past orders split by Rides vs Parcels -- cached in
    // _recomputeTypeSplits (run when the underlying data loads), not
    // recomputed on every rebuild.
    final activeRides = _activeRides;
    final activeParcels = _activeParcels;
    final pastRides = _pastRides;
    final pastParcels = _pastParcels;

    return Scaffold(
      // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                ResponsiveLayout.horizontalPadding(context),
                24,
                ResponsiveLayout.horizontalPadding(context),
                16,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Activity',
                          style: TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -1.5,
                            fontStyle: FontStyle.italic,
                            color: textColor,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Your past orders and deliveries',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: subtitleColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    height: 48,
                    width: 48,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF171A21) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark ? Colors.white.withOpacity(0.08) : const Color(0xFFE2E8F0),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(isDark ? 0.2 : 0.03),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        )
                      ]
                    ),
                    child: Center(
                      child: IconButton(
                        onPressed: () {
                          // Navigate to a new screen layout using Flutter's Navigator router
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const CustomerSupportScreen()),
                          );
                        },
                        icon: const Icon(
                          Icons.support_agent_rounded,
                          color: Color(0xFF10B981),
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Premium Sliding Toggle for Rides & Parcels
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: ResponsiveLayout.horizontalPadding(context),
                vertical: 8,
              ),
              child: Container(
                height: 48,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF171A21) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isDark ? Colors.white.withOpacity(0.05) : const Color(0xFFE2E8F0),
                    width: 1.0,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        // Update the widget state to trigger a UI rebuild with the new variables
                        onTap: () => setState(() => _selectedTab = 0),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          decoration: BoxDecoration(
                            color: _selectedTab == 0
                                ? (isDark ? const Color(0xFF1E293B) : Colors.white)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: _selectedTab == 0
                                ? [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(isDark ? 0.25 : 0.05),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    )
                                  ]
                                : null,
                          ),
                          child: Center(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.directions_car_rounded,
                                  size: 16,
                                  color: _selectedTab == 0 ? const Color(0xFF10B981) : subtitleColor,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Rides',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: _selectedTab == 0 ? FontWeight.bold : FontWeight.w600,
                                    color: _selectedTab == 0 ? textColor : subtitleColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        // Update the widget state to trigger a UI rebuild with the new variables
                        onTap: () => setState(() => _selectedTab = 1),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          decoration: BoxDecoration(
                            color: _selectedTab == 1
                                ? (isDark ? const Color(0xFF1E293B) : Colors.white)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: _selectedTab == 1
                                ? [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(isDark ? 0.25 : 0.05),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    )
                                  ]
                                : null,
                          ),
                          child: Center(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.inventory_2_rounded,
                                  size: 16,
                                  color: _selectedTab == 1 ? const Color(0xFFEA580C) : subtitleColor,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Parcels',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: _selectedTab == 1 ? FontWeight.bold : FontWeight.w600,
                                    color: _selectedTab == 1 ? textColor : subtitleColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            Expanded(
              child: (_selectedTab == 0 && activeRides.isEmpty && pastRides.isEmpty)
                  ? _empty(textColor, isDark, isRides: true)
                  : (_selectedTab == 1 && activeParcels.isEmpty && pastParcels.isEmpty)
                      ? _empty(textColor, isDark, isRides: false)
                      : ListView(
                              controller: _scrollController,
                              padding: EdgeInsets.fromLTRB(
                                ResponsiveLayout.horizontalPadding(context),
                                8,
                                ResponsiveLayout.horizontalPadding(context),
                                96 + Insets.bottom(context),
                              ), // bottom padding for nav bar
                              physics: const ClampingScrollPhysics(),
                              children: [
                                if (_selectedTab == 0) ...[
                                  // ── 1. ACTIVE RIDES SECTION
                                  if (activeRides.isNotEmpty) ...[
                                    Row(
                                      children: [
                                        Container(
                                          width: 6, height: 6,
                                          decoration: const BoxDecoration(
                                            color: Color(0xFF10B981),
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        const Text(
                                          'ACTIVE RIDES',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: 0.8,
                                            color: Color(0xFF10B981),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    ListView.separated(
                                      shrinkWrap: true,
                                      physics: const NeverScrollableScrollPhysics(),
                                      itemCount: activeRides.length,
                                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                                      itemBuilder: (_, i) => _ActiveOrderCard(order: activeRides[i]),
                                    ),
                                    const SizedBox(height: 24),
                                  ],

                                  // ── 2. PAST RIDES SECTION
                                  if (pastRides.isNotEmpty) ...[
                                    Text(
                                      'PAST RIDES',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.8,
                                        color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    ListView.separated(
                                      shrinkWrap: true,
                                      physics: const NeverScrollableScrollPhysics(),
                                      itemCount: pastRides.length,
                                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                                      itemBuilder: (_, i) => _ActivityTile(
                                        order: pastRides[i],
                                        onReviewSubmitted: () => loadOrders(showLoading: false),
                                      ),
                                    ),
                                  ],
                                ],
                                if (_selectedTab == 1) ...[
                                  // ── 1. ACTIVE PARCELS SECTION
                                  if (activeParcels.isNotEmpty) ...[
                                    Row(
                                      children: [
                                        Container(
                                          width: 6, height: 6,
                                          decoration: const BoxDecoration(
                                            color: Color(0xFFEA580C),
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        const Text(
                                          'ACTIVE PARCELS',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: 0.8,
                                            color: Color(0xFFEA580C),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    ListView.separated(
                                      shrinkWrap: true,
                                      physics: const NeverScrollableScrollPhysics(),
                                      itemCount: activeParcels.length,
                                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                                      itemBuilder: (_, i) => _ActiveOrderCard(order: activeParcels[i]),
                                    ),
                                    const SizedBox(height: 24),
                                  ],

                                  // ── 2. PAST PARCELS SECTION
                                  if (pastParcels.isNotEmpty) ...[
                                    Text(
                                      'PAST PARCELS',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.8,
                                        color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    ListView.separated(
                                      shrinkWrap: true,
                                      physics: const NeverScrollableScrollPhysics(),
                                      itemCount: pastParcels.length,
                                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                                      itemBuilder: (_, i) => _ActivityTile(
                                        order: pastParcels[i],
                                        onReviewSubmitted: () => loadOrders(showLoading: false),
                                      ),
                                    ),
                                  ],
                                ],
                                if ((_selectedTab == 0 && _loadingMoreRides) ||
                                    (_selectedTab == 1 && _loadingMoreParcels))
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 20),
                                    child: Center(child: CircularProgressIndicator()),
                                  ),
                              ],
                            ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(Color textColor, bool isDark, {required bool isRides}) {
    final themeColor = isRides ? const Color(0xFF10B981) : const Color(0xFFEA580C);
    final emptyIcon = isRides ? Icons.directions_car_rounded : Icons.inventory_2_rounded;
    final emptyTitle = isRides ? 'No past rides yet' : 'No past parcel deliveries';
    final emptyDesc = isRides
        ? 'When you complete or cancel any rides, they will appear beautifully listed right here.'
        : 'When you send or receive packages, your parcel history will be documented right here.';

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF171A21) : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: themeColor.withOpacity(0.2),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: themeColor.withOpacity(isDark ? 0.08 : 0.03),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Center(
                child: Icon(
                  emptyIcon,
                  color: themeColor,
                  size: 40,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              emptyTitle,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: textColor,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              emptyDesc,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                height: 1.45,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class _ActivityTile extends StatelessWidget {
  final Map<String, dynamic> order;
  final VoidCallback onReviewSubmitted;
  const _ActivityTile({required this.order, required this.onReviewSubmitted});

  bool get completed => order['order_status'] == 'completed' || order['order_status'] == 'delivered';

  @override
  // Build method responsible for rendering the entire widget layout hierarchy on the viewport
  Widget build(BuildContext context) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final cardBgColor = isDark ? const Color(0xFF171A21) : Colors.white;
    final themeColor = completed ? const Color(0xFF10B981) : const Color(0xFFEF4444);

    final type = order['order_type']?.toString() ?? 'ride';
    final isParcel = type.contains('parcel') || type.contains('delivery');

    final rawId = order['id']?.toString() ?? '';
    final idStr = order['order_code'] != null && order['order_code'].toString().isNotEmpty
        ? order['order_code'].toString()
        : 'WD-${rawId.length >= 6 ? rawId.substring(0, 6).toUpperCase() : rawId.toUpperCase()}';

    final dateStr = ActivityUiHelpers.formatPremiumDate(order['completed_at'] ?? order['cancelled_at'] ?? order['created_at']?.toString());
    final locationStr = ActivityUiHelpers.resolveCity(order);

    return Container(
      decoration: BoxDecoration(
        color: cardBgColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark ? Colors.white.withOpacity(0.04) : const Color(0xFFE2E8F0),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.2 : 0.02),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: ActivityUiHelpers.getVehicleImageWidget(order),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Order ID',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        idStr,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w900,
                          color: textColor,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: themeColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: themeColor.withOpacity(0.2), width: 1),
                  ),
                  child: Text(
                    completed ? 'COMPLETE' : 'CANCELLED',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      color: themeColor,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Service',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        ActivityUiHelpers.getCleanOrderType(order),
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        completed ? 'Date Completed' : 'Date Cancelled',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        dateStr,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Location',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        locationStr,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: isDark ? Colors.white.withOpacity(0.06) : const Color(0xFFE2E8F0),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () {
                      _reorderTrip(context);
                    },
                    borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(24)),
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            isParcel ? 'Send Again' : 'Ride Again',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF10B981),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Container(
                  width: 1,
                  height: 48,
                  color: isDark ? Colors.white.withOpacity(0.06) : const Color(0xFFE2E8F0),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () {
                      final status = order['order_status']?.toString().toLowerCase() ?? '';
                      final isCompleted = status == 'completed' || status == 'delivered';
                      if (isCompleted) {
                        // Navigate to a new screen layout using Flutter's Navigator router
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CompletedOrderDetailsScreen(
                              order: order,
                              onReviewSubmitted: onReviewSubmitted,
                            ),
                          ),
                        );
                      } else {
                        ActivityUiHelpers.showOrderDetailsSheet(
                          context,
                          order,
                          onReviewSubmitted: onReviewSubmitted,
                        );
                      }
                    },
                    borderRadius: const BorderRadius.only(bottomRight: Radius.circular(24)),
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      child: Text(
                        'View Details',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _reorderTrip(BuildContext context) {
    final type = order['order_type']?.toString() ?? 'ride';
    final distanceMeters = double.tryParse(order['distance_meters']?.toString() ?? '0') ?? 0;
    final isIntercityRide = type == 'intercity_ride' || (type == 'ride' && distanceMeters > 20000);
    final isParcel = type == 'local_parcel' || type == 'intercity_parcel';

    if (isParcel) {
      if (type == 'local_parcel') {
        // Navigate to a new screen layout using Flutter's Navigator router
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ParcelDetailsScreen(
              orderType: 'local_parcel',
              pickupAddress: order['pickup_address']?.toString(),
              destinationAddress: order['destination_address']?.toString(),
              pickupLat: double.tryParse(order['pickup_lat']?.toString() ?? ''),
              pickupLng: double.tryParse(order['pickup_lng']?.toString() ?? ''),
              destinationLat: double.tryParse(order['destination_lat']?.toString() ?? ''),
              destinationLng: double.tryParse(order['destination_lng']?.toString() ?? ''),
              totalDistanceMeters: double.tryParse(order['distance_meters']?.toString() ?? ''),
              durationSeconds: double.tryParse(order['time_taken_seconds']?.toString() ?? ''),
              receiverName: order['receiver_name']?.toString(),
              receiverPhone: order['receiver_phone']?.toString(),
              parcelType: order['parcel_type']?.toString(),
              weightCategory: order['weight_category']?.toString(),
              specialInstructions: order['special_instructions']?.toString(),
            ),
          ),
        );
      } else {
        // Navigate to a new screen layout using Flutter's Navigator router
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => IntercityDetailsScreen(
              orderType: 'intercity_parcel',
              pickupAddress: order['pickup_address']?.toString(),
              destinationAddress: order['destination_address']?.toString(),
              pickupLat: double.tryParse(order['pickup_lat']?.toString() ?? ''),
              pickupLng: double.tryParse(order['pickup_lng']?.toString() ?? ''),
              destinationLat: double.tryParse(order['destination_lat']?.toString() ?? ''),
              destinationLng: double.tryParse(order['destination_lng']?.toString() ?? ''),
              totalDistanceMeters: double.tryParse(order['distance_meters']?.toString() ?? ''),
              durationSeconds: double.tryParse(order['time_taken_seconds']?.toString() ?? ''),
              receiverName: order['receiver_name']?.toString(),
              receiverPhone: order['receiver_phone']?.toString(),
              parcelType: order['parcel_type']?.toString(),
              weightCategory: order['weight_category']?.toString(),
              specialInstructions: order['special_instructions']?.toString(),
            ),
          ),
        );
      }
    } else {
      // Navigate to a new screen layout using Flutter's Navigator router
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RideLocationScreen(
            orderType: isIntercityRide ? 'intercity' : 'ride',
            prefillPickupAddress: order['pickup_address']?.toString(),
            prefillDestinationAddress: order['destination_address']?.toString(),
            prefillPickupLat: double.tryParse(order['pickup_lat']?.toString() ?? ''),
            prefillPickupLng: double.tryParse(order['pickup_lng']?.toString() ?? ''),
            prefillDestinationLat: double.tryParse(order['destination_lat']?.toString() ?? ''),
            prefillDestinationLng: double.tryParse(order['destination_lng']?.toString() ?? ''),
          ),
        ),
      );
    }
  }
}

class _ActiveOrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  const _ActiveOrderCard({required this.order});

  @override
  // Build method responsible for rendering the entire widget layout hierarchy on the viewport
  Widget build(BuildContext context) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rawStatus = order['order_status']?.toString() ?? 'searching';
    final status = rawStatus == 'expired' ? 'searching' : rawStatus;
    final type = order['order_type']?.toString() ?? 'ride';

    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final cardBgColor = isDark ? const Color(0xFF171A21) : Colors.white;

    final isParcel = type.contains('parcel') || type.contains('delivery');
    final themeAccent = isParcel ? const Color(0xFFEA580C) : const Color(0xFF10B981);

    final rawId = order['id']?.toString() ?? '';
    final idStr = order['order_code'] != null && order['order_code'].toString().isNotEmpty
        ? order['order_code'].toString()
        : 'WD-${rawId.length >= 6 ? rawId.substring(0, 6).toUpperCase() : rawId.toUpperCase()}';

    final dateStr = ActivityUiHelpers.formatPremiumDate(order['created_at']?.toString());
    final locationStr = ActivityUiHelpers.resolveCity(order);

    String statusLabel = 'SEARCHING';
    if (status == 'accepted') statusLabel = 'ACCEPTED';
    if (status == 'rider_arrived') statusLabel = 'ARRIVED';
    if (status == 'ongoing' || status == 'picked_up') {
      statusLabel = isParcel ? 'IN DELIVERY' : 'IN TRANSIT';
    }
    if (status == 'rider_at_drop') statusLabel = 'ARRIVING';
    if (status == 'payment_pending') statusLabel = 'AWAITING PAYMENT';

    return Container(
      decoration: BoxDecoration(
        color: cardBgColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark ? themeAccent.withOpacity(0.3) : const Color(0xFFE2E8F0),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.3 : 0.04),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white : const Color(0xFFF1F5F9),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: themeAccent.withValues(alpha: 0.15),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: ActivityUiHelpers.getVehicleImageWidget(order),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Order ID',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        idStr,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w900,
                          color: textColor,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: themeAccent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: themeAccent.withOpacity(0.2), width: 1),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      color: themeAccent,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Service',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        ActivityUiHelpers.getCleanOrderType(order),
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Date',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        dateStr,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Location',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        locationStr,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: isDark ? Colors.white.withOpacity(0.06) : const Color(0xFFE2E8F0),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _resumeTracking(context),
                    borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(24)),
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.near_me_rounded,
                            size: 15,
                            color: themeAccent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Track',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              color: themeAccent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Container(
                  width: 1,
                  height: 48,
                  color: isDark ? Colors.white.withOpacity(0.06) : const Color(0xFFE2E8F0),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () {
                      ActivityUiHelpers.showOrderDetailsSheet(
                        context,
                        order,
                        onReviewSubmitted: () {},
                      );
                    },
                    borderRadius: const BorderRadius.only(bottomRight: Radius.circular(24)),
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      child: Text(
                        'View Details',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _resumeTracking(BuildContext context) {
    final orderType = order['order_type'];
    final distanceMeters = double.tryParse(order['distance_meters']?.toString() ?? '0') ?? 0;
    final isLocalParcel = orderType == 'local_parcel';
    final isIntercityParcel = orderType == 'intercity_parcel';
    final isIntercityRide = orderType == 'intercity_ride' || (orderType == 'ride' && distanceMeters > 20000);

    final rawStatus = order['order_status']?.toString();
    final status = rawStatus == 'expired' ? 'searching' : rawStatus;
    if (status == 'searching' || status == 'created') {
      // Navigate to a new screen layout using Flutter's Navigator router
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) {
            if (isLocalParcel) return ParcelSearchingScreen(orderId: order['id']);
            if (isIntercityParcel) return IntercitySearchingScreen(orderId: order['id']);
            if (isIntercityRide) return IntercitySearchingScreen(orderId: order['id']);
            return RideSearchingScreen(orderId: order['id']);
          },
        ),
      );
    } else {
      // Navigate to a new screen layout using Flutter's Navigator router
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) {
            if (isLocalParcel) return ParcelTrackingScreen(orderId: order['id']);
            if (isIntercityParcel) return IntercityTrackingScreen(orderId: order['id']);
            if (isIntercityRide) return IntercityTrackingScreen(orderId: order['id']);
            return RideTrackingScreen(orderId: order['id']);
          },
        ),
      );
    }
  }
}

class ActivityUiHelpers {
  static String formatTime(DateTime? dt) {
    if (dt == null) return '';
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  static String formatDate(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final checkDate = DateTime(dt.year, dt.month, dt.day);

    if (checkDate == today) return 'Today';
    if (checkDate == yesterday) return 'Yesterday';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  // orders has no `payment_method` column -- that exists only on the separate `payments` table
  // (one row per gateway transaction). Reading order['payment_method'] here was always null, so
  // this badge silently showed "CASH" for every order regardless of how it was actually settled.
  // fare_payment_method is the passenger's real settlement-time choice ('personal_upi' | 'cash' |
  // 'cashfree'); payment_mode (booking-time intent) is kept only as a fallback for orders that
  // never reached that flow.
  static String paymentMethodLabel(Map<String, dynamic> order) {
    final fareMethod = order['fare_payment_method']?.toString();
    final paymentMode = order['payment_mode']?.toString().toLowerCase();
    if (fareMethod == 'personal_upi') return 'PERSONAL UPI / QR';
    if (fareMethod == 'cash') return 'CASH';
    if (fareMethod == 'cashfree') return 'ONLINE PAYMENT';
    if (paymentMode == 'cash') return 'CASH';
    if (paymentMode == 'upi') return 'PERSONAL UPI / QR';
    return 'ONLINE PAYMENT';
  }

  static String getCleanOrderType(Map<String, dynamic> order) {
    final type = order['order_type']?.toString() ?? 'ride';
    switch (type) {
      case 'ride':
        return 'Ride';
      case 'intercity':
      case 'intercity_ride':
        return 'Intercity Ride';
      case 'ride_sharing':
        return 'Ride Sharing';
      case 'local_parcel':
        return 'Local Parcel';
      case 'intercity_parcel':
        return 'Intercity Parcel';
      default:
        return type.split('_').map((word) {
          if (word.isEmpty) return '';
          return word[0].toUpperCase() + word.substring(1);
        }).join(' ');
    }
  }

  static String formatFullDateTime(String? rawDate) {
    if (rawDate == null) return '';
    try {
      final dt = DateTime.parse(rawDate).toLocal();
      final datePart = formatPremiumDate(rawDate);
      final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
      final ampm = dt.hour >= 12 ? 'PM' : 'AM';
      final minuteStr = dt.minute.toString().padLeft(2, '0');
      return '$datePart, $hour:$minuteStr $ampm';
    } catch (_) {
      return '';
    }
  }

  static Widget getVehicleImageWidget(Map<String, dynamic> order) {
    final type = order['order_type']?.toString() ?? 'ride';
    final isParcel = type.contains('parcel') || type.contains('delivery');
    
    var vehicleType = (order['vehicle_type'] ?? '').toString().toLowerCase().trim();
    if (vehicleType.isEmpty) {
      final rider = order['rider'];
      final kyc = rider?['rider_kyc'];
      if (kyc != null) {
        if (kyc is Map) {
          vehicleType = (kyc['vehicle_type'] ?? '').toString().toLowerCase().trim();
        } else if (kyc is List && kyc.isNotEmpty) {
          vehicleType = (kyc[0]['vehicle_type'] ?? '').toString().toLowerCase().trim();
        }
      }
    }
    
    if (vehicleType.isEmpty) {
      vehicleType = isParcel ? 'bike' : 'cab';
    }

    String assetName = 'bike.jpg';
    if (isParcel) {
      assetName = 'delivery.png';
    } else {
      if (vehicleType.contains('auto') || vehicleType.contains('rickshaw')) {
        assetName = 'auto.jpg';
      } else if (vehicleType.contains('cab') || vehicleType.contains('car') || vehicleType.contains('sedan')) {
        assetName = 'cab.jpg';
      } else {
        assetName = 'bike.jpg';
      }
    }

    return ClipOval(
      child: Image.asset(
        'assets/images/$assetName',
        fit: BoxFit.cover,
      ),
    );
  }

  static String formatPremiumDate(String? rawDate) {
    if (rawDate == null) return 'Today';
    try {
      final dt = DateTime.parse(rawDate).toLocal();
      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${dt.day} ${months[dt.month - 1]}. ${dt.year}';
    } catch (_) {
      return 'Today';
    }
  }

  static String resolveCity(Map<String, dynamic> order) {
    final city = order['destination_city']?.toString() ?? '';
    if (city.isNotEmpty && city != 'Other') return city;
    final addr = order['destination_address']?.toString() ?? 'Aldo';
    final parts = addr.split(',');
    if (parts.isNotEmpty) {
      for (var part in parts) {
        final trimmed = part.trim();
        if (trimmed.toLowerCase() == 'india' || trimmed.toLowerCase() == 'karnataka' || trimmed.toLowerCase() == 'telangana' || trimmed.toLowerCase() == 'andhra pradesh' || trimmed.toLowerCase() == 'maharashtra' || trimmed.toLowerCase() == 'tamil nadu' || trimmed.toLowerCase() == 'delhi') {
          continue;
        }
        if (trimmed.isNotEmpty) return trimmed;
      }
    }
    return 'Aldo';
  }

  static void showOrderDetailsSheet(BuildContext context, Map<String, dynamic> order, {required VoidCallback onReviewSubmitted}) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final status = order['order_status']?.toString().toLowerCase() ?? 'searching';
    final type = order['order_type']?.toString() ?? 'ride';
    final isParcel = type.contains('parcel') || type.contains('delivery');
    
    String statusLabel = 'SEARCHING';
    Color themeColor = const Color(0xFF3B82F6); // Blue
    
    if (status == 'completed' || status == 'delivered') {
      statusLabel = 'COMPLETED';
      themeColor = const Color(0xFF10B981); // Green
    } else if (status == 'cancelled') {
      statusLabel = 'CANCELLED';
      themeColor = const Color(0xFFEF4444); // Red
    } else if (status == 'accepted') {
      statusLabel = 'ACCEPTED';
      themeColor = const Color(0xFFF59E0B); // Amber
    } else if (status == 'rider_arrived' || status == 'arrived') {
      statusLabel = 'ARRIVED';
      themeColor = const Color(0xFFF59E0B); // Amber
    } else if (status == 'ongoing' || status == 'picked_up' || status == 'pickedup') {
      statusLabel = isParcel ? 'IN DELIVERY' : 'IN TRANSIT';
      themeColor = const Color(0xFFF59E0B); // Amber
    } else if (status == 'rider_at_drop' || status == 'arriving') {
      statusLabel = 'ARRIVING';
      themeColor = const Color(0xFFF59E0B); // Amber
    } else if (status == 'payment_pending') {
      statusLabel = 'AWAITING PAYMENT';
      themeColor = const Color(0xFF10B981); // Green
    } else if (status == 'expired') {
      statusLabel = 'EXPIRED';
      themeColor = const Color(0xFF64748B); // Slate -- distinct from active(amber)/completed(green)/cancelled(red)
    }
    
    final fare = double.tryParse(order['final_fare']?.toString() ?? order['current_fare']?.toString() ?? '0') ?? 0;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final isCancelled = status == 'cancelled';
    
    // Present a premium modal bottom sheet drawer for user input/actions
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF171A21) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: themeColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: themeColor.withOpacity(0.2), width: 1.5),
                    ),
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: themeColor,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        children: [
                          const SizedBox(height: 4),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Color(0xFF10B981),
                              shape: BoxShape.circle,
                            ),
                          ),
                          Container(
                            width: 1.5,
                            height: 36,
                            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFCBD5E1),
                          ),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Color(0xFFEF4444),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'PICKUP LOCATION',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              order['pickup_address'] ?? 'Pickup Location',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: textColor,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'DESTINATION LOCATION',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              order['destination_address'] ?? 'Destination Location',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: textColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Divider(height: 1, color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
                  const SizedBox(height: 20),
                  
                  // Estimated Fare Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Estimated Fare',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                        ),
                      ),
                      Text(
                        '₹${fare.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  
                  // Payment Method Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Payment Method',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                        ),
                      ),
                      Text(
                        ActivityUiHelpers.paymentMethodLabel(order),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  
                  // Date Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Date',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                        ),
                      ),
                      Text(
                        formatFullDateTime(order['created_at']?.toString()),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                  
                  if (isCancelled && order['cancel_reason'] != null) ...[
                    const SizedBox(height: 24),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444).withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.15)),
                      ),
                      child: Text(
                        'Cancellation Reason: ${order['cancel_reason']}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFEF4444),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
