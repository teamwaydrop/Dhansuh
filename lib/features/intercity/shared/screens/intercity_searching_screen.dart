/// ============================================================================
/// File: intercity_searching_screen.dart
///
/// Module:
/// Intercity → Shared
///
/// Purpose:
/// Customer-facing intercity match searching and negotiations.
///
/// Responsibilities:
/// • Render active plans proposals, accept rider bids, direct to tracking.
///
/// Related:
/// intercity_location_screen.dart
/// intercity_tracking_screen.dart
/// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:waydrop/core/config/env.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:waydrop/models/transport_order.dart';
import 'package:waydrop/core/services/realtime/realtime_order_controller.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:waydrop/core/navigation/flow_modules.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_tracking_screen.dart';
import 'package:waydrop/modules/chat/screens/order_chat_screen.dart';
import 'package:waydrop/shared/helpers/fare_presentation_helper.dart';
import 'package:waydrop/shared/helpers/location_display_service.dart';
import 'package:waydrop/shared/helpers/time_format_helper.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:waydrop/shared/helpers/insets.dart';
import 'package:waydrop/features/intercity/shared/services/intercity_matching_service.dart';
import 'package:waydrop/features/user/intercity/screens/available_partners_screen.dart';
import 'package:waydrop/features/intercity/shared/widgets/partner_card.dart';
import 'package:waydrop/features/intercity/shared/widgets/travel_together_confirm_dialog.dart';


class IntercitySearchingScreen extends StatefulWidget {
  final String orderId;

  const IntercitySearchingScreen({
    super.key,
    required this.orderId,
  });

  @override
  State<IntercitySearchingScreen> createState() => _IntercitySearchingScreenState();
}

class _IntercitySearchingScreenState extends State<IntercitySearchingScreen> with TickerProviderStateMixin {
  final supabase = Supabase.instance.client;
  late RealtimeOrderController orderController;

  Map<String, dynamic>? order; // Kept as map for backward compat/RPC queries
  List<dynamic> nearbyRiders = [];
  List<dynamic> matchedPlans = [];
  bool loadingMatches = false;
  String? requestingRiderId;
  Map<String, String> assignmentStatuses = {};
  Map<String, double> assignmentFares = {};
  // P2 #3 (WayDrop production-scale audit): both channels below now routed through RealtimeManager
  // instead of their own raw supabase.channel() connections.
  String? assignmentsSubId;
  String? assignmentsSubChannel;
  Map<String, Map<String, dynamic>> intercityRequests = {};
  // Egress fix: a burst of related rider_assignments/intercity_requests events for this one order
  // (e.g. several riders responding close together) previously ran loadNearbyRiders()/
  // loadIntercityRequests() once per event -- 500ms-debounced, same pattern used elsewhere in the
  // app for the identical "realtime event -> full reload" situation. Not applied to the accept/
  // reject action paths themselves (those stay immediate).
  Timer? _nearbyRidersDebounceTimer;
  Timer? _intercityRequestsDebounceTimer;
  // Issue 2 fix (matching-screen lag): loadNearbyRiders() has THREE call sites -- the initial
  // load, the 500ms-debounced realtime callback above, and _maybeRefreshNearbyRiders()'s own
  // adaptive 5s/10s/20s poll gate (_lastNearbyRidersFetchAt, further below). Only the poll path
  // was ever rate-limited; the realtime path could fire a full heavy loadNearbyRiders() call
  // (one match-intercity-riders Edge Function invocation + a separate rider_assignments query)
  // completely independently, including moments after the poll path just finished one for the
  // same order. This tracks the completion time of the last successful run, shared by every call
  // site via loadNearbyRiders() itself, so a second call arriving within a short cooldown of an
  // already-fresh result is skipped -- without weakening either existing gate (the 500ms debounce
  // still coalesces realtime bursts; the 5/10/20s adaptive poll interval is unchanged) and without
  // touching any matching/eligibility rule.
  DateTime? _lastNearbyRidersCompletedAt;
  static const Duration _nearbyRidersMinRefreshGap = Duration(seconds: 3);
  String? intercityRequestsSubId;
  String? intercityRequestsSubChannel;
  bool loading = true;
  bool cancelling = false;
  double localFare = 0.0;
  bool showBargainControls = false;
  bool boosting = false;
  int activeTabIndex = 0;
  bool showDetails = false;
  bool _fetchingRoute = false;
  String? _lastRouteRiderId;
  List<dynamic> _riderRouteCoords = [];
  bool _showCustomInput = false;
  final TextEditingController _customFareController = TextEditingController();
  String _selectedDateFilter = 'All';

  late AnimationController pulseController;
  late Animation<double> pulseAnimation;
  WebViewController? mapController;

  final apiKey = Env.olaMapsApiKey;

  late DateTime _nextTimeoutTime;

  @override
  // Lifecycle method called once when the stateful widget initialized for the first time
  void initState() {
    // Lifecycle method called once when the stateful widget initialized for the first time
    super.initState();
    debugPrint('[RUNTIME_TRACE] ENTER IntercitySearchingScreen (intercity_searching_screen.dart) orderId=${widget.orderId}');
    _nextTimeoutTime = DateTime.now().add(Duration(seconds: 300 + Random().nextInt(300)));

    pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    pulseAnimation = Tween<double>(
      begin: 0.96,
      end: 1.04,
    ).animate(
      CurvedAnimation(
        parent: pulseController,
        curve: Curves.easeInOut,
      ),
    );

    orderController = RealtimeOrderController(orderId: widget.orderId);
    initialize();
  }

  @override
  // Lifecycle method called before the widget is removed permanently from the tree to clean resources
  void dispose() {
    // Lifecycle method called before the widget is removed permanently from the tree to clean resources
    _customFareController.dispose();
    // Lifecycle method called before the widget is removed permanently from the tree to clean resources
    pulseController.dispose();
    _nearbyRidersDebounceTimer?.cancel();
    _intercityRequestsDebounceTimer?.cancel();
    if (assignmentsSubId != null && assignmentsSubChannel != null) {
      RealtimeManager.instance.unsubscribe(assignmentsSubChannel!, assignmentsSubId!);
    }
    if (intercityRequestsSubId != null && intercityRequestsSubChannel != null) {
      RealtimeManager.instance.unsubscribe(intercityRequestsSubChannel!, intercityRequestsSubId!);
    }
    orderController.orderNotifier.removeListener(_onOrderUpdate);
    // Lifecycle method called before the widget is removed permanently from the tree to clean resources
    orderController.dispose();

    // Phase 2F-C1 -- explicit WebView teardown, mirroring the Phase 2A / 2F-B pattern (c1ccf56).
    // ola_map_searching.html tears the map/engine down only on the document 'unload' event, which
    // does not reliably fire when Flutter disposes the platform WebView without a navigation --
    // leaking the MapLibre GL context, the ripple-search animation, and the nearby-rider
    // AnimationManager RAF loop. All helpers are typeof-guarded and idempotent; the call is
    // try/catch-wrapped on the JS side and .catchError on the Dart side, and is fire-and-forget
    // because dispose() cannot await.
    final mapCtrl = mapController;
    if (mapCtrl != null) {
      mapCtrl
          .runJavaScript(
            'try { '
            'if (typeof stopSearchingAnimation === "function") { stopSearchingAnimation(); } '
            'if (typeof destroyNearbyRidersEngine === "function") { destroyNearbyRidersEngine(); } '
            'if (typeof destroyTrackingEngine === "function") { destroyTrackingEngine(); } '
            'if (typeof destroyMap === "function") { destroyMap(); } '
            '} catch (e) {}',
          )
          .catchError((_) {});
    }

    // Lifecycle method called before the widget is removed permanently from the tree to clean resources
    super.dispose();
  }

  Future<void> initialize() async {
    await orderController.start();
    orderController.orderNotifier.addListener(_onOrderUpdate);

    // Initial state check
    final initialOrder = orderController.orderNotifier.value;
    if (initialOrder == null) {
      // Small delay to allow controller fetch
      await Future.delayed(const Duration(milliseconds: 1000));
    }

    final currentOrder = orderController.orderNotifier.value;
    if (currentOrder == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to load order')),
        );
        // Close/pop the current screen or modal bottom sheet context
        Navigator.pop(context);
      }
      return;
    }

    _syncOrderMap(currentOrder);

    await loadNearbyRiders();
    await loadAssignmentStatuses();
    await loadIntercityRequests();
    subscribeOrderAssignments();
    subscribeIntercityRequests();
    initializeMap();
    startRiderRefresh();
  }

  void _syncOrderMap(TransportOrder obj) {
    if (!mounted) return;
    // Update the widget state to trigger a UI rebuild with the new variables
    setState(() {
      order = {
        'id': obj.id,
        'order_code': obj.orderCode,
        'order_status': obj.orderStatus,
        'order_type': obj.orderType,
        'vehicle_type': obj.vehicleType,
        'pickup_address': obj.pickupAddress,
        'pickup_lat': obj.pickupLat,
        'pickup_lng': obj.pickupLng,
        'destination_address': obj.destinationAddress,
        'destination_lat': obj.destinationLat,
        'destination_lng': obj.destinationLng,
        'current_fare': obj.currentFare,
        'actual_fare': obj.actualFare,
        'boost_percentage': obj.boostPercentage,
        'payment_mode': obj.paymentMode,
        'pickup_city': obj.pickupCity,
        'destination_city': obj.destinationCity,
        'travel_date': obj.travelDate?.toIso8601String(),
      };
      if (localFare == 0.0 || obj.currentFare > localFare) {
        localFare = obj.currentFare;
      }
      loading = false;
    });
  }

  String _formatTravelDate(dynamic dt) {
    if (dt == null) return '';
    try {
      final parsed = dt is DateTime ? dt : DateTime.parse(dt.toString());
      final localDt = parsed.toLocal();
      
      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      final month = months[localDt.month - 1];
      final day = localDt.day.toString();
      
      final hourVal = localDt.hour;
      final amPm = hourVal >= 12 ? 'PM' : 'AM';
      final hour12 = hourVal % 12 == 0 ? 12 : hourVal % 12;
      final minute = localDt.minute.toString().padLeft(2, '0');
      
      return '$day $month, $hour12:$minute $amPm';
    } catch (e) {
      return dt.toString();
    }
  }

  bool showTimeoutRetryOverlay = false;
  bool _trackingOpened = false;

  void _onOrderUpdate() {
    final typedOrder = orderController.orderNotifier.value;
    if (typedOrder == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Order was cancelled or completed.')),
        );
        Navigator.of(context).pop();
      }
      return;
    }

    _syncOrderMap(typedOrder);

    // P1 fix: piggyback the nearby-riders map refresh on this same update signal instead of a
    // second independent Timer.periodic -- see startRiderRefresh()'s doc comment for why this
    // fires on the same reliable ~5s cadence during searching that the old dedicated timer did.
    _maybeRefreshNearbyRiders();

    if (typedOrder.orderStatus == 'cancelled') {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Order has been cancelled. Returning home.')),
      );
      Navigator.popUntil(context, (route) => route.isFirst);
      return;
    }

    if (typedOrder.isAccepted || 
        typedOrder.isRiderArrived || 
        typedOrder.isOngoing || 
        typedOrder.isRiderAtDrop) {
      openTracking();
    }

    final bool isElapsed = DateTime.now().isAfter(_nextTimeoutTime);

    if (isElapsed && !showTimeoutRetryOverlay) {
      if (!mounted) return;
      // Update the widget state to trigger a UI rebuild with the new variables
      setState(() {
        showTimeoutRetryOverlay = true;
      });
    }
  }

  Future<void> loadNearbyRiders() async {
    // R13 perf fix: prevents two overlapping runs (e.g. the adaptive refresh tick and a
    // rider_assignments realtime event landing close together) from each independently
    // invoking match-intercity-riders and re-querying rider_assignments/rider_travel_plans/etc.
    // A later trigger after the current run's `finally` resets this still runs normally.
    if (loadingMatches) return;
    // Issue 2 fix (matching-screen lag): a second trigger (realtime event, adaptive poll tick, or
    // both landing close together) arriving within a short cooldown of the last successfully
    // completed run is redundant -- the previous run's result is still fresh -- so skip the heavy
    // match-intercity-riders invocation + rider_assignments query entirely rather than repeating
    // identical work. Does not replace or weaken either existing gate: the realtime callback's own
    // 500ms debounce and _maybeRefreshNearbyRiders()'s 5s/10s/20s adaptive poll interval are both
    // unchanged: this is a shared floor underneath both, not a substitute for either.
    if (_lastNearbyRidersCompletedAt != null &&
        DateTime.now().difference(_lastNearbyRidersCompletedAt!) < _nearbyRidersMinRefreshGap) {
      return;
    }
    try {
      if (order == null) return;

      // Update the widget state to trigger a UI rebuild with the new variables
      setState(() {
        loadingMatches = true;
      });

      String? currentUserRiderId;
      try {
        // Perform an asynchronous database operation using the Supabase client wrapper
        final currentUserId = supabase.auth.currentUser?.id;
        if (currentUserId != null) {
          final riderRes = await supabase
              .from('riders')
              .select('id')
              .eq('user_id', currentUserId)
              .maybeSingle();
          if (riderRes != null) {
            currentUserRiderId = riderRes['id']?.toString();
          }
        }
      } catch (e) {
        debugPrint('Error fetching current user rider ID: $e');
      }

      // Perform an asynchronous database operation using the Supabase client wrapper
      final response = await supabase.functions.invoke(
        'match-intercity-riders',
        body: {
          'order_id': widget.orderId,
        },
      );

      debugPrint('MATCH RIDERS RESPONSE => ${response.data}');

      List<dynamic> tempMatches = [];
      if (response.data != null && response.data['success'] == true) {
        tempMatches = List<dynamic>.from(response.data['matches'] ?? []);
      }

      // Also fetch any existing assignments for this order to display riders who manually sent offers
      try {
        // Egress fix: narrowed to the fields this block and the tempMatches-building loop below
        // actually read off `assList`/`candidates` (grepped exhaustively) -- rider_id,
        // assignment_status, estimated_earnings on the outer row, user_id/account_status/rating/
        // current_lat/current_lng on the joined rider.
        final assignmentsRes = await supabase
            .from('rider_assignments')
            .select(
              'rider_id, assignment_status, estimated_earnings, '
              'riders(user_id, account_status, rating, current_lat, current_lng)',
            )
            .eq('order_id', widget.orderId);
        
        final assList = List<Map<String, dynamic>>.from(assignmentsRes);

        // R13 perf fix: this fetch (select('*, riders(*)') above) already returns rider_id,
        // assignment_status, and estimated_earnings for every row -- a strict superset of what
        // the separate loadAssignmentStatuses() query used to fetch a moment later in the
        // realtime callback. Deriving assignmentStatuses/assignmentFares here, before the
        // filter/sort below reads them, removes that duplicate round trip while preserving the
        // exact same freshness guarantee (fresh data is available before filter/sort runs) --
        // same field names, same derivation logic as loadAssignmentStatuses() itself, just
        // sourced from data already in hand instead of a second query. Plain field assignment
        // (no setState) since the existing setState() at the end of this function already picks
        // up these values in the same rebuild as matchedPlans/nearbyRiders.
        final Map<String, String> freshAssignmentStatuses = {};
        final Map<String, double> freshAssignmentFares = {};
        for (final row in assList) {
          final rid = row['rider_id']?.toString();
          if (rid == null) continue;
          if (row['assignment_status'] != null) {
            freshAssignmentStatuses[rid] = row['assignment_status'].toString();
          }
          if (row['estimated_earnings'] != null) {
            freshAssignmentFares[rid] = double.tryParse(row['estimated_earnings'].toString()) ?? 0.0;
          }
        }
        assignmentStatuses = freshAssignmentStatuses;
        assignmentFares = freshAssignmentFares;

        final candidates = assList.where((ass) {
          final rId = ass['rider_id']?.toString();
          if (rId == null) return false;
          final alreadyMatched = tempMatches.any((m) => m['rider_id']?.toString() == rId);
          return !alreadyMatched;
        }).toList();

        if (candidates.isNotEmpty) {
          final riderIds = candidates.map((c) => c['rider_id'].toString()).toList();
          final userIds = candidates.map((c) => c['riders']?['user_id']?.toString()).whereType<String>().toList();

          // Egress fix: narrowed to the fields tempMatches-building reads off `planRes` below
          // (id, rider_id (join key), vehicle_type, travel_date, weight_preference, max_weight_kg).
          final plansRes = await supabase
              .from('rider_travel_plans')
              .select('id, rider_id, vehicle_type, travel_date, weight_preference, max_weight_kg')
              .inFilter('rider_id', riderIds)
              .eq('status', 'active');
          final planList = List<Map<String, dynamic>>.from(plansRes);
          final plansMap = {for (var p in planList) p['rider_id'].toString(): p};

          Map<String, Map<String, dynamic>> kycMap = {};
          if (userIds.isNotEmpty) {
            final kycRes = await supabase
                .from('rider_kyc')
                .select('user_id, full_name, vehicle_type, vehicle_number, rider_image')
                .inFilter('user_id', userIds);
            final kycList = List<Map<String, dynamic>>.from(kycRes);
            kycMap = {for (var k in kycList) k['user_id'].toString(): k};
          }

          for (final ass in candidates) {
            final rId = ass['rider_id']!.toString();
            final planRes = plansMap[rId];
            if (planRes != null) {
              final uId = ass['riders']?['user_id']?.toString();
              final kycRes = uId != null ? kycMap[uId] : null;

              tempMatches.add({
                'plan_id': planRes['id'],
                'rider_id': rId,
                'full_name': kycRes?['full_name'] ?? 'Drop Partner',
                // Issue 3 fix: prefer the travel plan's own vehicle_type (the vehicle this
                // traveller actually published for this specific trip -- already fetched into
                // planRes above) over their general KYC vehicle_type, which can differ. Matches
                // match-intercity-riders/index.ts's own planVehicle-first precedence for the
                // primary (non-manual-offer) match path.
                'vehicle_type': planRes['vehicle_type'] ?? kycRes?['vehicle_type'] ?? 'delivery',
                'vehicle_number': kycRes?['vehicle_number'] ?? '',
                'rider_image': kycRes?['rider_image'] ?? '',
                'travel_date': planRes['travel_date'],
                'weight_preference': planRes['weight_preference'],
                'account_status': ass['riders']?['account_status'],
                'rating': ass['riders']?['rating'] ?? 5.0,
                'current_lat': ass['riders']?['current_lat'],
                'current_lng': ass['riders']?['current_lng'],
                'max_weight_kg': double.tryParse(planRes['max_weight_kg']?.toString() ?? '0.0') ?? 0.0,
                'remaining_capacity_kg': double.tryParse(planRes['max_weight_kg']?.toString() ?? '0.0') ?? 0.0,
                'score': 85.0,
                'reliability_score': 90.0,
                'completion_rate': 100.0,
                'on_time_rate': 100.0,
                'total_completed': 0,
              });
            }
          }
        }
      } catch (ae) {
        debugPrint('Error loading manual offer riders: $ae');
      }

      // Fetch plan capacities and confirmed bookings/weight count
      try {
        final planIds = tempMatches.map((m) => m['plan_id']?.toString()).whereType<String>().toSet().toList();
        if (planIds.isNotEmpty) {
          final plansDetails = await supabase
              .from('rider_travel_plans')
              .select('id, seats_preference, max_bookings, max_weight_kg, weight_preference')
              .inFilter('id', planIds);
          
          final plansDetailsMap = {for (var p in plansDetails) p['id'].toString(): p};

          // Query confirmed requests along with their orders' weight categories
          // NOTE: intercity_requests has no 'plan_id' column — the travel plan reference is
          // named 'route_id' (see intercity_requests_route_id_fkey -> rider_travel_plans.id).
          // 'plan_id' here previously caused every call to 400 and be silently swallowed by the
          // catch below, so booked-seat counts, remaining weight capacity, and rider phone
          // numbers never populated for this manual/candidate-riders match path.
          final reqsRes = await supabase
              .from('intercity_requests')
              .select('route_id, status, orders(weight_category)')
              .inFilter('route_id', planIds)
              .inFilter('status', ['confirmed', 'paid', 'in_progress', 'completed']);

          final Map<String, int> bookedCounts = {};
          final Map<String, double> bookedWeights = {};

          for (final r in reqsRes) {
            final pid = r['route_id']?.toString();
            if (pid != null) {
              bookedCounts[pid] = (bookedCounts[pid] ?? 0) + 1;
              
              // Get weight from order
              double orderWeight = 5.0; // default average parcel weight
              final orderMap = r['orders'];
              if (orderMap is Map) {
                final wc = orderMap['weight_category']?.toString();
                if (wc != null) {
                  orderWeight = double.tryParse(wc) ?? 5.0;
                }
              }
              bookedWeights[pid] = (bookedWeights[pid] ?? 0.0) + orderWeight;
            }
          }

          final riderIds = tempMatches.map((m) => m['rider_id']?.toString()).whereType<String>().toSet().toList();
          final Map<String, String> phoneMap = {};
          if (riderIds.isNotEmpty) {
            final ridersRes = await supabase
                .from('riders')
                .select('id, users(phone)')
                .inFilter('id', riderIds);
            for (final r in ridersRes) {
              final rid = r['id']?.toString();
              final phone = r['users']?['phone']?.toString();
              if (rid != null && phone != null) {
                phoneMap[rid] = phone;
              }
            }
          }

          for (var i = 0; i < tempMatches.length; i++) {
            final pid = tempMatches[i]['plan_id']?.toString();
            final rid = tempMatches[i]['rider_id']?.toString();
            if (pid != null) {
              final details = plansDetailsMap[pid];
              final bookedCount = bookedCounts[pid] ?? 0;
              final bookedWeight = bookedWeights[pid] ?? 0.0;
              
              final double maxWeight = double.tryParse(details?['max_weight_kg']?.toString() ?? details?['weight_preference']?.toString() ?? '') ?? 50.0;
              final double remainingWeight = (maxWeight - bookedWeight).clamp(0.0, maxWeight);

              tempMatches[i] = {
                ...tempMatches[i],
                if (details != null) ...{
                  'seats_preference': details['seats_preference'],
                  'max_bookings': details['max_bookings'],
                  'max_weight_kg': maxWeight,
                },
                'booked_count': bookedCount,
                'remaining_capacity_kg': remainingWeight,
                'phone': phoneMap[rid] ?? '',
              };
            }
          }
        }
      } catch (e) {
        debugPrint('Error enriching plan capacities: $e');
      }

      // Filter out rejected or cancelled riders, and do not show the current user's own travel plan
      tempMatches = tempMatches.where((m) {
        final rId = m['rider_id']?.toString();
        if (rId == null) return true;
        if (currentUserRiderId != null && rId == currentUserRiderId) return false;
        final status = assignmentStatuses[rId];
        return status != 'rejected' && status != 'cancelled';
      }).toList();

      // Sort matching plans to bring active/new offers to the front
      tempMatches.sort((a, b) {
        final statusA = assignmentStatuses[a['rider_id']?.toString()] ?? '';
        final statusB = assignmentStatuses[b['rider_id']?.toString()] ?? '';
        
        int scoreA = 0;
        if (statusA == 'sent') {
          scoreA = 2;
        } else if (statusA == 'accepted_by_user') {
          scoreA = 1;
        }
        
        int scoreB = 0;
        if (statusB == 'sent') {
          scoreB = 2;
        } else if (statusB == 'accepted_by_user') {
          scoreB = 1;
        }

        if (scoreA != scoreB) {
          return scoreB.compareTo(scoreA);
        }

        final dateA = DateTime.tryParse(a['travel_date']?.toString() ?? '') ?? DateTime.now();
        final dateB = DateTime.tryParse(b['travel_date']?.toString() ?? '') ?? DateTime.now();
        return dateA.compareTo(dateB);
      });

      matchedPlans = tempMatches;
      nearbyRiders = matchedPlans.map((m) => {
        'id': m['rider_id'],
        'current_lat': m['current_lat'],
        'current_lng': m['current_lng'],
        'current_heading': m['current_heading'] ?? 0.0,
        'vehicle_type': m['vehicle_type'] ?? 'bike',
        'full_name': m['full_name'],
        'rider_image': m['rider_image'],
      }).where((r) => r['current_lat'] != null && r['current_lng'] != null).toList();

      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {});
        refreshMap();
        _checkAndDrawRiderRoute();
      }
    } catch (e) {
      debugPrint('LOAD RIDERS ERROR => $e');
    } finally {
      // Issue 2 fix: stamped on every completed attempt (success or error) so a persistently
      // failing call can't be retried in a tight loop by the realtime/poll call sites either --
      // matches the existing loadingMatches guard's own "fail-safe, not fail-fast" behavior.
      _lastNearbyRidersCompletedAt = DateTime.now();
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          loadingMatches = false;
        });
      }
    }
  }

  void subscribeOrderAssignments() {
    if (assignmentsSubId != null && assignmentsSubChannel != null) {
      RealtimeManager.instance.unsubscribe(assignmentsSubChannel!, assignmentsSubId!);
      assignmentsSubId = null;
      assignmentsSubChannel = null;
    }
    assignmentsSubChannel = 'order-assignments-${widget.orderId}';
    assignmentsSubId = RealtimeManager.instance.subscribe(
      channelName: assignmentsSubChannel!,
      table: 'rider_assignments',
      owner: 'IntercitySearchingScreen_Assignments',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'order_id',
      filterValue: widget.orderId,
      callback: (payload) {
        if (!mounted) return;
        // R13 perf fix: loadNearbyRiders() now derives assignmentStatuses/assignmentFares
        // internally from its own rider_assignments fetch (same table, same order_id filter)
        // before it filters/sorts -- the separate loadAssignmentStatuses() call here was a
        // duplicate query against the exact same data. initialize()'s own call sequence
        // (which calls loadAssignmentStatuses() separately, not immediately before
        // loadNearbyRiders()) is unchanged.
        _nearbyRidersDebounceTimer?.cancel();
        _nearbyRidersDebounceTimer = Timer(const Duration(milliseconds: 500), () {
          if (mounted) loadNearbyRiders();
        });
      },
    );
  }

  Future<void> loadIntercityRequests() async {
    try {
      // Egress fix: narrowed to the fields this map is actually read for -- the "traveller_id|
      // route_id" key fields plus `status`/`id` (the only fields read off a stored request
      // elsewhere in this file, see the PartnerCard status-badge/reject/chat block).
      final res = await supabase
          .from('intercity_requests')
          .select('id, traveller_id, route_id, status')
          .eq('parcel_id', widget.orderId);
      final Map<String, Map<String, dynamic>> newRequests = {};
      for (final row in res) {
        // Keyed by "travellerId|routeId" (not traveller_id alone) so a request already sent for
        // an OLDER travel plan from this rider never masks a DIFFERENT (e.g. newer) travel plan
        // the same rider later publishes -- each plan card looks up its own exact key below.
        // NOTE: intercity_requests has no 'plan_id' column -- the travel plan reference is named
        // 'route_id' (see intercity_requests_route_id_fkey -> rider_travel_plans.id).
        final key = '${row['traveller_id']}|${row['route_id']}';
        newRequests[key] = Map<String, dynamic>.from(row);
      }
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          intercityRequests = newRequests;
        });
      }
    } catch (e) {
      debugPrint('LOAD INTERCITY REQUESTS ERROR => $e');
    }
  }

  void subscribeIntercityRequests() {
    if (intercityRequestsSubId != null && intercityRequestsSubChannel != null) {
      RealtimeManager.instance.unsubscribe(intercityRequestsSubChannel!, intercityRequestsSubId!);
      intercityRequestsSubId = null;
      intercityRequestsSubChannel = null;
    }
    intercityRequestsSubChannel = 'order-requests-${widget.orderId}';
    intercityRequestsSubId = RealtimeManager.instance.subscribe(
      channelName: intercityRequestsSubChannel!,
      table: 'intercity_requests',
      owner: 'IntercitySearchingScreen_Requests',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'parcel_id',
      filterValue: widget.orderId,
      callback: (payload) {
        if (!mounted) return;
        _intercityRequestsDebounceTimer?.cancel();
        _intercityRequestsDebounceTimer = Timer(const Duration(milliseconds: 500), () {
          if (mounted) loadIntercityRequests();
        });
      },
    );
  }

  /// Sends a "Travel Together" request to [match] — always gated behind
  /// [showTravelTogetherConfirmDialog] first, same as the Available Partners screen's
  /// _travelTogether, so a request is never sent without the user confirming who/where/when.
  Future<void> _travelTogether(Map<String, dynamic> match) async {
    final riderId = match['rider_id'].toString();
    final planId = match['plan_id']?.toString();

    final travelDate = match['travel_date'] != null
        ? DateTime.tryParse(match['travel_date'].toString())?.toLocal()
        : null;
    final pCity = _getCleanCityName(match['pickup_city'] ?? order?['pickup_city'], match['pickup_address'] ?? order?['pickup_address'], 'Pickup');
    final dCity = _getCleanCityName(match['destination_city'] ?? order?['destination_city'], match['destination_address'] ?? order?['destination_address'], 'Destination');

    final confirmed = await showTravelTogetherConfirmDialog(
      context,
      partnerName: (match['full_name'] ?? 'Drop Partner').toString(),
      route: '$pCity → $dCity',
      travelDate: travelDate != null ? IntercityMatchingService.formatShortDate(travelDate) : 'Not specified',
    );
    if (confirmed != true) return;

    // Update the widget state to trigger a UI rebuild with the new variables
    setState(() {
      requestingRiderId = riderId;
    });

    try {
      final double initialProposedFare = double.parse((order?['current_fare'] ?? order?['actual_fare'] ?? 0.0).toString());
      final isParcel = order?['order_type']?.toString() == 'intercity_parcel';
      final travelDateStr = order?['travel_date']?.toString();

      await IntercityMatchingService.sendTravelTogetherRequest(
        orderId: widget.orderId,
        riderId: riderId,
        planId: planId,
        passengerUserId: supabase.auth.currentUser!.id,
        initiatedBy: 'sender',
        proposedFare: initialProposedFare,
        isParcel: isParcel,
        travelDateIso: travelDateStr,
      );

      await loadIntercityRequests();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Request sent! Awaiting traveler response.'),
            backgroundColor: Color(0xFF7C3AED),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('TRAVEL TOGETHER ERROR => $e');
      if (mounted) {
        final msg = e is TravelPlanFullyBookedException ? e.toString() : 'Failed to send request: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          requestingRiderId = null;
        });
      }
    }
  }

  Future<void> loadAssignmentStatuses() async {
    try {
      final res = await supabase
          .from('rider_assignments')
          .select('rider_id, assignment_status, estimated_earnings')
          .eq('order_id', widget.orderId);

      final Map<String, String> newStatuses = {};
      final Map<String, double> newFares = {};
      for (final row in res) {
        newStatuses[row['rider_id'].toString()] = row['assignment_status'].toString();
        if (row['estimated_earnings'] != null) {
          newFares[row['rider_id'].toString()] = double.tryParse(row['estimated_earnings'].toString()) ?? 0.0;
        }
      }

      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          assignmentStatuses = newStatuses;
          assignmentFares = newFares;
        });
        _checkAndDrawRiderRoute();
      }
    } catch (e) {
      debugPrint('LOAD ASSIGNMENT STATUSES ERROR => $e');
    }
  }

  Future<void> acceptRider(String riderId) async {
    if (requestingRiderId != null) return;

    // Update the widget state to trigger a UI rebuild with the new variables
    setState(() {
      requestingRiderId = riderId;
    });

    try {
      final double totalCustomerFare = double.parse((order?['final_fare'] ?? order?['current_fare'] ?? order?['actual_fare'] ?? 0.0).toString());

      // 1. Check if assignment already exists
      // Egress fix: only existence + `id` are read below.
      final existingResList = await supabase
          .from('rider_assignments')
          .select('id')
          .eq('order_id', widget.orderId)
          .eq('rider_id', riderId)
          .limit(1);

      final existingRes = existingResList.isNotEmpty ? existingResList.first : null;

      if (existingRes != null) {
        await supabase
            .from('rider_assignments')
            .update({
              'assignment_status': 'accepted_by_user',
              'sent_at': DateTime.now().toUtc().toIso8601String(),
              'expires_at': DateTime.now().add(const Duration(hours: 24)).toUtc().toIso8601String(),
            })
            .eq('id', existingRes['id']);
      } else {
        await supabase
            .from('rider_assignments')
            .insert({
              'order_id': widget.orderId,
              'rider_id': riderId,
              'assignment_round': 1,
              'assignment_status': 'accepted_by_user',
              'distance_km': 0.0,
              'estimated_earnings': totalCustomerFare,
              'sent_at': DateTime.now().toUtc().toIso8601String(),
              'expires_at': DateTime.now().add(const Duration(hours: 24)).toUtc().toIso8601String(),
            });
      }

      await loadAssignmentStatuses();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Accepted rider plan! You can now chat to negotiate.'),
            backgroundColor: Color(0xFF7C3AED),
          ),
        );
      }
    } catch (e) {
      debugPrint('ACCEPT RIDER ERROR => $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to accept rider: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          requestingRiderId = null;
        });
      }
    }
  }

  Future<void> rejectRider(String riderId) async {
    if (requestingRiderId != null) return;

    // Update the widget state to trigger a UI rebuild with the new variables
    setState(() {
      requestingRiderId = riderId;
    });

    try {
      // Egress fix: only existence + `id` are read below.
      final existingResList = await supabase
          .from('rider_assignments')
          .select('id')
          .eq('order_id', widget.orderId)
          .eq('rider_id', riderId)
          .limit(1);

      final existingRes = existingResList.isNotEmpty ? existingResList.first : null;

      if (existingRes != null) {
        await supabase
            .from('rider_assignments')
            .update({
              'assignment_status': 'rejected',
              'responded_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', existingRes['id']);
      } else {
        await supabase
            .from('rider_assignments')
            .insert({
              'order_id': widget.orderId,
              'rider_id': riderId,
              'assignment_round': 1,
              'assignment_status': 'rejected',
              'distance_km': 0.0,
              'estimated_earnings': 0.0,
              'sent_at': DateTime.now().toUtc().toIso8601String(),
              'responded_at': DateTime.now().toUtc().toIso8601String(),
            });
      }

      await loadAssignmentStatuses();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Offer rejected!'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      debugPrint('REJECT RIDER ERROR => $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to reject: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          requestingRiderId = null;
        });
      }
    }
  }

  Future<void> confirmRider(String riderId) async {
    const confirmed = true;

    try {
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          loading = true;
        });
      }

      // SECURITY/INTEGRITY FIX: this used to write orders.rider_id/order_status directly, plus two
      // more separate rider_assignments writes, with no ownership check (any authenticated user
      // could target any order_id), no row lock (a race between two concurrent confirmations for
      // different rider offers on the same order wasn't prevented), and no order_status
      // precondition. Now delegates to confirm_intercity_search_rider(), a SECURITY DEFINER RPC
      // that verifies the caller owns the order, locks it FOR UPDATE, and does all three writes
      // atomically. See migration 20260730000006_confirm_intercity_search_rider.sql.
      final response = await supabase.rpc('confirm_intercity_search_rider', params: {
        'p_order_id': widget.orderId,
        'p_rider_id': riderId,
      });
      final data = response is Map ? Map<String, dynamic>.from(response) : null;
      if (data == null || data['success'] != true) {
        throw Exception((data?['message'] as String?) ?? 'Failed to confirm ride. Please try again.');
      }

      await orderController.fetchOrder();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ride confirmed successfully! starting active transit.'),
            backgroundColor: Colors.green,
          ),
        );
        openTracking();
      }
    } catch (e) {
      debugPrint('CONFIRM RIDER ERROR => $e');
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          loading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to confirm ride: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<bool> _showDoubleConfirmDialog() async {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final firstConfirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF131929) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.shrink(),
              const SizedBox(height: 18),
              Text(
                'Confirm Drop Partner Offer?',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Do you want to confirm this traveler for your shipment? You will enter direct transit.',
                style: TextStyle(
                  color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                  fontSize: 13,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        side: BorderSide(color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade300),
                      ),
                      // Close/pop the current screen or modal bottom sheet context
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: const Color(0xFF7C3AED),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      // Close/pop the current screen or modal bottom sheet context
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Confirm'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );

    if (firstConfirm != true) return false;
    if (!mounted) return false;

    final secondConfirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF131929) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.shrink(),
              const SizedBox(height: 18),
              const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 40),
              const SizedBox(height: 12),
              Text(
                'Final Confirmation',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Are you absolutely sure? Once confirmed, other riders will be rejected, and you will finalize booking with this rider.',
                style: TextStyle(
                  color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                  fontSize: 13,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        side: BorderSide(color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade300),
                      ),
                      // Close/pop the current screen or modal bottom sheet context
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Go Back'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: Colors.orange.shade800,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      // Close/pop the current screen or modal bottom sheet context
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Yes, Absolutely Sure'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );

    return secondConfirm == true;
  }

  Future<void> _checkAndDrawRiderRoute() async {
    if (order == null || _fetchingRoute) return;

    String? acceptedRiderId;
    for (final entry in assignmentStatuses.entries) {
      if (entry.value == 'accepted_by_user') {
        acceptedRiderId = entry.key;
        break;
      }
    }

    if (acceptedRiderId == null) {
      if (_lastRouteRiderId != null) {
        _lastRouteRiderId = null;
        if (mounted) {
          // Update the widget state to trigger a UI rebuild with the new variables
          setState(() {
            _riderRouteCoords = [];
          });
        }
        refreshMap();
      }
      return;
    }

    if (_lastRouteRiderId == acceptedRiderId) return;

    final match = matchedPlans.firstWhere(
      (m) => m['rider_id']?.toString() == acceptedRiderId,
      orElse: () => null,
    );

    if (match == null) return;

    final double? riderLat = double.tryParse(match['current_lat']?.toString() ?? '');
    final double? riderLng = double.tryParse(match['current_lng']?.toString() ?? '');
    final double? pickupLat = double.tryParse(order!['pickup_lat']?.toString() ?? '');
    final double? pickupLng = double.tryParse(order!['pickup_lng']?.toString() ?? '');

    if (riderLat == null || riderLng == null || pickupLat == null || pickupLng == null) return;

    _fetchingRoute = true;
    _lastRouteRiderId = acceptedRiderId;

    try {
      final route = await OlaMapService.getDirections(
        originLat: riderLat,
        originLng: riderLng,
        destinationLat: pickupLat,
        destinationLng: pickupLng,
      ).timeout(const Duration(seconds: 8));

      if (route != null && route.polylinePoints.isNotEmpty) {
        final List<List<double>> coords = route.polylinePoints.map((pt) => [pt['lng']!, pt['lat']!]).toList();
        if (mounted) {
          // Update the widget state to trigger a UI rebuild with the new variables
          setState(() {
            _riderRouteCoords = coords;
          });
          refreshMap();
        }
      }
    } catch (e) {
      debugPrint('Error fetching rider-to-pickup route: $e');
      final fallback = [
        [riderLng, riderLat],
        [pickupLng, pickupLat]
      ];
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          _riderRouteCoords = fallback;
        });
        refreshMap();
      }
    } finally {
      _fetchingRoute = false;
    }
  }

  // P1 fix (consolidate duplicate searching-phase polling): see ride_searching_screen.dart's
  // identical fix for the full rationale. startRiderRefresh() used to own its OWN independent
  // Timer.periodic(5s), running alongside RealtimeOrderController's own internal polling fallback
  // -- two separate timer objects on the same 5s cadence for the entire searching phase. Not a
  // duplicate-data bug (this is a nearby-riders MAP DISPLAY query; RealtimeOrderController's poll
  // is this order's own status/assignment) -- but two independently-scheduled network round trips
  // per tick where one shared tick source is enough. During pure searching this order's realtime
  // channel receives zero deliveries (dispatch writes to rider_assignments/intercity_requests, not
  // orders, until acceptance), so RealtimeOrderController's own fallback poll already fires
  // unconditionally every 5s the whole time, and _onOrderUpdate() below already fires on that same
  // cadence (TransportOrder has no operator== override, so a fresh instance always notifies) --
  // piggybacking the nearby-riders refresh there removes one whole timer object with no change to
  // its effective cadence or the adaptive bands below. Does not touch RealtimeOrderController
  // itself, or rider discovery/matching, which is server-side (match-intercity-riders/start-dispatch)
  // and reaches the passenger via RealtimeOrderController's own realtime + fallback poll, unchanged.
  DateTime? _searchingStartedAt;
  DateTime? _lastNearbyRidersFetchAt;

  Duration _nearbyRidersRefreshInterval(Duration elapsed) {
    if (elapsed < const Duration(seconds: 60)) return const Duration(seconds: 5);
    if (elapsed < const Duration(seconds: 180)) return const Duration(seconds: 10);
    return const Duration(seconds: 20);
  }

  void startRiderRefresh() {
    _searchingStartedAt ??= DateTime.now();
  }

  // Same gating logic the old dedicated timer used, just invoked from _onOrderUpdate() instead of
  // an independent Timer.periodic.
  void _maybeRefreshNearbyRiders() {
    if (_searchingStartedAt == null) return;
    Future(() async {
        final now = DateTime.now();
        final interval = _nearbyRidersRefreshInterval(now.difference(_searchingStartedAt!));
        if (_lastNearbyRidersFetchAt != null && now.difference(_lastNearbyRidersFetchAt!) < interval) {
          return;
        }
        _lastNearbyRidersFetchAt = now;
        await loadNearbyRiders();
      },
    );
  }

  void initializeMap() {
    try {
      // Setup the web controller instance for rendering interactive map content
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..enableZoom(true)
        ..setNavigationDelegate(NavigationDelegate(
          onPageFinished: (_) {
            _injectMap();
          },
        ))
        ..loadFlutterAsset('assets/map/ola_map_searching.html');

      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          mapController = controller;
        });
      } else {
        mapController = controller;
      }
    } catch (e) {
      debugPrint('Error initializing map controller: $e');
    }
  }

  void _injectMap() {
    final apiKey = Env.olaMapsApiKey;
    final safeApiKey = apiKey.replaceAll('"', '');
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeMode = isDark ? 'dark' : 'light';
    final pLat = order?['pickup_lat'] ?? 0.0;
    final pLng = order?['pickup_lng'] ?? 0.0;
    mapController?.runJavaScript(
      'if(window.initSearchingMap){ window.initSearchingMap("$safeApiKey", "$themeMode", $pLat, $pLng); }'
    );
  }

  void refreshMap() {
    try {
      final ridersJson = jsonEncode(nearbyRiders);
      mapController?.runJavaScript('if(window.updateRiders){ window.updateRiders($ridersJson); }');
      
      final routeCoords = _riderRouteCoords;
      if (routeCoords.isNotEmpty) {
        final routeJson = jsonEncode(routeCoords);
        mapController?.runJavaScript('if(window.updateRiderRoute){ window.updateRiderRoute($routeJson); }');
      } else {
        mapController?.runJavaScript('if(window.clearRiderRoute){ window.clearRiderRoute(); }');
      }
    } catch (_) {}
  }

  void openTracking() {
    if (!mounted || _trackingOpened) return;
    _trackingOpened = true;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => IntercityTrackingScreen(
          orderId: widget.orderId,
        ),
      ),
    );
  }

  Future<void> cancelRide() async {
    if (cancelling) return;

    try {
      // Update the widget state to trigger a UI rebuild with the new variables
      setState(() {
        cancelling = true;
      });

      // SECURITY/INTEGRITY FIX: this used to fall back to a raw `orders.update(order_status:
      // 'cancelled')` on ANY exception from cancel-order -- that direct write skips the
      // rider_assignments/order_assignment_logs cleanup and order_status_history audit insert
      // cancel-order exists specifically to guarantee. Let a genuine failure surface as an error
      // (caught by the outer try/catch below) so the user can retry, instead of silently
      // corrupting cancellation bookkeeping.
      await supabase.functions.invoke(
        'cancel-order',
        body: {
          'order_id': widget.orderId,
          'cancelled_by': 'user',
          'cancel_reason': 'Cancelled by user',
        },
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Order cancelled')),
      );

      Navigator.popUntil(context, (route) => route.isFirst);
    } catch (e) {
      debugPrint('CANCEL ERROR => $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request closed')),
        );
        Navigator.popUntil(context, (route) => route.isFirst);
      }
    } finally {
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          cancelling = false;
        });
      }
    }
  }

  Future<void> retrySearchWithBoost(double nextFare) async {
    try {
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          boosting = true;
        });
      }

      final double priorCurrentFare = double.tryParse(order?['current_fare']?.toString() ?? '') ?? 0.0;
      final double additionalAmount = nextFare - priorCurrentFare;

      // boost-order-fare computes and validates every actual financial figure server-side (GST
      // split, commission, rider earning, boost breakdown, promo preservation) -- this only ever
      // sends the plain "how much more" the passenger chose.
      final response = await supabase.functions.invoke(
        'boost-order-fare',
        body: {
          'order_id': widget.orderId,
          'additional_amount': additionalAmount,
        },
      );

      final data = response.data;
      if (data == null || data['success'] != true) {
        final errMsg = data?['error'] ?? data?['message'] ?? 'Unknown error';
        throw Exception(errMsg);
      }

      // Phase 3 fix (Issue 4): this boost path never synced intercity_requests.proposed_fare at
      // all -- unlike increaseFare() (which had the same intent but a broken column name). Keeps
      // the negotiation snapshot from going stale after a "boost & search again" retry too.
      final serverFare = double.tryParse(data['order']?['current_fare']?.toString() ?? '') ?? nextFare;
      await _syncProposedFareToRequest(serverFare);

      await orderController.fetchOrder();

      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          showTimeoutRetryOverlay = false;
        });
      }
    } catch (e) {
      debugPrint('RETRY BOOST ERROR => $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to retry search: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          boosting = false;
        });
      }
    }
  }

  Widget _buildTimeoutRetryOverlay(BuildContext context) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final double actualFare = double.tryParse(order?['actual_fare']?.toString() ?? '') ?? 0.0;
    final double currentFare = double.tryParse(order?['current_fare']?.toString() ?? '') ?? 0.0;
    
    double boostedBase = actualFare * 1.20;
    double boostedFareInclusive = double.parse((boostedBase * 1.05).toStringAsFixed(2));
    if (boostedFareInclusive <= currentFare) {
      boostedFareInclusive = double.parse((currentFare * 1.20).toStringAsFixed(2));
    }
    double increaseAmount = boostedFareInclusive - currentFare;

    return Stack(
      children: [
        Positioned.fill(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              color: Colors.black.withOpacity(0.55),
            ),
          ),
        ),
        Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF131926) : Colors.white,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: isDark ? Colors.white.withOpacity(0.05) : const Color(0xFFE2E8F0),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 32,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.orange,
                      size: 36,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'No Partner Match Found',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Available travelers on this route corridor are currently busy. Boost your offer fare to attract active travelers instantly.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      height: 1.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '₹${currentFare.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          decoration: TextDecoration.lineThrough,
                          color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Icon(
                        Icons.trending_up_rounded,
                        color: Color(0xFF10B981),
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '₹${boostedFareInclusive.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF10B981),
                          letterSpacing: -0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withOpacity(0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3), width: 1.2),
                    ),
                    child: Text(
                      '+₹${increaseAmount.toStringAsFixed(2)} FOR HIGH VISIBILITY',
                      style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF10B981),
                      ),
                    ),
                  ),
                  const SizedBox(height: 26),
                  Container(
                    width: double.infinity,
                    height: 48,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF10B981), Color(0xFF059669)],
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shadowColor: Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: boosting
                          ? null
                          : () => retrySearchWithBoost(boostedFareInclusive),
                      child: boosting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                            )
                          : const Text(
                              'Boost & Search Again',
                              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                            ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent, width: 1.2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () {
                        // Update the widget state to trigger a UI rebuild with the new variables
                        setState(() {
                          showTimeoutRetryOverlay = false;
                          _nextTimeoutTime = DateTime.now().add(Duration(seconds: 300 + Random().nextInt(300)));
                        });
                      },
                      child: const Text(
                        'Cancel',
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // Inline mapHtml function deprecated and removed in favor of ola_map_searching.html asset.

  Widget buildStatusCard() {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final typedOrder = orderController.orderNotifier.value;
    final title = typedOrder != null 
        ? OrderStatusResolver.getStatusTitle(typedOrder.flowType, typedOrder.orderStatus)
        : 'Searching nearby partners';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF7C3AED),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF7C3AED).withValues(alpha: isDark ? 0.2 : 0.1),
            blurRadius: 16,
          ),
        ],
      ),
      child: Row(
        children: [
          ScaleTransition(
            scale: pulseAnimation,
            child: Container(
              height: 42,
              width: 42,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.search_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    if (typedOrder != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '(#${typedOrder.orderCode})',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  nearbyRiders.isEmpty
                      ? 'Searching for active partners nearby...'
                      : '${nearbyRiders.length} partners active nearby',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          const SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  void _showFullScreenMap(BuildContext context) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Map',
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, anim1, anim2) {
        return Scaffold(
          backgroundColor: isDark ? const Color(0xFF090D1A) : Colors.grey.shade50,
          body: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: mapController != null
                      ? WebViewWidget(controller: mapController!)
                      : const Center(
                          child: CircularProgressIndicator(),
                        ),
                ),
                // Back/Close Button floating
                Positioned(
                  top: 16,
                  left: 16,
                  child: GestureDetector(
                    onTap: () {
                      // Close/pop the current screen or modal bottom sheet context
                      Navigator.pop(context);
                      refreshMap();
                    },
                    child: Container(
                      height: 40,
                      width: 40,
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF131926).withOpacity(0.9) : Colors.white.withOpacity(0.9),
                        shape: BoxShape.circle,
                        boxShadow: const [
                          BoxShadow(color: Colors.black26, blurRadius: 8),
                        ],
                      ),
                      child: Icon(
                        Icons.close_rounded,
                        color: isDark ? Colors.white : Colors.black,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRouteMapCard(bool isDark, TransportOrder typedOrder) {
    return const SizedBox.shrink();
  }

  String formatFullDateTime(DateTime dt) {
    final months = [
      'June', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    final monthStr = months[dt.month - 1];
    final hourVal = dt.hour;
    final amPm = hourVal >= 12 ? 'PM' : 'AM';
    final hour12 = hourVal % 12 == 0 ? 12 : hourVal % 12;
    final minStr = dt.minute.toString().padLeft(2, '0');
    return "$monthStr ${dt.day}, ${dt.year} $hour12:$minStr $amPm";
  }

  Widget buildRideInfoCard() {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final typedOrder = orderController.orderNotifier.value;
    if (typedOrder == null) {
      return const SizedBox();
    }

    final isParcel = typedOrder.orderType == 'intercity_parcel' || typedOrder.orderType == 'local_parcel';
    final String vehicleName = isParcel ? '-' : (typedOrder.vehicleType ?? 'vehicle').toUpperCase();
    final String dateStr = order?['travel_date'] != null 
        ? _formatTravelDate(order!['travel_date']) 
        : '';
    final String orderTypeStr = isParcel ? 'Intercity Parcel' : 'Intercity Ride';
    final String pickupAddr = order?['pickup_address']?.toString() ?? 'Pickup Location';
    final String destAddr = order?['destination_address']?.toString() ?? 'Destination Location';
    final String paymentLabel = (order?['payment_status'] == 'paid' || typedOrder.paymentStatus == 'paid') ? 'PAID' : 'CASH';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF131926) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: isDark
            ? Border.all(color: const Color(0xFF1E293B), width: 1.0)
            : Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.2 : 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                orderTypeStr.toUpperCase(),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF7C3AED),
                  letterSpacing: 0.5,
                ),
              ),
              Text(
                'ID: #${typedOrder.orderCode}',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, thickness: 0.5, color: Colors.white10),
          const SizedBox(height: 12),
          Row(
            children: [
              // Travel Date
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'TRAVEL DATE',
                      style: TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                        color: textGray,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      dateStr.isNotEmpty ? dateStr : 'Not Scheduled',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
              ),
              // Vehicle Mode
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'VEHICLE MODE',
                      style: TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                        color: textGray,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      vehicleName,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
              ),
              // Payment Mode / Status
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'PAYMENT',
                      style: TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                        color: textGray,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      paymentLabel,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: paymentLabel == 'PAID' ? Colors.green : const Color(0xFF7C3AED),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1, thickness: 0.5, color: Colors.white10),
          const SizedBox(height: 16),
          // Route details
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'PICKUP ADDRESS',
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.bold,
                  color: textGray,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                pickupAddr,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white : Colors.black87,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'DESTINATION ADDRESS',
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.bold,
                  color: textGray,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                destAddr,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white : Colors.black87,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFareBreakup(double targetFare, double actualFare, Color primaryColor) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final double boostedBase = targetFare / 1.05;
    final double boostAmt = boostedBase - actualFare;
    final double gstAmt = boostedBase * 0.05;
    
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final labelColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final borderCol = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
    final bgCol = isDark ? const Color(0xFF0C101C) : const Color(0xFFF8FAFC);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgCol,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderCol),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Base Fare', style: TextStyle(fontSize: 11, color: labelColor, fontWeight: FontWeight.w500)),
              Text('₹${roundFareForDisplay(actualFare)}', style: TextStyle(fontSize: 11, color: textColor, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Boosted Amount', style: TextStyle(fontSize: 11, color: labelColor, fontWeight: FontWeight.w500)),
              Text('₹${roundFareForDisplay(boostAmt.clamp(0.0, double.infinity))}', style: TextStyle(fontSize: 11, color: textColor, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('GST (5%)', style: TextStyle(fontSize: 11, color: labelColor, fontWeight: FontWeight.w500)),
              Text('₹${roundFareForDisplay(gstAmt)}', style: TextStyle(fontSize: 11, color: textColor, fontWeight: FontWeight.w600)),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Divider(height: 1, thickness: 0.5),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Estimated Fare', style: TextStyle(fontSize: 12, color: textColor, fontWeight: FontWeight.w800)),
              Text('₹${roundFareForDisplay(targetFare)}', style: TextStyle(fontSize: 12, color: primaryColor, fontWeight: FontWeight.w800)),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildBoostCard() {
    if (order == null) return const SizedBox();

    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final actualFare = double.parse(order!['actual_fare'].toString());
    final currentFare = double.parse(order!['current_fare'].toString());
    final maxFare = 99999.0;
    final boosts = [5, 10, 15];
    final isMaxReached = currentFare >= (maxFare - 0.01);
    const primaryColor = Color(0xFF7C3AED);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF131929) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: isDark ? Border.all(color: const Color(0xFF1E293B)) : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.04),
            blurRadius: 12,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.local_fire_department,
                color: Colors.orange,
                size: 18,
              ),
              const SizedBox(width: 6),
              Text(
                'Increase fare',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
              const Spacer(),
              Text(
                '₹${currentFare.toStringAsFixed(2)}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (isMaxReached) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1A22) : const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: isDark ? const Color(0xFF3F1D1D) : const Color(0xFFFCA5A5)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    color: isDark ? const Color(0xFFF87171) : const Color(0xFFEF4444),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Max boost limit reached (₹${maxFare.toStringAsFixed(2)}). Waiting for riders...',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: isDark ? const Color(0xFFFDA4AF) : const Color(0xFF991B1B),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            Text(
              'Max increase: ₹${maxFare.toStringAsFixed(2)}',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 12),
            _buildFareBreakup(currentFare, actualFare, primaryColor),
            const SizedBox(height: 12),
            Row(
              children: boosts.map((boost) {
                final double boostAmt = actualFare * (boost / 100);
                final double nextFare = currentFare + (boostAmt * 1.05);
                final disabled = nextFare > maxFare;

                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: disabled
                          ? null
                          : () async {
                              await increaseFare(nextFare, boost);
                            },
                      child: Container(
                        height: 44,
                        decoration: BoxDecoration(
                          color: disabled 
                              ? (isDark ? const Color(0xFF1E293B) : Colors.grey.shade200) 
                              : (isDark ? const Color(0xFF1E293B) : const Color(0xFFEEF4FF)),
                          borderRadius: BorderRadius.circular(14),
                          border: (!disabled && isDark) ? Border.all(color: const Color(0xFF2563EB).withOpacity(0.3)) : null,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '+$boost%',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: disabled ? (isDark ? Colors.white30 : Colors.grey) : const Color(0xFF2563EB),
                              ),
                            ),
                            Text(
                              '₹${nextFare.toStringAsFixed(2)}',
                              style: TextStyle(
                                fontSize: 10,
                                color: disabled ? (isDark ? Colors.white30 : Colors.grey) : (isDark ? Colors.white70 : Colors.black),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: showCustomBoostSheet,
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF7C3AED) : Colors.black,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: Text(
                    'Custom Increase',
                    style: TextStyle(
                      color: isDark ? Colors.black : Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // nextFare is only ever used to compute how much MORE the passenger is offering over the
  // order's current fare -- a plain UI preference, not a financial calculation. Every actual
  // figure (GST split, commission, rider earning, boost breakdown, promo preservation) is computed
  // server-side by boost-order-fare; this function never calculates or writes any of them itself.
  // Phase 3 fix (Issue 4): intercity_requests.proposed_fare is a denormalized snapshot taken once
  // at request-send time -- orders.final_fare/current_fare (written correctly by boost-order-fare)
  // is the single authoritative post-boost amount. This keeps the snapshot from going stale after
  // ANY boost path, instead of leaving screens that still read proposed_fare first (Travel Plan
  // Details, Intercity Bookings) showing the old amount. Previously this used the wrong column name
  // ('order_id' -- intercity_requests has no such column, only 'parcel_id') so it silently failed
  // on every call; also broadened from 2 statuses to 3 ('fare_agreed' can still precede
  // order_status leaving 'searching', during which boost-order-fare still permits boosting).
  Future<void> _syncProposedFareToRequest(double serverFare) async {
    try {
      await supabase
          .from('intercity_requests')
          .update({'proposed_fare': serverFare})
          .eq('parcel_id', widget.orderId)
          .inFilter('status', ['request_sent', 'discussion_started', 'fare_agreed']);
    } catch (err) {
      debugPrint('Error updating intercity_requests proposed fare boost: $err');
    }
  }

  Future<void> increaseFare(double nextFare, int boost) async {
    try {
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          boosting = true;
        });
      }

      final double priorCurrentFare = double.tryParse(order?['current_fare']?.toString() ?? '') ?? 0.0;
      final double additionalAmount = nextFare - priorCurrentFare;

      final response = await supabase.functions.invoke(
        'boost-order-fare',
        body: {
          'order_id': widget.orderId,
          'additional_amount': additionalAmount,
        },
      );

      final data = response.data;
      if (data == null || data['success'] != true) {
        throw Exception(data?['error'] ?? data?['message'] ?? 'Failed to increase fare');
      }

      final serverFare = double.tryParse(data['order']?['current_fare']?.toString() ?? '') ?? nextFare;

      // Also update any active intercity negotiation request's proposed fare, to the
      // server-confirmed amount (never the client's own pre-request number).
      await _syncProposedFareToRequest(serverFare);

      await orderController.fetchOrder();

      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          showBargainControls = false;
          _showCustomInput = false;
          _customFareController.clear();
          localFare = serverFare;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Fare increased to ₹${serverFare.toStringAsFixed(2)}'),
          ),
        );
      }
    } catch (e) {
      debugPrint('BOOST ERROR => $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to increase fare: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          boosting = false;
        });
      }
    }
  }

  Future<bool> confirmFareIncrease(double fare) async {
    return await showModalBottomSheet<bool>(
          context: context,
          backgroundColor: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          builder: (_) => Container(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Confirm Fare Increase',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 12),
                Text(
                  'This increases your offer to ₹${fare.toStringAsFixed(2)} to attract riders faster.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        // Close/pop the current screen or modal bottom sheet context
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                        ),
                        // Close/pop the current screen or modal bottom sheet context
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Confirm'),
                      ),
                    ),
                  ],
                )
              ],
            ),
          ),
        ) ??
        false;
  }

  void showCustomBoostSheet() {
    final customAmountController = TextEditingController(text: '50');
    const primaryColor = Color(0xFF7C3AED);
    // Present a premium modal bottom sheet drawer for user input/actions
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final actualFare = double.parse(order!['actual_fare'].toString());
            final currentFare = double.parse(order!['current_fare'].toString());
            final double enteredBoostAmt = double.tryParse(customAmountController.text) ?? 0.0;
            final double nextFare = currentFare + (enteredBoostAmt * 1.05);
            final double maxFare = 99999.0;
            final disabled = enteredBoostAmt <= 0 || nextFare > maxFare;

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Container(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Custom Fare Boost',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: customAmountController,
                      keyboardType: TextInputType.number,
                      autofocus: true,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      decoration: InputDecoration(
                        labelText: 'Boost Increase Amount (₹)',
                        hintText: 'e.g. 50, 100...',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                        prefixText: '₹ ',
                      ),
                      onChanged: (_) {
                        setSheetState(() {});
                      },
                    ),
                    const SizedBox(height: 14),
                    if (nextFare > maxFare)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: Text(
                          'Total price cannot exceed ₹99,999',
                          style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'New Estimated Fare:',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                        Text(
                          '₹${nextFare.toStringAsFixed(2)}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: primaryColor),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _buildFareBreakup(nextFare, actualFare, primaryColor),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: disabled ? Colors.grey : const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: disabled
                            ? null
                            : () async {
                                // Close/pop the current screen or modal bottom sheet context
                                Navigator.pop(context);
                                await increaseFare(nextFare, 0);
                              },
                        child: const Text('Increase Offer'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) => customAmountController.dispose());
  }

  Widget _buildTrustMetricRow(String label, String value, String description, Color accentColor, bool isDark) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: accentColor.withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.shield_outlined, color: accentColor, size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                  ),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      color: accentColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: TextStyle(
                  fontSize: 10.5,
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSimpleMetricCard(String label, String value, IconData icon, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF131929) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? Colors.white.withOpacity(0.04) : const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF7C3AED), size: 16),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: 9,
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void showRiderPlanDetails(Map<String, dynamic> match) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final planDate = DateTime.tryParse(match['travel_date']?.toString() ?? '')?.toLocal() ?? DateTime.now();
    final dateStr = "${planDate.day.toString().padLeft(2, '0')}/${planDate.month.toString().padLeft(2, '0')}/${planDate.year}";
    final planTimeStr = TimeFormatHelper.formatTime12Hour(planDate);
    final double rating = double.tryParse((match['rating'] ?? 5.0).toString()) ?? 5.0;
    
    final double remainingWeight = double.tryParse(match['remaining_capacity_kg']?.toString() ?? '') ?? double.tryParse(match['weight_preference']?.toString() ?? '50') ?? 50.0;
    final double maxWeight = double.tryParse(match['max_weight_kg']?.toString() ?? '') ?? double.tryParse(match['weight_preference']?.toString() ?? '50') ?? 50.0;
    
    final reliability = (match['reliability_score'] as num?)?.round() ?? 95;
    final totalCompleted = match['total_completed'] ?? 0;
    final onTimeRate = (match['on_time_rate'] as num?)?.round() ?? 100;
    final matchScore = (match['score'] as num?)?.round() ?? 90;

    final isParcel = order?['order_type'] == 'intercity_parcel';

    // Present a premium modal bottom sheet drawer for user input/actions
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF131929) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return SafeArea(
          child: Container(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Center(
                    child: Text(
                      'Traveler Profile & Plan',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: isDark ? Colors.white : Colors.black,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  
                  // Traveler Profile Header Card
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: isDark ? Colors.white.withOpacity(0.04) : const Color(0xFFE2E8F0)),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 28,
                          backgroundColor: isDark ? const Color(0xFF090D1A) : Colors.grey.shade200,
                          backgroundImage: match['rider_image'] != null && match['rider_image'].toString().isNotEmpty
                              ? NetworkImage(match['rider_image'].toString())
                              : null,
                          child: match['rider_image'] == null || match['rider_image'].toString().isEmpty
                              ? const Icon(Icons.person, color: Color(0xFF7C3AED), size: 32)
                              : null,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                match['full_name'] ?? 'Traveler Partner',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: isDark ? Colors.white : Colors.black,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: match['account_status'] == 'online' ? Colors.green.withOpacity(0.15) : Colors.grey.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      match['account_status'] == 'online' ? 'ONLINE' : 'OFFLINE',
                                      style: TextStyle(
                                        color: match['account_status'] == 'online' ? Colors.green : Colors.grey,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  const Icon(Icons.star_rounded, color: Colors.amber, size: 14),
                                  const SizedBox(width: 3),
                                  Text(
                                    rating.toStringAsFixed(1),
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: isDark ? Colors.white70 : Colors.black87,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  
                  // Trust Profile Section
                  Text(
                    'TRUST PROFILE',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isDark ? const Color(0xFF64748B) : Colors.grey,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: isDark ? Colors.white.withOpacity(0.04) : const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      children: [
                        _buildTrustMetricRow('Match Score', '$matchScore% Match', 'Calculated dynamically based on route overlap, vehicle type, and capacity fit.', Colors.green, isDark),
                        const Divider(height: 24),
                        _buildTrustMetricRow('Reliability Rating', '$reliability% Reliable', 'Reflects completion rate, rating weight, and overall experience points.', const Color(0xFF4C84FF), isDark),
                        const Divider(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: _buildSimpleMetricCard('Completed runs', '$totalCompleted', Icons.inventory_2_outlined, isDark),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildSimpleMetricCard('On-time rate', '$onTimeRate%', Icons.timer_outlined, isDark),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  
                  // Route & Travel Details
                  Text(
                    'ROUTE & TRAVEL DETAILS',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isDark ? const Color(0xFF64748B) : Colors.grey,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: isDark ? Colors.white.withOpacity(0.04) : const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      children: [
                        _buildDetailRow(
                          Icons.route_rounded,
                          'Route Corridor',
                          '${_getCleanCityName(order?['pickup_city'], order?['pickup_address'], 'Pickup')} to ${_getCleanCityName(order?['destination_city'], order?['destination_address'], 'Destination')}',
                        ),
                        const Divider(height: 20),
                        _buildDetailRow(
                          Icons.calendar_month_rounded,
                          'Travel Date & Time',
                          '$dateStr at $planTimeStr',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Capacity & Vehicle details
                  Text(
                    'CAPACITY & VEHICLE',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isDark ? const Color(0xFF64748B) : Colors.grey,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: isDark ? Colors.white.withOpacity(0.04) : const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isParcel) ...[
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Remaining Weight Capacity',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                '${remainingWeight.toStringAsFixed(1)} kg / ${maxWeight.toStringAsFixed(1)} kg',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? Colors.white : Colors.black,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: maxWeight > 0 ? (remainingWeight / maxWeight).clamp(0.0, 1.0) : 0.0,
                              backgroundColor: isDark ? Colors.white10 : Colors.grey.shade200,
                              color: const Color(0xFF7C3AED),
                              minHeight: 6,
                            ),
                          ),
                          const Divider(height: 24),
                        ],
                        Builder(
                          builder: (context) {
                            final vehicleTypeStr = (match['vehicle_type']?.toString() ?? 'cab').toLowerCase();
                            final IconData vehicleIcon;
                            if (vehicleTypeStr == 'bike') {
                              vehicleIcon = Icons.motorcycle_rounded;
                            } else if (vehicleTypeStr == 'auto') {
                              vehicleIcon = Icons.electric_rickshaw_rounded;
                            } else {
                              vehicleIcon = Icons.local_taxi_rounded;
                            }
                            return _buildDetailRow(
                              vehicleIcon,
                              'Vehicle Verification',
                              vehicleTypeStr.toUpperCase(),
                            );
                          }
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _getCleanCityName(String? city, String? address, String defaultName) {
    return LocationDisplayService.resolveCity(
      city: city,
      address: address,
      fallback: defaultName,
    );
  }


  Widget _buildDetailRow(IconData icon, String label, String value) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: const Color(0xFF7C3AED)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: isDark ? const Color(0xFF64748B) : Colors.grey,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  





  Future<bool> _showExitConfirmation(BuildContext context) async {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF131929) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF131929) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.shrink(),
              const SizedBox(height: 18),
              Text(
                'Exit Active Screen?',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your search will continue in the background. You can track or resume it at any time from the Activity tab.',
                style: TextStyle(
                  color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                  fontSize: 13,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        side: BorderSide(color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade300),
                      ),
                      // Close/pop the current screen or modal bottom sheet context
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(
                        'Keep Tracking',
                        style: TextStyle(
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: const Color(0xFF7C3AED),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      // Close/pop the current screen or modal bottom sheet context
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text(
                        'Exit to Home',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ) ?? false;
  }

  @override
  // Build method responsible for rendering the entire widget layout hierarchy on the viewport
  Widget build(BuildContext context) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final typedOrder = orderController.orderNotifier.value;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final exit = await _showExitConfirmation(context);
        if (exit && context.mounted) {
          Navigator.popUntil(context, (route) => route.isFirst);
        }
      },
      child: Scaffold(
        backgroundColor: isDark ? const Color(0xFF090D1A) : Colors.grey.shade50,
        appBar: AppBar(
          backgroundColor: isDark ? const Color(0xFF131929) : Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: isDark ? Colors.white : const Color(0xFF0F172A)),
            onPressed: () async {
              final exit = await _showExitConfirmation(context);
              if (exit && context.mounted) {
                Navigator.popUntil(context, (route) => route.isFirst);
              }
            },
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Finding the best match...',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Searching for reliable travel partners',
                style: TextStyle(
                  fontSize: 10.5,
                  color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: Icon(Icons.groups_rounded, color: isDark ? Colors.white : const Color(0xFF0F172A)),
              tooltip: 'Available Partners',
              onPressed: () {
                final travelDateStr = order?['travel_date']?.toString();
                final travelDate = travelDateStr != null ? DateTime.tryParse(travelDateStr)?.toLocal() : null;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AvailablePartnersScreen(
                      orderId: widget.orderId,
                      pickupCity: _getCleanCityName(order?['pickup_city'], order?['pickup_address'], 'Pickup'),
                      destinationCity: _getCleanCityName(order?['destination_city'], order?['destination_address'], 'Destination'),
                      initialDate: travelDate ?? DateTime.now(),
                      isParcel: order?['order_type']?.toString() == 'intercity_parcel',
                    ),
                  ),
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: Center(
                child: SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: isDark ? Colors.white : const Color(0xFF7C3AED),
                  ),
                ),
              ),
            ),
            Theme(
              // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
              data: Theme.of(context).copyWith(
                cardColor: isDark ? const Color(0xFF131929) : Colors.white,
              ),
              child: PopupMenuButton<String>(
                icon: Icon(Icons.more_vert_rounded, color: isDark ? Colors.white : const Color(0xFF0F172A)),
                onSelected: (value) async {
                  if (value == 'cancel') {
                    final confirm = await showModalBottomSheet<bool>(
                      context: context,
                      backgroundColor: isDark ? const Color(0xFF131929) : Colors.white,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                      ),
                      builder: (context) {
                        return Container(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Cancel Order?',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Are you sure you want to cancel your request?',
                                style: TextStyle(
                                  color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                                  fontSize: 13,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 24),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        side: BorderSide(color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade300),
                                      ),
                                      // Close/pop the current screen or modal bottom sheet context
                                      onPressed: () => Navigator.pop(context, false),
                                      child: Text(
                                        'Keep Searching',
                                        style: TextStyle(
                                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.red,
                                        foregroundColor: Colors.white,
                                        elevation: 0,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                      // Close/pop the current screen or modal bottom sheet context
                                      onPressed: () => Navigator.pop(context, true),
                                      child: const Text(
                                        'Cancel Request',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    );

                    if (confirm == true) {
                      await cancelRide();
                    }
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem<String>(
                    value: 'cancel',
                    child: Row(
                      children: [
                        Icon(Icons.cancel_outlined, color: Colors.redAccent, size: 18),
                        SizedBox(width: 8),
                        Text(
                          'Cancel Request',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        body: loading
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF7C3AED)),
              )
            : SizedBox.expand(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).padding.bottom + 80),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 1. Order details card
                            buildRideInfoCard(),
                            const SizedBox(height: 16),

                            // 1b. Route Map Card
                            if (typedOrder != null) ...[
                              _buildRouteMapCard(isDark, typedOrder),
                              const SizedBox(height: 16),
                            ],

                            // 2. Increase offer / preset fare boosting
                            _buildBoostFareSection(isDark),
                            const SizedBox(height: 20),

                            // 3. Matched travelers section
                            _buildMatchedTravelersSection(isDark),
                          ],
                        ),
                      ),
                    ),
                    if (showTimeoutRetryOverlay)
                      Positioned.fill(
                        child: _buildTimeoutRetryOverlay(context),
                      ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildVehicleAsset(String? vehicleType, {double width = 36, double height = 36}) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final vt = (vehicleType ?? 'cab').toLowerCase();
    
    IconData iconData = Icons.directions_car_rounded;
    Color iconColor = const Color(0xFF7C3AED);
    if (vt == 'bike') {
      iconData = Icons.two_wheeler_rounded;
      iconColor = const Color(0xFF10B981);
    } else if (vt == 'auto') {
      iconData = Icons.electric_rickshaw_rounded;
      iconColor = Colors.orange;
    }
    
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF131926) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.06),
          width: 1,
        ),
      ),
      child: Icon(
        iconData,
        color: iconColor,
        size: 18,
      ),
    );
  }

  String _getVehicleModel(String? vehicleType) {
    final vt = (vehicleType ?? 'cab').toLowerCase();
    if (vt == 'bike') return 'Premium Bike';
    if (vt == 'auto') return 'Electric Auto';
    if (vt == 'cab' || vt == 'car') return 'Comfort Cab';
    return 'Waydrop Partner';
  }

  Widget _buildBoostFareSection(bool isDark) {
    final typedOrder = orderController.orderNotifier.value;
    if (typedOrder == null || order == null) return const SizedBox();

    final double currentFare = double.parse((order?['current_fare'] ?? order?['actual_fare'] ?? 0.0).toString());
    final double actualFare = double.parse((order?['actual_fare'] ?? 0.0).toString());
    const double maxAllowedFare = 50000.0;

    return StatefulBuilder(
      builder: (context, setLocalState) {
        if (localFare < currentFare) {
          localFare = currentFare;
        }

        Widget buildPresetChipLocal(String label, double amount) {
          final bool isSelected = !_showCustomInput && (localFare == currentFare + amount);
          return GestureDetector(
            onTap: () {
              setLocalState(() {
                _showCustomInput = false;
                _customFareController.clear();
                if (isSelected) {
                  localFare = currentFare;
                } else {
                  localFare = currentFare + amount;
                }
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF7C3AED).withOpacity(0.15)
                    : (isDark ? const Color(0xFF090D1A) : const Color(0xFFF1F5F9)),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected ? const Color(0xFF7C3AED) : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? const Color(0xFF7C3AED) : (isDark ? Colors.white : Colors.black),
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          );
        }

        Widget buildCustomToggleChipLocal() {
          final bool isSelected = _showCustomInput;
          return GestureDetector(
            onTap: () {
              setLocalState(() {
                if (_showCustomInput) {
                  _showCustomInput = false;
                  _customFareController.clear();
                  localFare = currentFare;
                } else {
                  _showCustomInput = true;
                  localFare = currentFare;
                }
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF7C3AED).withOpacity(0.15)
                    : (isDark ? const Color(0xFF090D1A) : const Color(0xFFF1F5F9)),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected ? const Color(0xFF7C3AED) : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Text(
                'Custom',
                style: TextStyle(
                  color: isSelected ? const Color(0xFF7C3AED) : (isDark ? Colors.white : Colors.black),
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          );
        }

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF131926) : Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: isDark ? Border.all(color: const Color(0xFF1E293B), width: 1.0) : Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isDark ? 0.2 : 0.03),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Your Offer',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: textGray,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Text(
                        currentFare > 0.0 ? '₹${roundFareForDisplay(currentFare)}' : '—',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          setLocalState(() {
                            _showCustomInput = !_showCustomInput;
                            if (!_showCustomInput) {
                              localFare = currentFare;
                              _customFareController.clear();
                            }
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF7C3AED).withOpacity(0.08),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.edit_rounded,
                            color: Color(0xFF7C3AED),
                            size: 14,
                          ),
                        ),
                      ),
                      if (currentFare > actualFare) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withOpacity(0.12),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3), width: 1.0),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.trending_up_rounded, color: Color(0xFF10B981), size: 12),
                              SizedBox(width: 4),
                              Text(
                                'BOOSTED',
                                style: TextStyle(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF10B981),
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'You can boost your offer',
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF7C3AED),
                      ),
                    ),
                  ),
                ],
              ),
              // currentFare (order.current_fare) is already the GST-inclusive payable total -- see
              // FareBreakdown.fromOrder / calculate-order-pricing -- so this is a presentation note,
              // never a client-side GST addition. Matches the "Inclusive of GST" wording/styling
              // already used on intercity_ride_booking_screen.dart's ESTIMATED FARE.
              if (currentFare > 0.0) ...[
                const SizedBox(height: 6),
                const Row(
                  children: [
                    Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 13),
                    SizedBox(width: 4),
                    Text(
                      'Inclusive of GST',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF10B981),
                      ),
                    ),
                  ],
                ),
              ],
              const Divider(height: 24, thickness: 1, color: Colors.white10),
              
              if (currentFare >= maxAllowedFare) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E1A22) : const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: isDark ? const Color(0xFF3F1D1D) : const Color(0xFFFCA5A5)),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        color: Colors.redAccent,
                        size: 18,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Max fare limit of ₹50,000 reached.',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.redAccent,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        if (localFare > currentFare)
                          Text(
                            'New Offer: ₹${roundFareForDisplay(localFare)}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF10B981),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        buildPresetChipLocal('+ ₹10', 10.0),
                        buildPresetChipLocal('+ ₹20', 20.0),
                        buildPresetChipLocal('+ ₹50', 50.0),
                        buildCustomToggleChipLocal(),
                      ],
                    ),

                    // 3. Custom Input Box (animated size)
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      child: _showCustomInput
                          ? Padding(
                              padding: const EdgeInsets.only(top: 14),
                              child: TextField(
                                controller: _customFareController,
                                keyboardType: TextInputType.number,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? Colors.white : Colors.black,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Enter custom add amount...',
                                  hintStyle: const TextStyle(color: textGray, fontSize: 12),
                                  prefixText: '+ ₹ ',
                                  prefixStyle: const TextStyle(color: Color(0xFF7C3AED), fontWeight: FontWeight.bold),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  filled: true,
                                  fillColor: isDark ? const Color(0xFF090D1A) : const Color(0xFFF1F5F9),
                                  border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      borderSide: BorderSide(
                                        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      borderSide: const BorderSide(color: Color(0xFF7C3AED), width: 1.5),
                                    ),
                                  ),
                                  onChanged: (val) {
                                    final double addAmt = double.tryParse(val) ?? 0.0;
                                    final double target = currentFare + addAmt;
                                    if (target > maxAllowedFare) {
                                      final double maxAdd = (maxAllowedFare - currentFare).clamp(0.0, maxAllowedFare);
                                      _customFareController.text = maxAdd.toStringAsFixed(2);
                                      _customFareController.selection = TextSelection.fromPosition(
                                        TextPosition(offset: _customFareController.text.length),
                                      );
                                      setLocalState(() {
                                        localFare = maxAllowedFare;
                                      });
                                    } else {
                                      setLocalState(() {
                                        localFare = target;
                                      });
                                    }
                                  },
                                ),
                              )
                          : const SizedBox.shrink(),
                    ),
                    
                    // Action Button for Fare Increase
                    AnimatedCrossFade(
                      firstChild: const SizedBox(height: 0),
                      secondChild: Padding(
                        padding: const EdgeInsets.only(top: 12.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildFareBreakup(localFare, actualFare, const Color(0xFF7C3AED)),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: Container(
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [Color(0xFF7C3AED), Color(0xFF5B21B6)],
                                  ),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.transparent,
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    shadowColor: Colors.transparent,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  onPressed: boosting
                                      ? null
                                      : () async {
                                          setLocalState(() {
                                            boosting = true;
                                          });
                                          await increaseFare(localFare, 0);
                                          setLocalState(() {
                                            boosting = false;
                                            _showCustomInput = false;
                                            _customFareController.clear();
                                            localFare = currentFare;
                                          });
                                        },
                                  child: boosting
                                      ? const SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Text(
                                          'Confirm Fare of ₹${roundFareForDisplay(localFare)}',
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                            ),
                                        ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      crossFadeState: localFare > currentFare
                          ? CrossFadeState.showSecond
                          : CrossFadeState.showFirst,
                      duration: const Duration(milliseconds: 250),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildMatchedTravelersSection(bool isDark) {
    final typedOrder = orderController.orderNotifier.value;
    if (typedOrder == null) return const SizedBox();

    // The passenger's own authoritative payable fare (same value shown as "Your Offer" above,
    // and the same value _travelTogether() actually sends as proposed_fare) -- passed into every
    // PartnerCard so it displays THIS, never the traveller's own price_per_seat (a different
    // number computed off the traveller's own, usually different-distance, posted route). Two
    // competing totals rendered on the same screen for the same booking was the root cause of the
    // ₹497 vs ₹463.84 mismatch.
    final double yourFare = double.tryParse((order?['current_fare'] ?? order?['actual_fare'] ?? 0.0).toString()) ?? 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title
        Row(
          children: [
            Text(
              "Available Drop Partners",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Date selection ChoiceChips
        if (matchedPlans.isNotEmpty) ...[
          const SizedBox(height: 8),

          Builder(
            builder: (context) {
              final now = DateTime.now();
              final today = DateTime(now.year, now.month, now.day);
              final tomorrow = today.add(const Duration(days: 1));
              final endOfWeek = today.add(const Duration(days: 7));

              final filteredPlans = matchedPlans.where((match) {
                if (match['travel_date'] == null) return true;
                final planDate = DateTime.tryParse(match['travel_date'].toString())?.toLocal() ?? DateTime.now();
                if (_selectedDateFilter == 'Today') {
                  return planDate.year == now.year && planDate.month == now.month && planDate.day == now.day;
                } else if (_selectedDateFilter == 'Tomorrow') {
                  return planDate.year == tomorrow.year && planDate.month == tomorrow.month && planDate.day == tomorrow.day;
                } else if (_selectedDateFilter == 'This Week') {
                  return planDate.isAfter(now.subtract(const Duration(minutes: 5))) && planDate.isBefore(endOfWeek);
                }
                return true;
              }).toList();

              if (filteredPlans.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      'No matching Drop Partners found for $_selectedDateFilter.',
                      style: const TextStyle(color: textGray, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ),
                );
              }

              return ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                itemCount: filteredPlans.length,
                itemBuilder: (context, index) {
                  final match = filteredPlans[index];
                  final riderId = match['rider_id'].toString();
                  final isRequestingThis = requestingRiderId == riderId;
                  final isRideOrder = order?['order_type']?.toString() == 'intercity_ride';
                  final pCity = _getCleanCityName(match['pickup_city'] ?? order?['pickup_city'], match['pickup_address'] ?? order?['pickup_address'], 'Pickup');
                  final dCity = _getCleanCityName(match['destination_city'] ?? order?['destination_city'], match['destination_address'] ?? order?['destination_address'], 'Destination');
                  // Scoped to THIS specific travel plan -- a request already sent for a different
                  // (older) plan from the same rider must not mark this plan as already requested.
                  final req = intercityRequests['$riderId|${match['plan_id']}'];

                  // Once a request exists, render its live negotiation status (badge +
                  // reject/call/chat) in place of the default PartnerCard button — the request
                  // lands as 'request_sent' (pending traveller Accept/Reject) the instant it's
                  // created by IntercityMatchingService.sendTravelTogetherRequest, and only ever
                  // reaches 'discussion_started'/'fare_agreed' if a future chat-negotiation step
                  // moves it there.
                  Widget? statusWidget;
                  if (req != null) {
                    final reqStatus = req['status']?.toString() ?? 'request_sent';
                    String statusLabel = 'Sent';
                    Color badgeColor = Colors.orange;

                    if (reqStatus == 'discussion_started' || reqStatus == 'fare_agreed') {
                      statusLabel = 'Negotiating';
                      badgeColor = const Color(0xFF7C3AED);
                    } else if (reqStatus == 'confirmed' || reqStatus == 'paid') {
                      statusLabel = 'Confirmed';
                      badgeColor = Colors.green;
                    } else if (reqStatus == 'in_progress') {
                      statusLabel = 'In Transit';
                      badgeColor = Colors.blue;
                    } else if (reqStatus == 'completed') {
                      statusLabel = 'Completed';
                      badgeColor = Colors.green;
                    } else if (reqStatus == 'cancelled') {
                      statusLabel = 'Cancelled';
                      badgeColor = Colors.red;
                    } else if (reqStatus == 'rejected') {
                      // Issue 2 fix: a rejected request previously fell through to the default
                      // 'Sent'/orange badge, indistinguishable from a still-pending request, and
                      // (below) kept showing live Call/Chat actions as if the traveller were still
                      // an available match.
                      statusLabel = 'Rejected';
                      badgeColor = Colors.red;
                    }

                    statusWidget = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: badgeColor.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: badgeColor.withOpacity(0.2)),
                          ),
                          child: Text(
                            statusLabel.toUpperCase(),
                            style: TextStyle(
                              color: badgeColor,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (['request_sent', 'discussion_started', 'fare_agreed'].contains(reqStatus)) ...[
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () async {
                              try {
                                await IntercityMatchingService.rejectTravelTogetherRequest(
                                  requestId: req['id'].toString(),
                                  actorType: 'sender',
                                );
                                await loadIntercityRequests();
                              } catch (e) {
                                debugPrint('Error rejecting travel together request: $e');
                              }
                            },
                            child: Container(
                              height: 34,
                              width: 34,
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.red.withOpacity(0.2)),
                              ),
                              child: const Center(
                                child: Icon(Icons.close_rounded, color: Colors.redAccent, size: 18),
                              ),
                            ),
                          ),
                        ],
                        // Issue 2 fix: Call and Chat are only ever presented as live actions for a
                        // request that is still actually pursuable. A 'rejected' request must not
                        // remain actionable and Chat specifically must not be offered for it.
                        if (reqStatus != 'rejected') ...[
                          const SizedBox(width: 8),
                          if (match['phone'] != null && match['phone'].toString().isNotEmpty) ...[
                            GestureDetector(
                              onTap: () async {
                                final phone = match['phone'].toString().replaceAll(RegExp(r'\s+'), '');
                                final uri = Uri.parse('tel:$phone');
                                try {
                                  await launchUrl(uri);
                                } catch (_) {}
                              },
                              child: Container(
                                height: 34,
                                width: 34,
                                decoration: BoxDecoration(
                                  color: Colors.green.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.green.withOpacity(0.2)),
                                ),
                                child: const Center(
                                  child: Text(
                                    'Call',
                                    style: TextStyle(
                                      color: Colors.green,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          SizedBox(
                            height: 34,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF3B82F6),
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              onPressed: () {
                                // Navigate to a new screen layout using Flutter's Navigator router
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => OrderChatScreen(
                                      orderId: widget.orderId,
                                      riderId: riderId,
                                      chatTitle: match['full_name'] ?? 'Drop Partner',
                                      riderImage: match['rider_image']?.toString(),
                                    ),
                                  ),
                                ).then((_) {
                                  loadIntercityRequests();
                                });
                              },
                              child: const Text(
                                'Chat',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      ],
                    );
                  }

                  return GestureDetector(
                    onTap: () => showRiderPlanDetails(match),
                    child: PartnerCard(
                      partner: {
                        ...match,
                        'pickup_city': pCity,
                        'destination_city': dCity,
                      },
                      isParcel: !isRideOrder,
                      isSending: isRequestingThis,
                      alreadySent: req != null,
                      onTravelTogether: () => _travelTogether(match),
                      statusWidget: statusWidget,
                      yourFare: yourFare > 0 ? yourFare : null,
                    ),
                  );
                },
              );
            }
          ),
        ] else ...[
          // Empty State
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.explore_off_rounded, size: 48, color: isDark ? Colors.white24 : Colors.grey.shade400),
                  const SizedBox(height: 12),
                  Text(
                    'No matching Drop Partners found.',
                    style: TextStyle(fontSize: 14, color: isDark ? Colors.white54 : Colors.grey.shade600, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  static const Color textGray = Color(0xFF94A3B8);

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
}
