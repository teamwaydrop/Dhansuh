/// ============================================================================
/// File: ride_location_screen.dart
///
/// Module:
/// Local Rides → Booking
///
/// Purpose:
/// Pick origin and destination locations for a local ride.
///
/// Responsibilities:
/// • Render map screen, search addresses, select vehicle types.
/// • Request driver matching and handle fare negotiations.
///
/// Related:
/// ride_searching_screen.dart
/// pricing_controller.dart
/// ============================================================================

// transport_location_screen.dart

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/core/services/location/location_permission_helper.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:waydrop/shared/helpers/location_display_service.dart';
import 'package:waydrop/shared/helpers/device_info_helper.dart';
import 'package:waydrop/shared/widgets/states/vehicle_pricing_skeleton_card.dart';
import 'package:waydrop/features/local_rides/searching/screens/ride_searching_screen.dart';
import 'package:waydrop/modules/payments/controllers/pricing_controller.dart';

import 'package:waydrop/features/local_parcels/booking/screens/parcel_details_screen.dart';
import 'package:waydrop/features/intercity/rides/booking/intercity_ride_booking_screen.dart';
import 'package:waydrop/shared/helpers/insets.dart';
import 'package:waydrop/core/services/location/serviceability_service.dart';

class RideLocationScreen extends StatefulWidget {
  final String orderType;
  final String? prefillPickupAddress;
  final String? prefillDestinationAddress;
  final double? prefillPickupLat;
  final double? prefillPickupLng;
  final double? prefillDestinationLat;
  final double? prefillDestinationLng;

  const RideLocationScreen({
    super.key,
    this.orderType = 'ride',
    this.prefillPickupAddress,
    this.prefillDestinationAddress,
    this.prefillPickupLat,
    this.prefillPickupLng,
    this.prefillDestinationLat,
    this.prefillDestinationLng,
  });

  @override
  State<RideLocationScreen> createState() =>
      _RideLocationScreenState();
}

class _RideLocationScreenState
    extends State<RideLocationScreen> with SingleTickerProviderStateMixin {

  late final AnimationController _pulseController;

  // Booking Flow States
  bool _showBookingOptions = false;
  late PricingController pricingController;
  String? selectedVehicle;
  String paymentMode = 'cash';
  double selectedBoostAmount = 0;
  bool creatingOrder = false;
  bool waitingForPayment = false;
  List<Map<String, dynamic>> nearbyRiders = [];
  bool showPromoField = false;
  final TextEditingController _promoController = TextEditingController();
  String? _appliedPromoCode;
  double _promoDiscount = 0.0;
  bool _isValidatingPromo = false;
  Timer? _riderRefreshTimer;
  final supabase = Supabase.instance.client;

  // =====================================================
  // CONTROLLERS
  // =====================================================

  final pickupController =
      TextEditingController();

  final destinationController =
      TextEditingController();

  final pickupFocus =
      FocusNode();

  final destinationFocus =
      FocusNode();

  // =====================================================
  // MAP PICKER STATE
  // =====================================================

  String? _draggedAddress;
  String? _draggedCity;
  double? _draggedLat;
  double? _draggedLng;
  bool _isGeocoding = false;
  bool _isProgrammaticMove = false;
  Timer? _debounceGeocode;

  // =====================================================
  // WEBVIEW
  // =====================================================

  WebViewController? webController;

  bool mapLoaded = false;

  bool injectingMap = false;

  // =====================================================
  // LOCATION
  // =====================================================

  double? pickupLat;

  double? pickupLng;

  String? pickupCity;

  double? destinationLat;

  double? destinationLng;

  String? destinationCity;

  // =====================================================
  // ROUTE
  // =====================================================

  double distanceMeters = 0;

  double durationSeconds = 0;

  List<Map<String, dynamic>>
      routePoints = [];

  bool loadingRoute = false;

  // =====================================================
  // SEARCH
  // =====================================================

  Timer? pickupDebounce;

  Timer? destinationDebounce;

  List<dynamic> pickupResults =
      [];

  List<dynamic>
      destinationResults = [];

  bool loadingPickupSearch =
      false;

  bool loadingDestinationSearch =
      false;

  // =====================================================
  // UI
  // =====================================================

  bool openingPreview = false;
  bool _autoNavigated = false;
  bool loadingPickupGeocode = false;

  bool loadingDestinationGeocode = false;

  String? _activeField;

  bool _pickupWasPrefilled = false;
  bool _destinationWasPrefilled = false;
  late final DateTime _screenOpenTime;

  // =====================================================
  // HELPERS
  // =====================================================

  Color get primaryColor => const Color(0xFF10B981);

  String get title {
    if (widget.orderType == 'local_parcel') return 'Local Parcel Route';
    if (widget.orderType == 'intercity_parcel') return 'Intercity Parcel Route';
    if (widget.orderType == 'intercity') return 'Intercity Route';
    return 'Choose Route';
  }

  // =====================================================
  // INIT
  // =====================================================

  @override
  void initState() {
    super.initState();
    pricingController = PricingController();
    _screenOpenTime = DateTime.now();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    )..repeat();
    _initialize();
  }

  Future<void> _initialize()
      async {
    pickupFocus.addListener(_onFocusChange);
    destinationFocus.addListener(_onFocusChange);
    pickupController.addListener(_onPickupTextChanged);
    destinationController.addListener(_onDestinationTextChanged);

    if (widget.prefillPickupAddress != null) {
      pickupController.text = widget.prefillPickupAddress!;
      pickupLat = widget.prefillPickupLat;
      pickupLng = widget.prefillPickupLng;
      _pickupWasPrefilled = true;
    }
    if (widget.prefillDestinationAddress != null) {
      destinationController.text = widget.prefillDestinationAddress!;
      destinationLat = widget.prefillDestinationLat;
      destinationLng = widget.prefillDestinationLng;
      _destinationWasPrefilled = true;
    }

    // [PERF POC #2] Defer heavy cold-start work (WebView creation + 748KB map
    // load + GPS/location chain + focus handoff) until after the first frame
    // so the route transition is not blocked on first open. Same calls, same
    // order, same error handling -- only the scheduling moved. The screen's
    // existing loading fallback renders until the map is ready.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _initWebView();
      if (!mounted) return;
      await _loadCurrentLocation();
      if (!mounted) return;

      if (pickupLat != null && pickupLng != null && (destinationLat == null || destinationLng == null)) {
        setState(() {
          _activeField = 'destination';
        });
        destinationFocus.requestFocus();
      }
    });
  }

  void _onFocusChange() {
    final within500ms = DateTime.now().difference(_screenOpenTime).inMilliseconds < 500;

    if (pickupFocus.hasFocus) {
      if (_activeField != 'pickup') {
        setState(() {
          _activeField = 'pickup';
          _draggedAddress = null;
          _draggedCity = null;
          _draggedLat = null;
          _draggedLng = null;
        });
      }
      
      if (_pickupWasPrefilled || within500ms) {
        if (pickupController.text.isNotEmpty) {
          pickupController.selection = TextSelection(
            baseOffset: 0,
            extentOffset: pickupController.text.length,
          );
        }
        _pickupWasPrefilled = false;
      }
    } else if (destinationFocus.hasFocus) {
      if (_activeField != 'destination') {
        setState(() {
          _activeField = 'destination';
          _draggedAddress = null;
          _draggedCity = null;
          _draggedLat = null;
          _draggedLng = null;
        });
      }

      if (_destinationWasPrefilled || within500ms) {
        if (destinationController.text.isNotEmpty) {
          destinationController.selection = TextSelection(
            baseOffset: 0,
            extentOffset: destinationController.text.length,
          );
        }
        _destinationWasPrefilled = false;
      }
    }
  }

  void _onPickupTextChanged() {
    if (pickupController.text.trim().isEmpty) {
      if (pickupLat != null || pickupLng != null) {
        setState(() {
          pickupLat = null;
          pickupLng = null;
          pickupResults = [];
        });
        _updateMarkers();
        _calculateRoute();
      }
    }
  }

  void _onDestinationTextChanged() {
    if (destinationController.text.trim().isEmpty) {
      if (destinationLat != null || destinationLng != null) {
        setState(() {
          destinationLat = null;
          destinationLng = null;
          destinationResults = [];
        });
        _updateMarkers();
        _calculateRoute();
      }
    }
  }

  // =====================================================
  // DISPOSE
  // =====================================================

  @override
  void dispose() {
    _pulseController.dispose();

    pickupFocus.removeListener(_onFocusChange);
    destinationFocus.removeListener(_onFocusChange);
    pickupController.removeListener(_onPickupTextChanged);
    destinationController.removeListener(_onDestinationTextChanged);

    pickupController.dispose();

    destinationController.dispose();

    pickupFocus.dispose();

    destinationFocus.dispose();

    pickupDebounce?.cancel();

    destinationDebounce?.cancel();

    _debounceGeocode?.cancel();

    _riderRefreshTimer?.cancel();
    _promoController.dispose();

    // Phase 2F-B -- explicit WebView teardown, mirroring the Phase 2A rider active-order screen.
    // This screen's webController loads ola_map_location_picker.html (which pulls in
    // ola_map_core.js, so destroyMap / destroyNearbyRidersEngine are defined). That page already
    // tears the map down on the document 'unload' event, but 'unload' does not reliably fire when
    // Flutter disposes the platform WebView without a navigation -- leaking the MapLibre GL
    // context and, if any nearby riders were plotted, the AnimationManager RAF loop. All helpers
    // are `typeof`-guarded and idempotent; the call is wrapped in try/catch on the JS side and
    // .catchError on the Dart side, and is fire-and-forget because dispose() cannot await. Skipped
    // on the mock/desktop map path (there is no WebView).
    if (!_useMockMap) {
      final controller = webController;
      if (controller != null) {
        controller
            .runJavaScript(
              'try { '
              'if (typeof destroyNearbyRidersEngine === "function") { destroyNearbyRidersEngine(); } '
              'if (typeof destroyTrackingEngine === "function") { destroyTrackingEngine(); } '
              'if (typeof destroyMap === "function") { destroyMap(); } '
              '} catch (e) {}',
            )
            .catchError((_) {});
      }
    }

    super.dispose();
  }

  // =====================================================
  // WEBVIEW
  // =====================================================

  bool get _useMockMap {
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  void _initWebView() {
    if (_useMockMap) {
      setState(() => mapLoaded = true);
      return;
    }
    try {
      webController = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
        ..addJavaScriptChannel(
          'Flutter',
          onMessageReceived: (message) {
            try {
              final data = jsonDecode(message.message);
              if (data['type'] == 'camera_move_start') {
                if (mounted) {
                  FocusScope.of(context).unfocus();
                }
              } else if (data['type'] == 'camera_move_end') {
                final lat = double.tryParse(data['lat']?.toString() ?? '');
                final lng = double.tryParse(data['lng']?.toString() ?? '');
                if (lat != null && lng != null) {
                  _onCameraMoveEnd(lat, lng);
                }
              }
            } catch (e) {
              debugPrint('MAP WEBVIEW MESSAGE ERROR => $e');
            }
          },
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (url) async {
              setState(() => mapLoaded = true);
              await _injectMap();
              await _updateMarkers();
              await _calculateRoute();
            },
          ),
        )
        ..loadFlutterAsset('assets/map/ola_map_location_picker.html');
    } catch (e) {
      debugPrint('Failed to initialize WebView: $e');
      setState(() => mapLoaded = true);
    }
  }

  Future<void> _injectMap() async {
    if (webController == null) return;
    final apiKey = OlaMapService.apiKey;
    final safeApiKey = apiKey.replaceAll('"', '');
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeMode = isDark ? 'dark' : 'light';
    final js = '''
      if(window.initializeMap){
        window.initializeMap(
          "$safeApiKey",
          "$themeMode"
        );
      }
    ''';
    await webController!.runJavaScript(js);
  }

  // =====================================================
  // CURRENT LOCATION
  // =====================================================

  Future<void>
      _loadCurrentLocation()
      async {
    if (widget.prefillPickupAddress != null) {
      _isProgrammaticMove = true;
      await _updateMarkers();
      return;
    }

    try {

      await LocationCacheService
          .initializeLocation();

      final lat =
          LocationCacheService
              .currentLat;

      final lng =
          LocationCacheService
              .currentLng;

      if (
        lat == null ||
        lng == null
      ) {
        pickupController.text = '';
        return;
      }

      pickupLat = lat;

      pickupLng = lng;

      final cachedAddress = LocationCacheService.cachedAddress;

      pickupCity = LocationCacheService.cachedCity ?? '';

      if (cachedAddress != null &&
          cachedAddress.trim().isNotEmpty &&
          cachedAddress != 'Selected Location' &&
          cachedAddress != 'Fetching location...') {
        pickupController.text = cachedAddress;
        _pickupWasPrefilled = true;
      } else {
        pickupController.text = '';
      }

      _isProgrammaticMove = true;

      await _updateMarkers();

    } catch (e) {

      debugPrint(
        'CURRENT LOCATION ERROR => $e',
      );
    }
  }

  Future<void> _useCurrentLocationForActiveField() async {
    final hasPermission = await LocationPermissionHelper.checkAndRequestLocation(
      context,
      primaryColor: primaryColor,
    );
    if (!hasPermission) return;

    try {
      final isDestination = _activeField == 'destination';
      
      setState(() {
        if (isDestination) {
          loadingDestinationGeocode = true;
        } else {
          loadingPickupGeocode = true;
        }
      });

      await LocationCacheService.initializeLocation();
      final lat = LocationCacheService.currentLat;
      final lng = LocationCacheService.currentLng;
      
      if (lat == null || lng == null) {
        _show('Could not fetch GPS coordinates. Please enable GPS.');
        return;
      }

      final address = LocationCacheService.currentAddress;
      final city = LocationCacheService.currentCity;
      
      _isProgrammaticMove = true;
      
      setState(() {
        if (isDestination) {
          destinationLat = lat;
          destinationLng = lng;
          destinationController.text = (address == 'Selected Location' || address == 'Fetching location...') ? 'Current Location' : address;
          destinationCity = city;
          destinationResults = [];
        } else {
          pickupLat = lat;
          pickupLng = lng;
          pickupController.text = (address == 'Selected Location' || address == 'Fetching location...') ? 'Current Location' : address;
          pickupCity = city;
          pickupResults = [];
        }
      });

      await _updateMarkers();
      await _calculateRoute();

      if (!mounted) return;
      if (isDestination) {
        if (pickupLat == null || pickupLng == null) {
          FocusScope.of(context).requestFocus(pickupFocus);
        } else {
          FocusScope.of(context).unfocus();
        }
      } else {
        if (destinationLat == null || destinationLng == null) {
          FocusScope.of(context).requestFocus(destinationFocus);
        } else {
          FocusScope.of(context).unfocus();
        }
      }

    } catch (e) {
      _show('Error fetching current location.');
    } finally {
      setState(() {
        loadingPickupGeocode = false;
        loadingDestinationGeocode = false;
      });
    }
  }

  Future<void> _recenterToCurrentLocation() async {
    final hasPermission = await LocationPermissionHelper.checkAndRequestLocation(
      context,
      primaryColor: primaryColor,
    );
    if (!hasPermission) return;

    try {
      await LocationCacheService.initializeLocation();
      final lat = LocationCacheService.currentLat;
      final lng = LocationCacheService.currentLng;

      if (lat == null || lng == null) {
        _show('Could not fetch GPS coordinates. Please enable GPS.');
        return;
      }

      _isProgrammaticMove = true;
      if (webController != null) {
        await webController!.runJavaScript('if(window.recenterMap) { window.recenterMap($lat, $lng); }');
      }

      setState(() {
        _draggedLat = lat;
        _draggedLng = lng;
        _isGeocoding = true;
      });

      final result = await OlaMapService.reverseGeocode(
        latitude: lat,
        longitude: lng,
      );
      if (!mounted) return;

      setState(() {
        _draggedAddress = result['address'];
        _draggedCity = result['city'];
        _isGeocoding = false;
      });
    } catch (e) {
      debugPrint('RECENTER TO CURRENT LOCATION ERROR => $e');
    }
  }

  // =====================================================
  // SEARCH
  // =====================================================

  Future<void>
      searchPickup(
    String value,
  ) async {

    pickupDebounce?.cancel();

    if (
      value.trim().isEmpty
    ) {

      setState(() {

        pickupResults = [];
      });

      return;
    }

    pickupDebounce = Timer(

      const Duration(
        milliseconds: 400,
      ),

      () async {

        setState(() {

          loadingPickupSearch =
              true;
        });

        final results =

            await OlaMapService
                .autocomplete(
          value,
        );

        if (!mounted) return;

        setState(() {

          pickupResults = results;

          loadingPickupSearch =
              false;
        });
      },
    );
  }

  Future<void>
      searchDestination(
    String value,
  ) async {

    destinationDebounce
        ?.cancel();

    if (
      value.trim().isEmpty
    ) {

      setState(() {

        destinationResults = [];
      });

      return;
    }

    destinationDebounce = Timer(

      const Duration(
        milliseconds: 400,
      ),

      () async {

        setState(() {

          loadingDestinationSearch =
              true;
        });

        final results =

            await OlaMapService
                .autocomplete(
          value,
        );

        if (!mounted) return;

        setState(() {

          destinationResults =
              results;

          loadingDestinationSearch =
              false;
        });
      },
    );
  }

  // =====================================================
  // SELECT PICKUP
  // =====================================================

  Future<void>
      selectPickup(
    dynamic item,
  ) async {

    final description =

        item['description']
            ?.toString()

        ??

        '';

    pickupController.text =
        description;

    pickupResults = [];

    setState(() {
      loadingPickupGeocode = true;
    });

    try {
      final String? placeId = item['place_id']?.toString();
      Map<String, dynamic>? coords;
      if (placeId != null && placeId.isNotEmpty) {
        coords = await OlaMapService.getCoordinatesFromPlaceId(placeId);
      }
      if (coords == null) {
        coords = await OlaMapService.getCoordinatesFromAddress(description);
      }

      if (
        coords == null
      ) {

        return;
      }

      _isProgrammaticMove = true;

      pickupLat =
          coords['latitude'];

      pickupLng =
          coords['longitude'];

      pickupCity = coords['city'] ?? '';

      setState(() {});

      await _updateMarkers();

      await _calculateRoute();
    } finally {
      if (mounted) {
        setState(() {
          loadingPickupGeocode = false;
        });
      }
    }

    if (!mounted) return;

    if (destinationLat == null || destinationLng == null) {
      FocusScope.of(context).requestFocus(destinationFocus);
    } else {
      FocusScope.of(context).unfocus();
    }
  }

  // =====================================================
  // SELECT DESTINATION
  // =====================================================

  Future<void>
      selectDestination(
    dynamic item,
  ) async {

    final description =

        item['description']
            ?.toString()

        ??

        '';

    destinationController.text =
        description;

    destinationResults = [];

    setState(() {
      loadingDestinationGeocode = true;
    });

    try {
      final String? placeId = item['place_id']?.toString();
      Map<String, dynamic>? coords;
      if (placeId != null && placeId.isNotEmpty) {
        coords = await OlaMapService.getCoordinatesFromPlaceId(placeId);
      }
      if (coords == null) {
        coords = await OlaMapService.getCoordinatesFromAddress(description);
      }

      if (
        coords == null
      ) {

        return;
      }

      _isProgrammaticMove = true;

      destinationLat =
          coords['latitude'];

      destinationLng =
          coords['longitude'];

      destinationCity = coords['city'] ?? '';

      setState(() {});

      await _updateMarkers();

      await _calculateRoute();
    } finally {
      if (mounted) {
        setState(() {
          loadingDestinationGeocode = false;
        });
      }
    }

    if (!mounted) return;

    // Unfocus or shift focus to pickup if empty
    if (pickupLat == null || pickupLng == null) {
      FocusScope.of(context).requestFocus(pickupFocus);
    } else {
      FocusScope.of(context).unfocus();
    }
  }

  // =====================================================
  // CLEAR ROUTE
  // =====================================================

  Future<void> _clearRoute() async {
    if (webController == null) return;
    try {
      await webController!.runJavaScript('''
        if(window.clearRoute){
          window.clearRoute();
        }
      ''');
    } catch (_) {}
  }

  // =====================================================
  // MAP PICKER HELPERS
  // =====================================================

  Future<void> _onCameraMoveEnd(double lat, double lng) async {
    if (_isProgrammaticMove) {
      _isProgrammaticMove = false;
      return;
    }

    final activeLat = _activeField == 'pickup' ? pickupLat : destinationLat;
    final activeLng = _activeField == 'pickup' ? pickupLng : destinationLng;
    if (_isClose(lat, lng, activeLat, activeLng)) {
      return;
    }

    _debounceGeocode?.cancel();
    _debounceGeocode = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted) return;
      setState(() {
        _isGeocoding = true;
        _draggedLat = lat;
        _draggedLng = lng;
      });

      try {
        final result = await OlaMapService.reverseGeocode(
          latitude: lat,
          longitude: lng,
        );
        if (!mounted) return;
        setState(() {
          _draggedAddress = result['formatted_address']?.toString();
          _draggedCity = result['city']?.toString();
          _isGeocoding = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _isGeocoding = false;
        });
      }
    });
  }

  bool _isClose(double lat1, double lng1, double? lat2, double? lng2) {
    if (lat2 == null || lng2 == null) return false;
    return (lat1 - lat2).abs() < 0.0005 && (lng1 - lng2).abs() < 0.0005;
  }

  void _confirmPickerLocation() {
    if (_draggedLat == null || _draggedLng == null) return;

    final address = (_draggedAddress == null || _draggedAddress == 'Selected Location')
        ? 'Pinned Location'
        : _draggedAddress!;
    final city = _draggedCity ?? '';

    setState(() {
      _isProgrammaticMove = true;
      if (_activeField == 'pickup') {
        pickupLat = _draggedLat;
        pickupLng = _draggedLng;
        pickupController.text = address;
        pickupCity = city;
        pickupResults = [];
        
        if (destinationLat == null || destinationLng == null) {
          FocusScope.of(context).requestFocus(destinationFocus);
        } else {
          FocusScope.of(context).unfocus();
          _activeField = null;
        }
      } else {
        destinationLat = _draggedLat;
        destinationLng = _draggedLng;
        destinationController.text = address;
        destinationCity = city;
        destinationResults = [];

        if (pickupLat == null || pickupLng == null) {
          FocusScope.of(context).requestFocus(pickupFocus);
        } else {
          FocusScope.of(context).unfocus();
          _activeField = null;
        }
      }
      _draggedAddress = null;
      _draggedLat = null;
      _draggedLng = null;
    });

    _updateMarkers();
    _calculateRoute();
  }

  // =====================================================
  // UPDATE MARKERS
  // =====================================================

  Future<void> _updateMarkers() async {
    if (webController == null) return;
    try {
      await webController!.runJavaScript('''
        if(window.clearMarkers){
          window.clearMarkers();
        }
      ''');

      if (pickupLat != null && pickupLng != null) {
        await webController!.runJavaScript('''
          if(window.addPickupMarker){
            window.addPickupMarker(
              $pickupLat,
              $pickupLng,
              15
            );
          }
        ''');
      }

      if (destinationLat != null && destinationLng != null) {
        await webController!.runJavaScript('''
          if(window.addDestinationMarker){
            window.addDestinationMarker(
              $destinationLat,
              $destinationLng,
              15
            );
          }
        ''');
      }
    } catch (_) {}
  }

  // =====================================================
  // ROUTE
  // =====================================================

  Future<void>
      _calculateRoute()
      async {

    if (

      pickupLat == null

      ||

      pickupLng == null

      ||

      destinationLat == null

      ||

      destinationLng == null

    ) {

      await _clearRoute();

      return;
    }

    try {

      setState(() {

        loadingRoute = true;
      });

      final route =

          await OlaMapService
              .getDirections(

        originLat:
            pickupLat!,

        originLng:
            pickupLng!,

        destinationLat:
            destinationLat!,

        destinationLng:
            destinationLng!,
      );

      if (
        route == null
      ) {

        return;
      }

      distanceMeters =
          route.distanceMeters;

      durationSeconds =
          route.durationSeconds;

      routePoints =
          route.polylinePoints;

      final polylineJson =
          jsonEncode(
        routePoints,
      );

      if (webController != null) {
        await webController!.runJavaScript('''
          if(window.drawRoute){
            window.drawRoute(
              $polylineJson
            );
          }
        ''');

        final String paddingJson = _showBookingOptions 
            ? '{"top": 120, "bottom": 240, "left": 50, "right": 50}' 
            : '{"top": 180, "bottom": 180, "left": 50, "right": 50}';

        await webController!.runJavaScript('''
          if(window.fitRouteBounds){
            window.fitRouteBounds($paddingJson);
          }
        ''');
      }

      if (mounted) {
        setState(() {});
        if (distanceMeters > 0 && !_autoNavigated) {
          _autoNavigated = true;
          // Route through continueFlow() unconditionally so local rides also pass through
          // its serviceability gate (ServiceabilityService.isLocationServiceable) instead of
          // jumping straight to _onRouteCalculated() and skipping it — continueFlow() itself
          // calls _onRouteCalculated() for the local-ride case once the gate passes.
          continueFlow();
        }
      }

    } catch (e) {

      debugPrint(
        'ROUTE ERROR => $e',
      );

    } finally {

      if (mounted) {

        setState(() {

          loadingRoute = false;
        });
      }
    }
  }

  // =====================================================
  // CONTINUE
  // =====================================================

  Future<void>
      continueFlow()
      async {

    if (

      pickupLat == null

      ||

      pickupLng == null

    ) {

      _show(
        'Select pickup location',
      );

      return;
    }

    final String pickupAddress = pickupController.text;
    final bool isLocal = widget.orderType == 'ride' || widget.orderType == 'local_parcel';
    if (isLocal) {
      final sResult = await ServiceabilityService.isLocationServiceable(
        address: pickupAddress,
        latitude: pickupLat,
        longitude: pickupLng,
        city: pickupCity,
      );
      if (!sResult.isServiceable) {
        Navigator.popUntil(context, (route) => route.isFirst);
        return;
      }
    }

    if (

      destinationLat == null

      ||

      destinationLng == null

    ) {

      _show(
        'Select destination location',
      );

      return;
    }

    if (pickupLat == destinationLat && pickupLng == destinationLng) {
      _show('Pickup and destination cannot be the same location.');
      return;
    }

    if (pickupController.text.trim().toLowerCase() == destinationController.text.trim().toLowerCase()) {
      _show('Pickup and destination cannot be the same address.');
      return;
    }

    final double distance = Geolocator.distanceBetween(
      pickupLat!,
      pickupLng!,
      destinationLat!,
      destinationLng!,
    );

    if (distance < 100.0) {
      _show('Pickup and destination must be at least 100 meters apart.');
      return;
    }

    try {

      setState(() {

        openingPreview = true;
      });

      if (widget.orderType.contains('parcel')) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ParcelDetailsScreen(
              orderType: widget.orderType,
              pickupAddress: pickupController.text,
              destinationAddress: destinationController.text,
              pickupLat: pickupLat!,
              pickupLng: pickupLng!,
              destinationLat: destinationLat!,
              destinationLng: destinationLng!,
              totalDistanceMeters: distanceMeters,
              durationSeconds: durationSeconds,
              routePoints: routePoints,
              pickupCity: pickupCity,
              destinationCity: destinationCity,
            ),
          ),
        );
      } else {
        final bool isIntercity = widget.orderType == 'intercity_ride' || distanceMeters > 20000;
        if (isIntercity) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => IntercityRideBookingScreen(
                pickupAddress: pickupController.text,
                destinationAddress: destinationController.text,
                pickupLat: pickupLat!,
                pickupLng: pickupLng!,
                destinationLat: destinationLat!,
                destinationLng: destinationLng!,
                totalDistanceMeters: distanceMeters,
                durationSeconds: durationSeconds,
                routePoints: routePoints,
                pickupCity: pickupCity,
                destinationCity: destinationCity,
              ),
            ),
          );
        } else {
          _onRouteCalculated();
        }
      }

    } finally {

      if (mounted) {
        setState(() {
          openingPreview = false;
          _autoNavigated = false;
        });
      }
    }
  }

  // =====================================================
  // MESSAGE
  // =====================================================

  void _show(
    String text,
  ) {

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(

      SnackBar(
        content: Text(text),
      ),
    );
  }

  // =====================================================
  // SEARCH RESULTS
  // =====================================================

  Widget buildSearchResults({
    required List<dynamic> results,
    required Function(dynamic) onTap,
  }) {
    if (results.isEmpty) {
      return const SizedBox();
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final textCol = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextCol = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    final containerBg = isDark ? const Color(0xFF0F172A) : Colors.white;
    final borderCol = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);

    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      decoration: BoxDecoration(
        color: containerBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderCol, width: 1.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: ListView.separated(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const BouncingScrollPhysics(),
          itemCount: results.length,
          separatorBuilder: (_, index) => Divider(
            height: 1,
            indent: 52,
            endIndent: 16,
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
          ),
          itemBuilder: (context, index) {
            final item = results[index];
            final description = item['description']?.toString() ?? '';
            
            final firstComma = description.indexOf(',');
            final String mainText;
            final String secondaryText;
            if (firstComma != -1) {
              mainText = description.substring(0, firstComma).trim();
              secondaryText = description.substring(firstComma + 1).trim();
            } else {
              mainText = description;
              secondaryText = '';
            }

            final cityName = OlaMapService.getCityFromDescription(mainText, secondaryText);

            return Material(
              color: Colors.transparent,
              child: ListTile(
                onTap: () {
                  FocusScope.of(context).unfocus();
                  onTap(item);
                },
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                leading: Container(
                  height: 36,
                  width: 36,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.location_on_rounded,
                    color: isDark ? Colors.white70 : const Color(0xFF64748B),
                    size: 18,
                  ),
                ),
                title: Text(
                  mainText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: textCol,
                    letterSpacing: -0.2,
                  ),
                ),
                subtitle: secondaryText.isNotEmpty
                    ? Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          secondaryText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: subTextCol,
                          ),
                        ),
                      )
                    : null,
                trailing: cityName.isNotEmpty
                    ? Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                            width: 1.0,
                          ),
                        ),
                        child: Text(
                          cityName,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                          ),
                        ),
                      )
                    : null,
              ),
            );
          },
        ),
      ),
    );
  }

  // =====================================================
  // INPUT
  // =====================================================

  Widget buildInput({
    required bool isPickup,
    required TextEditingController controller,
    required FocusNode focusNode,
    required Function(String) onChanged,
    required bool loading,
    required bool isGeocoding,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isPickup ? const Color(0xFF10B981) : const Color(0xFFEF4444);
    
    final textCol = isDark ? Colors.white : const Color(0xFF0F172A);
    final hintCol = isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);
    final borderCol = isDark 
        ? Colors.white.withValues(alpha: 0.08) 
        : const Color(0xFFE2E8F0);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : Colors.white,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: focusNode.hasFocus ? primaryColor : borderCol,
          width: focusNode.hasFocus ? 1.5 : 1.0,
        ),
        boxShadow: [
          // Soft ambient shadow
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        cursorColor: primaryColor,
        cursorWidth: 2.2,
        cursorRadius: const Radius.circular(1),
        textAlignVertical: TextAlignVertical.center,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: textCol,
          letterSpacing: -0.2,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
          hintText: isPickup 
              ? 'Enter pickup location...' 
              : (widget.orderType.contains('parcel') ? 'Enter delivery location...' : 'Where do you want to go?'),
          hintStyle: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: hintCol,
            letterSpacing: -0.2,
          ),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 20, right: 12),
            child: Icon(
              Icons.search_rounded,
              color: isDark ? Colors.white70 : const Color(0xFF0F172A),
              size: 22,
            ),
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 54,
          ),
          suffixIcon: (loading || isGeocoding)
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                    ),
                  ),
                )
              : controller.text.isEmpty
                  ? const SizedBox(width: 48, height: 48)
                  : IconButton(
                      onPressed: () {
                        controller.clear();
                        if (isPickup) {
                          pickupResults = [];
                          pickupLat = null;
                          pickupLng = null;
                        } else {
                          destinationResults = [];
                          destinationLat = null;
                          destinationLng = null;
                        }
                        _clearRoute();
                        setState(() {});
                      },
                      icon: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: hintCol,
                      ),
                    ),
        ),
      ),
    );
  }

  // =====================================================
  // BOOKING CORE METHODS
  // =====================================================

  // P2 fix (adaptive nearby-rider polling): reuses the exact same 5s->10s->20s elapsed-time bands
  // already proven for this identical "nearby riders map display" concept in
  // ride_searching_screen.dart/intercity_searching_screen.dart/parcel_searching_screen.dart -- not
  // a new threshold. The base 5s timer tick is unchanged, it now just re-evaluates whether a fetch
  // is actually due (by time spent on this screen) before calling _fetchNearbyRiders().
  DateTime? _riderTimerStartedAt;
  DateTime? _lastRiderFetchAt;

  Duration _riderRefreshInterval(Duration elapsed) {
    if (elapsed < const Duration(seconds: 60)) return const Duration(seconds: 5);
    if (elapsed < const Duration(seconds: 180)) return const Duration(seconds: 10);
    return const Duration(seconds: 20);
  }

  void _startRiderRefreshTimer() {
    _riderRefreshTimer?.cancel();
    _riderTimerStartedAt ??= DateTime.now();
    _riderRefreshTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      final now = DateTime.now();
      final interval = _riderRefreshInterval(now.difference(_riderTimerStartedAt!));
      if (_lastRiderFetchAt != null && now.difference(_lastRiderFetchAt!) < interval) {
        return;
      }
      _lastRiderFetchAt = now;
      _fetchNearbyRiders();
    });
  }

  Future<void> _fetchNearbyRiders() async {
    if (pickupLat == null || pickupLng == null) return;
    try {
      // CLIENT-3 (WayDrop Progressive Degradation Audit): this used to fetch every online rider
      // platform-wide every 5 seconds and filter to the 5km radius client-side in Dart. The
      // radius check below (haversine, unchanged) is the actual eligibility rule; this bounding
      // box is a strict superset of that same circle, so the returned rider set is identical --
      // it only lets Postgres discard far-away rows before they're sent over the network instead
      // of transferring the whole online-rider table on every poll tick.
      const double radiusKm = 5.0;
      const double kmPerDegreeLat = 111.32;
      final double latDelta = radiusKm / kmPerDegreeLat;
      final double lngDegreeKm =
          kmPerDegreeLat * cos(pickupLat! * (pi / 180)).abs();
      final double lngDelta =
          radiusKm / (lngDegreeKm < 0.000001 ? 0.000001 : lngDegreeKm);

      final response = await supabase
          .from('riders')
          .select(
            'id, current_lat, current_lng, current_heading, '
            'rider_kyc!riders_kyc_id_fkey(vehicle_type)',
          )
          .eq('account_status', 'online')
          .not('current_lat', 'is', null)
          .not('current_lng', 'is', null)
          .gte('current_lat', pickupLat! - latDelta)
          .lte('current_lat', pickupLat! + latDelta)
          .gte('current_lng', pickupLng! - lngDelta)
          .lte('current_lng', pickupLng! + lngDelta);

      final List<Map<String, dynamic>> riders =
          (response as List).map<Map<String, dynamic>>((r) {
        final map = Map<String, dynamic>.from(r as Map);
        final kyc = map['rider_kyc!riders_kyc_id_fkey'] ?? map['rider_kyc'];
        String vehicleType = 'bike';
        if (kyc is Map) {
          vehicleType = kyc['vehicle_type']?.toString().toLowerCase().trim() ?? 'bike';
        } else if (kyc is List && kyc.isNotEmpty && kyc[0] is Map) {
          vehicleType = kyc[0]['vehicle_type']?.toString().toLowerCase().trim() ?? 'bike';
        }
        if (vehicleType == 'car') {
          vehicleType = 'cab';
        }
        map['vehicle_type'] = vehicleType;
        map.remove('rider_kyc!riders_kyc_id_fkey');
        map.remove('rider_kyc');
        return map;
      }).where((rider) {
        final double? lat = double.tryParse(rider['current_lat']?.toString() ?? '');
        final double? lng = double.tryParse(rider['current_lng']?.toString() ?? '');
        if (lat == null || lng == null) return false;

        const p = 0.017453292519943295; // Math.PI / 180
        final a = 0.5 - cos((lat - pickupLat!) * p) / 2 +
            cos(pickupLat! * p) * cos(lat * p) *
            (1 - cos((lng - pickupLng!) * p)) / 2;
        final distanceKmObj = 12742 * asin(sqrt(a));
        return distanceKmObj <= 5.0;
      }).toList();

      if (mounted) {
        setState(() => nearbyRiders = riders);
      }
      await _updateRidersOnMap(filterType: selectedVehicle);
    } catch (e) {
      debugPrint('FETCH NEARBY RIDERS ERROR => $e');
    }
  }

  Future<void> _updateRidersOnMap({String? filterType}) async {
    if (!mapLoaded || webController == null) return;
    try {
      final ridersJson = jsonEncode(nearbyRiders);
      final filterArg = filterType != null ? '"$filterType"' : 'null';
      await webController!.runJavaScript(
        'if(window.showNearbyRiders){ window.showNearbyRiders($ridersJson, $filterArg); }',
      );
    } catch (e) {
      debugPrint('UPDATE RIDERS ON MAP ERROR => $e');
    }
  }

  Future<void> _fetchPricing() async {
    final double distanceKmObj = distanceMeters / 1000;
    await pricingController.fetchMultiplePricing(
      orderType: 'ride',
      distanceKm: distanceKmObj,
      pickupAddress: pickupController.text,
      maxBoostAmount: selectedBoostAmount,
      pickupLat: pickupLat!,
      pickupLng: pickupLng!,
    );

    if (selectedVehicle == null) {
      if (pricingController.pricingData.containsKey('bike')) {
        selectedVehicle = 'bike';
      } else if (pricingController.pricingData.containsKey('auto')) {
        selectedVehicle = 'auto';
      } else if (pricingController.pricingData.containsKey('cab')) {
        selectedVehicle = 'cab';
      }
    }
    if (mounted) {
      setState(() {});
      _updateRidersOnMap(filterType: selectedVehicle);
    }
  }

  Future<void> _applyPromo() async {
    final code = _promoController.text.trim();
    if (code.isEmpty) return;
    if (selectedVehicle == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a vehicle first.')),
      );
      return;
    }

    setState(() {
      _isValidatingPromo = true;
    });

    try {
      final pricingData = pricingController.pricingData;
      final currentFare = double.tryParse(pricingData[selectedVehicle]?['final_fare']?.toString() ?? '') ?? 0.0;
      final user = supabase.auth.currentUser;

      if (user == null) {
        throw Exception("User session not found");
      }

      final response = await supabase.rpc(
        'validate_and_calculate_promo',
        params: {
          'p_code': code,
          'p_order_value': currentFare,
          'p_user_id': user.id,
        },
      );

      if (response == null) {
        throw Exception("Failed to validate promo code");
      }

      final Map<String, dynamic> result = Map<String, dynamic>.from(response as Map);

      if (result['success'] == true) {
        setState(() {
          _appliedPromoCode = code.toUpperCase();
          _promoDiscount = (result['discount_amount'] ?? 0.0).toDouble();
          showPromoField = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Promo code "$_appliedPromoCode" applied! Discount: ₹${_promoDiscount.toStringAsFixed(2)}'),
              backgroundColor: const Color(0xFF10B981),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else {
        throw Exception(result['message'] ?? "Invalid promo code");
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll("Exception: ", "")),
            backgroundColor: const Color(0xFFEF4444),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isValidatingPromo = false;
        });
      }
    }
  }

  String extractCity(String? city, String address) {
    return LocationDisplayService.resolveCity(
      city: city,
      address: address,
      fallback: 'Other',
    );
  }

  Future<void> _submitOrderToBackend({String? paymentId, required String idempotencyKey}) async {
    final deviceMeta = await DeviceInfoHelper.getDeviceMetadata();
    final user = supabase.auth.currentUser;
    final double distanceKmObj = distanceMeters / 1000;

    final response = await supabase.functions.invoke(
      'create-order',
      body: {
        'user_id': user?.id,
        'order_type': 'ride',
        'vehicle_type': selectedVehicle,
        'pickup_address': pickupController.text,
        'pickup_lat': pickupLat,
        'pickup_lng': pickupLng,
        'destination_address': destinationController.text,
        'destination_lat': destinationLat,
        'destination_lng': destinationLng,
        'distance_km': distanceKmObj,
        'distance_meters': distanceMeters.round(),
        'duration_seconds': durationSeconds.round(),
        'payment_mode': paymentMode,
        'payment_id': paymentId,
        'pickup_city': extractCity(pickupCity, pickupController.text),
        'destination_city': extractCity(destinationCity, destinationController.text),
        'max_boost_amount': selectedBoostAmount,
        'promo_code': _appliedPromoCode,
        // Device snapshot
        'created_device_id': deviceMeta['device_id'],
        'device_model': deviceMeta['device_model'],
        'device_brand': deviceMeta['device_brand'],
        'os_version': deviceMeta['os_version'],
        'app_version': deviceMeta['app_version'],
        // P1 fix (create-order idempotency): identifies this specific tap of "Book" so a client
        // timeout + reconciliation retry (see _createOrder below) can never create a second
        // order for it -- create-order treats a repeat of the same key for the same user as a
        // no-op that returns the already-created order instead of inserting again.
        'idempotency_key': idempotencyKey,
      },
      // CLIENT-1 (WayDrop Progressive Degradation Audit): bounded so a stalled backend can never
      // hang this screen forever — surfaces as the same caught exception _createOrder already
      // handles (SnackBar + resetting creatingOrder), instead of an infinite "creating order" state.
    ).timeout(const Duration(seconds: 30));

    debugPrint('CREATE ORDER RESPONSE => ${response.data}');

    if (response.data == null || response.data['success'] != true) {
      final errorMsg = response.data?['error'] ?? 'Unknown error occurred while creating order';
      throw Exception(errorMsg);
    }

    final order = response.data['order'];
    if (order == null || order['id'] == null) {
      throw Exception('Failed to retrieve order ID from response');
    }

    if (!mounted) return;

    _riderRefreshTimer?.cancel();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => RideSearchingScreen(orderId: order['id']),
      ),
    );
  }

  /// P1 fix (create-order idempotency + timeout reconciliation): one identifier per tap of
  /// "Book", not per screen session -- a later, deliberate re-tap after a genuine failure
  /// (invalid promo, network error) always starts a clean new booking attempt with its own
  /// fresh key, while a TimeoutException from THIS SAME tap (see _createOrder below) safely
  /// retries with the identical key. create-order's own idempotency check (same user_id +
  /// idempotency_key) makes that retry a no-op if the original, timed-out-on-the-client call
  /// already created the order server-side -- it returns that existing order instead of
  /// inserting a second one.
  String _generateBookingIdempotencyKey() {
    final rand = Random.secure();
    final now = DateTime.now().microsecondsSinceEpoch;
    final r1 = rand.nextInt(0xFFFFFFFF);
    final r2 = rand.nextInt(0xFFFFFFFF);
    return '$now-${r1.toRadixString(16)}-${r2.toRadixString(16)}';
  }

  Future<void> _createOrder() async {
    if (selectedVehicle == null) return;

    // Both 'cash' and 'upi' are collected directly by the driver at trip
    // completion — no payment gateway involved at booking time.
    final idempotencyKey = _generateBookingIdempotencyKey();
    try {
      setState(() => creatingOrder = true);
      try {
        await _submitOrderToBackend(idempotencyKey: idempotencyKey);
      } on TimeoutException {
        // P1 fix: the first attempt's outcome is ambiguous here (create-order may have
        // succeeded server-side after this client gave up waiting) -- retry once with the SAME
        // idempotency key instead of surfacing an error that would let the user tap "Book"
        // again and risk creating a genuine duplicate order. Unconditionally safe: create-order
        // treats this as a no-op returning the already-created order if the first call already
        // went through, and creates the order fresh otherwise.
        await _submitOrderToBackend(idempotencyKey: idempotencyKey);
      }
    } catch (e, stackTrace) {
      // Phase 5 F2: non-fatal Crashlytics report so a production order-creation failure spike is
      // visible without a user complaint -- purely additive, does not affect the existing
      // SnackBar/finally behavior below.
      FirebaseCrashlytics.instance.recordError(
        e,
        stackTrace,
        reason: 'create-order (ride) failed',
        information: ['idempotencyKey: $idempotencyKey'],
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) {
        setState(() {
          creatingOrder = false;
          waitingForPayment = false;
        });
      }
    }
  }

  void _selectVehicle(String vehicle) {
    setState(() {
      selectedVehicle = vehicle;
      _appliedPromoCode = null;
      _promoDiscount = 0.0;
      _promoController.clear();
    });
    _updateRidersOnMap(filterType: vehicle);
  }

  void _onRouteCalculated() {
    setState(() {
      _showBookingOptions = true;
      selectedVehicle = null;
      _appliedPromoCode = null;
      _promoDiscount = 0.0;
      _promoController.clear();
    });
    if (webController != null) {
      webController!.runJavaScript('''
        if(window.fitRouteBounds){
          window.fitRouteBounds({"top": 120, "bottom": 240, "left": 50, "right": 50});
        }
      ''');
    }
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted && _showBookingOptions) {
        _fetchPricing();
        _startRiderRefreshTimer();
        _fetchNearbyRiders();
      }
    });
  }

  void _onRouteCleared() {
    _riderRefreshTimer?.cancel();
    setState(() {
      _showBookingOptions = false;
      nearbyRiders = [];
    });
  }

  void _editLocations() {
    _onRouteCleared();
    setState(() {
      _autoNavigated = false;
      _activeField = 'destination';
    });
    FocusScope.of(context).requestFocus(destinationFocus);
    _updateMarkers();
    _calculateRoute();
  }

  // =====================================================
  // BOOKING WIDGET BUILDERS
  // =====================================================

  Widget _buildVehicleItem({
    required String vehicle,
    required String title,
    required double fare,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasDiscount = selected && _appliedPromoCode != null && _promoDiscount > 0;
    final displayFare = hasDiscount ? (fare - _promoDiscount).clamp(0.0, double.infinity) : fare;
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(right: 14.0),
        child: SizedBox(
          width: 76,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                height: 72,
                width: 72,
                decoration: BoxDecoration(
                  color: selected
                      ? (isDark ? const Color(0xFF10B981).withValues(alpha: 0.18) : const Color(0xFFECFDF5))
                      : (isDark ? const Color(0xFF1E222B) : Colors.white),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: selected
                        ? const Color(0xFF10B981)
                        : (isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
                    width: selected ? 2.0 : 1.0,
                  ),
                  boxShadow: selected
                      ? [BoxShadow(color: const Color(0xFF10B981).withValues(alpha: 0.2), blurRadius: 12, offset: const Offset(0, 4))]
                      : [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.04), blurRadius: 8, offset: const Offset(0, 2))],
                ),
                padding: const EdgeInsets.all(6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(
                    'assets/images/$vehicle.jpg',
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      final isBike = vehicle == 'bike';
                      final isAuto = vehicle == 'auto';
                      return Icon(
                        isBike ? Icons.directions_bike : isAuto ? Icons.electric_rickshaw : Icons.local_taxi,
                        color: selected ? const Color(0xFF10B981) : (isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8)),
                        size: 32,
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                title,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.bold : FontWeight.w600,
                  color: selected
                      ? (isDark ? Colors.white : const Color(0xFF0F172A))
                      : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                ),
              ),
              const SizedBox(height: 2),
              if (hasDiscount)
                Text(
                  // Whole-rupee: fare is calculate-order-pricing's already-rounded final_fare.
                  '\u20B9${fare.toStringAsFixed(0)}',
                  style: TextStyle(
                    fontSize: 10,
                    decoration: TextDecoration.lineThrough,
                    color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                  ),
                ),
              Text(
                '\u20B9${displayFare.toStringAsFixed(0)}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: selected
                      ? const Color(0xFF10B981)
                      : (isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155)),
                ),
              ),
              const SizedBox(height: 1),
              Text(
                'incl. GST',
                style: TextStyle(
                  fontSize: 7.5,
                  color: isDark ? const Color(0xFF64748B) : Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentPanel() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171A21) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPaymentChipVertical(
            icon: Icons.payments_rounded,
            label: 'Pay via Cash',
            value: 'cash',
            accentColor: const Color(0xFF10B981),
            bgColor: isDark ? const Color(0xFF10B981).withValues(alpha: 0.15) : const Color(0xFFECFDF5),
          ),
          const SizedBox(height: 8),
          _buildPaymentChipVertical(
            icon: Icons.qr_code_rounded,
            label: 'Pay via UPI',
            value: 'online',
            accentColor: const Color(0xFF10B981),
            bgColor: isDark ? const Color(0xFF10B981).withValues(alpha: 0.15) : const Color(0xFFECFDF5),
          ),
          const SizedBox(height: 10),
          Divider(height: 1, color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => setState(() => showPromoField = !showPromoField),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E293B) : const Color(0xFFFFFBEB),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.card_giftcard_rounded, size: 14, color: isDark ? const Color(0xFF10B981) : const Color(0xFFD97706)),
                ),
                const SizedBox(width: 10),
                Text(
                  'Apply Promo Code',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? Colors.white : const Color(0xFF1E293B)),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: showPromoField ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                ),
              ],
            ),
          ),
          if (_appliedPromoCode != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF10B981).withValues(alpha: 0.12) : const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle_rounded, size: 14, color: const Color(0xFF10B981)),
                  const SizedBox(width: 8),
                  Text(
                    '$_appliedPromoCode Applied',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                  ),
                  const Spacer(),
                  Text(
                    '- \u20B9${_promoDiscount.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _appliedPromoCode = null;
                        _promoDiscount = 0.0;
                        _promoController.clear();
                      });
                    },
                    child: Icon(Icons.cancel_rounded, size: 16, color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8)),
                  ),
                ],
              ),
            ),
          ],
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: showPromoField
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _promoController,
                            autofocus: true,
                            textCapitalization: TextCapitalization.characters,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: isDark ? Colors.white : const Color(0xFF1E293B)),
                            decoration: InputDecoration(
                              hintText: 'Enter promo code...',
                              hintStyle: TextStyle(color: isDark ? const Color(0xFF64748B) : const Color(0xFFCBD5E1), fontWeight: FontWeight.normal, letterSpacing: 0),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                              isDense: true,
                              filled: true,
                              fillColor: isDark ? const Color(0xFF1E222B) : Colors.white,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0))),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF10B981), width: 1.5)),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0))),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: _applyPromo,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                            decoration: BoxDecoration(color: const Color(0xFF10B981), borderRadius: BorderRadius.circular(10)),
                            child: _isValidatingPromo
                               ? const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.0))
                                : const Text('Apply', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentChipVertical({
    required IconData icon,
    required String label,
    required String value,
    required Color accentColor,
    required Color bgColor,
  }) {
    final selected = paymentMode == value;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => setState(() => paymentMode = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? bgColor : (isDark ? const Color(0xFF1E222B) : Colors.white),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? accentColor.withValues(alpha: 0.6) : (isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
            width: selected ? 1.5 : 1.0,
          ),
          boxShadow: selected
              ? [BoxShadow(color: accentColor.withValues(alpha: 0.05), blurRadius: 6, offset: const Offset(0, 2))]
              : [],
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? accentColor : (isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8)),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? (isDark ? Colors.white : accentColor) : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569)),
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (selected)
              Icon(Icons.check_circle_rounded, size: 16, color: accentColor)
            else
              Container(
                height: 16,
                width: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFCBD5E1), width: 1.5),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // =====================================================
  // BUILD
  // =====================================================

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final km = distanceMeters / 1000;
    final mins = durationSeconds / 60;

    final isSearchingPickup = pickupFocus.hasFocus && pickupController.text.isNotEmpty;
    final isSearchingDestination = destinationFocus.hasFocus && destinationController.text.isNotEmpty;
    final isSearching = isSearchingPickup || isSearchingDestination;

    final showCenterPin = (_activeField != null) && mapLoaded && !(pickupLat != null && pickupLng != null && destinationLat != null && destinationLng != null);

    final bool isIntercityRide = widget.orderType == 'intercity_ride' || (!widget.orderType.contains('parcel') && distanceMeters > 20000);
    final String submitButtonText = widget.orderType.contains('parcel')
        ? 'Confirm & Add Details'
        : (isIntercityRide ? 'Confirm Intercity Ride' : 'Confirm & Search Rides');

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: isDark ? const Color(0xFF1E222B) : const Color(0xFFF8FAFC),
      body: Stack(
        children: [
          // 1. Full-screen map Webview
          Positioned.fill(
            child: _useMockMap
                ? _buildMockMapFallback(isDark)
                : (webController != null
                    ? WebViewWidget(controller: webController!)
                    : const Center(
                        child: CircularProgressIndicator(),
                      )),
          ),

          // Center Pin Overlay for Map Dragging/Picking
          if (showCenterPin)
            Align(
              alignment: Alignment.center,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 36),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _activeField == 'pickup' ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.12),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Text(
                        _activeField == 'pickup' ? 'Set Pickup' : 'Set Destination',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 72,
                      width: 72,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // 1. Pulsating radar at the tip of the pin (bottom center)
                          Positioned(
                            bottom: 6,
                            child: AnimatedBuilder(
                              animation: _pulseController,
                              builder: (context, child) {
                                final scale = 0.3 + (_pulseController.value * 1.2);
                                final opacity = 1.0 - _pulseController.value;
                                final color = _activeField == 'pickup' ? const Color(0xFF10B981) : const Color(0xFFEF4444);
                                return Transform.scale(
                                  scale: scale,
                                  child: Opacity(
                                    opacity: opacity,
                                    child: Container(
                                      height: 32,
                                      width: 32,
                                      decoration: BoxDecoration(
                                        color: color.withValues(alpha: 0.25),
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: color,
                                          width: 1.5,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),

                          // 2. Base point center dot
                          Positioned(
                            bottom: 18,
                            child: Container(
                              height: 6,
                              width: 6,
                              decoration: BoxDecoration(
                                color: _activeField == 'pickup' ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),

                          // 3. Floating Pin Icon itself
                          Padding(
                            padding: const EdgeInsets.only(bottom: 22),
                            child: AnimatedBuilder(
                              animation: _pulseController,
                              builder: (context, child) {
                                final double translationY = -6.0 * (1.0 - (_pulseController.value - 0.5).abs() * 2);
                                return Transform.translate(
                                  offset: Offset(0, translationY),
                                  child: child,
                                );
                              },
                              child: Icon(
                                Icons.location_on_rounded,
                                size: 40,
                                color: _activeField == 'pickup' ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 2. TOP GRADIENT SHADOW OVERLAY
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: 180,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withOpacity(0.25),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),

          // 3. MAIN UI SCENE LAYER
          SafeArea(
            child: Column(
              children: [
                // Top Custom Bar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          height: 48,
                          width: 48,
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF171A21).withValues(alpha: 0.9)
                                : Colors.white.withValues(alpha: 0.9),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                              width: 1.0,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.08),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.arrow_back_rounded,
                            size: 20,
                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                            letterSpacing: -0.8,
                            shadows: isDark
                                ? [
                                    Shadow(
                                      color: Colors.black.withValues(alpha: 0.4),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    )
                                  ]
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                if (!_showBookingOptions) ...[
                  // UNIFIED PREMIUM ROUTE SEARCH CARD (Simplified to flat, full-width inputs)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        buildInput(
                          isPickup: true,
                          controller: pickupController,
                          focusNode: pickupFocus,
                          onChanged: searchPickup,
                          loading: loadingPickupSearch,
                          isGeocoding: loadingPickupGeocode,
                        ),
                        const SizedBox(height: 10),
                        buildInput(
                          isPickup: false,
                          controller: destinationController,
                          focusNode: destinationFocus,
                          onChanged: searchDestination,
                          loading: loadingDestinationSearch,
                          isGeocoding: loadingDestinationGeocode,
                        ),
                      ],
                    ),
                  ),
                  if (isSearching)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 350),
                        child: buildSearchResults(
                          results: isSearchingPickup
                              ? pickupResults
                              : destinationResults,
                          onTap: isSearchingPickup
                              ? selectPickup
                              : selectDestination,
                        ),
                      ),
                    ),

                  // Use Current Location Button Row (Only show if NOT searching to avoid layout clutter!)
                  if (!isSearching)
                    Padding(
                      padding: const EdgeInsets.only(right: 16, top: 4),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: GestureDetector(
                          onTap: _useCurrentLocationForActiveField,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF171A21) : Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: isDark ? 0.1 : 0.06),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                              border: Border.all(
                                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                                width: 1.0,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.my_location_rounded,
                                  size: 16,
                                  color: Color(0xFF10B981),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  _activeField == 'destination'
                                      ? 'Use Current Location for Destination'
                                      : 'Use Current Location for Pickup',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF1E293B),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
                const Spacer(),
              ],
            ),
          ),

          // Floating Current Location FAB (Only show when picking on map to avoid duplication)
          if (mapLoaded && showCenterPin)
            Positioned(
              right: 16,
              bottom: (showCenterPin && _draggedLat != null)
                  ? (Insets.bottom(context) + 220)
                  : (Insets.bottom(context) + 24),
              child: FloatingActionButton(
                heroTag: 'ride_location_gps_fab',
                mini: true,
                backgroundColor: isDark ? const Color(0xFF171A21) : Colors.white,
                foregroundColor: const Color(0xFF10B981),
                elevation: 4,
                onPressed: _recenterToCurrentLocation,
                child: const Icon(Icons.my_location_rounded, size: 20),
              ),
            ),

          // Map Picker Bottom Confirmation Card
          if (showCenterPin && _draggedLat != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 24 + Insets.bottom(context)),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF171A21) : Colors.white,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                    border: Border.all(
                      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                      width: 1.0,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.06),
                        blurRadius: 20,
                        offset: const Offset(0, -6),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          Text(
                            'Select your location',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : const Color(0xFF0F172A),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      
                      // Card containing the address details with the red pin icon
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF0F1115) : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isDark ? Colors.white.withOpacity(0.04) : const Color(0xFFE2E8F0),
                            width: 1.0,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Left red/orange ring icon matching the screenshot
                            Padding(
                              padding: const EdgeInsets.only(top: 3.0),
                              child: Container(
                                height: 16,
                                width: 16,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xFF8A3000), // dark brown center
                                  border: Border.all(color: const Color(0xFFE05300), width: 3.5), // orange border
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFFE05300).withOpacity(0.3),
                                      blurRadius: 4,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _isGeocoding
                                      ? const SizedBox(
                                          height: 18,
                                          width: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFEF4444)),
                                          ),
                                        )
                                      : Text(
                                          _draggedAddress ?? 'Pinpoint location...',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                                            height: 1.4,
                                          ),
                                        ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      
                      const SizedBox(height: 20),
                      
                      // CTA Button: Select Drop / Select Pickup
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed: _isGeocoding ? null : _confirmPickerLocation,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primaryColor,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(26),
                            ),
                          ),
                          child: Text(
                            _activeField == 'pickup' ? 'Select Pickup' : 'Select Drop',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

          // 5. FLOATING BOTTOM SUMMARY CARD & ACTIONS (when route is active)
          if (!isSearching && distanceMeters > 0 && !showCenterPin && !_showBookingOptions)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24 + Insets.bottom(context),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Premium Floating Distance & ETA panel
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF171A21) : Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.08),
                            blurRadius: 20,
                            offset: const Offset(0, 4),
                          ),
                        ],
                        border: Border.all(
                          color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                          width: 1.0,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Container(
                                  height: 40,
                                  width: 40,
                                  decoration: BoxDecoration(
                                    color: isDark 
                                        ? const Color(0xFF1E293B).withValues(alpha: 0.6) 
                                        : const Color(0xFFEFF6FF),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.straighten_rounded,
                                    color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Wrap(
                                        crossAxisAlignment: WrapCrossAlignment.center,
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          Text(
                                            'DISTANCE',
                                            style: TextStyle(
                                              fontSize: 9,
                                              fontWeight: FontWeight.w700,
                                              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                          if (isIntercityRide)
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                                borderRadius: BorderRadius.circular(6),
                                                border: Border.all(color: const Color(0xFF10B981), width: 0.8),
                                              ),
                                              child: const Text(
                                                'INTERCITY',
                                                style: TextStyle(
                                                  fontSize: 7.5,
                                                  fontWeight: FontWeight.bold,
                                                  color: Color(0xFF10B981),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${km.toStringAsFixed(1)} km',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            height: 32,
                            width: 1,
                            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                          ),
                          Expanded(
                            child: Row(
                              children: [
                                const SizedBox(width: 16),
                                Container(
                                  height: 40,
                                  width: 40,
                                  decoration: BoxDecoration(
                                    color: isDark 
                                        ? const Color(0xFF1E293B).withValues(alpha: 0.6) 
                                        : const Color(0xFFECFDF5),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(
                                    Icons.access_time_filled_rounded,
                                    color: Color(0xFF10B981),
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'EST. TIME',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700,
                                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${mins.toStringAsFixed(0)} mins',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                          color: isDark ? Colors.white : const Color(0xFF0F172A),
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
                    const SizedBox(height: 12),

                    // Premium submit button
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        onPressed: loadingRoute || openingPreview ? null : continueFlow,
                        style: ElevatedButton.styleFrom(
                          elevation: isDark ? 4 : 8,
                          shadowColor: primaryColor.withValues(alpha: isDark ? 0.2 : 0.3),
                          backgroundColor: primaryColor,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: loadingRoute || openingPreview
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                ),
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    submitButtonText,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  const Icon(
                                    Icons.arrow_forward_rounded,
                                    size: 16,
                                    color: Colors.white,
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 6. COMBINED DRIFTING BOOKING SHEET (when route is active & show booking options)
          if (_showBookingOptions)
            Positioned.fill(
              child: DraggableScrollableSheet(
                initialChildSize: 0.45,
                minChildSize: 0.28,
                maxChildSize: 0.85,
                snap: true,
                snapSizes: const [0.28, 0.45, 0.85],
                builder: (context, scrollController) {
                  final isDark = Theme.of(context).brightness == Brightness.dark;
                  final double distanceKmVal = distanceMeters / 1000;
                  final double durationMinVal = durationSeconds / 60;
                  
                  final pricingData = pricingController.pricingData;
                  final hasPricing = pricingData.isNotEmpty;

                  // Find final fare for selected vehicle
                  double originalFare = 0.0;
                  if (selectedVehicle != null && pricingData.containsKey(selectedVehicle)) {
                    originalFare = double.tryParse(pricingData[selectedVehicle]?['final_fare']?.toString() ?? '') ?? 0.0;
                  }
                  final double finalFare = (originalFare - _promoDiscount).clamp(0.0, double.infinity);

                  return Container(
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF0F172A) : Colors.white,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                          blurRadius: 18,
                          offset: const Offset(0, -3),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        // Draggable pill
                        Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            margin: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),

                        // Scrollable content area
                        Expanded(
                          child: ListView(
                            controller: scrollController,
                            padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + Insets.bottom(context)),
                            children: [
                              // 1. Interactive editable address details (shows full address)
                              InkWell(
                                onTap: _editLocations,
                                borderRadius: BorderRadius.circular(24),
                                child: Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: isDark ? const Color(0xFF131929) : Colors.white,
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(
                                      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.04),
                                        blurRadius: 10,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                              children: [
                                                Text(
                                                  'ROUTE DETAILS',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w800,
                                                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                                    letterSpacing: 0.8,
                                                  ),
                                                ),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  child: Text(
                                                    '${distanceKmVal.toStringAsFixed(1)} km • ${durationMinVal.toStringAsFixed(0)} mins',
                                                    style: const TextStyle(
                                                      fontSize: 10,
                                                      fontWeight: FontWeight.w800,
                                                      color: Color(0xFF10B981),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 14),
                                            
                                            // Pickup address row
                                            Row(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Container(
                                                  margin: const EdgeInsets.only(top: 3),
                                                  height: 10, width: 10,
                                                  decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Text(
                                                        'Pickup Location',
                                                        style: TextStyle(
                                                          fontSize: 9,
                                                          fontWeight: FontWeight.w900,
                                                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                                        ),
                                                      ),
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        pickupController.text,
                                                        style: TextStyle(
                                                          fontSize: 13,
                                                          fontWeight: FontWeight.w700,
                                                          color: isDark ? Colors.white : const Color(0xFF1E293B),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                            
                                            // Dotted vertical line connector
                                            Align(
                                              alignment: Alignment.centerLeft,
                                              child: Container(
                                                margin: const EdgeInsets.only(left: 4, top: 4, bottom: 4),
                                                width: 1.5,
                                                height: 16,
                                                color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                                              ),
                                            ),

                                            // Drop address row
                                            Row(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Container(
                                                  margin: const EdgeInsets.only(top: 3),
                                                  height: 10, width: 10,
                                                  decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Text(
                                                        'Drop Location',
                                                        style: TextStyle(
                                                          fontSize: 9,
                                                          fontWeight: FontWeight.w900,
                                                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                                        ),
                                                      ),
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        destinationController.text,
                                                        style: TextStyle(
                                                          fontSize: 13,
                                                          fontWeight: FontWeight.w700,
                                                          color: isDark ? Colors.white : const Color(0xFF1E293B),
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
                                      const SizedBox(width: 12),
                                      // Edit plus button
                                      Container(
                                        height: 32,
                                        width: 32,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFF10B981),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.edit_rounded,
                                          color: Colors.white,
                                          size: 16,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),

                              // Payment & Promo code panels
                              _buildPaymentPanel(),
                              const SizedBox(height: 20),

                              // "Select a Ride" Title
                              Text(
                                'Select a Ride',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w900,
                                  color: isDark ? Colors.white : const Color(0xFF1E293B),
                                ),
                              ),
                              const SizedBox(height: 14),

                              // Vehicle Selector list (Horizontal previous layout style)
                              if (!hasPricing)
                                const SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children: [
                                      SizedBox(width: 280, child: VehiclePricingSkeletonCard()),
                                      SizedBox(width: 280, child: VehiclePricingSkeletonCard()),
                                      SizedBox(width: 280, child: VehiclePricingSkeletonCard()),
                                    ],
                                  ),
                                )
                              else
                                SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children: [
                                      if (pricingData.containsKey('bike'))
                                        _buildVehicleItem(
                                          vehicle: 'bike',
                                          title: 'Bike',
                                          fare: double.tryParse(pricingData['bike']?['final_fare']?.toString() ?? '') ?? 0.0,
                                          selected: selectedVehicle == 'bike',
                                          onTap: () => _selectVehicle('bike'),
                                        ),
                                      if (pricingData.containsKey('auto'))
                                        _buildVehicleItem(
                                          vehicle: 'auto',
                                          title: 'Auto',
                                          fare: double.tryParse(pricingData['auto']?['final_fare']?.toString() ?? '') ?? 0.0,
                                          selected: selectedVehicle == 'auto',
                                          onTap: () => _selectVehicle('auto'),
                                        ),
                                      if (pricingData.containsKey('cab'))
                                        _buildVehicleItem(
                                          vehicle: 'cab',
                                          title: 'Cab',
                                          fare: double.tryParse(pricingData['cab']?['final_fare']?.toString() ?? '') ?? 0.0,
                                          selected: selectedVehicle == 'cab',
                                          onTap: () => _selectVehicle('cab'),
                                        ),
                                    ],
                                  ),
                                ),
                              const SizedBox(height: 24),

                              // 2. Sticky Booking Button Row (Unified Price & Booking Button)
                              SizedBox(
                                width: double.infinity,
                                height: 56,
                                child: ElevatedButton(
                                  onPressed: (selectedVehicle == null || creatingOrder || waitingForPayment)
                                      ? null
                                      : _createOrder,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF10B981),
                                    disabledBackgroundColor: const Color(0xFF10B981).withValues(alpha: 0.5),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    elevation: 4,
                                    shadowColor: const Color(0xFF10B981).withValues(alpha: 0.35),
                                    padding: const EdgeInsets.symmetric(horizontal: 20),
                                  ),
                                  child: (creatingOrder || waitingForPayment)
                                      ? const SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              'Book Ride Now',
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                            SizedBox(width: 8),
                                            Icon(
                                              Icons.arrow_forward_rounded,
                                              color: Colors.white,
                                              size: 16,
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMockMapFallback(bool isDark) {
    final mapBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
    final lineColor = isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.03);
    
    return Container(
      color: mapBg,
      child: Stack(
        children: [
          // Street grid overlay
          Positioned.fill(
            child: CustomPaint(
              painter: _ScreenMapGridPainter(lineColor: lineColor),
            ),
          ),
          
          // Draw mock route line if both coordinates are present
          if (pickupLat != null && pickupLng != null && destinationLat != null && destinationLng != null)
            Positioned.fill(
              child: CustomPaint(
                painter: _MockRoutePainter(isDark: isDark),
              ),
            ),
            
          // Pickup Marker
          if (pickupLat != null && pickupLng != null)
            Align(
              alignment: Alignment.center,
              child: Transform.translate(
                offset: const Offset(-40, -20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('Pickup', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                    const Icon(Icons.location_on_rounded, color: Color(0xFF10B981), size: 24),
                  ],
                ),
              ),
            ),
            
          // Destination Marker
          if (destinationLat != null && destinationLng != null)
            Align(
              alignment: Alignment.center,
              child: Transform.translate(
                offset: const Offset(40, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('Dropoff', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                    const Icon(Icons.location_on_rounded, color: Color(0xFFEF4444), size: 24),
                  ],
                ),
              ),
            ),

          // Platform info banner
          Positioned(
            left: 16,
            right: 16,
            top: 100,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF0F172A).withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.desktop_mac_rounded,
                    color: Color(0xFF10B981),
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Running on Desktop: Mock map activated. Click inputs or search to set route.',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white70 : Colors.black87,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScreenMapGridPainter extends CustomPainter {
  final Color lineColor;
  _ScreenMapGridPainter({required this.lineColor});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    for (double y = 0; y < size.height; y += 45) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (double x = 0; x < size.width; x += 45) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _MockRoutePainter extends CustomPainter {
  final bool isDark;
  _MockRoutePainter({required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF10B981)
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final path = Path();
    final start = Offset(size.width / 2 - 40, size.height / 2 - 20);
    final end = Offset(size.width / 2 + 40, size.height / 2 + 20);
    
    path.moveTo(start.dx, start.dy);
    path.quadraticBezierTo(
      (start.dx + end.dx) / 2 - 20,
      (start.dy + end.dy) / 2 - 40,
      end.dx,
      end.dy,
    );
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}