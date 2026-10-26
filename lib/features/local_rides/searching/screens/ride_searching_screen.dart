import 'package:waydrop/core/services/diagnostics/ride_diagnostics.dart';
import 'package:waydrop/core/services/diagnostics/ride_diagnostics_owner.dart';
/// ============================================================================
/// File: ride_searching_screen.dart
///
/// Module:
/// Local Rides → Searching
///
/// Purpose:
/// Search and negotiate fares with nearby rider partners.
///
/// Responsibilities:
/// • Render searching/matching animations, show dynamic bidding/negotiations.
/// • Allow ride request cancellation.
///
/// Related:
/// ride_location_screen.dart
/// ride_tracking_screen.dart
/// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;
import 'package:flutter/material.dart';
import 'package:waydrop/core/config/env.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:waydrop/models/transport_order.dart';
import 'package:waydrop/core/services/realtime/realtime_order_controller.dart';
import 'package:waydrop/core/services/database/dispatch_config_cache.dart';
import 'package:waydrop/core/navigation/flow_modules.dart';
import 'package:waydrop/features/local_rides/tracking/screens/ride_tracking_screen.dart';
import 'package:waydrop/shared/helpers/insets.dart';
import 'package:waydrop/core/navigation/nav_trace.dart';

class RideSearchingScreen extends StatefulWidget {
  final String orderId;

  const RideSearchingScreen({
    super.key,
    required this.orderId,
  });

  @override
  State<RideSearchingScreen> createState() => _RideSearchingScreenState();
}

class _RideSearchingScreenState extends State<RideSearchingScreen> with TickerProviderStateMixin {
  final supabase = Supabase.instance.client;
  late RealtimeOrderController orderController;

  Map<String, dynamic>? order; // Kept as map for backward compat/RPC queries
  List<dynamic> nearbyRiders = [];
  // Sourced from the same server-authoritative dispatch_config Round 1 values start-dispatch
  // itself uses (never a client-invented radius) -- fetched once and cached, not re-fetched on
  // every 5s refresh tick. Defaults only cover the brief window before the first fetch resolves.
  double _nearbyRiderRadiusKm = 5.0;
  int _nearbyRiderLimit = 25;
  bool _nearbyConfigLoaded = false;
  bool _nearbyRidersFetchInFlight = false;
  bool loading = true;
  bool cancelling = false;
  double localFare = 0.0;
  bool showBargainControls = false;
  bool boosting = false;
  bool _showCustomInput = false;
  final TextEditingController _customFareController = TextEditingController();

  late AnimationController pulseController;
  late Animation<double> pulseAnimation;
  WebViewController? mapController;

  final apiKey = Env.olaMapsApiKey;

  late DateTime _nextTimeoutTime;

  late final RideDiagnosticOwner _rideDiagnosticOwner;

  @override
  void initState() {
    super.initState();
    _rideDiagnosticOwner = RideDiagnosticOwner.widget(() => mounted, surface: RideSurface.passengerSearching);
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

    mapController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(true)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          _injectMap();
        },
      ))
      ..loadFlutterAsset('assets/map/ola_map_searching.html');

    orderController = RealtimeOrderController(orderId: widget.orderId);
    initialize();
  }

  @override
  void dispose() {
    _rideDiagnosticOwner.dispose();
    _customFareController.dispose();
    pulseController.dispose();
    orderController.orderNotifier.removeListener(_onOrderUpdate);
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
        Navigator.pop(context);
      }
      return;
    }

    _syncOrderMap(currentOrder);

    await loadNearbyRiders();
    if (!mounted) return;
    initializeMap();
    startRiderRefresh();
  }

  void _syncOrderMap(TransportOrder obj) {
    if (!mounted) return;
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
      };
      if (localFare == 0.0 || obj.currentFare > localFare) {
        localFare = obj.currentFare;
      }
      loading = false;
    });
  }

  bool showTimeoutRetryOverlay = false;
  bool _trackingOpened = false;
  bool _terminalHandled = false;

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

    // The order row itself stays visible via RLS regardless of status (unlike the null-row case
    // above), so a server-side terminal transition -- most importantly the auto-expiry added for
    // "old ride requests"/stale-order cleanup (order_status = 'expired' once no rider accepted
    // within the search window) -- must be checked explicitly here, or this screen would keep
    // showing "searching" indefinitely on an order the server has already closed out.
    if ((typedOrder.isCancelled || typedOrder.isExpired) && !_terminalHandled) {
      _terminalHandled = true;
      debugPrint(
        '[TRACE_CANCEL] RideSearchingScreen._onOrderUpdate() claimed _terminalHandled '
        'order=${widget.orderId} status=${typedOrder.orderStatus} epoch=${DateTime.now().millisecondsSinceEpoch}',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              typedOrder.isExpired
                  ? 'No Drop Partners were available for your request. Please try booking again.'
                  : 'Order was cancelled.',
            ),
          ),
        );
        NavTrace.begin('RideSearchingScreen._onOrderUpdate', 'pop (terminal order=${widget.orderId})');
        Navigator.of(context).pop();
        NavTrace.end('RideSearchingScreen._onOrderUpdate', 'pop (terminal order=${widget.orderId})');
      }
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
      setState(() {
        showTimeoutRetryOverlay = true;
      });
    }
  }

  Future<void> loadNearbyRiders() async {
    if (_nearbyRidersFetchInFlight) return;
    _nearbyRidersFetchInFlight = true;

    try {
      if (!mounted) return;
      final currentOrder = order;
      if (currentOrder == null) return;

      if (!_nearbyConfigLoaded) {
        try {
          // Egress fix (Fix #6): shares the same session-wide DispatchConfigCache
          // rider_orders_screen.dart already uses, instead of this screen independently
          // fetching the identical dispatch_config row (the sibling ParcelSearchingScreen fetches
          // it too) -- same 30s TTL, same row shape, just not a fresh network round trip per screen.
          final config = await DispatchConfigCache.get(
            () => supabase
                .from('dispatch_config')
                .select('round_1_radius_km, round_1_batch_size')
                .eq('is_active', true)
                .maybeSingle(),
          );
          if (!mounted) return;
          final radius = double.tryParse(config?['round_1_radius_km']?.toString() ?? '');
          final limit = int.tryParse(config?['round_1_batch_size']?.toString() ?? '');
          if (radius != null && radius > 0) _nearbyRiderRadiusKm = radius;
          if (limit != null && limit > 0) _nearbyRiderLimit = limit;
        } catch (_) {
          // Keep the defaults above; never block the nearby-count display on this.
        } finally {
          if (mounted) _nearbyConfigLoaded = true;
        }
      }

      if (!mounted) return;

      // Same server-authoritative eligibility predicate dispatch itself uses (find_nearby_riders),
      // with the SAME Round 1 radius/limit start-dispatch's own first pass uses -- so this count
      // never drifts from what Round 1 dispatch would actually find eligible right now.
      final response = await supabase.rpc(
        'find_nearby_riders',
        params: {
          'p_order_id': widget.orderId,
          'p_pickup_lat': currentOrder['pickup_lat'],
          'p_pickup_lng': currentOrder['pickup_lng'],
          'p_radius_km': _nearbyRiderRadiusKm,
          'p_limit': _nearbyRiderLimit,
        },
      );
      if (!mounted) return;

      // find_nearby_riders returns the identity column as `rider_id`, but the shared map JS
      // (assets/map/ola_map_core.js) keys every marker off `id`, matching the convention every
      // other nearby-riders caller uses (raw `riders` table selects, which have a native `id`
      // column). Without this remap, rider.id is undefined for every row here -- collapsing all
      // riders into a single "undefined" buffer entry and throwing inside the WebView's
      // applyBufferedUpdates() on rider.id.toString() every 5-second refresh.
      final rawRiders = (response as List?) ?? [];
      nearbyRiders = rawRiders
          .map((r) => {...Map<String, dynamic>.from(r as Map), 'id': r['rider_id']})
          .toList();
      setState(() {});
      refreshMap();
    } catch (e) {
      debugPrint('LOAD RIDERS ERROR => $e');
    } finally {
      _nearbyRidersFetchInFlight = false;
    }
  }

  // P1 fix (consolidate duplicate searching-phase polling): startRiderRefresh() used to own its
  // OWN independent Timer.periodic(5s), running alongside RealtimeOrderController's own internal
  // polling fallback -- two separate timer objects both firing on the same 5s cadence for the
  // entire searching phase. They were never fetching the same data (this is a nearby-riders MAP
  // DISPLAY query; RealtimeOrderController's poll is this order's own status/assignment), so this
  // was never a duplicate-data bug -- but it was two independently-scheduled network round trips
  // per tick where one shared tick source is enough.
  //
  // ROOT CAUSE CONFIRMED (not assumed): during pure searching (no rider assigned yet), this
  // order's realtime channel receives zero deliveries -- dispatch writes to rider_assignments, not
  // orders, until acceptance -- so RealtimeOrderController's own fallback poll fires unconditionally
  // every 5s the entire time (its realtime-health gate never engages). Every one of those ticks
  // calls _applyOrderData(), which always assigns a NEW TransportOrder instance to
  // orderNotifier.value (TransportOrder has no operator== override, so ValueNotifier's identity
  // check never short-circuits) -- meaning _onOrderUpdate() below already fires reliably on the
  // same ~5s cadence as the old dedicated timer did, driven by network activity that is already
  // happening. Piggybacking the nearby-riders refresh on that existing signal removes one whole
  // timer object without changing its effective cadence or the adaptive bands below.
  //
  // This does NOT touch RealtimeOrderController itself (shared by tracking screens too -- untouched
  // here) and does NOT touch rider discovery/dispatch matching, which is entirely server-side
  // (start-dispatch) and driven to the passenger via RealtimeOrderController's own realtime +
  // fallback poll, unchanged. This nearby-riders list is cosmetic map reassurance only.
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

  // Same gating logic the old dedicated timer used, just invoked from _onOrderUpdate() (see its
  // doc comment above) instead of an independent Timer.periodic.
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
    _injectMap();
  }

  void _injectMap() {
    if (order == null || mapController == null) return;
    final apiKey = Env.olaMapsApiKey;
    final safeApiKey = apiKey.replaceAll('"', '');
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
    } catch (_) {}
  }

  void openTracking() {
    if (!mounted || _trackingOpened) return;
    _trackingOpened = true;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => RideTrackingScreen(
          orderId: widget.orderId,
        ),
      ),
    );
  }

  Future<void> cancelRide() async {
    // _terminalHandled is shared with _onOrderUpdate()'s cancelled/expired branch, which pops
    // this screen independently when the realtime postgres_changes push for this same
    // cancellation beats this function's own cancel-order response back to the client. Claiming
    // it here, synchronously and before the await below, makes the two navigation sources
    // mutually exclusive -- whichever fires first is the only one that ever calls Navigator.pop
    // /popUntil, instead of both racing on a context whose route the other already removed
    // (which emptied the Navigator stack and produced a black screen).
    if (cancelling || _terminalHandled) return;
    _terminalHandled = true;

    try {
      setState(() {
        cancelling = true;
      });
      debugPrint(
        '[TRACE_CANCEL] RideSearchingScreen.cancelRide() claimed _terminalHandled order=${widget.orderId} '
        'epoch=${DateTime.now().millisecondsSinceEpoch}',
      );

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

      NavTrace.begin('RideSearchingScreen.cancelRide', 'popUntil isFirst (success, order=${widget.orderId})');
      Navigator.popUntil(context, (route) => route.isFirst);
      NavTrace.end('RideSearchingScreen.cancelRide', 'popUntil isFirst (success, order=${widget.orderId})');
    } catch (e) {
      debugPrint('CANCEL ERROR => $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request closed')),
        );
        NavTrace.begin('RideSearchingScreen.cancelRide', 'popUntil isFirst (error, order=${widget.orderId})');
        Navigator.popUntil(context, (route) => route.isFirst);
        NavTrace.end('RideSearchingScreen.cancelRide', 'popUntil isFirst (error, order=${widget.orderId})');
      }
    } finally {
      if (mounted) {
        setState(() {
          cancelling = false;
        });
      }
    }
  }

  // Inline mapHtml function deprecated and removed in favor of ola_map_searching.html asset.

  Widget buildStatusCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final typedOrder = orderController.orderNotifier.value;
    final title = typedOrder != null 
        ? OrderStatusResolver.getStatusTitle(typedOrder.flowType, typedOrder.orderStatus)
        : 'Searching nearby partners';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF10B981),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.2 : 0.1),
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

  Widget buildRideInfoCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final typedOrder = orderController.orderNotifier.value;
    if (typedOrder == null) {
      return const SizedBox();
    }

    final module = FlowModuleFactory.resolve(typedOrder.flowType);
    
    String headerTitle = 'RIDE';

    final isBike = typedOrder.vehicleType == 'bike';
    final isAuto = typedOrder.vehicleType == 'auto';
    final isDelivery = typedOrder.vehicleType == 'delivery';
    headerTitle = (typedOrder.vehicleType ?? 'vehicle').toUpperCase();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(
        color: Colors.transparent,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                height: 50,
                width: 50,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E222B) : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFF10B981),
                    width: 1.5,
                  ),
                ),
                padding: const EdgeInsets.all(2),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/images/${typedOrder.vehicleType ?? "bike"}.jpg',
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Icon(
                        isBike 
                            ? Icons.two_wheeler 
                            : isAuto 
                                ? Icons.electric_rickshaw 
                                : isDelivery
                                    ? Icons.local_shipping
                                    : Icons.local_taxi,
                        color: const Color(0xFF10B981),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          headerTitle,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                          ),
                        ),
                        Text(
                          '#${typedOrder.orderCode}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF10B981),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      typedOrder.paymentMode.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                constraints: const BoxConstraints(maxWidth: 90),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '₹${typedOrder.currentFare.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                    ),
                    if (typedOrder.boostPercentage > 0)
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '+${typedOrder.boostPercentage.toStringAsFixed(0)}% boosted',
                          style: const TextStyle(
                            fontSize: 9,
                            color: Color(0xFF10B981),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          
          // Inject polymorphic searching metadata layout here! (User requests 3 & 4)
          const SizedBox(height: 12),
          module.buildSearchingMeta(context, typedOrder),

          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                children: [
                  Container(
                    height: 10,
                    width: 10,
                    decoration: const BoxDecoration(
                      color: Color(0xFF10B981),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Container(
                    width: 1.5,
                    height: 42,
                    color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade300,
                  ),
                  Container(
                    height: 10,
                    width: 10,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      typedOrder.pickupAddress,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      typedOrder.destinationAddress,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFareBreakup(double targetFare, double actualFare, Color primaryColor) {
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
              Text('₹${actualFare.toStringAsFixed(2)}', style: TextStyle(fontSize: 11, color: textColor, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Boosted Amount', style: TextStyle(fontSize: 11, color: labelColor, fontWeight: FontWeight.w500)),
              Text('₹${boostAmt.clamp(0.0, double.infinity).toStringAsFixed(2)}', style: TextStyle(fontSize: 11, color: textColor, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('GST (5%)', style: TextStyle(fontSize: 11, color: labelColor, fontWeight: FontWeight.w500)),
              Text('₹${gstAmt.toStringAsFixed(2)}', style: TextStyle(fontSize: 11, color: textColor, fontWeight: FontWeight.w600)),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Divider(height: 1, thickness: 0.5),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total Fare', style: TextStyle(fontSize: 12, color: textColor, fontWeight: FontWeight.w800)),
              Text('₹${targetFare.toStringAsFixed(2)}', style: TextStyle(fontSize: 12, color: primaryColor, fontWeight: FontWeight.w800)),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildBoostCard() {
    if (order == null) return const SizedBox();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final actualFare = double.parse(order!['actual_fare'].toString());
    final currentFare = double.parse(order!['current_fare'].toString());
    final maxFare = 99999.0;
    final boosts = [5, 10, 15];
    final isMaxReached = currentFare >= (maxFare - 0.01);
    const primaryColor = Color(0xFF10B981);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171A21) : Colors.white,
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
                  color: isDark ? const Color(0xFF10B981) : Colors.black,
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
  // order's current fare -- a plain UI preference (which preset chip / custom amount they picked),
  // not a financial calculation. Every actual figure (GST split, commission, rider earning, boost
  // breakdown, promo preservation) is computed server-side by boost-order-fare; this function
  // never calculates or writes any of them itself.
  Future<void> increaseFare(double nextFare, int boost) async {
    try {
      if (mounted) {
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

      await orderController.fetchOrder();

      final serverFare = double.tryParse(data['order']?['current_fare']?.toString() ?? '') ?? nextFare;

      if (mounted) {
        setState(() {
          showBargainControls = false;
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
        setState(() {
          boosting = false;
        });
      }
    }
  }

  // nextFare is only ever used to compute how much MORE the passenger is offering over the
  // order's current fare -- boost-order-fare computes and validates every actual financial figure
  // server-side; this function never calculates or writes any of them itself.
  Future<void> retrySearchWithBoost(double nextFare) async {
    try {
      if (mounted) {
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
        final errMsg = data?['error'] ?? data?['message'] ?? 'Unknown error';
        throw Exception(errMsg);
      }

      await orderController.fetchOrder();

      if (mounted) {
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
        setState(() {
          boosting = false;
        });
      }
    }
  }

  Widget _buildTimeoutRetryOverlay(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final double actualFare = double.tryParse(order?['actual_fare']?.toString() ?? '') ?? 0.0;
    final double currentFare = double.tryParse(order?['current_fare']?.toString() ?? '') ?? 0.0;
    
    double boostedBase = ((actualFare * 1.20) / 5).round() * 5.0;
    double boostedFareInclusive = double.parse((boostedBase * 1.05).toStringAsFixed(2));
    if (boostedFareInclusive <= currentFare) {
      boostedFareInclusive = ((currentFare * 1.20) / 5).round() * 5.0;
    }
    double increaseAmount = boostedFareInclusive - currentFare;

    return Container(
      color: Colors.black.withOpacity(0.85),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF171A21) : Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
              width: 1.0,
            ),
          ),
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.orange,
                    size: 32,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'No Drop Partner Found',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Drop Partners are busy right now. Boost your fare to increase visibility and get accepted faster.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                    height: 1.5,
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
                    Icon(
                      Icons.trending_up_rounded,
                      color: isDark ? const Color(0xFF10B981) : const Color(0xFF059669),
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '₹${boostedFareInclusive.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: isDark ? const Color(0xFF10B981) : const Color(0xFF059669),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF10B981).withOpacity(0.15) : const Color(0xFFECFDF5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '+₹${increaseAmount.toStringAsFixed(2)} for higher rider visibility',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isDark ? const Color(0xFF10B981) : const Color(0xFF059669),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
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
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      setState(() {
                        showTimeoutRetryOverlay = false;
                        _nextTimeoutTime = DateTime.now().add(Duration(seconds: 300 + Random().nextInt(300)));
                      });
                    },
                    child: const Text(
                      'Cancel',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
    const primaryColor = Color(0xFF10B981);
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


  Widget buildModernBottomCard(ScrollController scrollController) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final typedOrder = orderController.orderNotifier.value;
    if (typedOrder == null || order == null) return const SizedBox();

    final double currentFare = double.parse((order?['current_fare'] ?? order?['actual_fare'] ?? 0.0).toString());
    final double actualFare = double.parse((order?['actual_fare'] ?? 0.0).toString());
    final vehicleType = typedOrder.vehicleType ?? 'bike';
    final String partnerLabel = (vehicleType == 'bike') ? 'rider' : 'Drop Partner';

    // Premium brand colors
    const primaryColor = Color(0xFF10B981);
    const accentColor = Color(0xFF10B981);
    
    final double maxFare = 99999.0;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171A21) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.12),
            blurRadius: 24,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SingleChildScrollView(
        controller: scrollController,
        physics: const ClampingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(20, 18, 20, Insets.bottom(context) + 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Elegant top drag handle inside the sheet
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),

            // 1. Status Header Row (similar to _buildRouteProgressHeader in live details)
            Row(
              children: [
                ScaleTransition(
                  scale: pulseAnimation,
                  child: Container(
                    height: 38,
                    width: 38,
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.explore_rounded,
                      color: accentColor,
                      size: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Locating your $partnerLabel...',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${nearbyRiders.length} active partners nearby',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: primaryColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // 2. Unified Details Card (similar to live tracking details card)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B).withValues(alpha: 0.4) : const Color(0xFFF8FAFC).withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: isDark ? Colors.white.withValues(alpha: 0.04) : const Color(0xFFE2E8F0),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Upper Row: Vehicle Type, Order Code, Fare
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${(typedOrder.vehicleType ?? 'vehicle').toUpperCase()} REQUEST',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '#${typedOrder.orderCode}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF10B981),
                            ),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '₹${currentFare.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: isDark ? Colors.white : const Color(0xFF0F172A),
                            ),
                          ),
                          Text(
                            typedOrder.paymentMode.toUpperCase(),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Divider(color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0), height: 1),
                  const SizedBox(height: 12),

                  // Lower section: Pickup & Dropoff Address boxes
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        children: [
                          Container(
                            height: 8,
                            width: 8,
                            decoration: const BoxDecoration(
                              color: Color(0xFF10B981),
                              shape: BoxShape.circle,
                            ),
                          ),
                          Container(
                            width: 1.5,
                            height: 38,
                            color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade300,
                          ),
                          Container(
                            height: 8,
                            width: 8,
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              typedOrder.pickupAddress,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white : const Color(0xFF0F172A),
                              ),
                            ),
                            const SizedBox(height: 24),
                            Text(
                              typedOrder.destinationAddress,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white : const Color(0xFF0F172A),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // 3. Premium Fare Slider Section
            if (currentFare >= (maxFare - 0.01)) ...[
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Current Fare',
                            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '₹${currentFare.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : const Color(0xFF0F172A),
                            ),
                          ),
                        ],
                      ),
                      if (localFare > currentFare)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            const Text(
                              'New Fare',
                              style: TextStyle(color: Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '₹${localFare.toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF10B981),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  const Text(
                    'Boost Your Offer',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF94A3B8)),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildPresetChip(context, '+ ₹10', 10.0, currentFare),
                      _buildPresetChip(context, '+ ₹20', 20.0, currentFare),
                      _buildPresetChip(context, '+ ₹50', 50.0, currentFare),
                      _buildCustomToggleChip(context, currentFare),
                    ],
                  ),

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
                                hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                                prefixText: '+ ₹ ',
                                prefixStyle: const TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold),
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
                                  borderSide: const BorderSide(color: Color(0xFF10B981), width: 1.5),
                                ),
                              ),
                              onChanged: (val) {
                                final double addAmt = double.tryParse(val) ?? 0.0;
                                setState(() {
                                  localFare = (currentFare + addAmt).clamp(currentFare, 99999.0);
                                });
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
                          _buildFareBreakup(localFare, actualFare, primaryColor),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primaryColor,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: boosting
                                  ? null
                                  : () async {
                                      await increaseFare(localFare, 0);
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
                                      'Confirm Fare of ₹${localFare.toStringAsFixed(2)}',
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
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

            const SizedBox(height: 16),

            // Cancel Request button
            SizedBox(
              width: double.infinity,
              height: 44,
              child: TextButton(
                style: TextButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () async {
                  final confirm = await showModalBottomSheet<bool>(
                    context: context,
                    backgroundColor: isDark ? const Color(0xFF171A21) : Colors.white,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                    ),
                    builder: (context) {
                      return Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF171A21) : Colors.white,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                        ),
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
                              'Are you sure you want to cancel your ride request?',
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
                                    onPressed: () => Navigator.pop(context, true),
                                    child: const Text(
                                      'Cancel Ride',
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
                },
                child: cancelling
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.red,
                        ),
                      )
                    : const Text(
                        'Cancel Request',
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _showExitConfirmation(BuildContext context) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF171A21) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF171A21) : Colors.white,
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
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
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
  Widget build(BuildContext context) {
    final diagnosticStatus = orderController.orderNotifier.value?.orderStatus;
    _rideDiagnosticOwner.frame(context, widget.orderId, diagnosticStatus,
      () => orderController.orderNotifier.value?.orderStatus == diagnosticStatus);
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
        backgroundColor: isDark ? const Color(0xFF1E222B) : Colors.white,
        body: Stack(
              children: [
                Positioned.fill(
                  child: mapController != null
                      ? WebViewWidget(controller: mapController!)
                      : const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF10B981),
                          ),
                        ),
                ),
                // Map controls (top-right, below header row)
                Positioned(
                  top: 100,
                  right: 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Recenter button
                      Card(
                        elevation: 4,
                        shape: const CircleBorder(),
                        color: isDark ? const Color(0xFF171A21) : Colors.white,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () {
                            mapController?.runJavaScript('if(window.recenterToPickup){ window.recenterToPickup(); }');
                          },
                          child: const SizedBox(
                            height: 38,
                            width: 38,
                            child: Icon(Icons.my_location_rounded, size: 18, color: Color(0xFF10B981)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  top: Insets.top(context) + 14,
                  left: 14,
                  right: 14,
                  child: Row(
                    children: [
                      Card(
                        elevation: 4,
                        shape: const CircleBorder(),
                        color: isDark ? const Color(0xFF171A21) : Colors.white,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () async {
                            final exit = await _showExitConfirmation(context);
                            if (exit && context.mounted) {
                              Navigator.popUntil(context, (route) => route.isFirst);
                            }
                          },
                          child: SizedBox(
                            height: 44,
                            width: 44,
                            child: Icon(
                              Icons.arrow_back_rounded,
                              size: 20,
                              color: isDark ? Colors.white : const Color(0xFF0F172A),
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF171A21).withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(30),
                          border: isDark ? Border.all(color: const Color(0xFF1E293B)) : null,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.08),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              height: 8,
                              width: 8,
                              decoration: const BoxDecoration(
                                color: Color(0xFF10B981),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(
                              width: 6,
                            ),
                            Text(
                              'LIVE',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : const Color(0xFF0F172A),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                DraggableScrollableSheet(
                  initialChildSize: 0.58,
                  minChildSize: 0.15,
                  maxChildSize: 0.62,
                  snap: true,
                  builder: (context, scrollController) {
                    return ClipRRect(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
                      child: buildModernBottomCard(scrollController),
                    );
                  },
                ),
                if (showTimeoutRetryOverlay)
                  Positioned.fill(
                    child: _buildTimeoutRetryOverlay(context),
                  ),
                Positioned.fill(
                  child: AnimatedOpacity(
                    opacity: loading ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    child: IgnorePointer(
                      ignoring: !loading,
                      child: Container(
                        color: isDark ? const Color(0xFF1E222B) : Colors.white,
                        child: const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF10B981),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
      ),
    );
  }

  Widget _buildPresetChip(BuildContext context, String label, double amount, double currentFare) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bool isSelected = !_showCustomInput && (localFare == currentFare + amount);
    return GestureDetector(
      onTap: () {
        setState(() {
          _showCustomInput = false;
          _customFareController.clear();
          localFare = currentFare + amount;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF10B981).withOpacity(0.15)
              : (isDark ? const Color(0xFF090D1A) : const Color(0xFFF1F5F9)),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? const Color(0xFF10B981) : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFF10B981) : (isDark ? Colors.white : Colors.black),
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildCustomToggleChip(BuildContext context, double currentFare) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bool isSelected = _showCustomInput;
    return GestureDetector(
      onTap: () {
        setState(() {
          _showCustomInput = true;
          localFare = currentFare;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF10B981).withOpacity(0.15)
              : (isDark ? const Color(0xFF090D1A) : const Color(0xFFF1F5F9)),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? const Color(0xFF10B981) : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Text(
          'Custom',
          style: TextStyle(
            color: isSelected ? const Color(0xFF10B981) : (isDark ? Colors.white : Colors.black),
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}
