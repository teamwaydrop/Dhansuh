// home_location_screen.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/core/services/location/location_permission_helper.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:waydrop/core/services/location/serviceability_service.dart';
import 'package:waydrop/shared/helpers/insets.dart';

class HomeLocationScreen extends StatefulWidget {
  final String? prefillAddress;
  final double? prefillLat;
  final double? prefillLng;

  const HomeLocationScreen({
    super.key,
    this.prefillAddress,
    this.prefillLat,
    this.prefillLng,
  });

  @override
  State<HomeLocationScreen> createState() => _HomeLocationScreenState();
}

class _HomeLocationScreenState extends State<HomeLocationScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  // =====================================================
  // CONTROLLERS
  // =====================================================
  final locationController = TextEditingController();
  final locationFocus = FocusNode();

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

  // =====================================================
  // LOCATION
  // =====================================================
  double? selectedLat;
  double? selectedLng;

  // =====================================================
  // SEARCH
  // =====================================================
  Timer? searchDebounce;
  List<dynamic> searchResults = [];
  bool loadingSearch = false;
  bool loadingGeocode = false;

  Color get primaryColor => const Color(0xFF10B981);

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
    locationFocus.addListener(_onFocusChange);
    locationController.addListener(_onLocationTextChanged);

    if (widget.prefillAddress != null) {
      locationController.text = widget.prefillAddress!;
      selectedLat = widget.prefillLat;
      selectedLng = widget.prefillLng;
    }

    // [PERF POC] Defer heavy cold-start work (WebView creation + 748KB map
    // load + GPS/location chain) until after the first frame so the route
    // transition is not blocked on first open. Same calls, same order, same
    // error handling -- only the scheduling moved. The screen's existing
    // loading fallback renders until the map is ready.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _initWebView();
      if (!mounted) return;
      await _loadCurrentLocation();
    });
  }

  bool _isPickerActive = true;

  void _onFocusChange() {
    if (locationFocus.hasFocus) {
      setState(() {
        _isPickerActive = true;
      });
    }
  }

  void _onLocationTextChanged() {
    if (locationController.text.trim().isEmpty) {
      if (selectedLat != null || selectedLng != null) {
        setState(() {
          selectedLat = null;
          selectedLng = null;
          searchResults = [];
        });
        _updateMarkers();
      }
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    locationFocus.removeListener(_onFocusChange);
    locationController.removeListener(_onLocationTextChanged);
    locationController.dispose();
    locationFocus.dispose();
    searchDebounce?.cancel();
    _debounceGeocode?.cancel();

    // Phase 2F-C1 -- explicit WebView teardown, mirroring the Phase 2F-B pattern (c1ccf56).
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

  bool get _useMockMap {
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  Future<void> _initWebView() async {
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
              if (!mounted) return;
              setState(() => mapLoaded = true);
              await _injectMap();
              await _updateMarkers();
            },
          ),
        );
      await webController!.loadFlutterAsset('assets/map/ola_map_location_picker.html');
    } catch (e) {
      debugPrint('Failed to initialize WebView: $e');
      if (!mounted) return;
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

  Future<void> _loadCurrentLocation() async {
    if (widget.prefillAddress != null) {
      _isProgrammaticMove = true;
      await _updateMarkers();
      return;
    }

    try {
      await LocationCacheService.initializeLocation();
      final lat = LocationCacheService.currentLat;
      final lng = LocationCacheService.currentLng;

      if (lat == null || lng == null) {
        locationController.text = '';
        return;
      }

      selectedLat = lat;
      selectedLng = lng;

      final cachedAddress = LocationCacheService.cachedAddress;
      if (cachedAddress != null &&
          cachedAddress.trim().isNotEmpty &&
          cachedAddress != 'Selected Location' &&
          cachedAddress != 'Fetching location...') {
        locationController.text = cachedAddress;
      } else {
        locationController.text = '';
      }

      _isProgrammaticMove = true;
      await _updateMarkers();
    } catch (e) {
      debugPrint('CURRENT LOCATION ERROR => $e');
    }
  }

  Future<void> _useCurrentLocationForField() async {
    final hasPermission = await LocationPermissionHelper.checkAndRequestLocation(
      context,
      primaryColor: primaryColor,
    );
    if (!hasPermission) return;

    try {
      setState(() {
        loadingGeocode = true;
      });

      await LocationCacheService.initializeLocation();
      final lat = LocationCacheService.currentLat;
      final lng = LocationCacheService.currentLng;

      if (lat == null || lng == null) {
        _show('Could not fetch GPS coordinates. Please enable GPS.');
        return;
      }

      final address = LocationCacheService.currentAddress;
      _isProgrammaticMove = true;

      final resolvedAddress =
          (address == 'Selected Location' || address == 'Fetching location...')
              ? 'Current Location'
              : address;

      setState(() {
        selectedLat = lat;
        selectedLng = lng;
        locationController.text = resolvedAddress;
        searchResults = [];
      });

      await _updateMarkers();

      if (!mounted) return;
      Navigator.pop(context, {
        'latitude': selectedLat,
        'longitude': selectedLng,
        'address': locationController.text,
        'city': LocationCacheService.cachedCity ?? '',
      });
    } catch (e) {
      _show('Error fetching current location.');
    } finally {
      setState(() {
        loadingGeocode = false;
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

      if (!mounted) return;
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

  Future<void> searchLocation(String value) async {
    searchDebounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        searchResults = [];
      });
      return;
    }

    searchDebounce = Timer(const Duration(milliseconds: 400), () async {
      setState(() {
        loadingSearch = true;
      });

      final results = await OlaMapService.autocomplete(value);
      if (!mounted) return;

      setState(() {
        searchResults = results;
        loadingSearch = false;
      });
    });
  }

  Future<void> selectLocationItem(dynamic item) async {
    final description = item['description']?.toString() ?? '';
    locationController.text = description;
    searchResults = [];

    setState(() {
      loadingGeocode = true;
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
      if (coords == null) return;

      _isProgrammaticMove = true;
      selectedLat = coords['latitude'];
      selectedLng = coords['longitude'];
      setState(() {});

      await _updateMarkers();

      final city = coords['city']?.toString();
      await ServiceabilityService.isLocationServiceable(
        address: description,
        latitude: selectedLat,
        longitude: selectedLng,
        city: city,
      );


      if (!mounted) return;
      Navigator.pop(context, {
        'latitude': selectedLat,
        'longitude': selectedLng,
        'address': locationController.text,
        'city': city ?? '',
      });
    } finally {
      if (mounted) {
        setState(() {
          loadingGeocode = false;
        });
      }
    }
  }

  Future<void> _updateMarkers() async {
    if (webController == null) return;
    try {
      await webController!.runJavaScript('''
        if(window.clearMarkers){
          window.clearMarkers();
        }
      ''');

      if (selectedLat != null && selectedLng != null) {
        await webController!.runJavaScript('''
          if(window.addPickupMarker){
            window.addPickupMarker(
              $selectedLat,
              $selectedLng,
              15
            );
          }
        ''');
      }
    } catch (_) {}
  }

  Future<void> _onCameraMoveEnd(double lat, double lng) async {
    if (_isProgrammaticMove) {
      _isProgrammaticMove = false;
      return;
    }

    if (_isClose(lat, lng, selectedLat, selectedLng)) {
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

  Future<void> _confirmPickerLocation() async {
    if (_draggedLat == null || _draggedLng == null) return;

    final address =
        (_draggedAddress == null || _draggedAddress == 'Selected Location')
            ? 'Pinned Location'
            : _draggedAddress!;

    setState(() {
      _isProgrammaticMove = true;
      selectedLat = _draggedLat;
      selectedLng = _draggedLng;
      locationController.text = address;
      searchResults = [];
      _draggedAddress = null;
      _draggedLat = null;
      _draggedLng = null;
    });

    await ServiceabilityService.isLocationServiceable(
      address: address,
      latitude: selectedLat,
      longitude: selectedLng,
      city: _draggedCity,
    );


    if (!mounted) return;
    Navigator.pop(context, {
      'latitude': selectedLat,
      'longitude': selectedLng,
      'address': locationController.text,
      'city': _draggedCity ?? '',
    });
  }

  void _show(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Widget buildSearchResults() {
    if (searchResults.isEmpty) {
      return const SizedBox();
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textCol = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextCol =
        isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

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
          itemCount: searchResults.length,
          separatorBuilder: (_, index) => Divider(
            height: 1,
            indent: 52,
            endIndent: 16,
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
          ),
          itemBuilder: (context, index) {
            final item = searchResults[index];
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
                  selectLocationItem(item);
                },
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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

  Widget buildInput() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const primaryColor = Color(0xFF10B981);
    
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
          color: locationFocus.hasFocus ? primaryColor : borderCol,
          width: locationFocus.hasFocus ? 1.5 : 1.0,
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
        controller: locationController,
        focusNode: locationFocus,
        onChanged: searchLocation,
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
          hintText: 'Enter service location...',
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
          suffixIcon: (loadingSearch || loadingGeocode)
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                    ),
                  ),
                )
              : locationController.text.isEmpty
                  ? const SizedBox(width: 48, height: 48)
                  : IconButton(
                      onPressed: () {
                        locationController.clear();
                        searchResults = [];
                        selectedLat = null;
                        selectedLng = null;
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSearching =
        locationFocus.hasFocus && locationController.text.isNotEmpty;
    final showCenterPin = _isPickerActive && mapLoaded;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor:
          isDark ? const Color(0xFF1E222B) : const Color(0xFFF8FAFC),
      body: Stack(
        children: [
          // 1. Full-screen map Webview
          if (webController != null)
            Positioned.fill(
              child: WebViewWidget(controller: webController!),
            )
          else if (_useMockMap)
            Positioned.fill(
              child: _buildMockMapFallback(isDark),
            )
          else
            Positioned.fill(
              child: Container(
                color:
                    isDark ? const Color(0xFF1E222B) : const Color(0xFFF8FAFC),
                child: const Center(
                  child: CircularProgressIndicator(
                    color: Color(0xFF10B981),
                  ),
                ),
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Text(
                        'Set Location',
                        style: TextStyle(
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
                                final scale =
                                    0.3 + (_pulseController.value * 1.2);
                                final opacity = 1.0 - _pulseController.value;
                                const color = Color(0xFF10B981);
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
                              decoration: const BoxDecoration(
                                color: Color(0xFF10B981),
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
                                final double translationY = -6.0 *
                                    (1.0 -
                                        (_pulseController.value - 0.5).abs() *
                                            2);
                                return Transform.translate(
                                  offset: Offset(0, translationY),
                                  child: child,
                                );
                              },
                              child: const Icon(
                                Icons.location_on_rounded,
                                size: 40,
                                color: Color(0xFF10B981),
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
                      Colors.black.withValues(alpha: 0.25),
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
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
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
                              color: isDark
                                  ? const Color(0xFF1E293B)
                                  : const Color(0xFFE2E8F0),
                              width: 1.0,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(
                                    alpha: isDark ? 0.2 : 0.08),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.arrow_back_rounded,
                            size: 20,
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF0F172A),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          'Set Service Location',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF0F172A),
                            letterSpacing: -0.8,
                            shadows: isDark
                                ? [
                                    Shadow(
                                      color:
                                          Colors.black.withValues(alpha: 0.4),
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
                      buildInput(),
                    ],
                  ),
                ),
                if (isSearching)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 350),
                      child: buildSearchResults(),
                    ),
                  ),

                // Use Current Location Button Row
                if (!isSearching)
                  Padding(
                    padding: const EdgeInsets.only(right: 16, top: 4),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: GestureDetector(
                        onTap: _useCurrentLocationForField,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF171A21)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(
                                    alpha: isDark ? 0.1 : 0.06),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                            border: Border.all(
                              color: isDark
                                  ? const Color(0xFF1E293B)
                                  : const Color(0xFFE2E8F0),
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
                                'Use Current Location',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: isDark
                                      ? const Color(0xFFCBD5E1)
                                      : const Color(0xFF1E293B),
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
                          color: isDark ? Colors.white.withValues(alpha: 0.04) : const Color(0xFFE2E8F0),
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
                                    color: const Color(0xFFE05300).withValues(alpha: 0.3),
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
                    
                    // CTA Button: Confirm Location
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _isGeocoding ? null : _confirmPickerLocation,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(26),
                          ),
                        ),
                        child: const Text(
                          'Confirm Location',
                          style: TextStyle(
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
        ],
      ),
    );
  }

  Widget _buildMockMapFallback(bool isDark) {
    final mapBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
    final lineColor = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.03);

    return Container(
      color: mapBg,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _ScreenMapGridPainter(lineColor: lineColor),
            ),
          ),
          if (selectedLat != null && selectedLng != null)
            Align(
              alignment: Alignment.center,
              child: Transform.translate(
                offset: const Offset(0, -20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('Selected Location',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold)),
                    ),
                    const Icon(Icons.location_on_rounded,
                        color: Color(0xFF10B981), size: 24),
                  ],
                ),
              ),
            ),
          Positioned(
            left: 16,
            right: 16,
            top: 100,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF0F172A).withValues(alpha: 0.9)
                    : Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : const Color(0xFFE2E8F0),
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
                      'Running on Desktop: Mock map activated. Click inputs or search to set location.',
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
