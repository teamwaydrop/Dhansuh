// transport_location_screen.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/core/services/location/location_permission_helper.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:waydrop/core/services/location/serviceability_service.dart';
import 'package:waydrop/features/local_parcels/booking/screens/parcel_details_screen.dart';
import 'package:waydrop/features/local_parcels/booking/screens/parcel_booking_screen.dart';
import 'package:waydrop/features/intercity/parcels/booking/intercity_details_screen.dart';
import 'package:waydrop/features/intercity/parcels/booking/intercity_booking_screen.dart';
import 'package:waydrop/shared/helpers/insets.dart';

class ParcelLocationScreen extends StatefulWidget {
  final String orderType;
  final String? receiverName;
  final String? receiverPhone;
  final String? parcelType;
  final String? weightCategory;
  final String? specialInstructions;
  final List<String>? parcelImages;

  final bool isPickerMode;
  final String? initialPickupAddress;
  final double? initialPickupLat;
  final double? initialPickupLng;
  final String? initialDestinationAddress;
  final double? initialDestinationLat;
  final double? initialDestinationLng;

  const ParcelLocationScreen({
    super.key,
    this.orderType = 'local_parcel',
    this.receiverName,
    this.receiverPhone,
    this.parcelType,
    this.weightCategory,
    this.specialInstructions,
    this.parcelImages,
    this.isPickerMode = false,
    this.initialPickupAddress,
    this.initialPickupLat,
    this.initialPickupLng,
    this.initialDestinationAddress,
    this.initialDestinationLat,
    this.initialDestinationLng,
  });

  @override
  State<ParcelLocationScreen> createState() =>
      _ParcelLocationScreenState();
}

class _ParcelLocationScreenState
    extends State<ParcelLocationScreen> with SingleTickerProviderStateMixin {

  late final AnimationController _pulseController;

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
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    )..repeat();
    _initialize();
  }

  Future<void> _initialize() async {
    pickupFocus.addListener(_onFocusChange);
    destinationFocus.addListener(_onFocusChange);
    pickupController.addListener(_onPickupTextChanged);
    destinationController.addListener(_onDestinationTextChanged);

    if (widget.initialPickupAddress != null) {
      pickupController.text = widget.initialPickupAddress!;
      pickupLat = widget.initialPickupLat;
      pickupLng = widget.initialPickupLng;
    }
    if (widget.initialDestinationAddress != null) {
      destinationController.text = widget.initialDestinationAddress!;
      destinationLat = widget.initialDestinationLat;
      destinationLng = widget.initialDestinationLng;
    }

    // [PERF POC #4] Defer heavy cold-start work (WebView init + GPS/route chain)
    // until after the first frame so the route transition isn't blocked on
    // first open. Same calls, same order, same error handling — only the
    // scheduling moved. The build already renders a CircularProgressIndicator
    // fallback while webController == null.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _initWebView();
      if (!mounted) return;

      if (pickupLat == null || pickupLng == null) {
        await _loadCurrentLocation();
      } else {
        _isProgrammaticMove = true;
        await _updateMarkers();
        await _calculateRoute();
      }
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

    // Phase 2F-C1 -- explicit WebView teardown, mirroring the Phase 2F-B pattern (c1ccf56).
    // This screen's webController loads ola_map_location_picker.html (which pulls in
    // ola_map_core.js, so destroyMap / destroyNearbyRidersEngine are defined). That page already
    // tears the map down on the document 'unload' event, but 'unload' does not reliably fire when
    // Flutter disposes the platform WebView without a navigation -- leaking the MapLibre GL
    // context and, if any nearby riders were plotted, the AnimationManager RAF loop. All helpers
    // are `typeof`-guarded and idempotent; the call is wrapped in try/catch on the JS side and
    // .catchError on the Dart side, and is fire-and-forget because dispose() cannot await.
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

    super.dispose();
  }

  // =====================================================
  // WEBVIEW
  // =====================================================

  void _initWebView() {
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

      pickupCity = coords['city']?.toString() ?? '';

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

    // Auto shift focus to destination
    FocusScope.of(context).requestFocus(destinationFocus);
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

      destinationCity = coords['city']?.toString() ?? '';

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
        
        FocusScope.of(context).requestFocus(destinationFocus);
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

        await webController!.runJavaScript('''
          if(window.fitRouteBounds){
            window.fitRouteBounds();
          }
        ''');
      }

      if (mounted) {
        setState(() {});
        if (distanceMeters > 0 && !_autoNavigated && !widget.isPickerMode) {
          _autoNavigated = true;
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
    final bool isLocal = widget.orderType == 'local_parcel';
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

      if (widget.isPickerMode) {
        Navigator.pop(context, {
          'pickupAddress': pickupController.text,
          'pickupLat': pickupLat,
          'pickupLng': pickupLng,
          'pickupCity': pickupCity,
          'destinationAddress': destinationController.text,
          'destinationLat': destinationLat,
          'destinationLng': destinationLng,
          'destinationCity': destinationCity,
          'distanceMeters': distanceMeters,
          'durationSeconds': durationSeconds,
          'routePoints': routePoints,
        });
        return;
      }

      final bool isIntercity = distanceMeters > 20000;
      if (widget.receiverName != null) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => isIntercity
                ? IntercityBookingScreen(
                    orderType: 'intercity_parcel',
                    pickupAddress: pickupController.text,
                    destinationAddress: destinationController.text,
                    pickupLat: pickupLat!,
                    pickupLng: pickupLng!,
                    destinationLat: destinationLat!,
                    destinationLng: destinationLng!,
                    totalDistanceMeters: distanceMeters,
                    durationSeconds: durationSeconds,
                    routePoints: routePoints,
                    receiverName: widget.receiverName!,
                    receiverPhone: widget.receiverPhone ?? '',
                    parcelType: widget.parcelType ?? 'other',
                    weightCategory: widget.weightCategory ?? 'medium',
                    specialInstructions: widget.specialInstructions ?? '',
                    parcelImages: widget.parcelImages ?? [],
                    pickupCity: pickupCity,
                    destinationCity: destinationCity,
                  )
                : ParcelBookingScreen(
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
                    receiverName: widget.receiverName!,
                    receiverPhone: widget.receiverPhone ?? '',
                    parcelType: widget.parcelType ?? 'other',
                    weightCategory: widget.weightCategory ?? 'medium',
                    specialInstructions: widget.specialInstructions ?? '',
                    parcelImages: widget.parcelImages ?? [],
                    pickupCity: pickupCity,
                    destinationCity: destinationCity,
                  ),
          ),
        );
      } else {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => isIntercity
                ? IntercityDetailsScreen(
                    orderType: 'intercity_parcel',
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
                  )
                : ParcelDetailsScreen(
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
      }
    } catch (e) {
      debugPrint('CONFIRM LOCATION ERROR => $e');
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
          hintText: isPickup ? 'Enter pickup location...' : 'Enter delivery location...',
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

    final bool isIntercityParcel = widget.orderType.contains('parcel') && distanceMeters > 20000;
    final String submitButtonText = widget.isPickerMode
        ? 'Confirm Locations'
        : (isIntercityParcel
            ? 'Confirm Intercity Parcel'
            : (widget.orderType.contains('parcel')
                ? 'Confirm & Add Details'
                : 'Confirm & Search Rides'));

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: isDark ? const Color(0xFF1E222B) : const Color(0xFFF8FAFC),
      body: Stack(
        children: [
          // 1. Full-screen map Webview
          Positioned.fill(
            child: webController != null
                ? WebViewWidget(controller: webController!)
                : const Center(
                    child: CircularProgressIndicator(),
                  ),
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
                heroTag: 'parcel_location_gps_fab',
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
          if (!isSearching && distanceMeters > 0 && !showCenterPin)
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
                                          if (isIntercityParcel)
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
        ],
      ),
    );
  }
}