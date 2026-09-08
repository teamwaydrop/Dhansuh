/// ============================================================================
/// File: travel_plan_details_screen.dart
///
/// Module:
/// Rider → Travel Plans
///
/// Purpose:
/// Detail view for an intercity travel plan.
///
/// Responsibilities:
/// • Display matching travel plans list, negotiate with customers, manage rider privacy route hides.
///
/// Related:
/// intercity_bookings_screen.dart
/// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/modules/support/screens/customer_support_screen.dart';
import 'package:waydrop/shared/helpers/location_display_service.dart';
import 'package:waydrop/shared/helpers/time_format_helper.dart';
import 'package:waydrop/modules/chat/screens/order_chat_screen.dart';
import 'package:waydrop/shared/widgets/maps/transport_map_widget.dart';
import 'package:waydrop/shared/widgets/cancellation_reason_dialog.dart';
import 'package:waydrop/features/rider/orders/screens/rider_active_order_screen.dart';
import 'package:waydrop/features/intercity/shared/services/intercity_matching_service.dart';
import 'package:waydrop/shared/helpers/fare_presentation_helper.dart';

class TravelPlanDetailsScreen extends StatefulWidget {
  final Map<String, dynamic> plan;
  final Map<String, dynamic>? rider;
  final bool isOnline;
  final dynamic activeOrder;
  final Future<void> Function(String) loadActiveOrder;
  // Issue 2: now takes the traveller-supplied cancellation reason as a required second argument
  // -- cancel_travel_plan_by_traveller() requires a non-empty reason server-side, so every caller
  // must collect one before invoking this (see _confirmDeletePlan below).
  final Future<void> Function(String planId, String reason) deleteTravelPlan;
  // Unused by this screen (matches are loaded via IntercityMatchingService.fetchIncomingRequestsForPlan
  // instead) — kept optional so callers that don't have a fetch/handle-order-action implementation of
  // their own (e.g. IntercityBookingsScreen) don't need to fabricate no-ops just to navigate here.
  final Future<List<Map<String, dynamic>>> Function(Map<String, dynamic>)? fetchMatchingOrders;
  final Future<void> Function(BuildContext, Map<String, dynamic>, StateSetter)? handleOrderAction;

  const TravelPlanDetailsScreen({
    super.key,
    required this.plan,
    required this.rider,
    this.isOnline = false,
    this.activeOrder,
    required this.loadActiveOrder,
    required this.deleteTravelPlan,
    this.fetchMatchingOrders,
    this.handleOrderAction,
  });

  @override
  State<TravelPlanDetailsScreen> createState() => _TravelPlanDetailsScreenState();
}

class _TravelPlanDetailsScreenState extends State<TravelPlanDetailsScreen> with WidgetsBindingObserver {
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> matches = [];
  bool loading = true;
  bool accepting = false;
  String? acceptingOrderId;
  bool startingTrip = false;
  // Egress fix: migrated from 3 raw supabase.channel() calls to RealtimeManager -- each pools
  // with the identical rider-wide subscription IntercityBookingsScreen/RiderHomeTab/
  // RiderOrdersScreen already hold (this screen is reached via a push from
  // IntercityBookingsScreen, which stays mounted underneath, so both are live concurrently).
  String? _matchesSubChannel;
  String? _matchesSubId;
  Map<String, Map<String, dynamic>> intercityRequests = {};
  String? _requestsSubChannel;
  String? _requestsSubId;
  String? _ordersSubChannel;
  String? _ordersSubId;
  Timer? _requestsDebounceTimer;

  static const Color darkBg = Color(0xFF0F1115);
  static const Color darkCard = Color(0xFF171A21);
  static const Color primaryLime = Color(0xFFC5FF30);
  static const Color textGray = Color(0xFFA9B0BE);

  String formatRelativeDate(DateTime dateTime) {
    final now = DateTime.now().toLocal();
    final localDt = dateTime.toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final compareDate = DateTime(localDt.year, localDt.month, localDt.day);

    final hourVal = localDt.hour;
    final amPm = hourVal >= 12 ? 'PM' : 'AM';
    final hour12 = hourVal % 12 == 0 ? 12 : hourVal % 12;
    final minute = localDt.minute.toString().padLeft(2, '0');
    final timeStr = "$hour12:$minute $amPm";

    if (compareDate.isAtSameMomentAs(today)) {
      return "Today • $timeStr";
    } else if (compareDate.isAtSameMomentAs(tomorrow)) {
      return "Tomorrow • $timeStr";
    } else {
      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return "${localDt.day} ${months[localDt.month - 1]} • $timeStr";
    }
  }

  double getVehicleAverageSpeed(String? vehicleType) {
    final vt = (vehicleType ?? 'cab').toLowerCase();
    if (vt == 'bike') return 55.0;
    if (vt == 'auto') return 40.0;
    if (vt == 'car' || vt == 'cab') return 65.0;
    return 60.0;
  }

  DateTime estimateArrivalTime(DateTime departureTime, double distanceKm, String? vehicleType) {
    final speed = getVehicleAverageSpeed(vehicleType);
    final hours = distanceKm / speed;
    return departureTime.add(Duration(minutes: (hours * 60).round()));
  }

  String getCityCode(String? cityName) {
    if (cityName == null || cityName.trim().isEmpty) return 'LOC';
    final clean = cityName.trim().toUpperCase();
    if (clean.length >= 3) {
      return clean.substring(0, 3);
    }
    return clean;
  }

  String formatRuns(int runs) {
    if (runs >= 999) return "999+ Runs";
    return "$runs Runs";
  }

  Widget _buildMapMarkerNode({required bool isPickup}) {
    final color = isPickup ? primaryLime : Colors.redAccent;
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withOpacity(0.12),
        border: Border.all(color: color, width: 2),
      ),
      child: Center(
        child: Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
        ),
      ),
    );
  }

  Widget _buildSpecTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.04), width: 1),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: primaryLime.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: primaryLime, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: textGray,
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoBadge({required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.04), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: primaryLime.withOpacity(0.8), size: 12),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.18), width: 1),
      ),
      child: IconButton(
        icon: Icon(icon, color: color, size: 20),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required Color color,
    required Color textColor,
    required bool isLoading,
    required VoidCallback? onPressed,
  }) {
    final bool isAccent = color == primaryLime;
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: textColor,
          disabledBackgroundColor: Colors.white.withOpacity(0.04),
          disabledForegroundColor: Colors.white.withOpacity(0.15),
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: isAccent
                ? BorderSide.none
                : BorderSide(color: Colors.white.withOpacity(0.06), width: 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        child: isLoading
            ? SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(
                  color: isAccent ? Colors.black : primaryLime,
                  strokeWidth: 2,
                ),
              )
            : Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                  color: onPressed == null ? Colors.white.withOpacity(0.2) : textColor,
                  letterSpacing: 0.2,
                ),
              ),
      ),
    );
  }

  @override
  // Lifecycle method called once when the stateful widget initialized for the first time
  void initState() {
    // Lifecycle method called once when the stateful widget initialized for the first time
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMatches();
    _loadIntercityRequests();
    _subscribeMatches();
    _subscribeRequests();
    _subscribeOrders();
  }

  @override
  // Item 3 fix: realtime subscriptions cover live updates, but a socket can legitimately drop
  // while the app is backgrounded -- on resume, reconcile this screen with DB truth the same way
  // activity_tab.dart/home_tab.dart already do elsewhere in this app, instead of trusting whatever
  // stale state was left on screen.
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _loadMatches();
      _loadIntercityRequests();
    }
  }

  @override
  // Lifecycle method called before the widget is removed permanently from the tree to clean resources
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _requestsDebounceTimer?.cancel();
    if (_matchesSubChannel != null && _matchesSubId != null) {
      RealtimeManager.instance.unsubscribe(_matchesSubChannel!, _matchesSubId!);
    }
    if (_requestsSubChannel != null && _requestsSubId != null) {
      RealtimeManager.instance.unsubscribe(_requestsSubChannel!, _requestsSubId!);
    }
    if (_ordersSubChannel != null && _ordersSubId != null) {
      RealtimeManager.instance.unsubscribe(_ordersSubChannel!, _ordersSubId!);
    }
    // Lifecycle method called before the widget is removed permanently from the tree to clean resources
    super.dispose();
  }

  Future<void> _loadMatches() async {
    try {
      final list = await IntercityMatchingService.fetchIncomingRequestsForPlan(
        planId: widget.plan['id'].toString(),
        riderId: widget.plan['rider_id'].toString(),
      );
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          matches = list;
          loading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading matching orders: $e');
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          loading = false;
        });
      }
    }
  }

  Future<void> _loadIntercityRequests() async {
    try {
      // Egress fix: narrowed to the fields read off `req`/`intercityRequests[...]` throughout this
      // file (grepped exhaustively), plus parcel_id (the map key below).
      final res = await supabase
          .from('intercity_requests')
          .select('id, status, initiated_by, proposed_fare, parcel_id')
          .eq('traveller_id', widget.plan['rider_id'])
          .eq('route_id', widget.plan['id']);
      final Map<String, Map<String, dynamic>> newReqs = {};
      for (final row in res) {
        newReqs[row['parcel_id'].toString()] = Map<String, dynamic>.from(row);
      }
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          intercityRequests = newReqs;
        });
      }
    } catch (e) {
      debugPrint('Error loading intercity requests: $e');
    }
  }

  // Egress fix: pools with the identical rider-wide 'rider-assignments-$riderId' channel
  // RiderHomeTab/RiderOrdersScreen already share instead of a screen-local raw channel.
  void _subscribeMatches() {
    final riderId = widget.plan['rider_id'].toString();
    _matchesSubChannel = 'rider-assignments-$riderId';
    _matchesSubId = RealtimeManager.instance.subscribe(
      channelName: _matchesSubChannel!,
      table: 'rider_assignments',
      owner: 'TravelPlanDetailsScreen_Matches',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'rider_id',
      filterValue: riderId,
      callback: (payload) {
        if (!mounted) return;
        _loadMatches();
      },
    );
  }

  // Egress fix: pools with IntercityBookingsScreen's identical intercity_requests
  // (traveller_id=riderId, event=all) subscription instead of a screen-local raw channel.
  void _subscribeRequests() {
    final riderId = widget.plan['rider_id'].toString();
    _requestsSubChannel = 'rider-intercity-requests-$riderId';
    _requestsSubId = RealtimeManager.instance.subscribe(
      channelName: _requestsSubChannel!,
      table: 'intercity_requests',
      owner: 'TravelPlanDetailsScreen_Requests',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'traveller_id',
      filterValue: riderId,
      callback: (payload) {
        if (!mounted) return;
        // Egress fix: a burst of related events previously ran both loads per event with no
        // coalescing -- 500ms-debounced, same pattern used elsewhere in the app for the identical
        // "realtime event -> full reload" situation.
        _requestsDebounceTimer?.cancel();
        _requestsDebounceTimer = Timer(const Duration(milliseconds: 500), () {
          if (!mounted) return;
          _loadIntercityRequests();
          _loadMatches();
        });
      },
    );
  }

  // Egress fix: pools with the rider-wide 'rider-active-order-$riderId' channel
  // RiderHomeTab/RiderOrdersScreen/IntercityBookingsScreen already share for this exact
  // table/filter -- RealtimeManager requires an exact event match to pool, so this widens from
  // `update` to `all`; safe because orders are always created with rider_id still null and are
  // never deleted, so INSERT/DELETE can never actually fire for this filter (same invariant the
  // sibling screens' merge already relies on). Callback behavior (the `matches`-containment check)
  // is unchanged -- payload.newRecord is populated identically for an UPDATE regardless of the
  // channel's declared event breadth.
  void _subscribeOrders() {
    final riderId = widget.plan['rider_id'].toString();
    _ordersSubChannel = 'rider-active-order-$riderId';
    _ordersSubId = RealtimeManager.instance.subscribe(
      channelName: _ordersSubChannel!,
      table: 'orders',
      owner: 'TravelPlanDetailsScreen_Orders',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'rider_id',
      filterValue: riderId,
      callback: (payload) {
        if (!mounted) return;
        final newRec = payload.newRecord;
        if (newRec.isEmpty) return;
        final orderId = newRec['id']?.toString();
        final containsOrder = matches.any((m) => m['id']?.toString() == orderId);
        if (containsOrder) {
          _loadMatches();
        }
      },
    );
  }

  Future<void> _acceptIntercityRequest(String reqId, String orderId) async {
    final rId = widget.rider?['id']?.toString() ?? '';
    // Update the widget state to trigger a UI rebuild with the new variables
    setState(() {
      accepting = true;
      acceptingOrderId = orderId;
    });

    try {
      Map<String, dynamic>? data;
      try {
        // Perform an asynchronous database operation using the Supabase client wrapper
        final response = await supabase.functions.invoke(
          'accept-intercity-request',
          body: {
            'request_id': reqId,
          },
        );
        data = response.data is Map<String, dynamic> ? response.data as Map<String, dynamic> : null;
      } on FunctionException catch (fe) {
        // The edge function returns a non-2xx status for known failure codes (e.g.
        // ORDER_ALREADY_ASSIGNED), so supabase_flutter throws before `response.data` is reachable.
        // Recover the structured {code, message} body from `.details` the same way
        // rider_orders_screen.dart's _getExceptionMessage does, so the mapping below still applies.
        final details = fe.details;
        if (details is Map) {
          data = Map<String, dynamic>.from(details);
        } else if (details is String) {
          try {
            data = Map<String, dynamic>.from(jsonDecode(details) as Map);
          } catch (_) {
            data = null;
          }
        }
      }

      if (data == null || data['success'] != true) {
        final code = data?['code']?.toString() ?? 'ERROR';
        String msg = 'Failed to accept booking';
        if (code == 'ORDER_ALREADY_ASSIGNED') {
          msg = 'This request has already been accepted by another traveller.';
        } else if (code == 'REQUEST_EXPIRED') {
          msg = 'This request has expired.';
        } else if (code == 'TRAVEL_PLAN_INACTIVE') {
          msg = 'Your travel plan is no longer active.';
        } else if (code == 'PLAN_FULLY_BOOKED') {
          msg = 'This travel plan is fully booked. No seats remaining.';
        } else if (code == 'RIDER_ALREADY_BUSY') {
          msg = 'You cannot accept because you have another active order.';
        } else if (code == 'PASSENGER_ALREADY_CONFIRMED') {
          msg = 'Passenger already confirmed another trip.';
        } else if (code == 'INVALID_REQUEST') {
          msg = 'Invalid request configuration.';
        } else if (data?['message'] != null) {
          msg = data!['message'].toString();
        }
        throw Exception(msg);
      }

      await _loadIntercityRequests();
      await widget.loadActiveOrder(rId);

      if (mounted) {
        // Stay on the Travel Plan -- it's the primary object the Drop Partner is managing, not a
        // screen to be navigated away from the moment one request is accepted. _loadIntercityRequests
        // above already refreshed this same screen's own Accepted Users list, so the newly accepted
        // booking shows up here, still attached to its plan. The dialog's OK button only dismisses
        // itself -- it must never navigate away from this Travel Plan Details page.
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: darkCard,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withOpacity(0.08), width: 1),
            ),
            title: const Text(
              'Request Accepted',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            content: const Text(
              'Booking accepted! It stays listed under this Travel Plan.',
              style: TextStyle(color: textGray, fontSize: 13, height: 1.4),
            ),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryLime,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      }
    } catch (e, stackTrace) {
      // Phase 5 F2: non-fatal Crashlytics report for a genuinely unexpected acceptance failure --
      // the routine "already accepted by another traveller"/expired/inactive/busy/conflict outcomes
      // (all thrown as a plain Exception(msg) above) are expected business behavior, not reported
      // here to avoid noise, matching the same filter already used for local accept-order. Purely
      // additive -- does not affect the existing SnackBar behavior below.
      final msg = e.toString();
      final isKnownBenignOutcome = msg.contains('already been accepted by another traveller') ||
          msg.contains('This request has expired') ||
          msg.contains('travel plan is no longer active') ||
          msg.contains('fully booked') ||
          msg.contains('another active order') ||
          msg.contains('already confirmed another trip');
      if (!isKnownBenignOutcome) {
        FirebaseCrashlytics.instance.recordError(
          e,
          stackTrace,
          reason: 'accept-intercity-request failed',
          information: ['requestId/orderId: see message'],
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll('Exception:', '').trim()),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          accepting = false;
          acceptingOrderId = null;
        });
      }
    }
  }

  // Item 3: plan-level Start Trip -- one press starts every paid-and-not-yet-started passenger
  // under this plan via start_intercity_trip_for_plan, instead of requiring a separate
  // "Start Transit" press inside each passenger's own bottom sheet.
  Future<void> _startTripForPlan() async {
    final routeId = widget.plan['id']?.toString();
    if (routeId == null) return;

    setState(() => startingTrip = true);
    try {
      final response = await supabase.rpc('start_intercity_trip_for_plan', params: {'p_route_id': routeId});
      final data = Map<String, dynamic>.from(response as Map);
      if (data['success'] != true) {
        throw Exception(data['message']?.toString() ?? 'Unable to start trip.');
      }

      await _loadIntercityRequests();
      await widget.loadActiveOrder(widget.plan['rider_id']);

      if (mounted) {
        final startedCount = (data['order_ids'] as List?)?.length ?? 0;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Trip started for $startedCount passenger${startedCount == 1 ? '' : 's'}.'),
            backgroundColor: const Color(0xFF22C55E),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll('Exception:', '').trim()),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => startingTrip = false);
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

  Future<void> _confirmDeletePlan(BuildContext context, Map<String, dynamic> plan) async {
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

    // deleteTravelPlan (cancel_travel_plan_by_traveller under the hood) is the single source of
    // truth for both success and failure -- including the TRIP_ALREADY_STARTED refusal -- so this
    // screen shows whatever it reports rather than assuming success here.
    await widget.deleteTravelPlan(plan['id'], reason);
    if (mounted) {
      // Close/pop the current screen or modal bottom sheet context
      Navigator.pop(context); // Go back home after deletion
    }
  }

  void _viewFullScreenImage(BuildContext context, String imageUrl) {
    // Show an overlay dialog window on the screen for user decision
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.9),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
                placeholder: (_, __) => const Center(
                  child: CircularProgressIndicator(color: Colors.white54),
                ),
                errorWidget: (_, _, _) => const Center(
                  child: Icon(Icons.broken_image_rounded, size: 48, color: Colors.white30),
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.of(ctx).padding.top + 16,
              right: 16,
              child: GestureDetector(
                // Close/pop the current screen or modal bottom sheet context
                onTap: () => Navigator.pop(ctx),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded, color: Colors.white, size: 24),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showRoutePreviewBottomSheet(BuildContext context, Map<String, dynamic> order) {
    final double? pickupLat = double.tryParse(order['pickup_lat']?.toString() ?? '');
    final double? pickupLng = double.tryParse(order['pickup_lng']?.toString() ?? '');
    final double? destLat = double.tryParse(order['destination_lat']?.toString() ?? '');
    final double? destLng = double.tryParse(order['destination_lng']?.toString() ?? '');

    if (pickupLat == null || pickupLng == null || destLat == null || destLng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid route coordinates for this order.')),
      );
      return;
    }

    // Present a premium modal bottom sheet drawer for user input/actions
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: darkBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.65,
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            children: [
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Route Preview',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                      // Close/pop the current screen or modal bottom sheet context
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  child: _LazyRouteMap(
                    pickupLat: pickupLat,
                    pickupLng: pickupLng,
                    destinationLat: destLat,
                    destinationLng: destLng,
                    isDark: true,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Item 1 fix: once the trip has started, "Directions" must open the existing canonical
  // active-order/trip screen for THIS specific accepted order -- never launch Google Maps
  // directly from here. RiderActiveOrderScreen self-loads by orderId (see its own loadOrder()),
  // so pushing it here always resolves the correct passenger/parcel's own order, even when a
  // Travel Plan has multiple accepted passengers, since each card/order in this list carries its
  // own distinct order['id'] scoped per itemBuilder iteration. That screen already owns its own
  // "Directions on Maps" external-navigation button (rider_active_order_screen.dart's
  // _openExternalGoogleMaps) plus SWIPE TO ARRIVE/Call/Chat/Cancel Ride -- this never duplicates
  // that as a second, fake tracking surface.
  void _openActiveOrderScreen(String orderId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RiderActiveOrderScreen(orderId: orderId),
      ),
    );
  }

  // WayDrop Intercity is strictly User-initiated: this list (`matches`, from
  // IntercityMatchingService.fetchIncomingRequestsForPlan) only ever contains orders that already
  // have an `intercity_requests` row for this plan, so `req` is never actually null here — this is
  // a defensive fallback only, not a reverse Traveller-initiated "send offer" action (removed).
  Widget _buildSheetActionButton(Map<String, dynamic> order, Map<String, dynamic>? req) {
    final orderId = order['id'];
    final isThisAccepting = accepting && acceptingOrderId == orderId;

    if (req == null) {
      return const SizedBox.shrink();
    }

    final reqStatus = req['status']?.toString() ?? 'request_sent';
    String btnLabel = 'Offer Sent';
    Color btnColor = Colors.white.withOpacity(0.04);
    Color txtColor = Colors.white.withOpacity(0.3);
    VoidCallback? onBtnPressed;

    if ((reqStatus == 'request_sent' || reqStatus == 'discussion_started' || reqStatus == 'fare_agreed') &&
        req['initiated_by'] == 'sender') {
      // Passenger sent this request -> it's this traveller's turn to Accept/Reject (matches
      // accept_intercity_request's eligible statuses server-side).
      // Phase 3 fix (Issue 4): prefer the authoritative, always-fresh order fare (kept correct by
      // boost-order-fare) over the denormalized proposed_fare snapshot, which could be stale if a
      // boost happened after the request was sent.
      // Phase 11 (Issue 1): order['final_fare']/['current_fare'] are already whole-rupee (set by
      // calculate_fare_breakdown()); req['proposed_fare'] is the raw, unrounded negotiated figure
      // that only becomes whole-rupee once accept_intercity_request() rounds it -- displaying it
      // raw here showed e.g. "₹65.79" on this exact button, then "₹66.00" everywhere after accept.
      // roundFareForDisplay() shows the same whole-rupee amount the order will have the instant
      // this button is tapped.
      final amt = order['final_fare'] != null || order['current_fare'] != null
          ? (order['final_fare'] ?? order['current_fare']).toString()
          : roundFareForDisplay(double.tryParse(req['proposed_fare']?.toString() ?? '0') ?? 0.0).toString();
      btnLabel = 'Accept Request (₹$amt)';
      btnColor = const Color(0xFF22C55E); // Green accept button
      txtColor = Colors.white;
      onBtnPressed = () {
        _acceptIntercityRequest(req['id'].toString(), orderId);
        // Close/pop the current screen or modal bottom sheet context
        Navigator.pop(context);
      };
    } else if (reqStatus == 'request_sent') {
      btnLabel = 'Offer Sent (Pending)';
      btnColor = Colors.white.withOpacity(0.04);
      txtColor = Colors.white.withOpacity(0.3);
    } else if (reqStatus == 'discussion_started' || reqStatus == 'fare_agreed') {
      btnLabel = 'Awaiting Client Response';
      btnColor = Colors.white.withOpacity(0.04);
      txtColor = Colors.white.withOpacity(0.3);
    } else if (reqStatus == 'confirmed' || reqStatus == 'paid') {
      // Item 3: Start Trip is now a single plan-level action (the "Start Trip" button on the main
      // screen, calling start_intercity_trip_for_plan) instead of a per-passenger button here —
      // this row is a passive status until the traveller presses that button. Item 1 (business
      // rule): 'confirmed' already means ready to start -- payment happens after the trip
      // completes, not before, so this is never "awaiting payment".
      btnLabel = 'Ready to Start';
      btnColor = primaryLime.withOpacity(0.15);
      txtColor = primaryLime;
    } else if (reqStatus == 'in_progress') {
      // Item 1 fix: this used to launch Google Maps directly (_openDirectionsForOrder), skipping
      // the canonical active-order/trip screen entirely. Now it opens RiderActiveOrderScreen for
      // THIS accepted order -- the same screen reachable via "VIEW ORDER" right after accept --
      // which owns its own "Directions on Maps" external-navigation button plus SWIPE TO ARRIVE/
      // Call/Chat/Cancel, instead of duplicating a second, fake tracking surface here.
      btnLabel = 'Directions';
      btnColor = Colors.blueAccent;
      txtColor = Colors.white;
      onBtnPressed = () => _openActiveOrderScreen(orderId.toString());
    } else if (reqStatus == 'completed') {
      btnLabel = 'Trip Completed';
      btnColor = Colors.white.withOpacity(0.04);
      txtColor = Colors.white.withOpacity(0.3);
    } else if (reqStatus == 'cancelled') {
      btnLabel = 'Request Cancelled';
      btnColor = Colors.red.withOpacity(0.12);
      txtColor = Colors.redAccent;
    } else if (reqStatus == 'rejected') {
      btnLabel = 'Request Rejected';
      btnColor = Colors.red.withOpacity(0.12);
      txtColor = Colors.redAccent;
    }

    // Reject is only offered while it's the rider's turn to decide on a passenger-initiated
    // request (Parts 12/14) — mirrors exactly when the Accept button above is shown.
    final canReject = (reqStatus == 'request_sent' || reqStatus == 'discussion_started' || reqStatus == 'fare_agreed') &&
        req['initiated_by'] == 'sender';

    // Issue 4: an already-accepted-but-not-yet-started passenger/parcel can be cancelled
    // individually, without touching the travel plan itself or any other accepted passenger.
    // Distinct from _deleteTravelPlan (intercity_bookings_screen.dart), which cancels the entire
    // plan and is correctly refused once any trip is in_progress -- this only ever targets ONE
    // request via cancel_intercity_request_by_traveller, and only while it's still
    // confirmed/paid (not yet in_progress).
    final canCancelAccepted = reqStatus == 'confirmed' || reqStatus == 'paid';

    final primaryButton = SizedBox(
      width: double.infinity,
      height: 48,
      child: _buildActionButton(
        label: btnLabel,
        color: btnColor,
        textColor: txtColor,
        isLoading: isThisAccepting,
        onPressed: onBtnPressed,
      ),
    );

    if (canReject) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          primaryButton,
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: _buildActionButton(
              label: 'Reject Request',
              color: Colors.white.withOpacity(0.06),
              textColor: Colors.redAccent,
              isLoading: false,
              onPressed: () async {
                try {
                  await IntercityMatchingService.rejectTravelTogetherRequest(
                    requestId: req['id'].toString(),
                    actorType: 'traveller',
                  );
                } catch (e) {
                  debugPrint('Error rejecting request: $e');
                }
                if (mounted) {
                  Navigator.pop(context);
                  _loadIntercityRequests();
                }
              },
            ),
          ),
        ],
      );
    }

    if (canCancelAccepted) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          primaryButton,
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: _buildActionButton(
              label: 'Cancel This Passenger',
              color: Colors.white.withOpacity(0.06),
              textColor: Colors.redAccent,
              isLoading: false,
              onPressed: () => _cancelAcceptedPassenger(req['id'].toString()),
            ),
          ),
        ],
      );
    }

    return primaryButton;
  }

  /// Issue 4: prompts for a cancellation reason, then cancels ONE accepted passenger/parcel via
  /// cancel_intercity_request_by_traveller -- the travel plan and every other accepted passenger
  /// are left completely untouched. The passenger's own notification and the plan's
  /// fully_booked->active revival (if this frees the last full seat) both happen server-side via
  /// existing triggers, not from this client code.
  static const List<String> _individualCancelReasons = [
    'Passenger was rude',
    'Passenger was uncooperative',
    'Passenger changed plans',
    'Did not follow instructions',
    'Safety concern',
    'Other',
  ];

  Future<void> _cancelAcceptedPassenger(String requestId) async {
    final reason = await CancellationReasonDialog.show(
      context: context,
      title: 'Cancel This Passenger',
      description:
          'This only cancels this passenger\'s booking. Your travel plan and any other accepted passengers stay active.',
      reasons: _individualCancelReasons,
      confirmLabel: 'Cancel Passenger',
    );

    if (reason == null || reason.isEmpty) return;
    if (!mounted) return;

    try {
      final result = await IntercityMatchingService.cancelAcceptedPassengerRequest(
        requestId: requestId,
        cancelReason: reason,
      );
      if (!mounted) return;
      if (result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Passenger cancelled.'), backgroundColor: Colors.green),
        );
        _loadIntercityRequests();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text((result['message'] as String?) ?? 'Could not cancel this passenger.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error cancelling accepted passenger request: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not cancel this passenger. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showOrderDetailsBottomSheet(
    BuildContext context, 
    Map<String, dynamic> order, {
    Map<String, dynamic>? req,
    Widget? actionButton,
  }) {
    final isParcel = order['order_type']?.toString().contains('parcel') ?? false;
    final date = order['travel_date'] != null ? DateTime.tryParse(order['travel_date'].toString())?.toLocal() : null;
    final dateStr = date != null ? TimeFormatHelper.formatDateTime12Hour(date) : 'Anytime';
    final actualFare = double.tryParse(order['current_fare']?.toString() ?? order['actual_fare']?.toString() ?? '0') ?? 0.0;
    
    final reqStatus = req?['status']?.toString();
    final isAccepted = reqStatus == 'confirmed' || reqStatus == 'paid' || reqStatus == 'in_progress' || reqStatus == 'completed';

    final phone = order['users']?['phone']?.toString() ?? 'N/A';
    // Passenger identity (name/gender/photo/rating/completed trips) is shown at the request
    // stage so the traveller knows who they'd be serving before deciding to accept -- this
    // mirrors Uber/Rapido, which always shows the rider's name/photo/rating pre-accept. Contact
    // info (phone) and the exact pickup/drop address stay hidden until accepted.
    final senderName = order['users']?['full_name']?.toString() ?? 'Passenger';
    final senderGender = order['users']?['gender']?.toString();
    final senderPhotoUrl = order['users']?['profile_photo_url']?.toString();
    final senderRating = double.tryParse((order['users']?['rating'] ?? 5.0).toString()) ?? 5.0;
    final senderCompletedTrips = int.tryParse(order['users']?['completed_trips']?.toString() ?? '') ?? 0;

    final displaySenderName = senderName;
    final displayPhone = isAccepted ? phone : 'Hidden until accepted';

    final pickupCity = LocationDisplayService.resolveCity(city: order['pickup_city'], address: order['pickup_address'], fallback: 'Pickup');
    final destCity = LocationDisplayService.resolveCity(city: order['destination_city'], address: order['destination_address'], fallback: 'Destination');
    // Item 2 fix: the traveller needs the exact pickup/drop address BEFORE deciding to accept a
    // request, not only after -- this mirrors passenger identity (name/gender/photo/rating) above,
    // which was already shown pre-accept. Only contact info (phone) stays gated behind acceptance.
    // Falls back to the resolved city label only if this order genuinely has no street address on
    // file, never synthesizes one.
    final pickupAddrRaw = order['pickup_address']?.toString().trim() ?? '';
    final destAddrRaw = order['destination_address']?.toString().trim() ?? '';
    final displayPickupAddr = pickupAddrRaw.isNotEmpty ? pickupAddrRaw : pickupCity;
    final displayDestAddr = destAddrRaw.isNotEmpty ? destAddrRaw : destCity;

    final rawImages = order['parcel_images'];
    List<String> parcelImages = [];
    if (rawImages is List) {
      parcelImages = rawImages.map((e) => e.toString()).toList();
    } else if (rawImages is String && rawImages.isNotEmpty) {
      try {
        final parsed = jsonDecode(rawImages);
        if (parsed is List) {
          parcelImages = parsed.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }

    // Present a premium modal bottom sheet drawer for user input/actions
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: darkBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.6,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  
                  const SizedBox(height: 12),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: primaryLime.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            isParcel ? 'Parcel Delivery' : 'Passenger Ride',
                            style: const TextStyle(color: primaryLime, fontSize: 11, fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      Text(
                        // Phase 11 (Issue 1): whole-rupee format, matching every other fare
                        // display in this screen -- current_fare/actual_fare here are already
                        // whole-rupee (create-order rounds the booking-time estimate), only the
                        // ".00" suffix was inconsistent.
                        '₹${actualFare.toStringAsFixed(0)}',
                        style: const TextStyle(color: primaryLime, fontSize: 22, fontWeight: FontWeight.w900),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  
                  const Text('ROUTE DETAILS', style: TextStyle(color: textGray, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: darkCard,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.04), width: 1),
                    ),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Column(
                            children: [
                              const SizedBox(height: 4),
                              _buildMapMarkerNode(isPickup: true),
                              Expanded(
                                child: Container(
                                  width: 1.5,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [primaryLime.withOpacity(0.6), Colors.redAccent.withOpacity(0.6)],
                                    ),
                                  ),
                                ),
                              ),
                              _buildMapMarkerNode(isPickup: false),
                              const SizedBox(height: 4),
                            ],
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  pickupCity,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                                const SizedBox(height: 2),
                                Text(displayPickupAddr, style: const TextStyle(color: textGray, fontSize: 12)),
                                const SizedBox(height: 20),
                                Text(
                                  destCity,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                                const SizedBox(height: 2),
                                Text(displayDestAddr, style: const TextStyle(color: textGray, fontSize: 12)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  const Text('TRAVEL INFO', style: TextStyle(color: textGray, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: darkCard,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.04), width: 1),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Travel Date/Time', style: TextStyle(color: textGray, fontSize: 13)),
                            Text(dateStr, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: Container(height: 1, color: Colors.white.withOpacity(0.04)),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Distance', style: TextStyle(color: textGray, fontSize: 13)),
                            Text(
                              '${order['distance_km'] ?? (order['distance_meters'] != null ? (double.tryParse(order['distance_meters'].toString()) ?? 0.0) / 1000.0 : 0.0)} km',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: Container(height: 1, color: Colors.white.withOpacity(0.04)),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Vehicle Mode', style: TextStyle(color: textGray, fontSize: 13)),
                            Text(order['vehicle_type']?.toString().toUpperCase() ?? 'ANY', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                          ],
                        ),
                        if (isParcel) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8.0),
                            child: Container(height: 1, color: Colors.white.withOpacity(0.04)),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Weight Category', style: TextStyle(color: textGray, fontSize: 13)),
                              Text(
                                () {
                                  final wc = order['weight_category']?.toString();
                                  if (wc == null) return 'N/A';
                                  final double? parsed = double.tryParse(wc);
                                  return '${parsed?.round() ?? wc} kg';
                                }(),
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  const Text('PASSENGER DETAILS', style: TextStyle(color: textGray, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: darkCard,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.04), width: 1),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 24,
                              backgroundColor: Colors.white.withOpacity(0.06),
                              backgroundImage: (senderPhotoUrl != null && senderPhotoUrl.isNotEmpty)
                                  ? NetworkImage(senderPhotoUrl)
                                  : null,
                              child: (senderPhotoUrl == null || senderPhotoUrl.isEmpty)
                                  ? const Icon(Icons.person_rounded, color: textGray, size: 22)
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    displaySenderName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                                  ),
                                  const SizedBox(height: 3),
                                  Row(
                                    children: [
                                      Icon(
                                        senderGender == 'female'
                                            ? Icons.female_rounded
                                            : senderGender == 'male'
                                                ? Icons.male_rounded
                                                : Icons.wc_rounded,
                                        color: textGray,
                                        size: 13,
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        senderGender == 'male' ? 'Male' : senderGender == 'female' ? 'Female' : senderGender == 'other' ? 'Other' : 'Not specified',
                                        style: const TextStyle(color: textGray, fontSize: 11.5, fontWeight: FontWeight.w600),
                                      ),
                                      const SizedBox(width: 8),
                                      const Icon(Icons.star_rounded, color: Colors.amber, size: 13),
                                      const SizedBox(width: 2),
                                      Text(
                                        senderRating.toStringAsFixed(1),
                                        style: const TextStyle(color: textGray, fontSize: 11.5, fontWeight: FontWeight.w600),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '${formatRuns(senderCompletedTrips)} trips',
                                        style: const TextStyle(color: textGray, fontSize: 11.5, fontWeight: FontWeight.w600),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12.0),
                          child: Container(height: 1, color: Colors.white.withOpacity(0.04)),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Phone', style: TextStyle(color: textGray, fontSize: 13)),
                            Text(displayPhone, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  
                  if (isParcel && order['special_instructions'] != null && order['special_instructions'].toString().trim().isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Text('SPECIAL INSTRUCTIONS', style: TextStyle(color: textGray, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: darkCard,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withOpacity(0.04), width: 1),
                      ),
                      child: Text(
                        order['special_instructions'].toString(),
                        style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                      ),
                    ),
                  ],

                  if (isParcel && parcelImages.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Text('PARCEL IMAGES', style: TextStyle(color: textGray, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 100,
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        scrollDirection: Axis.horizontal,
                        itemCount: parcelImages.length,
                        itemBuilder: (context, imgIdx) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 12.0),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: CachedNetworkImage(
                                imageUrl: parcelImages[imgIdx],
                                width: 100,
                                height: 100,
                                fit: BoxFit.cover,
                                memCacheWidth: (100 * MediaQuery.of(context).devicePixelRatio).round(),
                                memCacheHeight: (100 * MediaQuery.of(context).devicePixelRatio).round(),
                                errorWidget: (_, _, _) => Container(
                                  width: 100,
                                  height: 100,
                                  color: Colors.white10,
                                  child: const Icon(Icons.broken_image_rounded, size: 24, color: Colors.white30),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  if (actionButton != null) ...[
                    actionButton,
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 12),
                ],
              ),
            );
          },
        );
      },
    );
  }
  Widget _buildSpecItem(IconData icon, String label, String value) {
    return Expanded(
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: primaryLime, size: 16),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: textGray, fontSize: 8, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomStatTile(IconData icon, String label, String value, String subtitle) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: primaryLime, size: 16),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(color: textGray, fontSize: 8, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(color: textGray, fontSize: 9),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  // Build method responsible for rendering the entire widget layout hierarchy on the viewport
  Widget build(BuildContext context) {
    final date = DateTime.tryParse(widget.plan['travel_date']?.toString() ?? '')?.toLocal() ?? DateTime.now();
    
    final pickupResolved = LocationDisplayService.resolveCity(
      city: widget.plan['pickup_city'],
      address: widget.plan['pickup_address'],
      fallback: 'Pickup Location',
    );
    final destinationResolved = LocationDisplayService.resolveCity(
      city: widget.plan['destination_city'],
      address: widget.plan['destination_address'],
      fallback: 'Destination Location',
    );

    final isRideMode = widget.plan['travel_plan_type'] == 'ride';

    final double? mapPickupLat = double.tryParse(widget.plan['pickup_lat']?.toString() ?? '');
    final double? mapPickupLng = double.tryParse(widget.plan['pickup_lng']?.toString() ?? '');
    final double? mapDestLat = double.tryParse(widget.plan['destination_lat']?.toString() ?? '');
    final double? mapDestLng = double.tryParse(widget.plan['destination_lng']?.toString() ?? '');
    final bool hasMapRoute = mapPickupLat != null && mapPickupLng != null && mapDestLat != null && mapDestLng != null;

    int bookedCount = 0;
    // Item 1 (business rule): intercity payment is collected from the passenger AFTER the trip
    // completes, not before -- so "ready to start" means the traveller has accepted the passenger
    // ('confirmed'), not that they've paid. Renamed from paidReadyCount accordingly; 'paid' stays
    // in the set so an already-paid-early passenger is still counted, but is no longer required.
    int readyToStartCount = 0;
    double expectedEarning = 0.0;
    for (final order in matches) {
      final req = intercityRequests[order['id']];
      final reqStatus = req?['status']?.toString();
      if (reqStatus == 'confirmed' || reqStatus == 'paid' || reqStatus == 'in_progress' || reqStatus == 'completed') {
        bookedCount++;
        // Phase 3 fix (Issue 4): order['final_fare']/['current_fare'] first -- authoritative,
        // boost-aware; proposed_fare only as a fallback if order data is somehow unavailable.
        final fare = double.tryParse(order['final_fare']?.toString() ?? order['current_fare']?.toString() ?? req?['proposed_fare']?.toString() ?? order['actual_fare']?.toString() ?? '0') ?? 0.0;
        expectedEarning += fare;
      }
      if (reqStatus == 'confirmed' || reqStatus == 'paid') {
        readyToStartCount++;
      }
    }

    final totalSlots = isRideMode ? (widget.plan['seats_preference'] ?? 4) : (widget.plan['max_bookings'] ?? 5);
    final double projected = matches.isNotEmpty 
        ? (double.tryParse(matches.first['current_fare']?.toString() ?? '') ?? 450.0) * totalSlots 
        : 2250.0;
    final statusStr = widget.plan['status']?.toString().toUpperCase() ?? 'ACTIVE';

    return Scaffold(
      backgroundColor: darkBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(left: 20, right: 20, top: 16, bottom: 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top Navigation Icons
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  GestureDetector(
                    // Close/pop the current screen or modal bottom sheet context
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white.withOpacity(0.08), width: 1),
                      ),
                      child: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 16),
                    ),
                  ),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () {
                          // Navigate to a new screen layout using Flutter's Navigator router
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const CustomerSupportScreen()),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white.withOpacity(0.08), width: 1),
                          ),
                          child: const Icon(Icons.headset_mic_outlined, color: Colors.white, size: 16),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withOpacity(0.08), width: 1),
                        ),
                        child: Theme(
                          // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
                          data: Theme.of(context).copyWith(
                            cardColor: darkCard,
                          ),
                          child: PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 18),
                            padding: EdgeInsets.zero,
                            onSelected: (value) {
                              if (value == 'delete') {
                                _confirmDeletePlan(context, widget.plan);
                              }
                            },
                            itemBuilder: (BuildContext context) => [
                              const PopupMenuItem<String>(
                                value: 'delete',
                                child: Row(
                                  children: [
                                    Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 18),
                                    SizedBox(width: 8),
                                    Text(
                                      'Delete Plan',
                                      style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Title: Travel Plan Details (reduced font size to 20)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Travel Plan Details',
                    style: TextStyle(
                      fontSize: 20, // Reduced font size!
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _showPlanDetailsBottomSheet(context, bookedCount, totalSlots, expectedEarning, projected, statusStr),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withOpacity(0.08), width: 1),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.info_outline_rounded, color: Colors.white70, size: 12),
                          SizedBox(width: 4),
                          Text(
                            'Plan Info',
                            style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Status badge -- reflects the plan's ACTUAL status (previously hardcoded to always
              // show "ACTIVE", even for a plan that had already flipped to FULLY_BOOKED the moment
              // its first passenger was accepted). "Fully booked" is still an in-flight, un-started
              // plan -- shown with the same positive styling as Active, just with accurate copy.
              Row(
                children: [
                  Builder(builder: (context) {
                    final isFullyBooked = statusStr == 'FULLY_BOOKED';
                    final badgeLabel = isFullyBooked ? 'FULLY BOOKED' : statusStr;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B4332), // dark green background
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF2D6A4F), width: 1),
                      ),
                      child: Text(
                        badgeLabel,
                        style: const TextStyle(
                          color: Color(0xFF52B788),
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    );
                  }),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: primaryLime.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: primaryLime.withOpacity(0.2), width: 1),
                    ),
                    child: Text(
                      isRideMode 
                          ? '${totalSlots - bookedCount} / $totalSlots Seats Left'
                          : '${totalSlots - bookedCount} / $totalSlots Slots Left',
                      style: const TextStyle(
                        color: primaryLime,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const Spacer(),
                ],
              ),
              const SizedBox(height: 16),

              // Simplified Connection Row
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: darkCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.04), width: 1),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // From City
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: primaryLime,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              pickupResolved,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14, // Reduced font size!
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Swap Arrow / Icon
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.arrow_forward_rounded, color: Colors.white.withOpacity(0.3), size: 14),
                    ),
                    // To City
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Text(
                              destinationResolved,
                              textAlign: TextAlign.end,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14, // Reduced font size!
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.location_on_rounded, color: Colors.redAccent, size: 14),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Matches Header
              // WayDrop Intercity is strictly User-initiated (the "Browse" entry point into
              // AvailableTravelersScreen -- Traveller browsing/inviting Users -- has been removed):
              // this header now only shows the count of Users who have already sent a request.
              Row(
                children: [
                  const Icon(Icons.people_alt_outlined, color: primaryLime, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isRideMode ? 'Matched Passengers (${matches.length})' : 'Matched Drop Partners (${matches.length})',
                      style: const TextStyle(
                        fontSize: 14, // Reduced font size!
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),

              // Item 3: single plan-level Start Trip action -- replaces pressing "Start Transit"
              // separately inside every accepted passenger's own bottom sheet. Visible whenever at
              // least one passenger under this plan has been accepted and is waiting to start;
              // calling it again after more passengers are accepted is safe
              // (start_intercity_trip_for_plan only ever touches passengers who are
              // 'confirmed'/'paid' and not yet started). Payment is NOT a precondition -- the
              // passenger pays the traveller after the trip completes, not before.
              if (readyToStartCount > 0) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: _buildActionButton(
                    label: startingTrip
                        ? 'Starting Trip…'
                        : 'Start Trip ($readyToStartCount passenger${readyToStartCount > 1 ? 's' : ''})',
                    color: primaryLime,
                    textColor: Colors.black,
                    isLoading: startingTrip,
                    onPressed: startingTrip ? null : _startTripForPlan,
                  ),
                ),
              ],
              const SizedBox(height: 12),

              // Matches List
              if (loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: CircularProgressIndicator(color: primaryLime)),
                )
              else if (matches.isEmpty)
                Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 48),
                  decoration: BoxDecoration(
                    color: darkCard.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.route_rounded, color: Colors.white12, size: 48),
                      const SizedBox(height: 12),
                      const Text(
                        'No travel requests yet',
                        style: TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Passengers who choose to travel with you on this plan will appear here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white30, fontSize: 11),
                      ),
                    ],
                  ),
                )
              else
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: matches.length,
                  padding: EdgeInsets.zero,
                  itemBuilder: (context, idx) {
                    final order = matches[idx];
                    final isParcel = order['order_type']?.toString().contains('parcel') ?? false;
                    final req = intercityRequests[order['id']];
                    final rawImages = order['parcel_images'];
                    List<String> parcelImages = [];
                    if (rawImages is List) {
                      parcelImages = rawImages.map((e) => e.toString()).toList();
                    } else if (rawImages is String && rawImages.isNotEmpty) {
                      try {
                        final parsed = jsonDecode(rawImages);
                        if (parsed is List) {
                          parcelImages = parsed.map((e) => e.toString()).toList();
                        }
                      } catch (_) {}
                    }
                    // Phase 3 fix (Issue 4): same authoritative-fare priority as above.
                    final actualFare = double.tryParse(order['final_fare']?.toString() ?? '') ??
                        double.tryParse(order['current_fare']?.toString() ?? '') ??
                        double.tryParse(req?['proposed_fare']?.toString() ?? '') ??
                        double.tryParse(order['actual_fare']?.toString() ?? '') ??
                        0.0;
                    final orderId = order['id'];
                    
                    final reqStatus = req?['status']?.toString();
                    final isAcceptedOrActive = reqStatus == 'confirmed' || reqStatus == 'paid' || reqStatus == 'in_progress' || reqStatus == 'completed';

                    final matchPickupResolved = LocationDisplayService.resolveCity(
                      city: order['pickup_city'],
                      address: order['pickup_address'],
                      fallback: 'Pickup',
                    );
                    final matchDestResolved = LocationDisplayService.resolveCity(
                      city: order['destination_city'],
                      address: order['destination_address'],
                      fallback: 'Drop',
                    );

                    return GestureDetector(
                      onTap: () => _showOrderDetailsBottomSheet(
                        context,
                        order,
                        req: req,
                        actionButton: _buildSheetActionButton(order, req),
                      ),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              darkCard,
                              darkCard.withOpacity(0.85),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: isAcceptedOrActive
                                ? primaryLime.withOpacity(0.15)
                                : Colors.white.withOpacity(0.04),
                            width: isAcceptedOrActive ? 1.5 : 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: isAcceptedOrActive
                                  ? primaryLime.withOpacity(0.04)
                                  : Colors.black.withOpacity(0.2),
                              blurRadius: isAcceptedOrActive ? 16 : 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Matched Card Header
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 20,
                                  backgroundColor: Colors.white.withOpacity(0.04),
                                  backgroundImage: () {
                                    final photoUrl = order['users']?['profile_photo_url']?.toString();
                                    if (photoUrl != null && photoUrl.isNotEmpty) {
                                      return NetworkImage(photoUrl);
                                    }
                                    return null;
                                  }(),
                                  child: (order['users']?['profile_photo_url']?.toString().isNotEmpty ?? false)
                                      ? null
                                      : const Icon(Icons.person_rounded, color: textGray, size: 18),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        order['users']?['full_name']?.toString() ?? 'Passenger',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          Icon(
                                            order['users']?['gender'] == 'female'
                                                ? Icons.female_rounded
                                                : order['users']?['gender'] == 'male'
                                                    ? Icons.male_rounded
                                                    : Icons.wc_rounded,
                                            color: Colors.white54,
                                            size: 12,
                                          ),
                                          const SizedBox(width: 5),
                                          const Icon(Icons.star_rounded, color: Colors.amber, size: 14),
                                          const SizedBox(width: 2),
                                          Text(
                                            (double.tryParse((order['users']?['rating'] ?? 5.0).toString()) ?? 5.0).toStringAsFixed(1),
                                            style: const TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white70,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Container(width: 3, height: 3, decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle)),
                                          const SizedBox(width: 6),
                                          Text(
                                            formatRuns(int.tryParse(order['users']?['completed_trips']?.toString() ?? '') ?? 0),
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: textGray,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      '₹${actualFare.toStringAsFixed(0)}',
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w900,
                                        color: primaryLime,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: primaryLime.withOpacity(0.08),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: primaryLime.withOpacity(0.15), width: 1),
                                      ),
                                      child: Text(
                                        '${(double.tryParse(order['score']?.toString() ?? '') ?? 95.0).round()}% Match',
                                        style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: primaryLime),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Divider(color: Colors.white10, height: 1, thickness: 1),
                            ),

                            // Route Timeline inside Match Card
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.02),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.white.withOpacity(0.03), width: 1),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.trip_origin_rounded, color: primaryLime, size: 14),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      matchPickupResolved,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    child: Icon(Icons.arrow_forward_rounded, color: textGray.withOpacity(0.3), size: 14),
                                  ),
                                  const Icon(Icons.location_on_rounded, color: Colors.redAccent, size: 14),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      matchDestResolved,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            
                            const SizedBox(height: 12),

                            // Info Badges
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _buildInfoBadge(
                                  icon: Icons.calendar_today_rounded,
                                  text: order['travel_date'] != null 
                                      ? formatRelativeDate(DateTime.parse(order['travel_date'].toString()).toLocal()) 
                                      : 'Instant Departure',
                                ),
                                _buildInfoBadge(
                                  icon: Icons.navigation_rounded,
                                  text: '${(double.tryParse(order['distance_km']?.toString() ?? '0.0') ?? 0.0).toStringAsFixed(0)} km',
                                ),
                                _buildInfoBadge(
                                  icon: isParcel ? Icons.scale_rounded : Icons.airline_seat_recline_normal_rounded,
                                  text: isParcel 
                                      ? (() {
                                          final wc = order['weight_category']?.toString();
                                          if (wc == null) return 'N/A';
                                          final double? parsed = double.tryParse(wc);
                                          return '${parsed?.round() ?? wc} kg';
                                        })()
                                      : '${order['seats_requested']?.toString() ?? order['capacity']?.toString() ?? '1'} Seats',
                                ),
                              ],
                            ),
                            
                            if (isParcel && parcelImages.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              SizedBox(
                                height: 48,
                                child: ListView.builder(
                                  padding: EdgeInsets.zero,
                                  scrollDirection: Axis.horizontal,
                                  itemCount: parcelImages.length,
                                  itemBuilder: (context, imgIdx) {
                                    return Padding(
                                      padding: const EdgeInsets.only(right: 8.0),
                                      child: GestureDetector(
                                        onTap: () => _viewFullScreenImage(context, parcelImages[imgIdx]),
                                        child: Container(
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: Colors.white.withOpacity(0.08), width: 1),
                                          ),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(8),
                                            child: CachedNetworkImage(
                                              imageUrl: parcelImages[imgIdx],
                                              width: 48,
                                              height: 48,
                                              fit: BoxFit.cover,
                                              memCacheWidth: (48 * MediaQuery.of(context).devicePixelRatio).round(),
                                              memCacheHeight: (48 * MediaQuery.of(context).devicePixelRatio).round(),
                                              errorWidget: (_, _, _) => Container(
                                                width: 48,
                                                height: 48,
                                                color: Colors.white10,
                                                child: const Icon(Icons.broken_image_rounded, size: 14, color: Colors.white24),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                            
                            const SizedBox(height: 16),

                            // Stylized Action Row inside Match Card
                            // WayDrop Intercity is strictly User-initiated: `matches` only ever
                            // contains orders that already have an intercity_requests row for this
                            // plan (fetchIncomingRequestsForPlan), so `req` is never actually null
                            // here — defensive fallback only, not a reverse Traveller-initiated
                            // "send offer" action (removed).
                            Builder(
                              builder: (context) {
                                final isThisAccepting = accepting && acceptingOrderId == orderId;
                                if (req == null) {
                                  return const SizedBox.shrink();
                                }

                                final reqStatus = req['status']?.toString() ?? 'request_sent';
                                String btnLabel = 'Offer Sent';
                                Color btnColor = Colors.white.withOpacity(0.04);
                                Color txtColor = Colors.white.withOpacity(0.3);
                                VoidCallback? onBtnPressed;

                                if ((reqStatus == 'request_sent' || reqStatus == 'discussion_started' || reqStatus == 'fare_agreed') &&
                                    req['initiated_by'] == 'sender') {
                                  // Phase 3 fix (Issue 4): same authoritative-fare priority as the
                                  // other "Accept Request" render path above.
                                  // Phase 11 (Issue 1): same roundFareForDisplay() fix as the other
                                  // "Accept Request" render path above -- proposed_fare is raw/
                                  // unrounded until accept_intercity_request() rounds it.
                                  final amt = order['final_fare'] != null || order['current_fare'] != null
                                      ? (order['final_fare'] ?? order['current_fare']).toString()
                                      : roundFareForDisplay(double.tryParse(req['proposed_fare']?.toString() ?? '0') ?? 0.0).toString();
                                  btnLabel = 'Accept Request (₹$amt)';
                                  btnColor = const Color(0xFF22C55E); // Green accept button
                                  txtColor = Colors.white;
                                  onBtnPressed = () => _acceptIntercityRequest(req['id'].toString(), orderId);
                                } else if (reqStatus == 'request_sent') {
                                  btnLabel = 'Offer Sent (Pending)';
                                  btnColor = Colors.white.withOpacity(0.04);
                                  txtColor = Colors.white.withOpacity(0.3);
                                } else if (reqStatus == 'discussion_started' || reqStatus == 'fare_agreed') {
                                  btnLabel = 'Awaiting Client Response';
                                  btnColor = Colors.white.withOpacity(0.04);
                                  txtColor = Colors.white.withOpacity(0.3);
                                  onBtnPressed = null;
                                } else if (reqStatus == 'confirmed' || reqStatus == 'paid') {
                                  // Item 3: Start Trip is now a single plan-level action (see the
                                  // "Start Trip" button on the main screen) instead of a
                                  // per-passenger button here. Item 1 (business rule): 'confirmed'
                                  // already means ready to start -- payment happens after the trip
                                  // completes, not before, so this is never "awaiting payment".
                                  btnLabel = 'Ready to Start';
                                  btnColor = primaryLime.withOpacity(0.15);
                                  txtColor = primaryLime;
                                } else if (reqStatus == 'in_progress') {
                                  // Item 1 fix: open the canonical active-order/trip screen for
                                  // THIS order instead of launching Google Maps directly.
                                  btnLabel = 'Directions';
                                  btnColor = Colors.blueAccent;
                                  txtColor = Colors.white;
                                  onBtnPressed = () => _openActiveOrderScreen(orderId.toString());
                                } else if (reqStatus == 'completed') {
                                  btnLabel = 'Trip Completed';
                                  btnColor = Colors.white.withOpacity(0.04);
                                  txtColor = Colors.white.withOpacity(0.3);
                                } else if (reqStatus == 'cancelled') {
                                  btnLabel = 'Request Cancelled';
                                  btnColor = Colors.red.withOpacity(0.12);
                                  txtColor = Colors.redAccent;
                                } else if (reqStatus == 'rejected') {
                                  btnLabel = 'Request Rejected';
                                  btnColor = Colors.red.withOpacity(0.12);
                                  txtColor = Colors.redAccent;
                                }

                                // Reject is only offered while it's the rider's turn to decide on
                                // a passenger-initiated request (Parts 12/14).
                                final canReject = (reqStatus == 'request_sent' || reqStatus == 'discussion_started' || reqStatus == 'fare_agreed') &&
                                    req['initiated_by'] == 'sender';

                                return SizedBox(
                                  height: 44,
                                  child: Row(
                                    children: [
                                      _buildIconButton(
                                        icon: Icons.chat_bubble_outline_rounded,
                                        color: const Color(0xFF4C84FF),
                                        tooltip: 'Chat with User',
                                        onPressed: () {
                                          final rId = widget.rider?['id']?.toString() ?? '';
                                          final chatTitle = order['users']?['full_name']?.toString() ?? 'Passenger';
                                          // Navigate to a new screen layout using Flutter's Navigator router
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => OrderChatScreen(
                                                orderId: order['id'],
                                                riderId: rId,
                                                chatTitle: chatTitle,
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                      const SizedBox(width: 8),
                                      if (canReject) ...[
                                        _buildIconButton(
                                          icon: Icons.close_rounded,
                                          color: Colors.redAccent,
                                          tooltip: 'Reject Request',
                                          onPressed: () async {
                                            try {
                                              await IntercityMatchingService.rejectTravelTogetherRequest(
                                                requestId: req['id'].toString(),
                                                actorType: 'traveller',
                                              );
                                            } catch (e) {
                                              debugPrint('Error rejecting request: $e');
                                            }
                                            if (mounted) _loadIntercityRequests();
                                          },
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      if (isAcceptedOrActive) ...[
                                        _buildIconButton(
                                          icon: Icons.directions_rounded,
                                          color: primaryLime,
                                          tooltip: 'View Route',
                                          onPressed: () => _showRoutePreviewBottomSheet(context, order),
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      Expanded(
                                        child: _buildActionButton(
                                          label: btnLabel,
                                          color: btnColor,
                                          textColor: txtColor,
                                          isLoading: isThisAccepting,
                                          onPressed: onBtnPressed,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPlanDetailsBottomSheet(
    BuildContext context,
    int bookedCount,
    int totalSlots,
    double expectedEarning,
    double projected,
    String statusStr,
  ) {
    final date = DateTime.tryParse(widget.plan['travel_date']?.toString() ?? '')?.toLocal() ?? DateTime.now();
    final dateStr = "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}";
    
    // Format to HH:MM AM/PM
    final hourVal = date.hour;
    final amPm = hourVal >= 12 ? 'PM' : 'AM';
    final hour12 = hourVal % 12 == 0 ? 12 : hourVal % 12;
    final timeStr = "${hour12.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')} $amPm";

    final isRideMode = widget.plan['travel_plan_type'] == 'ride';
    final remainingCapacity = totalSlots - bookedCount;

    // Use city names directly to avoid empty addresses
    final pickupAddr = widget.plan['pickup_city']?.toString() ?? widget.plan['pickup_address']?.toString() ?? 'N/A';
    final destinationAddr = widget.plan['destination_city']?.toString() ?? widget.plan['destination_address']?.toString() ?? 'N/A';

    // Present a premium modal bottom sheet drawer for user input/actions
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent, // transparent background for glass container
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Container(
          // Glassmorphic Premium Aesthetic Container
          decoration: BoxDecoration(
            color: darkCard.withOpacity(0.95),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: Colors.white.withOpacity(0.08), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.4),
                blurRadius: 24,
                offset: const Offset(0, -8),
              ),
            ],
          ),
          padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Travel Plan Info',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(color: Colors.white10),
                const SizedBox(height: 12),
                _buildDetailRow('FROM CITY', pickupAddr),
                _buildDetailRow('TO CITY', destinationAddr),
                _buildRouteTimeline(),
                _buildDetailRow('TRAVEL DATE', dateStr),
                _buildDetailRow('DEPARTURE TIME', timeStr),
                _buildDetailRow('VEHICLE TYPE', widget.plan['vehicle_type']?.toString().toUpperCase() ?? 'BIKE'),
                _buildDetailRow(
                  isRideMode ? 'TOTAL SEATS PREFERENCE' : 'MAX WEIGHT PREFERENCE',
                  isRideMode
                      ? '$totalSlots Seats'
                      : '${double.tryParse(widget.plan['weight_preference']?.toString() ?? '50')?.round() ?? 50} kg',
                ),
                _buildDetailRow(
                  isRideMode ? 'REMAINING SEATS' : 'REMAINING PARCEL CAPACITY',
                  isRideMode 
                      ? '$remainingCapacity Seats Available'
                      : '$remainingCapacity Slots Available',
                  valueColor: primaryLime,
                ),
                const SizedBox(height: 16),
                const Divider(color: Colors.white10),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _buildStatBadge('STATUS', statusStr, Colors.greenAccent),
                    const SizedBox(width: 36),
                    _buildStatBadge('BOOKED', '$bookedCount / $totalSlots', primaryLime),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Ordered declared-route waypoints saved on this plan (Origin -> Via... -> Destination), from
  /// selected_route_meta.waypoints. Returns [] for plans created before the Via-locations feature
  /// (or any plan with no declared route) -- the caller then renders nothing extra and the screen
  /// still works exactly as before.
  List<Map<String, dynamic>> _declaredRouteWaypoints() {
    try {
      final rawMeta = widget.plan['selected_route_meta'];
      if (rawMeta == null) return const [];
      final meta = rawMeta is String
          ? jsonDecode(rawMeta) as Map<String, dynamic>
          : Map<String, dynamic>.from(rawMeta as Map);
      final rawWps = meta['waypoints'];
      if (rawWps is! List || rawWps.isEmpty) return const [];
      final wps = rawWps
          .whereType<Map>()
          .map((w) => Map<String, dynamic>.from(w))
          .toList();
      // Preserve the traveller's declared order; sort by the stored index defensively.
      wps.sort((a, b) =>
          ((a['order'] as num?)?.toInt() ?? 0).compareTo((b['order'] as num?)?.toInt() ?? 0));
      return wps;
    } catch (_) {
      return const [];
    }
  }

  /// Vertical Origin -> Via -> Destination route, shown only when this plan has a declared route.
  Widget _buildRouteTimeline() {
    final wps = _declaredRouteWaypoints();
    if (wps.length < 2) return const SizedBox.shrink();

    Color dotColor(String type) {
      switch (type) {
        case 'origin':
          return primaryLime;
        case 'destination':
          return Colors.redAccent;
        default:
          return textGray;
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ROUTE',
            style: TextStyle(color: textGray, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5),
          ),
          const SizedBox(height: 8),
          for (int i = 0; i < wps.length; i++)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        margin: const EdgeInsets.only(top: 3),
                        decoration: BoxDecoration(
                          color: dotColor(wps[i]['type']?.toString() ?? 'via'),
                          shape: BoxShape.circle,
                        ),
                      ),
                      if (i != wps.length - 1)
                        Expanded(
                          child: Container(width: 2, color: Colors.white12),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: EdgeInsets.only(bottom: i == wps.length - 1 ? 0 : 12),
                    child: Text(
                      (wps[i]['label']?.toString().trim().isNotEmpty ?? false)
                          ? wps[i]['label'].toString()
                          : (wps[i]['type']?.toString() == 'origin'
                              ? 'Origin'
                              : wps[i]['type']?.toString() == 'destination'
                                  ? 'Destination'
                                  : 'Via $i'),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: (wps[i]['type']?.toString() == 'via')
                            ? FontWeight.w600
                            : FontWeight.bold,
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

  Widget _buildDetailRow(String label, String value, {Color valueColor = Colors.white}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: textGray, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(color: valueColor, fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildStatBadge(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: textGray, fontSize: 9, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withOpacity(0.2), width: 1),
          ),
          child: Text(
            value,
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}


class _LazyRouteMap extends StatefulWidget {
  final double pickupLat;
  final double pickupLng;
  final double destinationLat;
  final double destinationLng;
  final double? riderLat;
  final double? riderLng;
  final bool isDark;

  const _LazyRouteMap({
    required this.pickupLat,
    required this.pickupLng,
    required this.destinationLat,
    required this.destinationLng,
    this.riderLat,
    this.riderLng,
    required this.isDark,
  });

  @override
  State<_LazyRouteMap> createState() => _LazyRouteMapState();
}

class _LazyRouteMapState extends State<_LazyRouteMap> {
  String? _geometry;
  bool _loading = true;

  @override
  // Lifecycle method called once when the stateful widget initialized for the first time
  void initState() {
    // Lifecycle method called once when the stateful widget initialized for the first time
    super.initState();
    _fetchRoute();
  }

  Future<void> _fetchRoute() async {
    try {
      // Phase 10E 2D: pass the 8s budget INTO getDirections (Phase 2B mechanism) instead of
      // wrapping it in `.timeout()`. This is a one-shot initState fetch with no in-flight guard,
      // so there was no overlapping-request risk -- but the old `.timeout()` left the underlying
      // Ola HTTP request running against the shared Dio's 15s ceiling for ~7s after this widget
      // may already have been disposed. Now the request is actually cancelled at 8s. A timed-out
      // request returns null, which this method already handles identically to any empty route
      // (the `else` branch below just clears `_loading`).
      final route = await OlaMapService.getDirections(
        originLat: widget.pickupLat,
        originLng: widget.pickupLng,
        destinationLat: widget.destinationLat,
        destinationLng: widget.destinationLng,
        timeout: const Duration(seconds: 8),
      );

      if (route != null && route.polylinePoints.isNotEmpty) {
        final List<Map<String, double>> coords = route.polylinePoints.map((pt) => {
          'lat': pt['lat']!,
          'lng': pt['lng']!,
        }).toList();
        if (mounted) {
          // Update the widget state to trigger a UI rebuild with the new variables
          setState(() {
            _geometry = jsonEncode(coords);
            _loading = false;
          });
        }
      } else {
        if (mounted) {
          // Update the widget state to trigger a UI rebuild with the new variables
          setState(() {
            _loading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error fetching route directions for screen map: $e');
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  // Build method responsible for rendering the entire widget layout hierarchy on the viewport
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFC5FF30)),
      );
    }
    return TransportMapWidget(
      pickupLat: widget.pickupLat,
      pickupLng: widget.pickupLng,
      destinationLat: widget.destinationLat,
      destinationLng: widget.destinationLng,
      riderLat: widget.riderLat,
      riderLng: widget.riderLng,
      geometry: _geometry,
      isDark: widget.isDark,
      showRecenterButton: true,
      showZoomButtons: true,
    );
  }
}
