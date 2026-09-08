/// ============================================================================
/// File: ride_tracking_screen.dart
///
/// Module:
/// Local Rides → Tracking
///
/// Purpose:
/// Track active local ride trips in real-time.
///
/// Responsibilities:
/// • Listen to realtime driver location.
/// • Display active trip status, ETA card, and chat entry point.
///
/// Related:
/// order_chat_screen.dart
/// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:waydrop/core/config/env.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/models/transport_order.dart';
import 'package:waydrop/core/services/realtime/realtime_order_controller.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:waydrop/core/services/cache/cache_service.dart';
import 'package:waydrop/core/navigation/flow_modules.dart';
import 'package:waydrop/features/local_rides/rating/screens/rider_rating_screen.dart';
import 'package:waydrop/modules/chat/screens/order_chat_screen.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:waydrop/modules/support/screens/customer_support_screen.dart';
import 'package:waydrop/features/local_rides/searching/screens/ride_searching_screen.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_searching_screen.dart';
import 'package:waydrop/features/local_rides/shared/navigation/local_ride_home_navigator.dart';
import 'package:waydrop/shared/helpers/insets.dart';
import 'package:waydrop/core/navigation/nav_trace.dart';

const Color _primaryLime = Color(0xFFC5FF30);
const Color _darkBg = Color(0xFF0F1115);
const Color _darkCard = Color(0xFF171A21);
const Color _textGray = Color(0xFF94A3B8);

class RideTrackingScreen extends StatefulWidget {
  final String orderId;

  const RideTrackingScreen({
    super.key,
    required this.orderId,
  });

  @override
  State<RideTrackingScreen> createState() => _RideTrackingScreenState();
}

class _RideTrackingScreenState extends State<RideTrackingScreen> {
  late RealtimeOrderController orderController;
  WebViewController? mapController;
  // Phase 2F-E (C3) -- one-shot guard for the onWebResourceError renderer-recovery reload below.
  // Mirrors rider_active_order_screen.dart's Phase 2A _mapReloadAttempts. Never reset within a
  // screen instance: a reload storm on a genuinely dead renderer must be impossible.
  int _mapReloadAttempts = 0;
  bool loading = true;
  String routeGeometry = '[]';
  
  static final Map<String, List<List<double>>> _staticRouteCache = {};
  String? _currentRiderRouteHash;
  bool _isCompletedSheetShown = false;
  bool _cancelling = false;
  bool _exitSheetOpen = false;
  // Guards against the realtime/polling-driven order listener (_onOrderUpdate) and the direct
  // cancel-button success handler (_performCancel) both reacting to the same cancellation and
  // each independently calling Navigator on this screen -- the DB write happens mid-way through
  // the cancel-order edge function, so the realtime push can reach this screen before the HTTP
  // response the button is awaiting does. Two uncoordinated Navigator mutations racing on the
  // same screen is what intermittently corrupts the route stack into a black screen. Only the
  // first of the two to observe the terminal state may act; the other is a no-op.
  bool _hasLeftScreen = false;

  // Rider location staleness detection (H17): warn + offer a cancel escape
  // hatch if we haven't heard from the rider's app in a while.
  DateTime? _lastRiderLocationUpdateAt;
  bool _riderInactive = false;
  Timer? _staleCheckTimer;
  static const _riderStaleThreshold = Duration(seconds: 45);
  static const _activeRideStatuses = ['accepted', 'rider_arrived', 'ongoing', 'picked_up', 'rider_at_drop'];

  // Track last known rider position for the map controls
  double? _riderLat;
  double? _riderLng;

  // Track background directions fetching status & throttling
  bool _fetchingRiderRoute = false;
  DateTime? _lastRiderRouteFetchTime;
  double? _lastTargetLat;
  double? _lastTargetLng;
  double? _lastFetchedRiderLat;
  double? _lastFetchedRiderLng;
  // Set when a target/status change wants an immediate route refresh but a Directions request for
  // the previous target was already in flight -- consumed by _fetchAndSetRiderRoute's finally
  // block (via a re-run of _onRiderLocationUpdate) so the change is retried the instant the
  // in-flight request completes instead of being silently dropped or waiting for the next
  // throttle window. WayDrop Ola Directions egress reduction (2026-08-22).
  bool _pendingForceRouteFetch = false;

  // WayDrop Ola Directions egress reduction (2026-08-22): the old flat "refetch every 15s OR every
  // 50m" throttle re-called Ola's Directions API on almost every rider location tick for the
  // entire acceptance-to-drop-off window (audited as the single largest source of Ola/Krutrim
  // consumption per ride). Replaced with a distance-to-target-aware floor: far from the target, a
  // polyline that's a few tens of seconds stale is visually indistinguishable, so the refresh
  // floor widens; close to the target (last-mile approach, where small route changes are more
  // visible) it stays tighter. The 50m movement trigger is kept per audit instruction, but is now
  // also floored by _minMovementGapSeconds so a fast-moving rider crossing 50m every few seconds
  // can no longer re-trigger a fresh Directions call faster than that floor.
  static const double _nearTargetThresholdKm = 0.6;
  static const int _farRefreshIntervalSeconds = 40;
  static const int _nearRefreshIntervalSeconds = 20;
  static const int _minMovementGapSeconds = 12;
  static const double _movementThresholdKm = 0.05;


  @override
  // Lifecycle method called once when the stateful widget initialized for the first time
  void initState() {
    // Lifecycle method called once when the stateful widget initialized for the first time
    super.initState();
    orderController = RealtimeOrderController(orderId: widget.orderId);
    initialize();
  }

  @override
  // Lifecycle method called before the widget is removed permanently from the tree to clean resources
  void dispose() {
    debugPrint(
      '[TRACE_CANCEL] RideTrackingScreen.dispose() ENTER order=${widget.orderId} '
      '_hasLeftScreen=$_hasLeftScreen _cancelling=$_cancelling '
      // webview_flutter exposes no separate disposal hook to Dart code -- the WebViewWidget
      // (mapController) is a child of this widget's subtree, so its underlying platform view is
      // torn down by the framework as part of this same dispose(), not observably before/after it.
      'epoch=${DateTime.now().millisecondsSinceEpoch}',
    );
    orderController.orderNotifier.removeListener(_onOrderUpdate);
    orderController.riderLocationNotifier.removeListener(_onRiderLocationUpdate);
    _staleCheckTimer?.cancel();
    // Lifecycle method called before the widget is removed permanently from the tree to clean resources
    orderController.dispose();

    // Phase 2F-B -- explicit WebView teardown, mirroring the Phase 2A rider active-order screen.
    // ola_map_tracking_user.html only tears the map/engine down on the document 'unload' event,
    // which does not reliably fire when Flutter disposes the platform WebView without a navigation
    // -- leaking the MapLibre GL context, its RAF render loop and the marker animation frame. All
    // three JS helpers are idempotent (they guard on their own window state); the call is wrapped
    // in try/catch on the JS side and .catchError on the Dart side, and is fire-and-forget because
    // dispose() cannot await.
    final mapCtrl = mapController;
    if (mapCtrl != null) {
      mapCtrl
          .runJavaScript(
            'try { '
            'if (typeof destroyNearbyRidersEngine === "function") { destroyNearbyRidersEngine(); } '
            'if (typeof destroyTrackingEngine === "function") { destroyTrackingEngine(); } '
            'if (typeof destroyMap === "function") { destroyMap(); } '
            '} catch (e) {}',
          )
          .catchError((_) {});
    }

    // Lifecycle method called before the widget is removed permanently from the tree to clean resources
    super.dispose();
    debugPrint(
      '[TRACE_CANCEL] RideTrackingScreen.dispose() EXIT order=${widget.orderId} '
      'epoch=${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  Future<void> initialize() async {
    await orderController.start();

    final orderObj = orderController.orderNotifier.value;
    if (orderObj == null) {
      await Future.delayed(const Duration(milliseconds: 1000));
    }

    final currentOrder = orderController.orderNotifier.value;
    if (currentOrder == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to load tracking details')),
        );
        // Close/pop the current screen or modal bottom sheet context
        Navigator.pop(context);
      }
      return;
    }

    orderController.orderNotifier.addListener(_onOrderUpdate);
    orderController.riderLocationNotifier.addListener(_onRiderLocationUpdate);

    _lastRiderLocationUpdateAt = DateTime.now();
    _staleCheckTimer = Timer.periodic(const Duration(seconds: 15), (_) => _checkRiderStaleness());

    await loadRoute(currentOrder);

    // Update the widget state to trigger a UI rebuild with the new variables
    if (mounted) setState(() => loading = false);
  }

  void _onOrderUpdate() {
    final orderObj = orderController.orderNotifier.value;
    debugPrint(
      '[TRACE_CANCEL] RideTrackingScreen._onOrderUpdate() FIRED order=${widget.orderId} '
      'status=${orderObj?.orderStatus} isCancelled=${orderObj?.isCancelled} '
      'isCompleted=${orderObj?.isCompleted} _hasLeftScreen=$_hasLeftScreen mounted=$mounted '
      'epoch=${DateTime.now().millisecondsSinceEpoch}',
    );
    if (_hasLeftScreen) return;
    if (orderObj == null) {
      if (mounted) {
        _hasLeftScreen = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Order was cancelled or completed.')),
        );
        NavTrace.begin('RideTrackingScreen._onOrderUpdate', 'returnToLocalRideHome (order==null)');
        returnToLocalRideHome(context, isRider: false);
        NavTrace.end('RideTrackingScreen._onOrderUpdate', 'returnToLocalRideHome (order==null)');
      }
      return;
    }

    if (orderObj.isCompleted && !_isCompletedSheetShown) {
      _isCompletedSheetShown = true;
      showCompletedSheet(orderObj);
    }

    if (orderObj.isCancelled) {
      if (mounted) {
        _hasLeftScreen = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Order has been cancelled')),
        );
        NavTrace.begin('RideTrackingScreen._onOrderUpdate', 'returnToLocalRideHome (isCancelled)');
        returnToLocalRideHome(context, isRider: false);
        NavTrace.end('RideTrackingScreen._onOrderUpdate', 'returnToLocalRideHome (isCancelled)');
      }
      return;
    }

    if (orderObj.orderStatus == 'searching' || orderObj.orderStatus == 'created') {
      if (mounted) {
        _hasLeftScreen = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Drop Partner cancelled. Re-searching for a new Drop Partner...')),
        );
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) {
              if (orderObj.orderType == 'intercity_ride' || (orderObj.orderType == 'ride' && (double.tryParse(orderObj.distanceMeters.toString()) ?? 0.0) > 20000)) {
                return IntercitySearchingScreen(orderId: widget.orderId);
              } else {
                return RideSearchingScreen(orderId: widget.orderId);
              }
            },
          ),
        );
      }
    }

    _onRiderLocationUpdate();
  }

  void _onRiderLocationUpdate() {
    final location = orderController.riderLocationNotifier.value;
    if (location == null) return;
    _lastRiderLocationUpdateAt = DateTime.now();
    if (mapController == null) return;

    final lat = location['lat']!;
    final lng = location['lng']!;
    final heading = location['heading'] ?? 0.0;

    // Cache for map focus button
    _riderLat = lat;
    _riderLng = lng;

    // Get rider name, image & vehicle type from controller (with fallback)
    final name = orderController.riderNotifier.value?['name']?.toString() ?? '';
    final image = orderController.riderNotifier.value?['rider_image']?.toString() ?? '';
    final vehicleType = orderController.riderNotifier.value?['vehicle_type']?.toString() ?? orderController.orderNotifier.value?.vehicleType ?? 'cab';

    // Smooth animated move via JS interpolation
    final status = orderController.orderNotifier.value?.orderStatus ?? '';
    mapController!.runJavaScript("if (typeof updateRiderLocation === 'function') { updateRiderLocation($lat, $lng, ${jsonEncode(name)}, ${jsonEncode(image)}, ${jsonEncode(vehicleType)}, $heading, ${jsonEncode(status)}); }");

    // Fetch road-snapped Directions from rider to active target
    final orderObj = orderController.orderNotifier.value;
    // Duplicate/validity guard (Ola egress reduction): never resolve a target or schedule a
    // Directions fetch for an order that has already finished -- previously this fell through to
    // the pickup-target "else" branch below for any status it didn't explicitly recognize,
    // including 'completed'/'cancelled'.
    if (orderObj != null && !orderObj.isCompleted && !orderObj.isCancelled) {
      double targetLat;
      double targetLng;
      if (status == 'ongoing' || status == 'picked_up' || status == 'rider_at_drop') {
        targetLat = orderObj.destinationLat;
        targetLng = orderObj.destinationLng;
      } else {
        targetLat = orderObj.pickupLat;
        targetLng = orderObj.pickupLng;
      }

      // If target changed (e.g. status transitioned pickup -> ongoing), trigger immediate fetch
      bool forceFetch = false;
      if (_lastTargetLat != targetLat || _lastTargetLng != targetLng) {
        _lastTargetLat = targetLat;
        _lastTargetLng = targetLng;
        forceFetch = true;
      }
      // A forced refresh that arrived while a request was already in flight (see the in-flight
      // guard below) is queued here instead of dropped.
      if (_pendingForceRouteFetch) {
        forceFetch = true;
      }

      double distanceMoved = 999.0;
      if (_lastFetchedRiderLat != null && _lastFetchedRiderLng != null) {
        distanceMoved = _calculateHaversineDistance(
          lat, lng,
          _lastFetchedRiderLat!, _lastFetchedRiderLng!,
        );
      }

      // Query road-snapped route in background asynchronously, throttled to avoid spamming the
      // API. WayDrop Ola Directions egress reduction (2026-08-22): the refresh floor now adapts to
      // how far the rider still is from the active target instead of a flat 15s (see the
      // constants declared with the state fields above), and the 50m movement trigger can no
      // longer fire more than once every _minMovementGapSeconds.
      final now = DateTime.now();
      final timeSinceLastFetch = _lastRiderRouteFetchTime == null
          ? const Duration(seconds: 999)
          : now.difference(_lastRiderRouteFetchTime!);

      final double distanceToTargetKm = _calculateHaversineDistance(lat, lng, targetLat, targetLng);
      final int refreshIntervalSeconds = distanceToTargetKm <= _nearTargetThresholdKm
          ? _nearRefreshIntervalSeconds
          : _farRefreshIntervalSeconds;
      final bool intervalElapsed = timeSinceLastFetch.inSeconds >= refreshIntervalSeconds;
      final bool movementTriggered = distanceMoved >= _movementThresholdKm &&
          timeSinceLastFetch.inSeconds >= _minMovementGapSeconds;

      if (forceFetch || intervalElapsed || movementTriggered) {
        if (_fetchingRiderRoute) {
          // Duplicate-request guard: a Directions request for this rider is already in flight --
          // never start a second one. If this trigger was a forced (target/status-change) one,
          // remember it so it fires the instant the in-flight request completes (see
          // _fetchAndSetRiderRoute's finally block) instead of waiting for the next throttle
          // window or being silently dropped.
          if (forceFetch) _pendingForceRouteFetch = true;
        } else {
          _pendingForceRouteFetch = false;
          _fetchingRiderRoute = true;
          _lastRiderRouteFetchTime = now;
          _lastFetchedRiderLat = lat;
          _lastFetchedRiderLng = lng;
          _fetchAndSetRiderRoute(orderObj, lat, lng, targetLat, targetLng);
        }
      }
    }
  }

  void _checkRiderStaleness() {
    if (!mounted) return;
    final orderObj = orderController.orderNotifier.value;
    if (orderObj == null || !_activeRideStatuses.contains(orderObj.orderStatus)) {
      if (_riderInactive) setState(() => _riderInactive = false);
      return;
    }
    final lastUpdate = _lastRiderLocationUpdateAt;
    final isStale = lastUpdate == null || DateTime.now().difference(lastUpdate) > _riderStaleThreshold;
    if (isStale != _riderInactive) {
      setState(() => _riderInactive = isStale);
    }
  }

  Future<void> _fetchAndSetRiderRoute(TransportOrder orderObj, double originLat, double originLng, double targetLat, double targetLng) async {
    try {
      // Phase 10E 2D: same lifecycle fix as the rider active-order screen (Phase 2B). `.timeout()`
      // around the call only stopped THIS await at 8s -- it released `_fetchingRiderRoute` while
      // the underlying Ola HTTP request stayed alive against the shared Dio's 15s ceiling. In that
      // ~7s gap a fast-moving rider crossing the 50m movement threshold (floored at
      // _minMovementGapSeconds = 12s) could start a second, overlapping Directions request.
      // Passing the budget INTO getDirections cancels the in-flight request at 8s, so the guard
      // and the request are released together. A cancelled/timed-out request returns null here --
      // handled exactly like any other failed fetch (no map update).
      final route = await OlaMapService.getDirections(
        originLat: originLat,
        originLng: originLng,
        destinationLat: targetLat,
        destinationLng: targetLng,
        timeout: const Duration(seconds: 8),
      );

      if (route != null && route.polylinePoints.isNotEmpty) {
        final List<List<double>> coords = route.polylinePoints.map((pt) => [pt['lng']!, pt['lat']!]).toList();
        
        final String targetType = (orderObj.orderStatus == 'ongoing' || orderObj.orderStatus == 'picked_up' || orderObj.orderStatus == 'rider_at_drop')
            ? 'destination'
            : 'pickup';
        final String cacheKey = "${orderObj.id}_${orderObj.orderStatus}_$targetType";

        // Store to memory cache (Cap at 100, FIFO eviction)
        _staticRouteCache[cacheKey] = coords;
        if (_staticRouteCache.length > 100) {
          _staticRouteCache.remove(_staticRouteCache.keys.first);
        }

        // Store to persistent CacheService for active orders only (30-min TTL)
        if (!orderObj.isCompleted && !orderObj.isCancelled) {
          CacheService.instance.put('route_$cacheKey', coords, ttl: const Duration(minutes: 30));
        }

        // De-duplicate updates to avoid map line flickering
        final newHash = coords.map((c) => "${c[0].toStringAsFixed(5)},${c[1].toStringAsFixed(5)}").join(";");
        if (newHash != _currentRiderRouteHash) {
          _currentRiderRouteHash = newHash;
          mapController?.runJavaScript("if (typeof updateRiderRoute === 'function') { updateRiderRoute(${jsonEncode(coords)}); }");
        }
      }
    } catch (e) {
      debugPrint('Error fetching rider route directions: $e');
    } finally {
      _fetchingRiderRoute = false;
      // Duplicate-request guard follow-up: a target/status change arrived while this request was
      // in flight (see _onRiderLocationUpdate) -- retry immediately using the freshest known
      // order/rider state instead of waiting for the next throttle window. Re-running the same
      // decision method (rather than re-fetching directly here) keeps target resolution, the
      // active-order guard, and cache/hash bookkeeping in exactly one place.
      if (_pendingForceRouteFetch && mounted) {
        _onRiderLocationUpdate();
      }
    }
  }

  Future<void> loadRoute(TransportOrder orderObj) async {
    routeGeometry = '[]';

    final String targetType = (orderObj.orderStatus == 'ongoing' || orderObj.orderStatus == 'picked_up' || orderObj.orderStatus == 'rider_at_drop')
        ? 'destination'
        : 'pickup';
    final String cacheKey = "${orderObj.id}_${orderObj.orderStatus}_$targetType";

    // Retrieve from memory cache first
    List<List<double>> cachedCoords = _staticRouteCache[cacheKey] ?? [];

    // If memory cache is empty, check persistent CacheService
    if (cachedCoords.isEmpty) {
      final cachedVal = CacheService.instance.get('route_$cacheKey');
      if (cachedVal is List) {
        cachedCoords = List<List<double>>.from(
          cachedVal.map((e) => List<double>.from(e as List))
        );
        _staticRouteCache[cacheKey] = cachedCoords;
      }
    }

    // Setup the web controller instance for rendering interactive map content
    mapController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) async {
          if (!mounted) return;
          final apiKey = Env.olaMapsApiKey;
          final safeApiKey = apiKey.replaceAll('"', '');
          // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final themeMode = isDark ? 'dark' : 'light';
          
          await mapController?.runJavaScript(
            'if(window.initTrackingMap){ window.initTrackingMap("$safeApiKey", "$themeMode", ${orderObj.pickupLat}, ${orderObj.pickupLng}, ${orderObj.destinationLat}, ${orderObj.destinationLng}, [], ${jsonEncode(cachedCoords)}); }'
          );

          if (cachedCoords.isNotEmpty) {
            _currentRiderRouteHash = cachedCoords.map((c) => "${c[0].toStringAsFixed(5)},${c[1].toStringAsFixed(5)}").join(";");
          }

          _onRiderLocationUpdate();
        },
        // Phase 2F-E (C3) -- minimal renderer-recovery, ported verbatim from the Phase 2A rider
        // tracking screen (rider_active_order_screen.dart). The map document is a bundled Flutter
        // asset, so a main-frame load failure essentially only happens when the Android renderer
        // process is killed under memory pressure -- exactly the failure mode behind the reported
        // "blank map, can't finish the ride" symptom. Without this the screen sits permanently
        // blank. Reload the asset ONCE; onPageFinished above then re-runs initTrackingMap +
        // _onRiderLocationUpdate() and the map comes back. The one-shot _mapReloadAttempts guard
        // makes a reload storm impossible; non-main-frame failures (map tiles, fonts) are ignored
        // -- MapLibre already retries those. loadOlaMap()'s re-entry guard only calls destroyMap(),
        // not destroyTrackingEngine(), so tear the engine down explicitly first (guarded,
        // idempotent, fire-and-forget) to stop the reload stacking a second tracking engine.
        onWebResourceError: (error) {
          if (!mounted) return;
          if (error.isForMainFrame != true) return;
          if (_mapReloadAttempts >= 1) return;
          _mapReloadAttempts++;
          mapController
              ?.runJavaScript(
                'try { '
                'if (typeof destroyTrackingEngine === "function") { destroyTrackingEngine(); } '
                'if (typeof destroyNearbyRidersEngine === "function") { destroyNearbyRidersEngine(); } '
                'if (typeof destroyMap === "function") { destroyMap(); } '
                '} catch (e) {}',
              )
              .catchError((_) {});
          mapController?.loadFlutterAsset('assets/map/ola_map_tracking_user.html');
        },
      ));
    await mapController!.loadFlutterAsset('assets/map/ola_map_tracking_user.html');
  }

  double _calculateHaversineDistance(double lat1, double lon1, double lat2, double lon2) {
    const double r = 6371.0; // Earth's radius in km
    final double dLat = (lat2 - lat1) * pi / 180.0;
    final double dLon = (lon2 - lon1) * pi / 180.0;
    final double a = sin(dLat / 2.0) * sin(dLat / 2.0) +
        cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) *
        sin(dLon / 2.0) * sin(dLon / 2.0);
    final double c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a));
    return r * c;
  }

  // R15 perf fix: this exact branching (rider_arrived -> 0, ongoing/picked_up/rider_at_drop ->
  // distance-to-destination at 30km/h, else -> distance-to-pickup at 25km/h, else fall back to
  // the server-computed liveState ETA) used to be copy-pasted verbatim in two places --
  // _buildFloatingEtaCard() below and the bottom-sheet's route-progress AnimatedBuilder further
  // down -- both listening to the same riderLocationNotifier/liveStateNotifier and recomputing
  // the identical result independently on every rider-location tick. Extracted into one shared
  // method so both call sites can never silently diverge; behavior is byte-for-byte unchanged --
  // same inputs, same formula, same constants, same fallback.
  ({double distanceKm, double etaMinutes}) _computeDistanceAndEta(
    TransportOrder orderObj,
    Map<String, double>? riderLoc,
    Map<String, dynamic>? liveState,
  ) {
    double estimatedArrivalMinutes = 0.0;
    double distanceKm = 0.0;

    if (riderLoc != null) {
      final double rLat = riderLoc['lat']!;
      final double rLng = riderLoc['lng']!;
      final String status = orderObj.orderStatus;

      if (status == 'rider_arrived') {
        estimatedArrivalMinutes = 0.0;
        distanceKm = 0.0;
      } else if (status == 'ongoing' || status == 'picked_up' || status == 'rider_at_drop') {
        distanceKm = _calculateHaversineDistance(
          rLat, rLng,
          orderObj.destinationLat, orderObj.destinationLng,
        );
        estimatedArrivalMinutes = distanceKm * 2.0; // average 30 km/h speed
      } else {
        distanceKm = _calculateHaversineDistance(
          rLat, rLng,
          orderObj.pickupLat, orderObj.pickupLng,
        );
        estimatedArrivalMinutes = distanceKm * 2.4; // average 25 km/h speed
      }
    } else {
      final etaVal = liveState?['tracking']?['estimated_arrival_minutes'];
      estimatedArrivalMinutes = double.tryParse(etaVal?.toString() ?? '') ?? 0.0;
    }

    return (distanceKm: distanceKm, etaMinutes: estimatedArrivalMinutes);
  }

  // ── Focus helpers ──────────────────────────────────────────────────────────

  void _focusOnRider() {
    if (_riderLat != null && _riderLng != null) {
      mapController?.runJavaScript("if (typeof focusOnRider === 'function') { focusOnRider(); }");
    }
  }

  Widget _buildFloatingEtaCard(bool isDark) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        orderController.orderNotifier,
        orderController.riderLocationNotifier,
        orderController.liveStateNotifier,
      ]),
      builder: (context, _) {
        final orderObj = orderController.orderNotifier.value;
        final riderLoc = orderController.riderLocationNotifier.value;
        final liveState = orderController.liveStateNotifier.value;

        if (orderObj == null || orderObj.riderId == null) {
          return const SizedBox();
        }

        final etaResult = _computeDistanceAndEta(orderObj, riderLoc, liveState);
        final double estimatedArrivalMinutes = etaResult.etaMinutes;
        final double distanceKm = etaResult.distanceKm;

        String etaText;
        String distanceText;

        final String status = orderObj.orderStatus;
        if (status == 'rider_arrived') {
          etaText = 'Arrived';
          distanceText = 'Drop Partner at Pickup';
        } else if (status == 'rider_at_drop') {
          etaText = 'Arrived';
          distanceText = 'Drop Partner at Destination';
        } else {
          final roundedMins = estimatedArrivalMinutes.round();
          final bool isOngoing = status == 'ongoing' || status == 'picked_up';
          
          if (roundedMins <= 0) {
            etaText = 'Arriving Now';
          } else {
            etaText = isOngoing ? '$roundedMins min to Destination' : '$roundedMins min to Pickup';
          }
          
          if (isOngoing) {
            distanceText = '${distanceKm.toStringAsFixed(1)} km remaining';
          } else {
            distanceText = '${distanceKm.toStringAsFixed(1)} km away';
          }
        }

        return Positioned(
          top: MediaQuery.of(context).padding.top + 68,
          left: 14,
          right: 14,
          child: Container(
            decoration: BoxDecoration(
              color: isDark ? _darkCard : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFE2E8F0),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.16),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _primaryLime.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.navigation_rounded,
                    color: _primaryLime,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        etaText,
                        style: TextStyle(
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        distanceText,
                        style: TextStyle(
                          color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Completed sheet ────────────────────────────────────────────────────────

  void showCompletedSheet(TransportOrder orderObj) {
    if (!mounted) return;
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final module = FlowModuleFactory.resolve(orderObj.flowType);

    // Present a premium modal bottom sheet drawer for user input/actions
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: isDark ? _darkCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                module.buildCompletionContent(context, orderObj),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      elevation: 0,
                      backgroundColor: _primaryLime,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    onPressed: () {
                      // Close/pop the current screen or modal bottom sheet context
                      Navigator.pop(context);
                      // Task 4 (local): replace (not push-on-top-of) this tracking screen so its
                      // WebView/realtime listeners are disposed immediately via a single, normal
                      // route transition -- same fix as the Intercity tracking screen's Done
                      // button, eliminating the black-screen race a later bulk popUntil could
                      // cause while a still-live WebView sat underneath.
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (_) => RiderRatingScreen(
                            order: orderObj,
                            riderData: orderController.riderNotifier.value,
                          ),
                        ),
                      );
                    },
                    child: const Text('Done', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }



  // ── Map HTML ───────────────────────────────────────────────────────────────



  Future<bool> _showExitConfirmation(BuildContext context) async {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: isDark ? _darkCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark ? _darkCard : Colors.white,
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
                'Your ride request will continue in the background. You can track or resume it at any time from the Activity tab.',
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
                        side: BorderSide(color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.grey.shade300),
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
                        backgroundColor: _primaryLime,
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
                          color: Colors.black,
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

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  // Build method responsible for rendering the entire widget layout hierarchy on the viewport
  Widget build(BuildContext context) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (loading) {
      return const SkeletonLoader();
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_exitSheetOpen) return;
        _exitSheetOpen = true;
        final exit = await _showExitConfirmation(context);
        _exitSheetOpen = false;
        if (exit && context.mounted) {
          Navigator.popUntil(context, (route) => route.isFirst);
        }
      },
      child: Scaffold(
        backgroundColor: isDark ? _darkBg : Colors.white,
        body: Stack(
        children: [
          // ── 1. Full-screen map
          Positioned.fill(
            child: WebViewWidget(controller: mapController!),
          ),

          _buildFloatingEtaCard(isDark),

          // ── 2. Top-left: back button & support button
          Positioned(
            top: Insets.top(context) + 10,
            left: 14,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MapBtn(
                  icon: Icons.arrow_back_rounded,
                  onTap: () async {
                    if (_exitSheetOpen) return;
                    _exitSheetOpen = true;
                    final exit = await _showExitConfirmation(context);
                    _exitSheetOpen = false;
                    if (exit && context.mounted) {
                      Navigator.popUntil(context, (route) => route.isFirst);
                    }
                  },
                ),
                const SizedBox(width: 10),
                _MapBtn(
                  icon: Icons.support_agent_rounded,
                  tooltip: 'Customer Support',
                  onTap: () {
                    // Navigate to a new screen layout using Flutter's Navigator router
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const CustomerSupportScreen()),
                    );
                  },
                ),
              ],
            ),
          ),

          // ── 3. Top-right: LIVE badge + map focus controls
          Positioned(
            top: Insets.top(context) + 10,
            right: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                // LIVE badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: isDark ? _darkCard.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20),
                    border: isDark ? Border.all(color: Colors.white.withValues(alpha: 0.06)) : null,
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.08), blurRadius: 8, offset: const Offset(0, 3))],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('LIVE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isDark ? Colors.white : const Color(0xFF0F172A))),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                // Focus on rider
                _MapBtn(
                  icon: Icons.directions_car_rounded,
                  tooltip: 'Focus rider',
                  onTap: _focusOnRider,
                ),
              ],
            ),
          ),

          // ── 4. Bottom card (draggable/slideable sheet)
          DraggableScrollableSheet(
            initialChildSize: 0.42,
            minChildSize: 0.15,
            maxChildSize: 0.85,
            snap: true,
            builder: (context, scrollController) {
              return ValueListenableBuilder<TransportOrder?>(
                valueListenable: orderController.orderNotifier,
                builder: (context, orderObj, _) {
                  if (orderObj == null) return const SizedBox();

                  return Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: isDark ? _darkCard : Colors.white,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                      border: isDark ? Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1.0) : null,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.08),
                          blurRadius: 24,
                          offset: const Offset(0, -6),
                        ),
                      ],
                    ),
                    child: SingleChildScrollView(
                      controller: scrollController,
                      physics: const ClampingScrollPhysics(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Elegant top drag handle inside the sheet
                          const SizedBox(height: 12),
                          Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(height: 12),

                          ValueListenableBuilder<Map<String, dynamic>?>(
                            valueListenable: orderController.riderNotifier,
                            builder: (context, rider, _) {
                              final name          = rider?['name']?.toString() ?? '';
                              final vehicleNum    = rider?['vehicle_number']?.toString() ?? '';
                              final vehicleType   = rider?['vehicle_type']?.toString() ?? orderObj.vehicleType ?? 'cab';
                              final riderImageUrl = rider?['rider_image']?.toString() ?? '';
                              final vehicleImageUrl = rider?['vehicle_image']?.toString();
                              final phone         = rider?['phone']?.toString() ?? '';
                              final initial       = name.isNotEmpty ? name[0].toUpperCase() : '';
                              final completedOrders = rider?['total_completed_orders'] ?? rider?['total_orders'] ?? 150;

                              return AnimatedBuilder(
                                animation: Listenable.merge([
                                  orderController.orderNotifier,
                                  orderController.riderLocationNotifier,
                                  orderController.liveStateNotifier,
                                  orderController.userNameNotifier,
                                ]),
                                builder: (context, _) {
                                  final location = orderController.riderLocationNotifier.value;
                                  final etaResult = _computeDistanceAndEta(
                                    orderObj,
                                    location,
                                    orderController.liveStateNotifier.value,
                                  );
                                  final double estimatedArrivalMinutes = etaResult.etaMinutes;
                                  final double distanceKm = etaResult.distanceKm;

                                  final Color themeAccent = orderObj.orderType == 'local_parcel' || orderObj.orderType == 'intercity_parcel'
                                      ? const Color(0xFFEA580C)
                                      : (orderObj.flowType == OrderFlowType.intercity ? const Color(0xFF7C3AED) : const Color(0xFFC5FF30));

                                  return Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildRouteProgressHeader(context, orderObj, distanceKm, estimatedArrivalMinutes, isDark),
                                      _buildDriverDetailsCard(
                                        context,
                                        rider,
                                        name,
                                        phone,
                                        riderImageUrl,
                                        initial,
                                        completedOrders,
                                        isDark,
                                        themeAccent,
                                        vehicleNum.isNotEmpty ? '$vehicleNum • ${vehicleType.toUpperCase()}' : 'Drop Partner',
                                      ),
                                      _buildOtpVerificationCard(context, orderObj, isDark),
                                      _buildRiderInactiveBanner(context, orderObj, isDark),
                                      _buildCancelButton(context, orderObj, isDark),
                                      _buildUnifiedDetailsCard(context, orderObj, name, vehicleNum, vehicleType, vehicleImageUrl, isDark),
                                      SizedBox(height: 12 + Insets.bottom(context)),
                                    ],
                                    );
                                  },
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${dt.day} ${months[dt.month - 1]}, ${dt.year}';
  }

  String _getCityName(String address, String fallback) {
    if (address.isEmpty) return fallback;
    final parts = address.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (parts.length > 1) {
      final statesAndCountries = {
        'telangana', 'andhra pradesh', 'karnataka', 'tamil nadu', 'maharashtra',
        'delhi', 'goa', 'gujarat', 'haryana', 'himachal pradesh', 'kerala',
        'madhya pradesh', 'punjab', 'rajasthan', 'uttar pradesh', 'uttarakhand',
        'west bengal', 'bihar', 'chhattisgarh', 'odisha', 'india'
      };
      for (int i = parts.length - 2; i >= 0; i--) {
        final candidate = parts[i];
        final lower = candidate.toLowerCase().replaceAll(RegExp(r'\d+'), '').trim();
        if (lower.isNotEmpty && !statesAndCountries.contains(lower)) {
          return candidate;
        }
      }
      if (parts.length >= 3) {
        return parts[parts.length - 3];
      }
      return parts[parts.length - 2];
    }
    return address;
  }

  Widget _buildRouteProgressHeader(
    BuildContext context,
    TransportOrder orderObj,
    double distanceKm,
    double estimatedArrivalMinutes,
    bool isDark,
  ) {
    final Color themeAccent = orderObj.orderType == 'local_parcel' || orderObj.orderType == 'intercity_parcel'
        ? const Color(0xFFEA580C)
        : (orderObj.flowType == OrderFlowType.intercity ? const Color(0xFF7C3AED) : const Color(0xFFC5FF30));

    // The trip has ended but this is a 'upi' order awaiting the passenger's payment -- show the
    // UPI intent panel front and center instead of the normal status banner.
    if (orderObj.isAwaitingUpiPayment) {
      return Column(
        children: [
          _buildRideStatusBanner(orderObj, themeAccent, isDark),
          const SizedBox(height: 12),
          FarePaymentPanel(order: orderObj),
        ],
      );
    }

    return _buildRideStatusBanner(orderObj, themeAccent, isDark);
  }

  Widget _buildRideStatusBanner(TransportOrder orderObj, Color themeAccent, bool isDark) {
    final status = orderObj.orderStatus;
    final isRide = orderObj.isRide;

    String message = 'Waiting for partner updates...';
    IconData icon = Icons.info_outline_rounded;
    Color iconColor = themeAccent;

    if (isRide) {
      if (status == 'accepted') {
        message = 'Great news! Your rider has been assigned and is on the way to your pickup location.';
        icon = Icons.person_pin_circle_rounded;
      } else if (status == 'rider_arrived') {
        message = 'Your rider has arrived. Share the pickup OTP to begin your journey.';
        icon = Icons.login_rounded;
        iconColor = const Color(0xFF10B981);
      } else if (status == 'ongoing' || status == 'picked_up') {
        message = 'Your journey is underway. Sit back, relax, and enjoy a safe ride.';
        icon = Icons.moped_rounded;
        iconColor = const Color(0xFF2563EB);
      } else if (status == 'rider_at_drop') {
        message = 'You\'ve reached your destination. We hope you had a pleasant ride.';
        icon = Icons.sports_motorsports_rounded;
      } else if (status == 'payment_pending') {
        message = 'You\'ve reached your destination. Pay your Drop Partner to complete the trip.';
        icon = Icons.qr_code_rounded;
        iconColor = const Color(0xFF10B981);
      } else if (status == 'completed' || status == 'delivered') {
        message = 'Ride completed successfully. Thank you for choosing WayDrop!';
        icon = Icons.verified_rounded;
        iconColor = const Color(0xFF10B981);
      }
    } else {
      if (status == 'accepted') {
        message = 'Your delivery partner has been assigned and is heading to collect your parcel.';
        icon = Icons.assignment_ind_rounded;
      } else if (status == 'rider_arrived') {
        message = 'Your delivery partner has arrived. Share the pickup OTP to hand over your parcel.';
        icon = Icons.login_rounded;
        iconColor = const Color(0xFF10B981);
      } else if (status == 'picked_up' || status == 'ongoing') {
        message = 'Your parcel is safely on its way. Track every step until delivery.';
        icon = Icons.local_shipping_rounded;
        iconColor = const Color(0xFF2563EB);
      } else if (status == 'rider_at_drop') {
        message = 'Your parcel has reached its destination. Share the delivery OTP to complete the handoff.';
        icon = Icons.sports_motorsports_rounded;
      } else if (status == 'completed' || status == 'delivered') {
        message = 'Delivery completed successfully. Thank you for trusting WayDrop!';
        icon = Icons.verified_rounded;
        iconColor = const Color(0xFF10B981);
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: isDark
            ? const LinearGradient(
                colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : const LinearGradient(
                colors: [Color(0xFFFFFFFF), Color(0xFFF8FAFC)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        boxShadow: [
          BoxShadow(
            color: iconColor.withOpacity(isDark ? 0.08 : 0.12),
            blurRadius: 24,
            spreadRadius: -4,
            offset: const Offset(0, 8),
          ),
        ],
        border: Border.all(
          color: iconColor.withOpacity(0.15),
          width: 1.5,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 5,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [iconColor, iconColor.withOpacity(0.5)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: iconColor.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: iconColor, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: iconColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'LIVE STATUS',
                              style: TextStyle(
                                fontSize: 9.5,
                                letterSpacing: 1.2,
                                fontWeight: FontWeight.w900,
                                color: iconColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 400),
                          transitionBuilder: (Widget child, Animation<double> animation) {
                            return FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0.0, 0.2),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: child,
                              ),
                            );
                          },
                          child: Text(
                            message,
                            key: ValueKey<String>(message),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              height: 1.4,
                              color: isDark ? Colors.white : const Color(0xFF0F172A),
                            ),
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
      ),
    );
  }

  Widget _buildTimelineNode({
    required bool isActive,
    required bool isCompleted,
    required IconData icon,
    required Color themeAccent,
    required Color inactiveColor,
    required Color inactiveIconColor,
  }) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isCompleted
            ? themeAccent
            : (isActive ? Colors.white : inactiveColor),
        border: Border.all(
          color: isActive ? themeAccent : inactiveColor,
          width: 2,
        ),
      ),
      child: Icon(
        icon,
        size: 14,
        color: isCompleted
            ? Colors.white
            : (isActive ? themeAccent : inactiveIconColor),
      ),
    );
  }

  Widget _buildTimelineConnector({
    required bool isActive,
    required Color themeAccent,
    required Color inactiveColor,
  }) {
    return Container(
      height: 4,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: isActive ? themeAccent : inactiveColor,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _buildOtpVerificationCard(
    BuildContext context,
    TransportOrder orderObj,
    bool isDark,
  ) {
    if (orderObj.isCompleted || orderObj.isCancelled) {
      return const SizedBox();
    }

    // SECURITY FIX (P0): this card used to render for whoever opened this screen, based only on
    // order_status -- but this same screen is also opened by the DRIVER (e.g. from
    // intercity_bookings_screen.dart's "Track / Navigate" button), who would then see the exact
    // pickup/delivery OTP the passenger/receiver is supposed to keep secret and read aloud to
    // prove the right person is present. Only the order's own passenger may ever see it here.
    if (Supabase.instance.client.auth.currentUser?.id != orderObj.userId) {
      return const SizedBox();
    }

    String? otp;
    String title;
    String subtitle;

    final status = orderObj.orderStatus;
    if (status == 'accepted' || status == 'rider_arrived') {
      otp = orderObj.pickupOtp;
      title = 'Pickup OTP';
      subtitle = 'Share this OTP with the partner at pickup to verify.';
    } else if (!orderObj.isRide && (status == 'picked_up' || status == 'ongoing' || status == 'rider_at_drop')) {
      otp = orderObj.deliveryOtp;
      title = 'Delivery OTP';
      subtitle = 'Share this OTP with the receiver or partner to complete delivery.';
    } else {
      return const SizedBox();
    }

    if (otp == null || otp.isEmpty) {
      return const SizedBox();
    }

    final formattedOtp = otp.split('').join('  ');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: isDark
            ? const LinearGradient(
                colors: [Color(0xFF1E293B), Color(0xFF111827)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : const LinearGradient(
                colors: [Color(0xFFF8FAFC), Color(0xFFF1F5F9)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFE2E8F0),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark ? Colors.white.withValues(alpha: 0.1) : const Color(0xFFCBD5E1),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              formattedOtp,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
                color: isDark ? const Color(0xFF7C3AED) : const Color(0xFF2563EB),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRiderInactiveBanner(BuildContext context, TransportOrder orderObj, bool isDark) {
    if (!_riderInactive) return const SizedBox();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFFEF4444).withOpacity(0.1) : const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? const Color(0xFFEF4444).withOpacity(0.3) : const Color(0xFFFCA5A5), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_off_rounded, color: isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "We haven't heard from your rider's app in a while. You can keep waiting or cancel.",
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 42,
            child: OutlinedButton(
              onPressed: _cancelling ? null : () => _confirmCancel(context, orderObj),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: isDark ? const Color(0xFFEF4444).withOpacity(0.4) : const Color(0xFFDC2626), width: 1.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(
                _cancelling ? 'Cancelling...' : 'Cancel Ride',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCancelButton(BuildContext context, TransportOrder orderObj, bool isDark) {
    final status = orderObj.orderStatus;
    if (status != 'accepted' && status != 'rider_arrived') {
      return const SizedBox();
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      height: 50,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: isDark ? const Color(0xFFEF4444).withOpacity(0.3) : const Color(0xFFFCA5A5), width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: isDark ? const Color(0xFFEF4444).withOpacity(0.06) : const Color(0xFFFEF2F2),
        ),
        onPressed: _cancelling ? null : () => _confirmCancel(context, orderObj),
        icon: Icon(Icons.cancel_outlined, color: isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626), size: 18),
        label: Text(
          _cancelling ? 'Cancelling...' : 'Cancel Order',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmCancel(BuildContext context, TransportOrder orderObj) async {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Show an overlay dialog window on the screen for user decision
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(
          'Cancel Request?',
          style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? Colors.white : const Color(0xFF0F172A)),
        ),
        content: Text(
          'Are you sure you want to cancel this order?',
          style: TextStyle(color: isDark ? Colors.white70 : Colors.black54),
        ),
        actions: [
          TextButton(
            // Close/pop the current screen or modal bottom sheet context
            onPressed: () => Navigator.pop(ctx),
            child: Text('No', style: TextStyle(color: isDark ? Colors.white60 : Colors.grey.shade600)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              debugPrint(
                '[TRACE_CANCEL] RideTrackingScreen CANCEL_BUTTON_PRESSED order=${orderObj.id} '
                'epoch=${DateTime.now().millisecondsSinceEpoch}',
              );
              // Close/pop the current screen or modal bottom sheet context
              Navigator.pop(ctx);
              _performCancel(context, orderObj);
            },
            child: const Text('Yes, Cancel', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _performCancel(BuildContext context, TransportOrder orderObj) async {
    // Update the widget state to trigger a UI rebuild with the new variables
    setState(() => _cancelling = true);
    try {
      final supabase = Supabase.instance.client;
      // SECURITY/INTEGRITY FIX: this used to fall back to a raw `orders.update(order_status:
      // 'cancelled')` on ANY exception from cancel-order (network blip or a genuine failure
      // alike) -- that direct write skips the rider_assignments/order_assignment_logs cleanup and
      // order_status_history audit insert cancel-order exists specifically to guarantee, leaving
      // stale 'sent'/'accepted' assignment rows behind with no audit trail. Let a genuine failure
      // surface as an error (caught by the outer try/catch below) so the user can retry, instead
      // of silently corrupting cancellation bookkeeping.
      debugPrint(
        '[TRACE_CANCEL] RideTrackingScreen cancel-order INVOKE START order=${orderObj.id} '
        'epoch=${DateTime.now().millisecondsSinceEpoch}',
      );
      final cancelStopwatch = Stopwatch()..start();
      await supabase.functions.invoke(
        'cancel-order',
        body: {
          'order_id': orderObj.id,
          'cancelled_by': 'user',
          'cancel_reason': 'Cancelled by user from tracking screen',
        },
      );
      debugPrint(
        '[TRACE_CANCEL] RideTrackingScreen cancel-order INVOKE END order=${orderObj.id} '
        'tookMs=${cancelStopwatch.elapsedMilliseconds} mounted=$mounted '
        '_hasLeftScreen=$_hasLeftScreen epoch=${DateTime.now().millisecondsSinceEpoch}',
      );

      if (mounted && !_hasLeftScreen) {
        _hasLeftScreen = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Order has been cancelled successfully')),
        );
        NavTrace.begin('RideTrackingScreen._performCancel', 'returnToLocalRideHome (API success)');
        returnToLocalRideHome(context, isRider: false);
        NavTrace.end('RideTrackingScreen._performCancel', 'returnToLocalRideHome (API success)');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to cancel order: $e')),
        );
      }
    } finally {
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() => _cancelling = false);
      }
    }
  }

  Widget _buildUnifiedDetailsCard(
    BuildContext context,
    TransportOrder orderObj,
    String name,
    String vehicleNum,
    String vehicleType,
    String? vehicleImageUrl,
    bool isDark,
  ) {
    final String leftTitle = orderObj.isRide ? 'Passenger' : 'Sent by';
    final String leftValue = orderObj.isRide ? 'You' : (orderController.userNameNotifier.value.isNotEmpty ? orderController.userNameNotifier.value : 'Sender (You)');
    final String rightTitle = orderObj.isRide ? 'Drop Partner' : 'Received by';
    final String rightValue = orderObj.isRide
        ? (name.isNotEmpty ? name : 'Finding...')
        : (orderObj.receiverName != null
            ? '${orderObj.receiverName}${orderObj.receiverPhone != null && orderObj.receiverPhone!.isNotEmpty ? ' (${orderObj.receiverPhone})' : ''}'
            : 'Not Specified');

    final isPaid = orderObj.paymentStatus.toLowerCase() == 'paid';
    final paymentText = orderObj.paymentStatus.toUpperCase();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.04) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!orderObj.isRide) ...[
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        leftTitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        leftValue,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 24,
                  width: 1,
                  color: isDark ? Colors.white.withValues(alpha: 0.1) : const Color(0xFFE2E8F0),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rightTitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        rightValue,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Divider(color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0), height: 1),
            const SizedBox(height: 16),
          ],

          if (vehicleNum.isNotEmpty || vehicleType.isNotEmpty) ...[
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Assigned Vehicle',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        vehicleType.toUpperCase(),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 24,
                  width: 1,
                  color: isDark ? Colors.white.withValues(alpha: 0.1) : const Color(0xFFE2E8F0),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Plate Number',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        vehicleNum.isNotEmpty ? vehicleNum : 'Not Registered',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Divider(color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0), height: 1),
            const SizedBox(height: 16),
          ],

          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFF10B981),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Pickup Address',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text(
                  orderObj.pickupAddress,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0), height: 1),
          const SizedBox(height: 16),

          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFFEF4444),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Dropoff Address',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text(
                  orderObj.destinationAddress,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0), height: 1),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Estimates Fare',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          '₹${orderObj.payableFare.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isPaid
                                ? const Color(0xFFD1FAE5)
                                : const Color(0xFFFEE2E2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            paymentText,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: isPaid
                                  ? const Color(0xFF065F46)
                                  : const Color(0xFF991B1B),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                height: 24,
                width: 1,
                color: isDark ? Colors.white.withValues(alpha: 0.1) : const Color(0xFFE2E8F0),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      orderObj.isRide ? 'Payment Mode' : 'Weight',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      orderObj.isRide
                          ? orderObj.paymentMode.toUpperCase()
                          : formatWeightCategory(orderObj.weightCategory),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
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

  Widget _buildDriverDetailsCard(
    BuildContext context,
    Map<String, dynamic>? rider,
    String name,
    String phone,
    String riderImageUrl,
    String initial,
    dynamic completedOrders,
    bool isDark,
    Color themeAccent,
    String roleText,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.04) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        children: [
          Container(
            height: 52,
            width: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: themeAccent, width: 1.5),
              color: isDark ? const Color(0xFF0F1115) : const Color(0xFFEFF6FF),
            ),
            child: ClipOval(
              child: (riderImageUrl.isNotEmpty && riderImageUrl.startsWith('http'))
                  ? CachedNetworkImage(
                      imageUrl: riderImageUrl,
                      fit: BoxFit.cover,
                      fadeInDuration: Duration.zero,
                      fadeOutDuration: Duration.zero,
                      placeholder: (ctx, url) => const ImageSkeleton(shape: BoxShape.circle),
                      errorWidget: (ctx, url, err) => _riderInitial(initial, isDark),
                    )
                  : _riderInitial(initial, isDark),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isNotEmpty ? name : 'Finding Partner...',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  name.isNotEmpty ? roleText : 'Assigning soon',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          if (phone.isNotEmpty) ...[
            GestureDetector(
              onTap: () async {
                final cleanPhone = phone.replaceAll(RegExp(r'\s+'), '');
                final formattedPhone = cleanPhone.startsWith('+') ? cleanPhone : '+$cleanPhone';
                final uri = Uri.parse('tel:$formattedPhone');
                try {
                  await launchUrl(uri);
                } catch (e) {
                  debugPrint('Could not launch dialer: $e');
                }
              },
              child: Container(
                height: 44,
                width: 44,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF2D3748) : const Color(0xFFFFF7ED),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFFED7AA),
                    width: 1,
                  ),
                ),
                child: const Icon(
                  Icons.call_rounded,
                  size: 20,
                  color: Color(0xFFEA580C),
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          if (rider != null || orderController.orderNotifier.value?.riderId != null)
            GestureDetector(
              onTap: () {
                final riderId = rider?['id']?.toString() ?? orderController.orderNotifier.value?.riderId;
                // Navigate to a new screen layout using Flutter's Navigator router
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => OrderChatScreen(
                      orderId: widget.orderId,
                      riderId: riderId,
                      chatTitle: name,
                      riderImage: riderImageUrl,
                      isSupport: false,
                    ),
                  ),
                );
              },
              child: Container(
                height: 44,
                width: 44,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF2D3748) : const Color(0xFFFFF7ED),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFFED7AA),
                    width: 1,
                  ),
                ),
                child: const Icon(
                  Icons.chat_bubble_rounded,
                  size: 18,
                  color: Color(0xFFEA580C),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Rider initial avatar fallback ─────────────────────────────────────────

Widget _riderInitial(String initial, bool isDark) {
  if (initial.isEmpty) {
    return Center(
      child: Icon(Icons.person, size: 24, color: isDark ? _primaryLime : const Color(0xFF2563EB)),
    );
  }
  return Center(
    child: Text(
      initial,
      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: isDark ? _primaryLime : const Color(0xFF2563EB)),
    ),
  );
}

// ── Reusable map control button ────────────────────────────────────────────

class _MapBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  const _MapBtn({required this.icon, required this.onTap, this.tooltip});

  @override
  // Build method responsible for rendering the entire widget layout hierarchy on the viewport
  Widget build(BuildContext context) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 40, width: 40,
        decoration: BoxDecoration(
          color: isDark ? _darkCard : Colors.white,
          shape: BoxShape.circle,
          border: isDark ? Border.all(color: Colors.white.withValues(alpha: 0.06)) : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.10),
              blurRadius: 8,
              offset: const Offset(0, 3),
            )
          ],
        ),
        child: Icon(
          icon,
          size: 18,
          color: isDark ? _primaryLime : const Color(0xFF334155),
        ),
      ),
    );
  }
}
