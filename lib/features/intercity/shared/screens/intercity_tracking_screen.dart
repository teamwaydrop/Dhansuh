import 'package:waydrop/core/services/diagnostics/ride_diagnostics.dart';
import 'package:waydrop/core/services/diagnostics/ride_diagnostics_owner.dart';
/// ============================================================================
/// File: intercity_tracking_screen.dart
///
/// Module:
/// Intercity → Shared
///
/// Purpose:
/// Real-time map tracking screen for active intercity rides/parcels.
///
/// Responsibilities:
/// • Display active route path, show OTP verification for pickup/delivery, show status indicators.
///
/// Related:
/// order_chat_screen.dart
/// ============================================================================

import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:waydrop/core/config/env.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:waydrop/models/transport_order.dart';
import 'package:waydrop/features/intercity/shared/widgets/waiting_for_travel_day_card.dart';
import 'package:waydrop/core/services/realtime/realtime_order_controller.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:waydrop/core/services/cache/cache_service.dart';
import 'package:waydrop/core/navigation/flow_modules.dart';
import 'package:waydrop/features/local_rides/rating/screens/rider_rating_screen.dart';
import 'package:waydrop/modules/chat/screens/order_chat_screen.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:waydrop/modules/support/screens/customer_support_screen.dart';
import 'package:waydrop/features/local_rides/searching/screens/ride_searching_screen.dart';
import 'package:waydrop/features/local_parcels/searching/screens/parcel_searching_screen.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_searching_screen.dart';
import 'package:waydrop/features/intercity/shared/navigation/intercity_home_navigator.dart';
import 'package:waydrop/shared/helpers/location_display_service.dart';
import 'package:waydrop/shared/helpers/insets.dart';
import 'package:waydrop/core/navigation/nav_trace.dart';



const Color _primaryLime = Color(0xFFC5FF30);
const Color _darkBg = Color(0xFF0F1115);
const Color _darkCard = Color(0xFF171A21);

class IntercityTrackingScreen extends StatefulWidget {
  final String orderId;

  const IntercityTrackingScreen({
    super.key,
    required this.orderId,
  });

  @override
  State<IntercityTrackingScreen> createState() => _IntercityTrackingScreenState();
}

class _IntercityTrackingScreenState extends State<IntercityTrackingScreen> {
  late RealtimeOrderController orderController;
  WebViewController? mapController;
  // Phase 2F-E (C3) -- one-shot guard for the onWebResourceError renderer-recovery reload below.
  // Mirrors rider_active_order_screen.dart's Phase 2A _mapReloadAttempts. Never reset within a
  // screen instance: a reload storm on a genuinely dead renderer must be impossible.
  int _mapReloadAttempts = 0;
  bool loading = true;
  String routeGeometry = '[]';
  List<Map<String, dynamic>> verifications = [];
  bool loadingVerifications = true;

  static final Map<String, List<List<double>>> _staticRouteCache = {};
  String? _currentRiderRouteHash;
  bool _isCompletedSheetShown = false;
  bool _cancelling = false;
  // Guards against the realtime/polling-driven order listener (_onOrderUpdate) and the direct
  // cancel-button success handler (_performCancel) both reacting to the same cancellation and
  // each independently calling Navigator on this screen -- the DB write happens mid-way through
  // the cancel-order edge function, so the realtime push can reach this screen before the HTTP
  // response the button is awaiting does. Two uncoordinated Navigator mutations racing on the
  // same screen is what intermittently corrupts the route stack into a black screen. Only the
  // first of the two to observe the terminal state may act; the other is a no-op.
  bool _hasLeftScreen = false;

  // Track last known rider position for the map controls
  double? _riderLat;
  double? _riderLng;

  // Track background directions fetching status & throttling
  bool _fetchingRiderRoute = false;
  DateTime? _lastRiderRouteFetchTime;
  double? _lastTargetLat;
  double? _lastTargetLng;
  // Set when a target/status change wants an immediate route refresh but a Directions request for
  // the previous target was already in flight -- consumed by _fetchAndSetRiderRoute's finally
  // block (via a re-run of _onRiderLocationUpdate) so the change is retried the instant the
  // in-flight request completes instead of being silently dropped or waiting for the next
  // throttle window. WayDrop Ola Directions egress reduction (2026-08-22) -- same fix already
  // applied and tested on ride_tracking_screen.dart; this screen had the identical pre-fix pattern.
  bool _pendingForceRouteFetch = false;

  // WayDrop Ola Directions egress reduction (2026-08-22): the old flat "refetch every 15s OR every
  // 50m" throttle re-called Ola's Directions API on almost every rider location tick for the
  // entire acceptance-to-drop-off window. Replaced with a distance-to-target-aware floor: far from
  // the target, a polyline that's a few tens of seconds stale is visually indistinguishable, so the
  // refresh floor widens; close to the target (last-mile approach) it stays tighter. The 50m
  // movement trigger is kept but is now also floored by a minimum time gap so a fast-moving rider
  // crossing 50m every few seconds can no longer re-trigger a fresh Directions call faster than
  // that floor.
  static const double _nearTargetThresholdKm = 0.6;
  static const int _farRefreshIntervalSeconds = 40;
  static const int _nearRefreshIntervalSeconds = 20;
  static const int _minMovementGapSeconds = 12;
  static const double _movementThresholdKm = 0.05;
  double? _lastFetchedRiderLat;
  double? _lastFetchedRiderLng;

  late final RideDiagnosticOwner _rideDiagnosticOwner;

  @override
  // Lifecycle method called once when the stateful widget initialized for the first time
  void initState() {
    // Lifecycle method called once when the stateful widget initialized for the first time
    super.initState();
    _rideDiagnosticOwner = RideDiagnosticOwner.widget(() => mounted, surface: RideSurface.passengerTracking);
    orderController = RealtimeOrderController(orderId: widget.orderId);
    initialize();
  }

  @override
  // Lifecycle method called before the widget is removed permanently from the tree to clean resources
  void dispose() {
    _rideDiagnosticOwner.dispose();
    debugPrint(
      '[TRACE_CANCEL] IntercityTrackingScreen.dispose() ENTER order=${widget.orderId} '
      '_hasLeftScreen=$_hasLeftScreen _cancelling=$_cancelling '
      // webview_flutter exposes no separate disposal hook to Dart code -- the WebViewWidget
      // (mapController) is a child of this widget's subtree, so its underlying platform view is
      // torn down by the framework as part of this same dispose(), not observably before/after it.
      'epoch=${DateTime.now().millisecondsSinceEpoch}',
    );
    orderController.orderNotifier.removeListener(_onOrderUpdate);
    orderController.riderLocationNotifier.removeListener(_onRiderLocationUpdate);
    orderController.riderNotifier.removeListener(_onRiderLocationUpdate);
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
      '[TRACE_CANCEL] IntercityTrackingScreen.dispose() EXIT order=${widget.orderId} '
      'epoch=${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  Future<void> fetchVerifications() async {
    try {
      final res = await Supabase.instance.client
          .from('order_verifications')
          .select('photo_url, verification_type, verification_status, metadata')
          .eq('order_id', widget.orderId);
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          verifications = List<Map<String, dynamic>>.from(res);
          loadingVerifications = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching verifications: $e');
    }
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
    orderController.riderNotifier.addListener(_onRiderLocationUpdate);

    await loadRoute(currentOrder);
    await fetchVerifications();

    // Update the widget state to trigger a UI rebuild with the new variables
    if (mounted) setState(() => loading = false);
  }

  void _onOrderUpdate() {
    final orderObj = orderController.orderNotifier.value;
    debugPrint(
      '[TRACE_CANCEL] IntercityTrackingScreen._onOrderUpdate() FIRED order=${widget.orderId} '
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
        NavTrace.begin('IntercityTrackingScreen._onOrderUpdate', 'returnToIntercityHome (order==null)');
        returnToIntercityHome(context, isTraveller: false);
        NavTrace.end('IntercityTrackingScreen._onOrderUpdate', 'returnToIntercityHome (order==null)');
      }
      return;
    }

    // R6 perf fix: fetchVerifications() was firing unconditionally on every orderNotifier tick
    // (every `orders` realtime UPDATE + every stale-realtime polling fallback fetch), regardless
    // of whether verification data could possibly have changed.
    //   1. The verification UI only ever renders for !orderObj.isRide (see
    //      _buildVerificationPhotosRow's own guard below) -- order_verifications is never
    //      populated for ride orders either (every writer -- process-verification-photo,
    //      _bypassVerification -- is parcel-only), so a ride order's query is always empty. Skip.
    //   2. order_verifications is INSERT-only (no UPDATE writer exists anywhere in the codebase) --
    //      once both the pickup and dropoff rows exist for an intercity_parcel order, nothing left
    //      can ever change, so further refetches are guaranteed no-ops. Skip.
    // Every other case (verification data not yet complete, or a non-ride/non-intercity_parcel
    // type this screen may still show) keeps calling fetchVerifications() exactly as before --
    // gating on orderStatus/deliveryOtp instead was ruled unsafe (pickup_verification_completed
    // isn't exposed by TransportOrder/RealtimeOrderController), so that gate is deliberately NOT
    // used here.
    final verificationsAlreadyComplete = orderObj.orderType == 'intercity_parcel' &&
        verifications.any((v) => v['verification_type'] == 'pickup') &&
        verifications.any((v) => v['verification_type'] == 'dropoff');
    if (!orderObj.isRide && !verificationsAlreadyComplete) {
      fetchVerifications();
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
        NavTrace.begin('IntercityTrackingScreen._onOrderUpdate', 'returnToIntercityHome (isCancelled)');
        returnToIntercityHome(context, isTraveller: false);
        NavTrace.end('IntercityTrackingScreen._onOrderUpdate', 'returnToIntercityHome (isCancelled)');
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
              if (orderObj.orderType == 'local_parcel') {
                return ParcelSearchingScreen(orderId: widget.orderId);
              } else if (orderObj.orderType == 'intercity_parcel') {
                return IntercitySearchingScreen(orderId: widget.orderId);
              } else if (orderObj.orderType == 'intercity_ride' || (orderObj.orderType == 'ride' && (double.tryParse(orderObj.distanceMeters.toString()) ?? 0.0) > 20000)) {
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
    if (location == null || mapController == null) return;

    final lat = location['lat']!;
    final lng = location['lng']!;
    final heading = location['heading'] ?? 0.0;

    // Cache for map focus button
    _riderLat = lat;
    _riderLng = lng;

    // Get rider name, image & vehicle type from controller (with fallback)
    final name = orderController.riderNotifier.value?['name']?.toString() ?? '';
    final image = orderController.riderNotifier.value?['rider_image']?.toString() ?? '';
    // Issue 3 fix (audit follow-up): never fall back to orderNotifier.value?.vehicleType here --
    // for an intercity order that is the PASSENGER's own booking-time preference, not the
    // traveller's actual vehicle, and falling back to it re-introduces the same CAR-shown-as-BIKE
    // class of bug this screen was fixed for. A neutral default is used instead.
    final vehicleType = orderController.riderNotifier.value?['vehicle_type']?.toString() ?? 'cab';

    // Smooth animated move via JS interpolation
    final status = orderController.orderNotifier.value?.orderStatus ?? '';
    mapController!.runJavaScript("if (typeof updateRiderLocation === 'function') { updateRiderLocation($lat, $lng, ${jsonEncode(name)}, ${jsonEncode(image)}, ${jsonEncode(vehicleType)}, $heading, ${jsonEncode(status)}); }");

    // Fetch road-snapped Directions from rider to active target
    final orderObj = orderController.orderNotifier.value;
    // Duplicate/validity guard (Ola egress reduction): never resolve a target or schedule a
    // Directions fetch for an order that has already finished.
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
      // how far the rider still is from the active target instead of a flat 15s, and the 50m
      // movement trigger can no longer fire more than once every _minMovementGapSeconds.
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
          // remember it so it fires the instant the in-flight request completes.
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
      // in flight -- retry immediately using the freshest known order/rider state instead of
      // waiting for the next throttle window.
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
        gradientPart(lat1, lat2, dLon);
    final double c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a));
    return r * c;
  }

  double gradientPart(double lat1, double lat2, double dLon) {
    return cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) * sin(dLon / 2.0) * sin(dLon / 2.0);
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
                      backgroundColor: const Color(0xFF7C3AED),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    onPressed: () {
                      // Close/pop the modal bottom sheet
                      Navigator.pop(context);
                      // Task 4: replace (not push-on-top-of) this tracking screen so its
                      // WebView/realtime listeners are disposed immediately via a single, normal
                      // route transition — this is what eliminates the black-screen race that used
                      // to happen when a later bulk popUntil tore down a still-live WebView.
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
                'Your delivery tracking will continue in the background. You can track or resume it at any time from the Activity tab.',
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
      return Scaffold(
        backgroundColor: isDark ? _darkBg : Colors.white,
        body: const Center(child: CircularProgressIndicator(color: Color(0xFF7C3AED))),
      );
    }

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
        backgroundColor: isDark ? _darkBg : Colors.white,
        body: Stack(
          children: [
            // ── 1. Full-screen map
            Positioned.fill(
              child: WebViewWidget(controller: mapController!),
            ),

            // Task 2: live tracking is only meaningful (and only shown) once the traveller has
            // pressed Start Trip — before that, block the live map behind a neutral backdrop
            // instead of letting the passenger interact with a map that has nothing live to show.
            // The bottom sheet (below) already carries the actionable WaitingForTravelDayCard, so
            // this backdrop is deliberately just a message, not a duplicate of that card.
            // The WebView itself stays mounted underneath (avoids a costly re-init); only the
            // visible/interactive surface is gated.
            ValueListenableBuilder<TransportOrder?>(
              valueListenable: orderController.orderNotifier,
              builder: (context, orderObj, _) {
                if (orderObj == null || !orderObj.isWaitingForTravelDay) return const SizedBox.shrink();
                return Positioned.fill(
                  child: Container(
                    color: isDark ? _darkBg : Colors.white,
                    child: SafeArea(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 40),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.event_available_rounded, size: 40, color: isDark ? Colors.white38 : Colors.black26),
                              const SizedBox(height: 12),
                              Text(
                                'Live tracking will begin once your travel partner starts the trip.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: isDark ? Colors.white38 : Colors.black38,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
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
                      final exit = await _showExitConfirmation(context);
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

            // ── 3. Top-right: LIVE badge + map focus controls (Task 2: hidden until Start Trip)
            Positioned(
              top: Insets.top(context) + 10,
              right: 14,
              child: ValueListenableBuilder<TransportOrder?>(
                valueListenable: orderController.orderNotifier,
                builder: (context, orderObj, _) {
                  if (orderObj != null && orderObj.isWaitingForTravelDay) return const SizedBox.shrink();
                  return Column(
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
                        Container(
                          width: 7, height: 7,
                          decoration: const BoxDecoration(color: Color(0xFF7C3AED), shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 5),
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
                  );
                },
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
                    _rideDiagnosticOwner.frame(context, widget.orderId, orderObj.orderStatus,
                      () => orderController.orderNotifier.value?.orderStatus == orderObj.orderStatus);

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
                                // Issue 3 fix (audit follow-up): never fall back to orderObj.vehicleType
                                // here -- for an intercity order that is the PASSENGER's own booking-time
                                // preference, not the traveller's actual vehicle. A neutral default is
                                // used instead so a transient missing value can never display a specific,
                                // possibly-wrong vehicle type.
                                final vehicleType   = rider?['vehicle_type']?.toString() ?? 'vehicle';
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
                                    double estimatedArrivalMinutes = 0.0;
                                    double distanceKm = 0.0;
                                    final location = orderController.riderLocationNotifier.value;

                                    if (location != null) {
                                      final double rLat = location['lat']!;
                                      final double rLng = location['lng']!;
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
                                      final liveState = orderController.liveStateNotifier.value;
                                      final etaVal = liveState?['tracking']?['estimated_arrival_minutes'];
                                      estimatedArrivalMinutes = double.tryParse(etaVal?.toString() ?? '') ?? 0.0;
                                    }

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
                                          orderObj.isRide ? 'Traveler Partner' : 'Delivery Partner',
                                        ),
                                        _buildOtpVerificationCard(context, orderObj, isDark),
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
    final pickupCity = orderObj.isRide
        ? 'Pickup Point'
        : (orderObj.pickupCity == null || orderObj.pickupCity!.isEmpty || orderObj.pickupCity == 'Other')
            ? _getCityName(orderObj.pickupAddress, 'Pickup')
            : orderObj.pickupCity!;
    final destCity = orderObj.isRide
        ? 'Destination'
        : (orderObj.destinationCity == null || orderObj.destinationCity!.isEmpty || orderObj.destinationCity == 'Other')
            ? _getCityName(orderObj.destinationAddress, 'Dropoff')
            : orderObj.destinationCity!;

    final createdStr = orderObj.createdAt != null
        ? _formatDate(orderObj.createdAt!)
        : 'Today';

    String estStr;
    if (estimatedArrivalMinutes > 0) {
      final minutes = estimatedArrivalMinutes.round();
      if (minutes < 60) {
        estStr = 'Est $minutes min';
      } else {
        final hours = (minutes / 60).toStringAsFixed(1);
        estStr = 'Est $hours hrs';
      }
    } else {
      final travelDt = orderObj.travelDate ?? orderObj.createdAt?.add(const Duration(days: 3)) ?? DateTime.now();
      estStr = 'Est ${_formatDate(travelDt)}';
    }

    final status = orderObj.orderStatus;
    int activeStep = 0;
    if (status == 'accepted' || status == 'rider_arrived') {
      activeStep = 1;
    } else if (status == 'picked_up' || status == 'ongoing' || status == 'rider_at_drop') {
      activeStep = 2;
    } else if (status == 'completed' || status == 'delivered') {
      activeStep = 3;
    }

    final Color themeAccent = orderObj.orderType == 'local_parcel' || orderObj.orderType == 'intercity_parcel'
        ? const Color(0xFFEA580C)
        : (orderObj.flowType == OrderFlowType.intercity ? const Color(0xFF7C3AED) : const Color(0xFFC5FF30));

    final Color inactiveColor = isDark ? Colors.white.withValues(alpha: 0.1) : const Color(0xFFE2E8F0);
    final Color inactiveIconColor = isDark ? Colors.white.withValues(alpha: 0.3) : const Color(0xFF94A3B8);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pickupCity,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      createdStr,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      destCity,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      estStr,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _buildRideStatusBanner(orderObj, themeAccent, isDark),
          if (orderObj.isAwaitingUpiPayment) ...[
            const SizedBox(height: 12),
            FarePaymentPanel(order: orderObj),
          ],
          if (orderObj.isWaitingForTravelDay) ...[
            // Feature 7: "Both apps now show Waiting for Travel Day" — the passenger side is
            // informational only (no Start Trip button; only the traveller can start the trip).
            WaitingForTravelDayCard(
              travelDate: orderObj.travelDate,
              isTraveller: false,
            ),
          ],
          if (!orderObj.isRide) ...[
            _buildVerificationPhotosRow(context, isDark),
          ],
        ],
      ),
    );
  }

  Widget _buildVerificationPhotosRow(BuildContext context, bool isDark) {
    if (verifications.isEmpty) return const SizedBox.shrink();

    final pickupV = verifications.firstWhere(
      (v) => v['verification_type'] == 'pickup',
      orElse: () => <String, dynamic>{},
    );
    final dropoffV = verifications.firstWhere(
      (v) => v['verification_type'] == 'dropoff',
      orElse: () => <String, dynamic>{},
    );

    if (pickupV.isEmpty && dropoffV.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0), height: 24),
        Row(
          children: [
            const Icon(Icons.photo_library_outlined, size: 14, color: _primaryLime),
            const SizedBox(width: 6),
            Text(
              'Handoff Verification Proofs',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (pickupV.isNotEmpty)
              Expanded(
                child: _buildVerificationThumbnail(context, 'Pickup Proof', pickupV, isDark),
              ),
            if (pickupV.isNotEmpty && dropoffV.isNotEmpty)
              const SizedBox(width: 12),
            if (dropoffV.isNotEmpty)
              Expanded(
                child: _buildVerificationThumbnail(context, 'Delivery Proof', dropoffV, isDark),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildVerificationThumbnail(
    BuildContext context,
    String title,
    Map<String, dynamic> v,
    bool isDark,
  ) {
    final status = v['verification_status']?.toString();
    final url = v['photo_url']?.toString();
    final isBypassed = status == 'bypassed';
    final reason = v['metadata'] is Map ? (v['metadata']['bypass_reason']?.toString() ?? 'No reason') : 'No reason';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 10,
            color: isDark ? const Color(0xFF64748B) : Colors.grey,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: isBypassed || url == null || url.isEmpty
              ? null
              : () => _showFullscreenImage(context, url),
          child: Container(
            height: 90,
            width: double.infinity,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark ? Colors.white.withOpacity(0.06) : const Color(0xFFE2E8F0),
              ),
            ),
            child: isBypassed
                ? Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.info_outline_rounded, color: Colors.orangeAccent, size: 18),
                        const SizedBox(height: 4),
                        const Text(
                          'BYPASSED',
                          style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.orangeAccent),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          reason,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 9,
                            color: isDark ? Colors.white70 : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  )
                : (url != null && url.isNotEmpty)
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          imageUrl: url,
                          fit: BoxFit.cover,
                          placeholder: (ctx, _) => const Center(
                            child: SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: _primaryLime),
                            ),
                          ),
                          errorWidget: (ctx, _, __) => const Center(
                            child: Icon(Icons.broken_image_rounded, color: Colors.redAccent, size: 20),
                          ),
                        ),
                      )
                    : const Center(
                        child: Icon(Icons.image_not_supported_rounded, color: Colors.white24, size: 20),
                      ),
          ),
        ),
      ],
    );
  }

  void _showFullscreenImage(BuildContext context, String url) {
    // Show an overlay dialog window on the screen for user decision
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            GestureDetector(
              // Close/pop the current screen or modal bottom sheet context
              onTap: () => Navigator.pop(ctx),
              child: Container(
                color: Colors.black.withOpacity(0.9),
                width: double.infinity,
                height: double.infinity,
                child: InteractiveViewer(
                  child: CachedNetworkImage(
                    imageUrl: url,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
                // Close/pop the current screen or modal bottom sheet context
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
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

    // SECURITY FIX (P0): only the order's own passenger may ever see the pickup/delivery OTP
    // here -- this same screen is also opened by the traveller/driver (e.g. from
    // intercity_bookings_screen.dart's "Track / Navigate" button), who would otherwise see the
    // exact code the passenger/receiver is supposed to keep secret and read aloud to verify.
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

  // Issue 8 fix: cancellation reasons offered to the User/Passenger when cancelling an Intercity
  // trip/request. `orders.cancel_reason` already exists and already stores whatever string is
  // passed here -- no new column, no new mechanism, just real user input instead of the previous
  // hardcoded literal.
  static const List<String> _cancellationReasons = [
    'Plans changed',
    'Found another option',
    "Traveller timing doesn't work",
    'Price issue',
    'No longer need the delivery',
    'Other',
  ];

  Future<void> _confirmCancel(BuildContext context, TransportOrder orderObj) async {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    String? selectedReason;
    final otherController = TextEditingController();
    // Show an overlay dialog window on the screen for user decision
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: Text(
            'Why are you cancelling?',
            style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? Colors.white : const Color(0xFF0F172A)),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _cancellationReasons.map((reason) {
                    final selected = selectedReason == reason;
                    return ChoiceChip(
                      label: Text(reason),
                      selected: selected,
                      onSelected: (_) => setDialogState(() => selectedReason = reason),
                      selectedColor: const Color(0xFFDC2626).withOpacity(0.15),
                      labelStyle: TextStyle(
                        color: selected
                            ? const Color(0xFFDC2626)
                            : (isDark ? Colors.white70 : Colors.black87),
                        fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                      ),
                      backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                    );
                  }).toList(),
                ),
                if (selectedReason == 'Other') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: otherController,
                    autofocus: true,
                    maxLines: 2,
                    style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                    decoration: InputDecoration(
                      hintText: 'Tell us more (optional)',
                      hintStyle: TextStyle(color: isDark ? Colors.white38 : Colors.black38),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ],
            ),
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
              // Cancellation must still work even if no specific reason is picked -- never block
              // the actual cancel action on this being filled in.
              onPressed: () {
                debugPrint(
                  '[TRACE_CANCEL] IntercityTrackingScreen CANCEL_BUTTON_PRESSED order=${orderObj.id} '
                  'epoch=${DateTime.now().millisecondsSinceEpoch}',
                );
                final otherText = otherController.text.trim();
                final reason = selectedReason == 'Other' && otherText.isNotEmpty
                    ? otherText
                    : (selectedReason ?? 'Other');
                // Close/pop the current screen or modal bottom sheet context
                Navigator.pop(ctx);
                _performCancel(context, orderObj, reason);
              },
              child: const Text('Yes, Cancel', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _performCancel(BuildContext context, TransportOrder orderObj, [String? reason]) async {
    // Update the widget state to trigger a UI rebuild with the new variables
    setState(() => _cancelling = true);
    try {
      final supabase = Supabase.instance.client;
      // SECURITY/INTEGRITY FIX: this used to fall back to a raw `orders.update(order_status:
      // 'cancelled')` on ANY exception from cancel-order -- that direct write skips the
      // rider_assignments/order_assignment_logs cleanup and order_status_history audit insert
      // cancel-order exists specifically to guarantee. Let a genuine failure surface as an error
      // (caught by the outer try/catch below) so the user can retry, instead of silently
      // corrupting cancellation bookkeeping.
      debugPrint(
        '[TRACE_CANCEL] IntercityTrackingScreen cancel-order INVOKE START order=${orderObj.id} '
        'epoch=${DateTime.now().millisecondsSinceEpoch}',
      );
      final cancelStopwatch = Stopwatch()..start();
      await supabase.functions.invoke(
        'cancel-order',
        body: {
          'order_id': orderObj.id,
          'cancelled_by': 'user',
          'cancel_reason': reason ?? 'Cancelled by user from tracking screen',
        },
      );
      debugPrint(
        '[TRACE_CANCEL] IntercityTrackingScreen cancel-order INVOKE END order=${orderObj.id} '
        'tookMs=${cancelStopwatch.elapsedMilliseconds} mounted=$mounted '
        '_hasLeftScreen=$_hasLeftScreen epoch=${DateTime.now().millisecondsSinceEpoch}',
      );

      if (mounted && !_hasLeftScreen) {
        _hasLeftScreen = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Order has been cancelled successfully')),
        );
        NavTrace.begin('IntercityTrackingScreen._performCancel', 'returnToIntercityHome (API success)');
        returnToIntercityHome(context, isTraveller: false);
        NavTrace.end('IntercityTrackingScreen._performCancel', 'returnToIntercityHome (API success)');
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
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Passenger Name',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        orderController.userNameNotifier.value.isNotEmpty
                            ? orderController.userNameNotifier.value
                            : 'You',
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
                        'Seats Booked',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${orderObj.seatsRequested} Seats',
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
    return GestureDetector(
      onTap: rider == null
          ? null
          : () {
              final orderObj = orderController.orderNotifier.value;
              if (orderObj != null) {
                _showAssignedRiderProfileDetails(context, rider, orderObj);
              }
            },
      child: Container(
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
      ),
    );
  }

  void _showAssignedRiderProfileDetails(
    BuildContext context,
    Map<String, dynamic> rider,
    TransportOrder orderObj,
  ) {
    // Present a premium modal bottom sheet drawer for user input/actions
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF171A21) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return AssignedRiderProfileSheet(
          rider: rider,
          order: orderObj,
        );
      },
    );
  }
}

Widget _riderInitial(String initial, bool isDark) {
  if (initial.isEmpty) {
    return Center(
      child: Icon(Icons.person, size: 24, color: isDark ? const Color(0xFF7C3AED) : const Color(0xFF2563EB)),
    );
  }
  return Center(
    child: Text(
      initial,
      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFF7C3AED) : const Color(0xFF2563EB)),
    ),
  );
}

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
          color: isDark ? const Color(0xFF7C3AED) : const Color(0xFF334155),
        ),
      ),
    );
  }
}

class AssignedRiderProfileSheet extends StatefulWidget {
  final Map<String, dynamic> rider;
  final TransportOrder order;

  const AssignedRiderProfileSheet({
    super.key,
    required this.rider,
    required this.order,
  });

  @override
  State<AssignedRiderProfileSheet> createState() => _AssignedRiderProfileSheetState();
}

class _AssignedRiderProfileSheetState extends State<AssignedRiderProfileSheet> {
  final supabase = Supabase.instance.client;
  bool _loadingCapacity = false;
  double? _remainingWeight;
  double? _maxWeight;
  int? _remainingSeats;
  int? _maxSeats;

  @override
  // Lifecycle method called once when the stateful widget initialized for the first time
  void initState() {
    // Lifecycle method called once when the stateful widget initialized for the first time
    super.initState();
    _fetchCapacity();
  }

  Future<void> _fetchCapacity() async {
    // Update the widget state to trigger a UI rebuild with the new variables
    setState(() => _loadingCapacity = true);
    try {
      final riderId = widget.rider['id']?.toString();
      if (riderId != null) {
        final res = await supabase
            .from('rider_travel_plans')
            .select('max_weight_kg, max_bookings')
            .eq('rider_id', riderId)
            .eq('status', 'active')
            .order('travel_date', ascending: true)
            .limit(1)
            .maybeSingle();

        if (res != null) {
          _maxWeight = double.tryParse(res['max_weight_kg']?.toString() ?? '');
          _maxSeats = int.tryParse(res['max_bookings']?.toString() ?? '') ?? 3;

          if (widget.order.orderType == 'intercity_parcel') {
            final capRes = await supabase
                .from('travel_plan_capacity_view')
                .select('remaining_capacity_kg')
                .eq('rider_id', riderId)
                .limit(1)
                .maybeSingle();
            if (capRes != null && mounted) {
              // Update the widget state to trigger a UI rebuild with the new variables
              setState(() {
                _remainingWeight = double.tryParse(capRes['remaining_capacity_kg']?.toString() ?? '');
              });
            } else {
              _remainingWeight = _maxWeight;
            }
          } else {
            final ordersRes = await supabase
                .from('orders')
                .select('seats_requested, capacity')
                .eq('rider_id', riderId)
                .inFilter('order_status', ['accepted', 'rider_arrived', 'ongoing', 'picked_up', 'rider_at_drop']);

            int bookedSeats = 0;
            for (var o in ordersRes) {
              final int seats = int.tryParse(o['seats_requested']?.toString() ?? '') ??
                                int.tryParse(o['capacity']?.toString() ?? '') ?? 1;
              bookedSeats += seats;
            }
            if (mounted) {
              // Update the widget state to trigger a UI rebuild with the new variables
              setState(() {
                _remainingSeats = (_maxSeats! - bookedSeats).clamp(0, _maxSeats!);
              });
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error fetching active plan capacity for tracking sheet: $e');
    } finally {
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() => _loadingCapacity = false);
      }
    }
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

  String _getCleanCityName(String? city, String? address, String defaultName) {
    return LocationDisplayService.resolveCity(
      city: city,
      address: address,
      fallback: defaultName,
    );
  }

  @override
  // Build method responsible for rendering the entire widget layout hierarchy on the viewport
  Widget build(BuildContext context) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final planDateStr = widget.order.travelDate != null
        ? _formatTravelDate(widget.order.travelDate)
        : '';
        
    final double rating = double.tryParse((widget.rider['rating'] ?? 5.0).toString()) ?? 5.0;
    final reliability = (widget.rider['reliability_score'] as num?)?.round() ?? 95;
    final totalCompleted = widget.rider['total_completed'] ?? widget.rider['total_completed_orders'] ?? widget.rider['total_orders'] ?? 0;
    final onTimeRate = (widget.rider['on_time_rate'] as num?)?.round() ?? 100;

    final isParcel = widget.order.orderType == 'intercity_parcel';

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
                  'Traveler Profile',
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
                      backgroundColor: isDark ? const Color(0xFF1E222B) : Colors.grey.shade200,
                      backgroundImage: widget.rider['rider_image'] != null && widget.rider['rider_image'].toString().isNotEmpty
                          ? NetworkImage(widget.rider['rider_image'].toString())
                          : null,
                      child: widget.rider['rider_image'] == null || widget.rider['rider_image'].toString().isEmpty
                          ? const Icon(Icons.person, color: Color(0xFF7C3AED), size: 32)
                          : null,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.rider['name'] ?? 'Traveler Partner',
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
                                  color: widget.rider['account_status'] == 'online' ? Colors.green.withOpacity(0.15) : Colors.grey.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  widget.rider['account_status'] == 'online' ? 'ONLINE' : 'OFFLINE',
                                  style: TextStyle(
                                    color: widget.rider['account_status'] == 'online' ? Colors.green : Colors.grey,
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
                      '${_getCleanCityName(widget.order.pickupCity, widget.order.pickupAddress, 'Pickup')} to ${_getCleanCityName(widget.order.destinationCity, widget.order.destinationAddress, 'Destination')}',
                      isDark,
                    ),
                    if (planDateStr.isNotEmpty) ...[
                      const Divider(height: 20),
                      _buildDetailRow(
                        Icons.calendar_month_rounded,
                        'Travel Date & Time',
                        planDateStr,
                        isDark,
                      ),
                    ],
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
                      if (_loadingCapacity) ...[
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 8.0),
                            child: SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF7C3AED)),
                            ),
                          ),
                        ),
                      ] else ...[
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
                              '${(_remainingWeight ?? 50.0).toStringAsFixed(1)} kg / ${(_maxWeight ?? 50.0).toStringAsFixed(1)} kg',
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
                            value: (_maxWeight ?? 50.0) > 0 ? ((_remainingWeight ?? 50.0) / (_maxWeight ?? 50.0)).clamp(0.0, 1.0) : 0.0,
                            backgroundColor: isDark ? Colors.white10 : Colors.grey.shade200,
                            color: const Color(0xFF7C3AED),
                            minHeight: 6,
                          ),
                        ),
                      ],
                      const Divider(height: 24),
                    ] else ...[
                      if (_loadingCapacity) ...[
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 8.0),
                            child: SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF7C3AED)),
                            ),
                          ),
                        ),
                      ] else ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Seats Capacity Left',
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              '${_remainingSeats ?? 3} Seats Left / ${_maxSeats ?? 3} Seats',
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
                            value: (_maxSeats ?? 3) > 0 ? ((_remainingSeats ?? 3) / (_maxSeats ?? 3)).clamp(0.0, 1.0) : 0.0,
                            backgroundColor: isDark ? Colors.white10 : Colors.grey.shade200,
                            color: const Color(0xFF7C3AED),
                            minHeight: 6,
                          ),
                        ),
                      ],
                      const Divider(height: 24),
                    ],
                    _buildDetailRow(
                      // Phase 11 (Issue 3): this icon was hardcoded to two_wheeler regardless of
                      // the actual vehicle -- the label right next to it already read the real
                      // vehicle_type correctly, so a CAR trip showed the correct text with a bike
                      // icon. Same bike/auto/car convention already used in transport_map_widget.dart.
                      (() {
                        final vt = widget.rider['vehicle_type']?.toString().toLowerCase();
                        if (vt == 'auto') return Icons.local_taxi_rounded;
                        if (vt == 'cab' || vt == 'car') return Icons.directions_car_rounded;
                        return Icons.two_wheeler_rounded;
                      })(),
                      'Vehicle Verification',
                      '${widget.rider['vehicle_type']?.toString().toUpperCase() ?? "VEHICLE"} (${widget.rider['vehicle_number'] ?? "N/A"})',
                      isDark,
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
        color: isDark ? const Color(0xFF171A21) : Colors.white,
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

  Widget _buildDetailRow(IconData icon, String label, String value, bool isDark) {
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
}
