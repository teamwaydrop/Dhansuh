import 'package:waydrop/core/services/diagnostics/ride_diagnostics.dart';
import 'package:waydrop/core/services/diagnostics/ride_diagnostics_owner.dart';
/// ============================================================================
/// File: intercity_bookings_screen.dart
///
/// Module:
/// Rider → Intercity
///
/// Purpose:
/// Rider dashboard for managing intercity matches.
///
/// Responsibilities:
/// • Browse intercity matching requests, bid on customer requests, manage active intercity journeys.
///
/// Related:
/// travel_plan_details_screen.dart
/// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'bookings_refresh_read.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/modules/chat/screens/order_chat_screen.dart';
import 'package:waydrop/features/local_rides/tracking/screens/ride_tracking_screen.dart';
import 'package:waydrop/features/local_parcels/tracking/screens/parcel_tracking_screen.dart';
import 'package:waydrop/shared/helpers/fare_presentation_helper.dart';
import 'package:waydrop/shared/helpers/location_display_service.dart';
import 'package:waydrop/shared/helpers/time_format_helper.dart';
import 'package:waydrop/features/rider/travel_plans/screens/travel_plan_details_screen.dart';
import 'package:waydrop/features/rider/orders/screens/rider_active_order_screen.dart';
import 'package:waydrop/features/intercity/shared/services/intercity_matching_service.dart';
import 'package:waydrop/shared/widgets/cancellation_reason_dialog.dart';

class IntercityBookingsScreen extends StatefulWidget {
  const IntercityBookingsScreen({super.key});

  @override
  State<IntercityBookingsScreen> createState() => _IntercityBookingsScreenState();
}

class _IntercityBookingsScreenState extends State<IntercityBookingsScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final supabase = Supabase.instance.client;
  late TabController _tabController;
  bool _loading = true;
  String? _riderId;
  String? _dataAccountId;
  final _refreshReads = BookingsRefreshRead();
  StreamSubscription<AuthState>? _accountSubscription;
  // Defensive guard only — the real boundary is the rider_travel_plans /
  // intercity_requests RLS policies (20260718000012), which already prevent
  // a Local Rides-mode partner from having any data to see here. This just
  // avoids showing an empty/broken screen if this route is ever reached via
  // a stale deep link.
  bool _wrongMode = false;

  List<Map<String, dynamic>> _travelPlans = [];
  List<Map<String, dynamic>> _completedPlans = [];
  List<Map<String, dynamic>> _negotiations = [];
  List<Map<String, dynamic>> _upcomingTrips = [];
  List<Map<String, dynamic>> _activeTrips = [];
  List<Map<String, dynamic>> _history = [];

  // Root-cause fix for "accepted Travel Together work disappears": this screen previously had no
  // realtime subscription at all (only initState + manual pull-to-refresh), so a Drop Partner
  // already sitting on it never saw a fresh acceptance/status change without backing out and back
  // in.
  // Egress fix: was a single raw supabase.channel() -- migrated to RealtimeManager so the
  // `orders` half pools with the rider-wide 'rider-active-order-$riderId' channel
  // RiderHomeTab/RiderOrdersScreen/TravelPlanDetailsScreen already share, and the
  // `intercity_requests` half pools with TravelPlanDetailsScreen's identical subscription (both
  // screens can be mounted concurrently: Home -> this screen -> TravelPlanDetailsScreen, none
  // dispose the ones below them).
  String? _requestsSubChannel;
  String? _requestsSubId;
  String? _ordersSubChannel;
  String? _ordersSubId;
  Timer? _realtimeDebounceTimer;

  static const Color primaryLime = Color(0xFFC5FF30);
  static const Color darkBg = Color(0xFF0F1115);
  static const Color darkCard = Color(0xFF171A21);
  static const Color textGray = Color(0xFF94A3B8);

  late final RideDiagnosticOwner _rideDiagnosticOwner;

  @override
  void initState() {
    super.initState();
    _rideDiagnosticOwner = RideDiagnosticOwner.widget(() => mounted, surface: RideSurface.intercityBookings);
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 5, vsync: this);
    _accountSubscription = supabase.auth.onAuthStateChange.listen((event) {
      final previous = _dataAccountId;
      if (previous != null && event.session?.user.id != previous) {
        _refreshReads.retire(previous);
        _dataAccountId = null;
        _riderId = null;
        if (mounted) {
          setState(() {
            _travelPlans = []; _completedPlans = [];
            _negotiations = []; _upcomingTrips = []; _activeTrips = []; _history = [];
          });
        }
      }
    });
    _initializeData();
  }

  @override
  void dispose() {
    _rideDiagnosticOwner.dispose();
    _refreshReads.dispose();
    _accountSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _realtimeDebounceTimer?.cancel();
    if (_requestsSubChannel != null && _requestsSubId != null) {
      RealtimeManager.instance.unsubscribe(_requestsSubChannel!, _requestsSubId!);
    }
    if (_ordersSubChannel != null && _ordersSubId != null) {
      RealtimeManager.instance.unsubscribe(_ordersSubChannel!, _ordersSubId!);
    }
    _tabController.dispose();
    super.dispose();
  }

  // App resume/reconnect reconciliation: if a realtime event was missed while backgrounded (or
  // the socket dropped), coming back to the foreground re-fetches so the accepted/started work is
  // never stuck showing stale state without requiring a restart or manual tab-switch.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _riderId != null) {
      _fetchData().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  Future<void> _initializeData() async {
    setState(() => _loading = true);
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;
      _dataAccountId = user.id;

      // Egress fix: narrowed to the two fields actually read below (service_mode, id).
      final riderRes = await supabase
          .from('riders')
          .select('id, service_mode')
          .eq('user_id', user.id)
          .maybeSingle();

      if (!mounted || _dataAccountId != user.id || supabase.auth.currentUser?.id != user.id) return;

      if (riderRes != null) {
        if (riderRes['service_mode'] != 'intercity') {
          _wrongMode = true;
          return;
        }
        _riderId = riderRes['id'];
        await _fetchData();
        if (!mounted || _dataAccountId != user.id || supabase.auth.currentUser?.id != user.id) return;
        _subscribeRealtime();
      }
    } catch (e) {
      debugPrint('Error initializing intercity bookings: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  // Fixes "accepted Travel Together work disappears": previously this screen only ever fetched
  // once in initState plus manual pull-to-refresh. A fresh acceptance (intercity_requests status
  // change) or a Start Trip elsewhere (orders.trip_started_at) now pushes a live update here too.
  // Always triggers a full _fetchData() (never an incremental append), so realtime + resume +
  // pull-to-refresh firing together can't produce duplicate cards -- each just re-renders the
  // same correctly-bucketed lists.
  void _subscribeRealtime() {
    if (!mounted || _dataAccountId != supabase.auth.currentUser?.id) return;
    if (_riderId == null) return;
    final riderId = _riderId!;

    // Egress fix: pools with TravelPlanDetailsScreen's identical intercity_requests
    // (traveller_id=riderId, event=all) subscription instead of opening a second socket --
    // both screens can be mounted concurrently (Home -> here -> TravelPlanDetailsScreen).
    _requestsSubChannel = 'rider-intercity-requests-$riderId';
    _requestsSubId = RealtimeManager.instance.subscribe(
      channelName: _requestsSubChannel!,
      table: 'intercity_requests',
      owner: 'IntercityBookingsScreen_Requests',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'traveller_id',
      filterValue: riderId,
      callback: (payload) {
        if (!mounted) return;
        _debouncedRefresh();
      },
    );

    // Egress fix: pools with the rider-wide 'rider-active-order-$riderId' channel
    // RiderHomeTab/RiderOrdersScreen/TravelPlanDetailsScreen already share for this exact
    // table/filter -- RealtimeManager requires an exact event match to pool, so this widens from
    // `update` to `all`; safe because orders are always created with rider_id still null and are
    // never deleted, so INSERT/DELETE can never actually fire for this filter (same invariant the
    // sibling screens' merge already relies on).
    _ordersSubChannel = 'rider-active-order-$riderId';
    _ordersSubId = RealtimeManager.instance.subscribe(
      channelName: _ordersSubChannel!,
      table: 'orders',
      owner: 'IntercityBookingsScreen_Orders',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'rider_id',
      filterValue: riderId,
      callback: (payload) {
        if (!mounted) return;
        // R5 perf fix: _fetchData()'s bucketing only ever reads order_status off the joined
        // order (display fields like fare/pickup_city/destination_city are immutable once a
        // traveller_id is assigned -- see boost-order-fare, which only permits a fare change
        // while order_status == 'searching'). Other orders columns (trip_started_at,
        // pickup_verification_completed, delivery_otp, etc.) already get their own dedicated
        // signal via the intercity_requests subscription above whenever they're UI-relevant --
        // gate on the diff `orders` already delivers (REPLICA IDENTITY FULL) instead of
        // re-fetching for a column this screen never reads.
        if (payload.oldRecord['order_status'] == payload.newRecord['order_status']) return;
        _debouncedRefresh();
      },
    );
  }

  // Egress fix: a burst of related realtime events (e.g. accept -> a status write on both
  // intercity_requests and orders moments apart) previously triggered one full _fetchData() per
  // event -- same 500ms-debounce pattern already used by intercity_rides_screen.dart/
  // intercity_parcels_screen.dart for the identical situation.
  void _debouncedRefresh() {
    _realtimeDebounceTimer?.cancel();
    _realtimeDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _fetchData().then((_) {
        if (mounted) setState(() {});
      });
    });
  }

  Future<void> _fetchData() async {
    final riderId = _riderId;
    final accountId = _dataAccountId;
    if (!mounted || riderId == null || accountId == null || supabase.auth.currentUser?.id != accountId) return;
    try {
      // R18 perf fix: these three queries are independent -- each depends only on _riderId
      // (already resolved above), none reads another's result, and each result is assigned to
      // its own separate variable below (plansRes -> _travelPlans, completedPlansRes ->
      // _completedPlans, reqsRes -> the bucketing loop) with no cross-reference between them.
      // Awaited concurrently instead of one at a time; same queries, same filters, same ordering,
      // same error handling (a failure in any one still aborts the whole update via the shared
      // try/catch below, exactly as today -- no partial state is ever applied either way).
      final observation = await _refreshReads.read(accountId, riderId, () async {
        if (!mounted || _dataAccountId != accountId || _riderId != riderId ||
            supabase.auth.currentUser?.id != accountId) {
          throw StateError('Bookings refresh retired');
        }
        return await Future.wait([
        // 1. Fetch active travel plans. ROOT CAUSE FIX: a plan automatically flips to
        // 'fully_booked' the moment its confirmed/paid/in_progress bookings reach max_bookings
        // (see 20260617000001's trigger) -- for a single-seat plan that's the very first
        // acceptance. This tab used to query status='active' only, so an accepted plan vanished
        // from "Travel Plans" here too, the same bug fixed in rider_home_tab.dart's
        // loadTravelPlans().
        supabase
            .from('rider_travel_plans')
            .select()
            .eq('rider_id', riderId)
            .inFilter('status', ['active', 'fully_booked'])
            .order('travel_date', ascending: true),

        // 1b. Fetch completed travel plans (moved out of Active once the
        // journey completes — see _completeTravelPlanIfDone).
        supabase
            .from('rider_travel_plans')
            .select()
            .eq('rider_id', riderId)
            .eq('status', 'completed')
            .order('travel_date', ascending: false),

        // 2. Fetch intercity requests joined with orders and plans.
        // Egress fix: the outer intercity_requests row and its `orders` join were previously
        // `*` (every column of both tables); narrowed to the fields this screen and its card
        // builders actually read (status, proposed_fare, booking_type, parcel_id, route_id,
        // expiry_reason from the request; final_fare/current_fare/order_status/pickup_city/
        // destination_city/users from the order -- grepped exhaustively across every `req[...]`
        // / `order?[...]` access in this file). `rider_travel_plans(*)` is left unnarrowed: the
        // joined plan map is passed wholesale into TravelPlanDetailsScreen (via _openPlanDetails),
        // a ~2500-line screen with 30+ distinct field reads on it -- narrowing that join safely
        // would require auditing that screen's full field usage, out of scope for this pass.
        supabase
            .from('intercity_requests')
            .select(
              'status, proposed_fare, booking_type, parcel_id, route_id, expiry_reason, '
              'orders(final_fare, current_fare, order_status, pickup_city, destination_city, '
              'users(full_name, phone)), rider_travel_plans(*)',
            )
            .eq('traveller_id', riderId)
            .order('created_at', ascending: false),
      ]);
      });
      if (!mounted || !_refreshReads.isCurrent(observation, supabase.auth.currentUser?.id, _riderId) ||
          _dataAccountId != accountId) {
        return;
      }
      final results = observation.results;
      final plansRes = results[0];
      final completedPlansRes = results[1];
      final reqsRes = results[2];

      final List<Map<String, dynamic>> allRequests = List<Map<String, dynamic>>.from(reqsRes);

      _travelPlans = List<Map<String, dynamic>>.from(plansRes);
      _completedPlans = List<Map<String, dynamic>>.from(completedPlansRes);
      _negotiations.clear();
      _upcomingTrips.clear();
      _activeTrips.clear();
      _history.clear();

      for (var req in allRequests) {
        final status = req['status']?.toString();
        final order = req['orders'] as Map<String, dynamic>?;
        final orderStatus = order?['order_status']?.toString();

        if (['request_sent', 'discussion_started', 'fare_agreed'].contains(status)) {
          _negotiations.add(req);
        } else if (['expired', 'cancelled', 'rejected', 'completed'].contains(status) ||
                   ['completed', 'cancelled', 'delivered'].contains(orderStatus)) {
          // Checked ahead of the active/upcoming buckets below: a request can reach
          // 'completed'/'cancelled' (synced from the linked order by update-order-status) while
          // orderStatus is still momentarily a pre-terminal value, so status must win the
          // terminal classification whenever either side says the trip is over.
          _history.add(req);
        } else if (status == 'confirmed' ||
                   (status == 'paid' && orderStatus == 'accepted')) {
          // 'paid' + orderStatus still 'accepted' means the trip hasn't been started yet (Start
          // Trip sets trip_started_at / intercity_requests.status='in_progress' without ever
          // touching order_status -- see start_intercity_trip_for_plan, 20260721000003) so it
          // still belongs here, not in Active.
          _upcomingTrips.add(req);
        } else if (status == 'in_progress' ||
                   (status == 'paid' && ['picked_up', 'ongoing', 'rider_at_drop'].contains(orderStatus))) {
          // Bug 2 fix: 'in_progress' (Start Trip pressed) must land here regardless of
          // orderStatus. The old check required orderStatus to already be
          // picked_up/ongoing/rider_at_drop, but order_status deliberately stays 'accepted' for
          // the entire "trip started, handover not yet confirmed" window (order_chat_screen.dart's
          // _confirmHandover is the only thing that advances it) -- a request in that window
          // matched neither this bucket nor Upcoming (which requires status in
          // confirmed/paid) and vanished from every tab.
          _activeTrips.add(req);
        }
      }
    } catch (e) {
      debugPrint('Error fetching intercity data: $e');
    }
  }

  // Issue 2: routed through the single canonical cancel_travel_plan_by_traveller() RPC (via
  // IntercityMatchingService.cancelTravelPlan) instead of a direct rider_travel_plans update.
  // The RPC performs its own authoritative trip_started_at-based "genuinely started" check --
  // pre-trip cancellations (even with accepted passengers) now succeed instead of being blocked
  // by the previously-buggy cascade trigger; a trip that has actually started is still refused,
  // with the same TRIP_ALREADY_STARTED message this screen already surfaced.
  Future<void> _deleteTravelPlan(String planId, String reason) async {
    try {
      final result = await IntercityMatchingService.cancelTravelPlan(
        routeId: planId,
        cancelReason: reason,
      );
      if (!mounted) return;
      if (result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Travel plan cancelled successfully.'), backgroundColor: Colors.green),
        );
        await _fetchData();
        if (mounted) setState(() {});
      } else {
        final msg = (result['message'] as String?) ?? 'Could not cancel this travel plan.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to cancel travel plan: $msg'), backgroundColor: Colors.redAccent),
        );
      }
    } catch (e) {
      if (mounted) {
        final msg = e is PostgrestException ? e.message : e.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to cancel travel plan: $msg'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  static const List<String> _wholePlanCancelReasons = [
    'Personal reason',
    'Vehicle problem',
    'Change of travel plan',
    'Emergency',
    'Unable to travel',
    'Other',
  ];

  /// Quick-delete entry point (the list-row trash icon) -- collects the required reason via the
  /// shared picker before calling _deleteTravelPlan, matching the confirmation + reason flow
  /// TravelPlanDetailsScreen._confirmDeletePlan already uses for its own delete action.
  Future<void> _confirmAndDeleteTravelPlan(String planId) async {
    final reason = await CancellationReasonDialog.show(
      context: context,
      title: 'Cancel Travel Plan',
      description: 'This cancels your entire travel plan. Any accepted passengers will be '
          'notified and their bookings cancelled. This cannot be undone.',
      reasons: _wholePlanCancelReasons,
      confirmLabel: 'Cancel Plan',
    );
    if (reason == null || reason.isEmpty) return;
    if (!mounted) return;
    await _deleteTravelPlan(planId, reason);
  }

  // ROOT CAUSE FIX (P0): this used to write order_status: 'completed' directly to the orders
  // table, reachable from any status with no delivery-OTP check at all -- skipping
  // credit_rider_for_completed_order, apply_order_government_tax, the intercity_requests/
  // travel-plan completion sync, and the order_status_history audit insert entirely, since none of
  // that lives here -- it only ever ran inside update-order-status, which this never called. Every
  // intercity parcel delivery through this screen paid the rider nothing. Now delegates to
  // complete_intercity_parcel_delivery(), a SECURITY DEFINER RPC that requires the order to already
  // be at 'rider_at_drop' (see _markRideArrived below) and verifies enteredOtp against
  // orders.delivery_otp server-side before applying the exact same settlement sequence
  // update-order-status's completion block applies for every other order type. See migration
  // 20260730000004_intercity_parcel_delivery_settlement.sql.
  Future<void> _completeParcel(Map<String, dynamic> request, String enteredOtp) async {
    final orderId = request['parcel_id'];
    setState(() => _loading = true);
    try {
      final response = await _rideDiagnosticOwner.api(RideEndpoint.intercityCompletion, orderId?.toString(), () => supabase.rpc('complete_intercity_parcel_delivery', params: {
        'p_order_id': orderId,
        'p_delivery_otp': enteredOtp,
      }), status: 'delivered');
      final data = response is Map ? Map<String, dynamic>.from(response) : null;
      if (data == null || data['success'] != true) {
        throw Exception((data?['message'] as String?) ?? 'Failed to complete delivery. Please try again.');
      }

      if (!mounted) return;

      // Issue 5 fix: complete_intercity_parcel_delivery() now only verifies the OTP and moves the
      // order to payment_pending -- it no longer settles/completes the delivery inline. Hand off
      // to the same payment-collection screen local rides/parcels already use (RiderActiveOrderScreen),
      // exactly like _verifyOtp's ride path above, so the traveller sees an explicit "Payment
      // Received?" confirmation before the delivery is actually marked complete.
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => RiderActiveOrderScreen(orderId: orderId)),
      );

      if (!mounted) return;
      await _fetchData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to complete delivery: ${e.toString().replaceAll("Exception: ", "")}'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ROOT CAUSE FIX: replaces a direct orders.update() that generated delivery_otp with
  // `(1000 + (9000 * (DateTime.now().millisecond / 1000))).round()` -- client-side, drawn from
  // only ~1000 possible values seeded by a clock reading, not cryptographically random. Now
  // delegates to mark_intercity_trip_at_dropoff(), a SECURITY DEFINER RPC that issues a real,
  // collision-checked, server-generated OTP (same generation pattern accept_intercity_request
  // already uses for pickup_otp) and validates the caller is the order's assigned rider before
  // writing anything. Shared by both ride and parcel bookings, matching the prior behavior -- for
  // rides, _verifyOtp's own downstream flow (payment_pending -> update-order-status) is unchanged.
  Future<void> _markRideArrived(Map<String, dynamic> request) async {
    final orderId = request['parcel_id'];
    setState(() => _loading = true);
    try {
      final response = await _rideDiagnosticOwner.api(RideEndpoint.intercityArrival, orderId?.toString(), () => supabase.rpc('mark_intercity_trip_at_dropoff', params: {
        'p_order_id': orderId,
      }), status: 'rider_at_drop');
      final data = response is Map ? Map<String, dynamic>.from(response) : null;
      if (data == null || data['success'] != true) {
        throw Exception((data?['message'] as String?) ?? 'Failed to mark arrived. Please try again.');
      }
      final newOtp = data['delivery_otp']?.toString() ?? '';

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Marked arrived! Completion OTP generated: $newOtp'), backgroundColor: Colors.green),
      );
      await _fetchData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to mark arrived: ${e.toString().replaceAll("Exception: ", "")}'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyOtp(Map<String, dynamic> request, String enteredOtp) async {
    final orderId = request['parcel_id'];
    setState(() => _loading = true);
    try {
      final orderRes = await _rideDiagnosticOwner.api(RideEndpoint.verificationRead, orderId?.toString(),
        () => supabase.from('orders').select('delivery_otp').eq('id', orderId).single());
      final correctOtp = orderRes['delivery_otp']?.toString();

      if (correctOtp != enteredOtp) {
        throw Exception("Invalid OTP. Please check with the passenger and try again.");
      }

      // Move to payment_pending via the guarded state machine (update-order-status), never a
      // direct table write -- a Travel Together ride is a payable order exactly like a local ride,
      // and must stop for fare collection before it can complete. This also makes the driver's
      // existing Personal QR / Cashfree QR / Cash collection screen (RiderActiveOrderScreen)
      // reachable for these rides, instead of the OTP silently completing the order for free.
      final response = await _rideDiagnosticOwner.api(RideEndpoint.status, orderId?.toString(), () => supabase.functions.invoke(
        'update-order-status',
        body: {'order_id': orderId, 'new_status': 'payment_pending'},
      ), status: 'payment_pending');
      final data = response.data is Map ? Map<String, dynamic>.from(response.data as Map) : null;
      if (data == null || data['success'] != true) {
        throw Exception((data?['error'] as String?) ?? 'Failed to confirm drop-off. Please try again.');
      }

      if (!mounted) return;

      // Hand off to the same payment-collection screen local rides already use. That screen's own
      // payment_pending -> completed transition (via update-order-status) is what actually
      // completes this order -- which also triggers the existing server-side travel-plan /
      // intercity_requests completion sync in update-order-status/index.ts, so no separate
      // client-side "_completeTravelPlanIfDone" call is needed here anymore.
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => RiderActiveOrderScreen(orderId: orderId)),
      );

      if (!mounted) return;
      await _fetchData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString().replaceAll("Exception: ", "")}'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Once a passenger's ride completes, auto-complete its Travel Plan when
  /// no other bookings against that plan are still pending/active — a
  /// Travel Plan can carry multiple seats, so it should only leave Active
  /// once every confirmed seat's trip has actually finished. This mirrors
  /// the existing intercity_parcel auto-complete behavior in the
  /// update-order-status edge function, which does not run for this
  /// direct-update ride-completion path.
  // ROOT CAUSE FIX: same weak-client-OTP issue as _markRideArrived, now delegates to
  // regenerate_intercity_delivery_otp() (server-generated, collision-checked, requires the caller
  // to be the assigned rider and the order to already be at 'rider_at_drop').
  Future<void> _resendOtp(Map<String, dynamic> request) async {
    final orderId = request['parcel_id'];
    setState(() => _loading = true);
    try {
      final response = await supabase.rpc('regenerate_intercity_delivery_otp', params: {
        'p_order_id': orderId,
      });
      final data = response is Map ? Map<String, dynamic>.from(response) : null;
      if (data == null || data['success'] != true) {
        throw Exception((data?['message'] as String?) ?? 'Failed to resend OTP. Please try again.');
      }
      final newOtp = data['delivery_otp']?.toString() ?? '';

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Completion OTP resent! (New OTP: $newOtp)'), backgroundColor: Colors.green),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to resend OTP: ${e.toString().replaceAll("Exception: ", "")}'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // isRide decides which server-side verification path VERIFY routes to: rides continue through
  // _verifyOtp (-> payment_pending -> update-order-status), parcels now go through _completeParcel
  // (-> complete_intercity_parcel_delivery, real server-side OTP check + full settlement) instead
  // of completing with no OTP check at all.
  void _showOtpDialog(Map<String, dynamic> request, {required bool isRide}) {
    final otpController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: darkCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Colors.white10)),
        title: const Text('Enter Passenger Completion OTP', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: otpController,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 8),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                hintText: '0000',
                hintStyle: const TextStyle(color: Colors.white24, letterSpacing: 8),
                filled: true,
                fillColor: darkBg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _resendOtp(request);
              },
              icon: const Icon(Icons.refresh, color: primaryLime, size: 16),
              label: const Text('Resend OTP / Regenerate Code', style: TextStyle(color: primaryLime, fontSize: 12)),
            )
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCEL', style: TextStyle(color: Colors.white30)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryLime,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              if (isRide) {
                _verifyOtp(request, otpController.text.trim());
              } else {
                _completeParcel(request, otpController.text.trim());
              }
            },
            child: const Text('VERIFY', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    ).then((_) => otpController.dispose());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        backgroundColor: darkCard,
        elevation: 0,
        title: const Text(
          'Intercity Dashboard',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: primaryLime,
          labelColor: primaryLime,
          unselectedLabelColor: textGray,
          tabs: const [
            Tab(text: 'Travel Plans'),
            Tab(text: 'Negotiations'),
            Tab(text: 'Upcoming'),
            Tab(text: 'Active'),
            Tab(text: 'History'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: primaryLime))
          : _wrongMode
              ? _buildEmptyState(
                  'Switch to Intercity Traveller mode in your Profile to use the Intercity Dashboard.',
                  Icons.tune_rounded,
                )
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildTravelPlansTab(),
                    _buildNegotiationsTab(),
                    _buildUpcomingTab(),
                    _buildActiveTab(),
                    _buildHistoryTab(),
                  ],
                ),
    );
  }

  Widget _buildEmptyState(String text, IconData icon) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: Colors.white12),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: textGray, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTravelPlansTab() {
    if (_travelPlans.isEmpty) {
      return _buildEmptyState('No active travel plans found. Post a travel plan from the home screen to start matching.', Icons.route_rounded);
    }
    return RefreshIndicator(
      onRefresh: _fetchData,
      color: primaryLime,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _travelPlans.length,
        itemBuilder: (context, index) => _buildPlanCard(_travelPlans[index]),
      ),
    );
  }

  /// Shared Travel Plan card — used for both the Active "Travel Plans" tab
  /// and the completed plans shown in the History tab.
  Widget _buildPlanCard(Map<String, dynamic> plan, {bool showDelete = true}) {
    final date = DateTime.parse(plan['travel_date']).toLocal();
    final dateStr = "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}";
    final timeStr = TimeFormatHelper.formatTime12Hour(date);
    final isRide = plan['travel_plan_type'] == 'ride';
    final status = plan['status']?.toString() ?? 'active';

    return GestureDetector(
      onTap: () => _openPlanDetails(plan),
      child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    isRide ? Icons.directions_car_rounded : Icons.all_inclusive_rounded,
                    color: primaryLime,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    plan['travel_plan_type']?.toString().toUpperCase() ?? 'BOTH',
                    style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              if (showDelete)
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
                  onPressed: () => _confirmAndDeleteTravelPlan(plan['id']),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    status.toUpperCase(),
                    style: const TextStyle(color: Colors.green, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${plan['pickup_city']} → ${plan['destination_city']}',
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today_rounded, color: textGray, size: 14),
                    const SizedBox(width: 4),
                    Text(dateStr, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    const Icon(Icons.access_time_rounded, color: textGray, size: 14),
                    const SizedBox(width: 4),
                    Text(timeStr, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(Icons.people_rounded, color: textGray, size: 14),
                    const SizedBox(width: 4),
                    Text('Max Bookings: ${plan['max_bookings']}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
              if (!isRide)
                Expanded(
                  child: Row(
                    children: [
                      const Icon(Icons.scale_rounded, color: textGray, size: 14),
                      const SizedBox(width: 4),
                      Text('Max Weight: ${plan['max_weight_kg'] ?? plan['weight_preference']} kg', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
      ),
    );
  }

  void _openPlanDetails(Map<String, dynamic> plan) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TravelPlanDetailsScreen(
          plan: plan,
          rider: {'id': _riderId},
          loadActiveOrder: (_) => _fetchData(),
          deleteTravelPlan: _deleteTravelPlan,
        ),
      ),
    ).then((_) => _fetchData());
  }

  Widget _buildNegotiationsTab() {
    if (_negotiations.isEmpty) {
      return _buildEmptyState('No active negotiations found.', Icons.question_answer_rounded);
    }
    return RefreshIndicator(
      onRefresh: _fetchData,
      color: primaryLime,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _negotiations.length,
        itemBuilder: (context, index) {
          final req = _negotiations[index];
          final order = req['orders'];
          final passengerName = order?['users']?['full_name'] ?? 'Passenger';
          // WHOLE-RUPEE FARE CONSISTENCY FIX: this card is for PENDING negotiations only (status
          // in request_sent/discussion_started/fare_agreed -- see _negotiations above), i.e.
          // strictly BEFORE acceptance. The "prefer order fare" rule from Phase 3/Issue 4 is
          // correct for the Active/Upcoming/History tabs (an ALREADY-accepted order's own fare is
          // always the freshest, e.g. after a post-acceptance boost) but was wrong here: at this
          // pre-acceptance stage the order's own current_fare is still whatever create-order
          // estimated at Travel Request time, while req['proposed_fare'] is the actually
          // up-to-date negotiated figure the rider is about to accept (accept_intercity_request()
          // rounds exactly this field into the order's authoritative fare). Preferring the stale
          // order fare here could show a completely different number than what acceptance will
          // actually produce. proposed_fare is raw/unrounded until acceptance, so it's rounded
          // here for DISPLAY ONLY (never written anywhere) via roundFareForDisplay() -- the same
          // canonical whole-rupee rounding accept_intercity_request() applies server-side -- so
          // this card already shows the exact amount the order will have the instant it's accepted.
          final proposedFare = roundFareForDisplay(
            double.tryParse(req['proposed_fare']?.toString() ?? '0') ?? 0.0,
          );
          final isRide = req['booking_type'] == 'ride';

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: darkCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: primaryLime.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        isRide ? 'RIDE' : 'PARCEL',
                        style: const TextStyle(color: primaryLime, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                    Text(
                      '₹$proposedFare',
                      style: const TextStyle(color: primaryLime, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Passenger: $passengerName',
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  'Route: ${order?['pickup_city'] ?? 'Pickup'} → ${order?['destination_city'] ?? 'Destination'}',
                  style: const TextStyle(color: textGray, fontSize: 12),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryLime,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => OrderChatScreen(
                                orderId: req['parcel_id'],
                                riderId: _riderId!,
                                chatTitle: passengerName,
                              ),
                            ),
                          ).then((_) => _fetchData());
                        },
                        icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                        label: const Text('Open Chat', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // Groups a flat list of intercity_requests rows by their Travel Plan (route_id) -- preserves the
  // first-seen order of plans (requests are already fetched newest-first).
  Map<String, List<Map<String, dynamic>>> _groupByPlan(List<Map<String, dynamic>> requests) {
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final req in requests) {
      final routeId = req['route_id']?.toString();
      if (routeId == null) continue;
      grouped.putIfAbsent(routeId, () => []).add(req);
    }
    return grouped;
  }

  // ROOT CAUSE FIX for "accepted requests appear as separate Upcoming cards, competing with the
  // Travel Plan they belong to": this tab previously rendered one flat card per accepted
  // intercity_requests row, each with its own independent "Start Trip" button -- so a plan with 2
  // accepted passengers showed as 2 separate "RIDE - CONFIRMED" cards with 2 separate Start Trip
  // actions, and looked entirely disconnected from the "Travel Plans" tab/Home section. Now every
  // accepted request is grouped by its Travel Plan (route_id) and rendered as ONE card per plan --
  // "N Accepted" + a single "View Trip" action that opens TravelPlanDetailsScreen, which is the
  // one and only place Start Trip and per-passenger Chat now live (removing this tab's duplicate
  // Start Trip button also removes the double-start race it created).
  Widget _buildUpcomingTab() {
    if (_upcomingTrips.isEmpty) {
      return _buildEmptyState('No upcoming trips found.', Icons.schedule_rounded);
    }
    final grouped = _groupByPlan(_upcomingTrips);
    final pendingByPlan = _groupByPlan(_negotiations);
    final planIds = grouped.keys.toList();

    return RefreshIndicator(
      onRefresh: _fetchData,
      color: primaryLime,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: planIds.length,
        itemBuilder: (context, index) {
          final routeId = planIds[index];
          final requests = grouped[routeId]!;
          final firstOrder = requests.first['orders'];
          final plan = requests.first['rider_travel_plans'] as Map<String, dynamic>?;
          final isRide = requests.first['booking_type'] == 'ride';
          final acceptedCount = requests.length;
          final pendingCount = pendingByPlan[routeId]?.length ?? 0;
          // Phase 3 fix (Issue 4): prefer each request's authoritative, always-fresh order fare.
          final totalFare = requests.fold<double>(
            0.0,
            (sum, r) => sum +
                (double.tryParse(
                      r['orders']?['final_fare']?.toString() ?? r['orders']?['current_fare']?.toString() ?? r['proposed_fare']?.toString() ?? '0',
                    ) ??
                    0.0),
          );

          return GestureDetector(
            onTap: plan == null ? null : () => _openPlanDetails(Map<String, dynamic>.from(plan)),
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: darkCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: primaryLime.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          isRide ? 'RIDE PLAN' : 'PARCEL PLAN',
                          style: const TextStyle(color: primaryLime, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                      Text(
                        // Phase 11 (Issue 1): whole-rupee format, matching the Pending tab's
                        // roundFareForDisplay() card above -- each summed fare is already
                        // whole-rupee (order.final_fare/current_fare preferred).
                        '₹${totalFare.toStringAsFixed(0)}',
                        style: const TextStyle(color: primaryLime, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Route: ${firstOrder?['pickup_city'] ?? plan?['pickup_city'] ?? 'Pickup'} → ${firstOrder?['destination_city'] ?? plan?['destination_city'] ?? 'Destination'}',
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: primaryLime.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '$acceptedCount Accepted',
                          style: const TextStyle(color: primaryLime, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                      if (pendingCount > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.orangeAccent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '$pendingCount Pending',
                            style: const TextStyle(color: Colors.orangeAccent, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryLime,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: plan == null ? null : () => _openPlanDetails(Map<String, dynamic>.from(plan)),
                      icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                      label: const Text('View Trip', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildActiveTab() {
    if (_activeTrips.isEmpty) {
      return _buildEmptyState('No active trips in transit.', Icons.local_shipping_outlined);
    }
    return RefreshIndicator(
      onRefresh: _fetchData,
      color: primaryLime,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _activeTrips.length,
        itemBuilder: (context, index) {
          final req = _activeTrips[index];
          final order = req['orders'];
          final passengerName = order?['users']?['full_name'] ?? 'Passenger';
          // Phase 3 fix (Issue 4): prefer the authoritative, always-fresh order fare.
          final fare = double.tryParse(
                order?['final_fare']?.toString() ?? order?['current_fare']?.toString() ?? req['proposed_fare']?.toString() ?? '0',
              ) ??
              0.0;
          final isRide = req['booking_type'] == 'ride';
          final status = req['status']?.toString();

          final orderStatus = order?['order_status']?.toString() ?? '';

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: darkCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: primaryLime.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        (isRide ? 'RIDE' : 'PARCEL') + ' - ' + orderStatus.toUpperCase(),
                        style: const TextStyle(color: primaryLime, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                    Text(
                      // Phase 11 (Issue 1): whole-rupee format, matching the rest of this screen.
                      '₹${fare.toStringAsFixed(0)}',
                      style: const TextStyle(color: primaryLime, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Passenger: $passengerName',
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  'Route: ${order?['pickup_city'] ?? 'Pickup'} → ${order?['destination_city'] ?? 'Destination'}',
                  style: const TextStyle(color: textGray, fontSize: 12),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white24),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => isRide
                                  ? RideTrackingScreen(orderId: req['parcel_id'])
                                  : ParcelTrackingScreen(orderId: req['parcel_id']),
                            ),
                          );
                        },
                        icon: const Icon(Icons.map_rounded, size: 16),
                        label: const Text('Track / Navigate'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryLime,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () {
                          // Phase 3 fix (Issue 5): intercity_parcel's drop-off (mandatory delivery-
                          // proof photo, then server-gated OTP generation) now lives exclusively in
                          // RiderActiveOrderScreen -- this screen has no photo-capture UI at all, so
                          // driving a parcel through _markRideArrived/_showOtpDialog directly would
                          // let it reach OTP entry without ever satisfying that requirement. Ride
                          // behavior (no photo-proof concept) is completely unchanged.
                          if (!isRide) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => RiderActiveOrderScreen(orderId: req['parcel_id'])),
                            ).then((_) => _fetchData());
                            return;
                          }
                          if (orderStatus == 'rider_at_drop') {
                            _showOtpDialog(req, isRide: isRide);
                          } else {
                            _markRideArrived(req);
                          }
                        },
                        icon: Icon(orderStatus == 'rider_at_drop' ? Icons.vpn_key_rounded : Icons.location_on_rounded, size: 16),
                        label: Text(orderStatus == 'rider_at_drop' ? 'Verify OTP' : 'Arrived', style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHistoryTab() {
    if (_completedPlans.isEmpty && _history.isEmpty) {
      return _buildEmptyState('No past history found.', Icons.history_rounded);
    }
    return RefreshIndicator(
      onRefresh: _fetchData,
      color: primaryLime,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_completedPlans.isNotEmpty) ...[
            const Text(
              'COMPLETED TRAVEL PLANS',
              style: TextStyle(color: textGray, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
            ),
            const SizedBox(height: 8),
            ..._completedPlans.map((p) => _buildPlanCard(p, showDelete: false)),
            const SizedBox(height: 16),
          ],
          if (_history.isNotEmpty) ...[
            const Text(
              'BOOKING HISTORY',
              style: TextStyle(color: textGray, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
            ),
            const SizedBox(height: 8),
            ..._history.map(_buildHistoryRequestCard),
          ],
        ],
      ),
    );
  }

  Widget _buildHistoryRequestCard(Map<String, dynamic> req) {
    final order = req['orders'];
    final passengerName = order?['users']?['full_name'] ?? 'Passenger';
    // Phase 3 fix (Issue 4): prefer the authoritative, always-fresh order fare.
    final fare = double.tryParse(
          order?['final_fare']?.toString() ?? order?['current_fare']?.toString() ?? req['proposed_fare']?.toString() ?? '0',
        ) ??
        0.0;
    final isRide = req['booking_type'] == 'ride';
    final status = req['status']?.toString();

    Color statusColor = textGray;
    if (status == 'completed') statusColor = Colors.green;
    if (status == 'cancelled' || status == 'rejected') statusColor = Colors.redAccent;
    if (status == 'expired') statusColor = Colors.orangeAccent;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  ((isRide ? 'RIDE' : 'PARCEL') + ' - ' + status!).toUpperCase(),
                  style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                // Phase 11 (Issue 1): whole-rupee format, matching the rest of this screen.
                '₹${fare.toStringAsFixed(0)}',
                style: TextStyle(color: status == 'completed' ? primaryLime : textGray, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Passenger: $passengerName',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text(
            'Route: ${order?['pickup_city'] ?? 'Pickup'} → ${order?['destination_city'] ?? 'Destination'}',
            style: const TextStyle(color: textGray, fontSize: 12),
          ),
          if (req['expiry_reason'] != null) ...[
            const SizedBox(height: 8),
            Text(
              'Expiry Reason: ${req['expiry_reason']}',
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 11, fontStyle: FontStyle.italic),
            ),
          ],
        ],
      ),
    );
  }
}
