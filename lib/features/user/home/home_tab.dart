import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/core/services/network/poll_backoff.dart';
import 'package:waydrop/modules/notifications/screens/notifications_inbox_screen.dart';
import 'package:waydrop/modules/notifications/widgets/notification_bell_badge.dart';
import 'package:waydrop/modules/notifications/services/notification_badge_service.dart';
import 'package:waydrop/features/rider/navigation/rider_main_navigation_screen.dart';

import 'package:waydrop/features/local_rides/booking/screens/ride_location_screen.dart';
import 'package:waydrop/features/user/home/home_location_screen.dart';
import 'package:waydrop/features/local_rides/searching/screens/ride_searching_screen.dart';
import 'package:waydrop/features/local_rides/tracking/screens/ride_tracking_screen.dart';
import 'package:waydrop/features/local_parcels/searching/screens/parcel_searching_screen.dart';
import 'package:waydrop/features/local_parcels/booking/screens/parcel_details_screen.dart';
import 'package:waydrop/features/local_parcels/tracking/screens/parcel_tracking_screen.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_searching_screen.dart';
import 'package:waydrop/features/intercity/parcels/booking/intercity_details_screen.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_tracking_screen.dart';
import 'package:waydrop/features/intercity/parcels/dashboard/intercity_parcels_screen.dart';
import 'package:waydrop/features/intercity/rides/dashboard/intercity_rides_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_entry_handler.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_payout_details_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/service_mode_selection_screen.dart';
import 'package:waydrop/shared/widgets/mode_switch_overlay.dart';
import 'package:waydrop/features/rider/services/rider_status_service.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/core/services/developer/developer_mode_service.dart';
import 'package:waydrop/core/services/config/feature_flags.dart';
import 'package:waydrop/shared/helpers/insets.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:waydrop/core/providers/app_mode_provider.dart';
import 'package:waydrop/core/providers/initial_data_provider.dart';
import 'package:waydrop/main_navigation_screen.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:waydrop/design_system/waydrop_design_system.dart';
import 'package:waydrop/shared/animations/waydrop_bike_animation.dart';
import 'package:waydrop/core/services/location/serviceability_service.dart';
import 'package:waydrop/core/theme/responsive_layout.dart';

class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key});

  @override
  ConsumerState<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends ConsumerState<HomeTab> with WidgetsBindingObserver {
  final supabase = Supabase.instance.client;
  Map<String, dynamic>? userProfile;
  Map<String, dynamic>? riderProfile;
  Map<String, dynamic>? kycProfile;
  List<Map<String, dynamic>> recentOrders = [];
  bool loading = true;
  // [PERF] Rebuild-scope gate (Issue #1A): counts builds that rendered real content (not the
  // skeleton) so a skeleton-first build (login/OTP flow) never consumes the one-time entrance
  // animation below.
  int _contentBuildCount = 0;
  RealtimeChannel? channel;
  String? _homeActiveOrdersSubId;
  String? _homeActiveOrdersChannelName;
  String? _lastOrderStateHash;
  Timer? _cooldownTimer;
  // [PERF] Issue #1B: the 1 s cooldown tick drives only this notifier (no setState).
  final ValueNotifier<DateTime> _cooldownTicker = ValueNotifier<DateTime>(DateTime.now());
  Timer? _silentRefreshTimer;
  // Timestamp of the last realtime delivery for this tab (users/riders/kyc/orders
  // channels). Used to skip the redundant 30s silent refresh while realtime is
  // healthy -- the timer stays as the pure fallback when realtime is stale.
  DateTime? _lastRealtimeEventAt;
  // Egress fix: _load() swallows its own errors internally (existing
  // try/catch/debugPrint, never rethrows), so recorded directly from inside its own
  // success/catch paths. Consulted by the 30s silent-refresh timer only -- initState,
  // resume, and realtime callbacks all call _load() unconditionally.
  final PollBackoff _refreshBackoff = PollBackoff();

  String? _subscribedUserId;
  String? _subscribedRiderId;
  String? _subscribedKycId;

  // Location and Map state variables
  bool _hasLocationPermission = false;
  bool _gpsEnabled = true;
  Position? _currentPosition;
  bool _isLocating = false;
  Timer? _locationCheckTimer;
  bool _hasCheckedServiceabilityOnInit = false;
  bool _isLocationServiceable = true;
  DateTime? _lastLocationUpdateTime;
  bool _isLocationPromptShowing = false;
  BuildContext? _locationPromptContext;

  // Manual location overrides (mock values)
  double? get _mockLatitude => LocationCacheService.manualMockLat;
  double? get _mockLongitude => LocationCacheService.manualMockLng;
  String? get _mockAddress => LocationCacheService.manualMockAddress;

  Future<void> _updateMockLocation(
    double? lat,
    double? lng,
    String? address,
  ) async {
    await LocationCacheService.saveMockLocationToPrefs(
      lat: lat,
      lng: lng,
      address: address,
    );
    if (mounted) {
      // Update the widget state to trigger a UI rebuild with the new variables
      setState(() {});
    }
  }

  double? get _currentLat =>
      _mockLatitude ??
      _currentPosition?.latitude ??
      LocationCacheService.currentLat;
  double? get _currentLng =>
      _mockLongitude ??
      _currentPosition?.longitude ??
      LocationCacheService.currentLng;
  String get _currentAddress {
    if (_mockAddress != null) return _mockAddress!;
    if (!_gpsEnabled) return 'Location services disabled';
    if (!_hasLocationPermission) return 'Location permission off';
    return LocationCacheService.currentAddress;
  }

  String get _locationElapsedText {
    if (_lastLocationUpdateTime == null) return 'Updated now';
    final diff = DateTime.now().difference(_lastLocationUpdateTime!);
    if (diff.inMinutes < 1) return 'Updated now';
    if (diff.inMinutes == 1) return 'Updated 1 min ago';
    return 'Updated ${diff.inMinutes} mins ago';
  }

  @override
  // Lifecycle method called once when the stateful widget initialized for the first time
  void initState() {
    // Lifecycle method called once when the stateful widget initialized for the first time
    super.initState();
    debugPrint('[RUNTIME_TRACE] ENTER HomeTab (home_tab.dart)');
    debugPrint('[PERF_HOME] HomeTab initState epoch=${DateTime.now().millisecondsSinceEpoch}');
    // Register this widget state class to listen to application lifecycle updates (resumed, paused)
    WidgetsBinding.instance.addObserver(this);

    // Register listener for location cache updates
    LocationCacheService.addListener(_onLocationCacheUpdated);

    // Feature 1: start the realtime-driven unread notification badge (safe to call repeatedly).
    NotificationBadgeService.instance.startListening();

    // Initialize location permission, GPS, and serviceability from cache immediately
    final hasCache = LocationCacheService.cachedPosition != null;
    _hasLocationPermission = hasCache;
    _gpsEnabled = hasCache;
    if (hasCache) {
      _isLocationServiceable = LocationCacheService.isServiceable;
    }

    final initialData = ref.read(initialUserDataProvider);
    if (initialData != null) {
      userProfile = initialData.userProfile;
      riderProfile = initialData.riderProfile;
      kycProfile = initialData.kycProfile;
      recentOrders = initialData.recentOrders;
      loading = false;
    }

    // B3: AppStartScreen already fetched this tab's data into
    // initialUserDataProvider — skip the duplicate first fetch; the 30s
    // fallback, resume, and realtime callbacks still perform full refreshes.
    _load(useInitialData: initialData != null);
    _initializeLocationFlow();
    _startSilentRefreshTimer();
  }

  void _onLocationCacheUpdated() {
    if (!mounted) return;
    // Update the widget state to trigger a UI rebuild with the new variables
    setState(() {
      _currentPosition = LocationCacheService.cachedPosition;
      _isLocationServiceable = LocationCacheService.isServiceable;
      _hasLocationPermission = LocationCacheService.cachedPosition != null;
      _gpsEnabled = LocationCacheService.cachedPosition != null;
      _lastLocationUpdateTime = LocationCacheService.lastUpdated;
    });

    if (_isLocationPromptShowing &&
        LocationCacheService.cachedPosition != null &&
        _locationPromptContext != null) {
      Navigator.of(_locationPromptContext!).pop();
    }
  }

  void _startSilentRefreshTimer() {
    _silentRefreshTimer?.cancel();
    // Setup a timer instance for delayed execution or polling intervals
    _silentRefreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (!mounted) return;
      // Realtime-health gate: realtime already refreshed this tab's data
      // within the last period, so the full _load() would be a duplicate.
      // Falls back to the full refresh when realtime is quiet or stale.
      final lastEvent = _lastRealtimeEventAt;
      if (lastEvent != null &&
          DateTime.now().difference(lastEvent) <
              const Duration(seconds: 30)) {
        return;
      }
      // Egress fix: skip this background refresh if recent attempts have been
      // failing (Supabase throttle/outage) -- doesn't affect initState/resume/
      // realtime-callback calls to _load(), only this passive timer.
      if (!_refreshBackoff.shouldAttempt()) return;
      _load();
    });
  }

  @override
  // Lifecycle method called before the widget is removed permanently from the tree to clean resources
  void dispose() {
    LocationCacheService.removeListener(_onLocationCacheUpdated);
    _silentRefreshTimer?.cancel();
    _locationCheckTimer?.cancel();
    _cooldownTimer?.cancel();
    _cooldownTicker.dispose();
    // Unregister lifecycle observers to prevent callbacks when the widget is dead
    WidgetsBinding.instance.removeObserver(this);
    if (channel != null) {
      // Perform an asynchronous database operation using the Supabase client wrapper
      supabase.removeChannel(channel!);
      channel = null;
    }
    if (_homeActiveOrdersSubId != null && _homeActiveOrdersChannelName != null) {
      // Remove the real-time Postgres subscription to release memory resources.
      // Uses the channel name captured at subscribe time (not the current auth
      // user) so this still unsubscribes correctly even if the user has already
      // signed out by the time this widget is disposed.
      RealtimeManager.instance.unsubscribe(
        _homeActiveOrdersChannelName!,
        _homeActiveOrdersSubId!,
      );
      _homeActiveOrdersSubId = null;
      _homeActiveOrdersChannelName = null;
    }
    // Lifecycle method called before the widget is removed permanently from the tree to clean resources
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkLocationPermission();
      _load();
    }
  }

  Future<void> _initializeLocationFlow() async {
    try {
      // Request location permissions or fetch GPS coordinates from the device hardware
      LocationPermission permission = await Geolocator.checkPermission();
      // Request location permissions or fetch GPS coordinates from the device hardware
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      final hasPerm =
          (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse);

      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          _hasLocationPermission = hasPerm;
          _gpsEnabled = serviceEnabled;
        });
      }

      if (hasPerm && serviceEnabled) {
        _getCurrentLocation();
      } else {
        // If we don't have location permission AND no manual mock location, always prompt to setup location!
        if (LocationCacheService.manualMockLat == null) {
          _showLocationSetupPrompt();
        } else {
          _updateServiceability();
        }
      }
    } catch (e) {
      debugPrint('Error initializing location flow: $e');
    }
  }

  void _showLocationSetupPrompt() {
    if (!mounted) return;
    if (_isLocationPromptShowing) return;
    _isLocationPromptShowing = true;
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;

    SharedPreferences.getInstance()
        .then((prefs) {
          prefs.setInt(
            'last_location_prompt_shown_at',
            DateTime.now().millisecondsSinceEpoch,
          );
        })
        .catchError((_) => null);

    // Present a premium modal bottom sheet drawer for user input/actions
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: isDark ? const Color(0xFF171A21) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetCtx) {
        _locationPromptContext = sheetCtx;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox.shrink(),
              const SizedBox(height: 24),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.location_on_rounded,
                    color: Color(0xFF10B981),
                    size: 36,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Set Your Location',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'WayDrop needs to know your location to show available ride options and nearby Drop Partners.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF64748B),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 28),
              ElevatedButton.icon(
                icon: const Icon(
                  Icons.my_location_rounded,
                  color: Colors.white,
                  size: 18,
                ),
                label: const Text(
                  'Use Current Location',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                onPressed: () async {
                  // Close/pop the current screen or modal bottom sheet context
                  Navigator.pop(sheetCtx);
                  await _requestLocationPermissionAndLocate();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.search_rounded, size: 18),
                label: const Text(
                  'Select Location Manually',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                onPressed: () {
                  // Close/pop the current screen or modal bottom sheet context
                  Navigator.pop(sheetCtx);
                  _selectLocation();
                },
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: isDark ? Colors.white24 : const Color(0xFFCBD5E1),
                  ),
                  foregroundColor: isDark
                      ? Colors.white
                      : const Color(0xFF0F172A),
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ).then((_) {
      _isLocationPromptShowing = false;
      _locationPromptContext = null;
    });
  }

  Future<void> _requestLocationPermissionAndLocate() async {
    try {
      // Request location permissions or fetch GPS coordinates from the device hardware
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.deniedForever) {
        _showDeniedForeverDialog();
        return;
      }

      // Request location permissions or fetch GPS coordinates from the device hardware
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.deniedForever) {
        _showDeniedForeverDialog();
        return;
      }

      final hasPerm =
          (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse);
      // Request location permissions or fetch GPS coordinates from the device hardware
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();

      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          _hasLocationPermission = hasPerm;
          _gpsEnabled = serviceEnabled;
        });
      }

      if (hasPerm && serviceEnabled) {
        _getCurrentLocation();
      } else {
        _showLocationSetupPrompt();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Location permission denied. Please select your location manually.',
              ),
              backgroundColor: Color(0xFFEF4444),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error requesting location permission: $e');
    }
  }

  void _showDeniedForeverDialog() {
    if (!mounted) return;
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Show an overlay dialog window on the screen for user decision
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF171A21) : Colors.white,
        title: const Text('Location Access Permanently Disabled'),
        content: const Text(
          'Location access is permanently disabled in system settings. Please open app settings to enable it, or choose to set location manually.',
        ),
        actions: [
          TextButton(
            // Close/pop the current screen or modal bottom sheet context
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
            ),
            onPressed: () async {
              // Close/pop the current screen or modal bottom sheet context
              Navigator.pop(context);
              // Request location permissions or fetch GPS coordinates from the device hardware
              await Geolocator.openAppSettings();
            },
            child: const Text(
              'Open Settings',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _checkLocationPermission() async {
    try {
      // Request location permissions or fetch GPS coordinates from the device hardware
      LocationPermission permission = await Geolocator.checkPermission();
      // Request location permissions or fetch GPS coordinates from the device hardware
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      final hasPerm =
          (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse);

      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          _hasLocationPermission = hasPerm;
          _gpsEnabled = serviceEnabled;
        });
      }

      if (hasPerm && serviceEnabled) {
        _getCurrentLocation();
      }
    } catch (e) {
      debugPrint('Error checking location permission: $e');
    }
  }



  Future<void> _getCurrentLocation() async {
    if (_isLocating) return;
    _isLocating = true;
    try {
      // 1. Check if the location is already cached and valid in LocationCacheService
      if (LocationCacheService.cachedPosition != null) {
        if (mounted) {
          // Update the widget state to trigger a UI rebuild with the new variables
          setState(() {
            _currentPosition = LocationCacheService.cachedPosition;
          });
          await _updateServiceability();
        }
        if (LocationCacheService.hasValidCache) {
          _isLocating = false;
          // Update the widget state to trigger a UI rebuild with the new variables
          if (mounted) setState(() {});
          return;
        }
      }

      // 2. Fetch/wait for fresh position from LocationCacheService
      await LocationCacheService.initializeLocation();
      
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          _currentPosition = LocationCacheService.cachedPosition;
        });
        await _updateServiceability();
      }
    } catch (e) {
      debugPrint('Error getting current location: $e');
    } finally {
      _isLocating = false;
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {});
      }
    }
  }

  Future<void> _updateServiceability() async {
    final lat = _currentLat;
    final lng = _currentLng;
    final address = _currentAddress;

    if (lat == null || lng == null) {
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          _isLocationServiceable = true;
        });
      }
      return;
    }

    await ServiceabilityService.loadActiveZones();

    String resolvedAddress = address;
    String? resolvedCity;
    if (resolvedAddress == 'Fetching location...' ||
        resolvedAddress.isEmpty ||
        resolvedAddress == 'Location Permission Off') {
      try {
        // Reverse-geocode coordinates into a human-readable street address using Ola Maps API
        final olaAddressResult = await OlaMapService.reverseGeocode(
          latitude: lat,
          longitude: lng,
        );
        final formattedAddress =
            olaAddressResult['formatted_address']?.toString() ?? '';
        resolvedCity = olaAddressResult['city']?.toString() ?? '';
        if (formattedAddress.isNotEmpty) {
          resolvedAddress = formattedAddress;
        }
      } catch (e) {
        debugPrint('Error reverse geocoding in _updateServiceability: $e');
      }
    }

    if (!mounted) return;

    resolvedCity ??= (_mockAddress != null
        ? ''
        : (LocationCacheService.cachedCity ?? ''));

    final result = await ServiceabilityService.isLocationServiceable(
      address: resolvedAddress,
      latitude: lat,
      longitude: lng,
      city: resolvedCity.isEmpty ? null : resolvedCity,
    );

    if (_mockAddress != null) {
      await _updateMockLocation(_mockLatitude, _mockLongitude, resolvedAddress);
    }
    if (mounted) {
      // Update the widget state to trigger a UI rebuild with the new variables
      setState(() {
        _isLocationServiceable = result.isServiceable;
        _lastLocationUpdateTime = DateTime.now();
      });
      LocationCacheService.isServiceableNotifier.value = result.isServiceable;
    }
  }

  Future<void> _checkServiceabilityOnInit() async {
    if (_hasCheckedServiceabilityOnInit) return;
    if (!_hasLocationPermission) return;
    await _updateServiceability();
    _hasCheckedServiceabilityOnInit = true;
  }

  Future<void> _load({bool useInitialData = false}) async {
    final Stopwatch perfLoad = Stopwatch()..start();
    try {
      // Perform an asynchronous database operation using the Supabase client wrapper
      final user = supabase.auth.currentUser;
      if (user == null) {
        if (mounted) {
          // Update the widget state to trigger a UI rebuild with the new variables
          setState(() {
            loading = false;
          });
        }
        return;
      }

      // B3: On the initial mount, AppStartScreen already fetched this exact
      // dataset (users/riders/rider_kyc/orders) into initialUserDataProvider,
      // and initState applied it above — skip the 4 redundant queries. All
      // later refreshes (resume, 30s fallback, realtime callbacks) still run
      // the full query; the side effects below run in both paths.
      final bool skipQuery =
          useInitialData && ref.read(initialUserDataProvider) != null;

      if (!skipQuery) {
        final Stopwatch perfQuery = Stopwatch()..start();
        // Egress fix: this screen only ever reads userProfile['full_name'],
        // riderProfile['id'], and kycProfile['id'/'blocked_until'/'kyc_status']
        // (grepped exhaustively) -- projected instead of pulling full rows
        // (which include KYC document URLs/numbers on rider_kyc) on every
        // initState, 30s silent refresh, resume, and realtime callback.
        final userFuture = supabase
            .from('users')
            .select('full_name')
            .eq('id', user.id)
            .maybeSingle();
        final riderFuture = supabase
            .from('riders')
            .select('id')
            .eq('user_id', user.id)
            .maybeSingle();
        final kycFuture = supabase
            .from('rider_kyc')
            .select('id, blocked_until, kyc_status')
            .eq('user_id', user.id)
            .maybeSingle();
        // Egress fix: narrowed from `*` to the exact fields read off `order` below (grepped
        // exhaustively). limit(10) intentionally unchanged -- the display logic re-sorts to
        // promote active orders before slicing to the 4 shown, so fewer candidates risks dropping
        // an active order that isn't in the newest 4 by created_at.
        final ordersFuture = supabase
            .from('orders')
            .select(
              'id, order_type, order_status, created_at, final_fare, current_fare, '
              'distance_meters, pickup_address, destination_address, pickup_lat, pickup_lng, '
              'destination_lat, destination_lng, time_taken_seconds, estimated_duration_min, '
              'receiver_name, receiver_phone, parcel_type, weight_category, '
              'special_instructions',
            )
            .eq('user_id', user.id)
            .inFilter('order_status', [
              'created',
              'searching',
              'expired',
              'accepted',
              'rider_arrived',
              'picked_up',
              'ongoing',
              'rider_at_drop',
              'payment_pending',
              'completed',
              'delivered',
              'cancelled',
            ])
            .order('created_at', ascending: false)
            .limit(10);

        // Execute multiple future tasks concurrently to optimize screen load times
        final results = await Future.wait([
          userFuture,
          riderFuture,
          kycFuture,
          ordersFuture,
        ]);
        debugPrint('[PERF_HOME] _load 4-query batch took ${perfQuery.elapsedMilliseconds}ms epoch=${DateTime.now().millisecondsSinceEpoch}');
        if (!mounted) return;

        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() {
          userProfile = results[0] as Map<String, dynamic>?;
          riderProfile = results[1] as Map<String, dynamic>?;
          kycProfile = results[2] as Map<String, dynamic>?;

          final List<Map<String, dynamic>> rawOrders =
              List<Map<String, dynamic>>.from(results[3] as List);
          // Sort active rides to the first, chronological descending.
          // 'expired' (abandoned searches the backend cron already gave up on) is intentionally
          // excluded from this "active" bucket -- it's a terminal state, and including it here
          // was letting old abandoned searches float above genuinely newer completed orders.
          rawOrders.sort((a, b) {
            final aStatus = a['order_status']?.toString() ?? 'completed';
            final bStatus = b['order_status']?.toString() ?? 'completed';
            final aActive = [
              'created',
              'searching',
              'accepted',
              'rider_arrived',
              'picked_up',
              'ongoing',
              'rider_at_drop',
              'payment_pending',
            ].contains(aStatus);
            final bActive = [
              'created',
              'searching',
              'accepted',
              'rider_arrived',
              'picked_up',
              'ongoing',
              'rider_at_drop',
              'payment_pending',
            ].contains(bStatus);

            if (aActive && !bActive) return -1;
            if (!aActive && bActive) return 1;

            final aTime =
                DateTime.tryParse(a['created_at']?.toString() ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0);
            final bTime =
                DateTime.tryParse(b['created_at']?.toString() ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0);
            return bTime.compareTo(aTime);
          });

          recentOrders = rawOrders.take(4).toList();
          loading = false;
        });
      }
      debugPrint('[PERF_HOME] _load total ${perfLoad.elapsedMilliseconds}ms (skipQuery=$skipQuery) epoch=${DateTime.now().millisecondsSinceEpoch}');

      _startCooldownTimerIfNeeded();
      _subscribeRealtime(user.id);
      _subscribeActiveOrders(user.id);
      _checkServiceabilityOnInit();
      _refreshBackoff.recordSuccess();
    } catch (e) {
      _refreshBackoff.recordFailure();
      // Update the widget state to trigger a UI rebuild with the new variables
      if (mounted) setState(() => loading = false);
    }
  }

  void _startCooldownTimerIfNeeded() {
    _cooldownTimer?.cancel();
    final String? blockedUntilStr = kycProfile?['blocked_until'];
    if (blockedUntilStr != null) {
      final blockedUntil = DateTime.tryParse(blockedUntilStr);
      if (blockedUntil != null && blockedUntil.isAfter(DateTime.now())) {
        // Setup a timer instance for delayed execution or polling intervals
        bool expiryHandled = false; // closure-local one-shot (Issue #1B)
        _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (mounted) {
            // [PERF] Issue #1B: drive only the countdown text, no full-tab rebuild.
            final now = DateTime.now();
            _cooldownTicker.value = now;
            if (blockedUntil.isBefore(now)) {
              _cooldownTimer?.cancel();
              if (!expiryHandled) {
                expiryHandled = true;
                _handleCooldownExpiry();
              }
            }
          }
        });
      }
    }
  }

  // [PERF] Issue #1B: the single parent rebuild at expiry so the card flips
  // Blocked → Normal exactly on time. Invoked only from the timer callback.
  void _handleCooldownExpiry() {
    if (!mounted) return;
    setState(() {});
  }

  // R2 FIX (Passenger Home realtime GPS rebuild): the exact `riders` columns
  // LocationCacheService.updateRiderLocation() writes on every GPS heartbeat/movement update --
  // same allowlist as RiderHomeTab._locationHeartbeatFields/RiderOrdersScreen.listenRiderStatus()'s
  // isLocationOnlyUpdate gate, which this mirrors verbatim. Grepped exhaustively: this screen only
  // ever reads riderProfile?['id'] (self-referential, for the subscription's own dedup) and
  // riderProfile != null (an existence check for the dual-mode CTA) -- no UI or logic here reads
  // any GPS/location column off riderProfile, so a `riders` UPDATE confined to these columns can
  // never affect anything rendered by this screen. Kept as an explicit allowlist (not a blocklist)
  // so any *new* field this screen starts depending on in the future safely falls through to a
  // refresh by default instead of silently being ignored.
  static const Set<String> _locationHeartbeatFields = {
    'current_lat',
    'current_lng',
    'current_heading',
    'last_location_updated_at',
    'last_active_at',
    'updated_at',
  };

  void _subscribeRealtime(String userId) {
    final riderId = riderProfile?['id']?.toString();
    final kycId = kycProfile?['id']?.toString();

    if (_subscribedUserId == userId &&
        _subscribedRiderId == riderId &&
        _subscribedKycId == kycId) {
      return; // Already correctly subscribed
    }
    _subscribedUserId = userId;
    _subscribedRiderId = riderId;
    _subscribedKycId = kycId;

    if (channel != null) {
      // Perform an asynchronous database operation using the Supabase client wrapper
      supabase.removeChannel(channel!);
      channel = null;
    }

    var builder = supabase
        .channel('home-realtime-$userId')
        // Setup a dynamic event handler for incoming database insert, update, or delete notifications
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'users',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: userId,
          ),
          callback: (payload) {
            if (!mounted) return;
            _lastRealtimeEventAt = DateTime.now();
            // Update the widget state to trigger a UI rebuild with the new variables
            setState(
              () => userProfile = Map<String, dynamic>.from(payload.newRecord),
            );
          },
        );

    if (kycId != null) {
      // Setup a dynamic event handler for incoming database insert, update, or delete notifications
      builder = builder.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'rider_kyc',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
          value: kycId,
        ),
        callback: (payload) {
          if (!mounted) return;
          _lastRealtimeEventAt = DateTime.now();
          // Update the widget state to trigger a UI rebuild with the new variables
          setState(() {
            if (payload.eventType == PostgresChangeEvent.delete) {
              kycProfile = null;
            } else {
              kycProfile = Map<String, dynamic>.from(payload.newRecord);
            }
          });
          _startCooldownTimerIfNeeded();
        },
      );
    }

    if (riderId != null) {
      // Setup a dynamic event handler for incoming database insert, update, or delete notifications
      builder = builder.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'riders',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
          value: riderId,
        ),
        callback: (payload) {
          if (!mounted) return;
          // R2 FIX (Passenger Home realtime GPS rebuild): skip this event entirely -- no
          // _lastRealtimeEventAt stamp, no setState -- when it's an UPDATE confined to GPS
          // heartbeat columns. Scoped to eventType == update only, so INSERT/DELETE (this
          // subscription's event: .all covers both) are never gated. Conservative fallback
          // (matches RiderHomeTab's own gating): if oldRecord is empty (no diff available), every
          // key counts as changed, so this still falls through to the existing unconditional
          // behavior below instead of silently skipping.
          if (payload.eventType == PostgresChangeEvent.update) {
            final oldRecord = payload.oldRecord;
            final newRecord = payload.newRecord;
            final isLocationOnlyUpdate = oldRecord.isNotEmpty &&
                newRecord.keys.every((key) =>
                    !oldRecord.containsKey(key) ||
                    oldRecord[key] == newRecord[key] ||
                    _locationHeartbeatFields.contains(key));
            if (isLocationOnlyUpdate) return;
          }
          _lastRealtimeEventAt = DateTime.now();
          // Update the widget state to trigger a UI rebuild with the new variables
          setState(() {
            if (payload.eventType == PostgresChangeEvent.delete) {
              riderProfile = null;
            } else {
              riderProfile = Map<String, dynamic>.from(payload.newRecord);
            }
          });
        },
      );
    }

    channel = builder.subscribe();
  }

  // P8 FIX #4 (passenger home duplicate active-order query): this used to be
  // _checkForActiveOrder(), a second `orders` query run on every _load() call (init, the 30s
  // timer, app resume, every realtime order event). Tracing every read of its result proved it
  // was dead: the query's own `.inFilter('order_type', ['ride', 'intercity_ride',
  // 'ride_sharing'])` guarantees the fetched row's order_type can never be
  // 'local_parcel'/'intercity_parcel'/'food_delivery'/'grocery_delivery'/'batch_delivery' -- so
  // the only code that read the result (an "if it's a parcel/delivery type, return" check) could
  // never fire, and nothing else in the function used the fetched row at all (no navigation, no
  // state, no return value consumed by the one call site, which didn't even await it). Grepped
  // repo-wide: `_checkForActiveOrder` had exactly one call site (here) and no other references,
  // including in test/. Removing the query (and the unreachable conditional that was its only
  // consumer) is therefore behavior-preserving by construction, not an approximation reusing
  // _load()'s own already-fetched batch would have been (that batch is `.limit(10)` across ALL
  // order types before any ride-type filtering, so it isn't provably a superset of what this
  // query would return for a user with more than 10 total recent orders -- reusing it would have
  // traded one duplicate query for an unproven edge case, for a value nothing reads either way).
  // The actual "active order -> navigate to tracking" behavior lives entirely in
  // _subscribeActiveOrders()'s realtime callback below, which this never fed into and is
  // untouched.

  void _subscribeActiveOrders(String userId) {
    if (_homeActiveOrdersSubId != null && _homeActiveOrdersChannelName != null) {
      // Remove the real-time Postgres subscription to release memory resources
      RealtimeManager.instance.unsubscribe(
        _homeActiveOrdersChannelName!,
        _homeActiveOrdersSubId!,
      );
      _homeActiveOrdersSubId = null;
      _homeActiveOrdersChannelName = null;
    }

    // Subscribe to Postgres database updates in real-time to auto-sync layout data
    _homeActiveOrdersChannelName = 'home-active-orders-$userId';
    _homeActiveOrdersSubId = RealtimeManager.instance.subscribe(
      channelName: _homeActiveOrdersChannelName!,
      table: 'orders',
      owner: 'HomeTab',
      event: PostgresChangeEvent.all,
      filterColumn: 'user_id',
      filterValue: userId,
      callback: (payload) {
        if (!mounted) return;
        _lastRealtimeEventAt = DateTime.now();

        if (payload.eventType == PostgresChangeEvent.delete) {
          final oldRecord = payload.oldRecord;
          if (oldRecord.isNotEmpty && oldRecord['user_id'] == userId) {
            _lastOrderStateHash = ""; // reset hash to allow forced reload
            _load();
          }
          return;
        }

        final record = payload.newRecord;
        if (record.isEmpty) return;
        if (record['user_id'] != userId) return;

        final status = record['order_status'];
        final riderId = record['rider_id'];
        final orderId = record['id'];

        // Distinct until changed check to avoid redundant _load calls
        final stateHash = "${orderId}_${status}_$riderId";
        if (stateHash == _lastOrderStateHash) return;
        _lastOrderStateHash = stateHash;

        // Reload recent orders list in real-time
        _load();

        final orderType = record['order_type']?.toString() ?? '';
        final distanceMeters =
            double.tryParse(record['distance_meters']?.toString() ?? '') ?? 0.0;
        final isLocalParcel = orderType == 'local_parcel';
        final isIntercityParcel = orderType == 'intercity_parcel';
        final isIntercityRide =
            orderType == 'intercity_ride' ||
            (orderType == 'ride' && distanceMeters > 20000);
        final isCurrent = ModalRoute.of(context)?.isCurrent ?? false;

        // Do not auto-redirect for parcel or delivery orders
        if (orderType == 'local_parcel' ||
            orderType == 'intercity_parcel' ||
            orderType == 'food_delivery' ||
            orderType == 'grocery_delivery' ||
            orderType == 'batch_delivery') {
          return;
        }

        if (isCurrent) {
          if ([
            'accepted',
            'rider_arrived',
            'picked_up',
            'ongoing',
            'rider_at_drop',
            'payment_pending',
          ].contains(status)) {
            // Navigate to a new screen layout using Flutter's Navigator router
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) {
                  if (isLocalParcel) {
                    return ParcelTrackingScreen(orderId: orderId);
                  }
                  if (isIntercityParcel || isIntercityRide) {
                    return IntercityTrackingScreen(orderId: orderId);
                  }
                  return RideTrackingScreen(orderId: orderId);
                },
              ),
            );
          }
        }
      },
    );
  }

  Future<void> _switchToRider() async {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.shrink(),
            const SizedBox(height: 20),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF14532D).withValues(alpha: 0.2)
                    : const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.swap_horiz_rounded,
                color: Color(0xFF10B981),
                size: 30,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Switch to Drop Partner Mode?',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'You will switch to rider view to accept jobs and start earning.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: isDark
                    ? const Color(0xFF94A3B8)
                    : const Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    // Close/pop the current screen or modal bottom sheet context
                    onPressed: () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                        color: isDark
                            ? Colors.white24
                            : const Color(0xFFCBD5E1),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      minimumSize: const Size.fromHeight(52),
                    ),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    // Close/pop the current screen or modal bottom sheet context
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      minimumSize: const Size.fromHeight(52),
                    ),
                    child: const Text(
                      'Switch',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;

    ref
        .read(modeSwitchOverlayProvider.notifier)
        .trigger(
          asyncAction: () async {
            await RiderStatusService.switchToRiderMode();
            ref.read(appModeProvider.notifier).switchToRider();
          },
          onMidpoint: () {
            Navigator.pushAndRemoveUntil(
              context,
              PageRouteBuilder(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    const RiderMainNavigationScreen(),
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
              ),
              (_) => false,
            );
          },
          onError: (err) {
            final errorMsg = err.toString();
            if (errorMsg.contains('Payout details not registered')) {
              // Navigate to a new screen layout using Flutter's Navigator router
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const RiderPayoutDetailsScreen(),
                ),
              );
            } else if (errorMsg.contains('Service Mode not chosen')) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ServiceModeSelectionScreen(),
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(errorMsg.replaceFirst('Exception: ', '')),
                  backgroundColor: const Color(0xFFEF4444),
                ),
              );
            }
          },
        );
  }

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  // Build method responsible for rendering the entire widget layout hierarchy on the viewport
  Widget build(BuildContext context) {
    final initialData = ref.watch(initialUserDataProvider);
    final shouldShowSkeleton =
        initialData == null && !LocationCacheService.isInitialized;
    if (!shouldShowSkeleton) _contentBuildCount++;

    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFFE2E8F0);

    final fullName = userProfile?['full_name']?.toString() ?? 'WayDrop User';
    final String? blockedUntilStr = kycProfile?['blocked_until'];
    bool isBlocked = false;
    if (blockedUntilStr != null) {
      final blockedUntil = DateTime.tryParse(blockedUntilStr);
      if (blockedUntil != null && blockedUntil.isAfter(DateTime.now())) {
        isBlocked = true;
      }
    }
    final kycStatus = isBlocked
        ? 'blocked'
        : kycProfile?['kyc_status']?.toString();
    final hasKyc = kycProfile != null;


    return Scaffold(
      // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: shouldShowSkeleton
            ? const SkeletonLoader()
            : SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  ResponsiveLayout.horizontalPadding(context),
                  16,
                  ResponsiveLayout.horizontalPadding(context),
                  16 + 96 + Insets.bottom(context),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Header Row ──────────────────────
                    _animateEntrance(
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '$_greeting 👋',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: isDark ? const Color(0xFF94A3B8) : WayDropColors.secondaryText,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  fullName.split(' ')[0],
                                  style: TextStyle(
                                    fontSize: 32,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -1.0,
                                    color: textColor,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Where are you going today?',
                                  style: TextStyle(
                                    fontSize: 14.5,
                                    color: isDark ? const Color(0xFF94A3B8) : WayDropColors.secondaryText,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => const NotificationsInboxScreen()),
                              );
                            },
                            child: NotificationBellBadge(
                              child: Container(
                                width: 44,
                                height: 44,
                                margin: const EdgeInsets.only(right: 10),
                                decoration: BoxDecoration(
                                  color: isDark ? const Color(0xFF1E293B) : WayDropColors.emeraldLight,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: WayDropColors.primaryEmerald.withValues(alpha: 0.15),
                                    width: 1.5,
                                  ),
                                ),
                                child: const Center(
                                  child: Icon(
                                    Icons.notifications_none_rounded,
                                    color: WayDropColors.primaryEmerald,
                                    size: 24,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              context.findAncestorStateOfType<MainNavigationScreenState>()?.setIndex(3);
                            },
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF1E293B) : WayDropColors.emeraldLight,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: WayDropColors.primaryEmerald.withValues(alpha: 0.15),
                                  width: 1.5,
                                ),
                              ),
                              child: const Center(
                                child: Icon(
                                  Icons.person_rounded,
                                  color: WayDropColors.primaryEmerald,
                                  size: 24,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      0,
                      disableAnimations,
                    ),

                    // ── Developer Test Mode Indicator ───────────────────────
                    if (DeveloperModeService.instance.isDeveloperTestModeEnabled) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: isDark ? 0.18 : 0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.bug_report_rounded, color: Colors.orange, size: 16),
                            const SizedBox(width: 6),
                            Text(
                              'Developer Test Mode — service area checks bypassed',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: isDark ? Colors.orange.shade200 : Colors.orange.shade800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),

                    // ── Location Selector Bar ───────────────────────────────
                    _animateEntrance(
                      _buildLocationSelectorBar(isDark, textColor, borderColor),
                      80,
                      disableAnimations,
                    ),
                    const SizedBox(height: 20),

                    // ── Service Unavailable Warning Banner ──────────────────
                    if (!_isLocationServiceable) ...[
                      _animateEntrance(
                        _buildNotServiceableView(isDark, textColor, borderColor),
                        160,
                        disableAnimations,
                      ),
                    ] else ...[
                      // ── Quick Services (Search Bar & Categories) ──────────
                      _animateEntrance(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Quick Services',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900,
                                    color: textColor,
                                    letterSpacing: -0.5,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                _buildServiceBubble(
                                  label: 'Ride',
                                  imagePath: 'assets/images/ride.png',
                                  icon: Icons.directions_car_rounded,
                                  color: const Color(0xFF10B981),
                                  isDark: isDark,
                                  textColor: textColor,
                                  borderColor: borderColor,
                                  // Phase 1 production control: ride_booking_enabled/local_rides_enabled are
                                  // remote kill switches (production_config), independent of location
                                  // serviceability -- the actual booking call is additionally enforced
                                  // server-side in create-order.
                                  isDisabled: !FeatureFlags.rideBookingEnabled || !FeatureFlags.localRidesEnabled,
                                  disabledMessage: 'Ride booking is temporarily unavailable. Please try again later.',
                                  onTap: () {
                                    if (!_isLocationServiceable) {
                                      return;
                                    }
                                    // Navigate to a new screen layout using Flutter's Navigator router
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => RideLocationScreen(
                                          orderType: 'ride',
                                          prefillPickupAddress:
                                              _currentAddress.isNotEmpty &&
                                                  _currentAddress !=
                                                      'Location services disabled' &&
                                                  _currentAddress !=
                                                      'Location permission off' &&
                                                  _currentAddress !=
                                                      'Fetching location...'
                                              ? _currentAddress
                                              : null,
                                          prefillPickupLat: _currentLat,
                                          prefillPickupLng: _currentLng,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                _buildServiceBubble(
                                  label: 'Parcel',
                                  imagePath: 'assets/images/parcel.png',
                                  icon: Icons.inventory_2_rounded,
                                  color: const Color(0xFF059669),
                                  isDark: isDark,
                                  textColor: textColor,
                                  borderColor: borderColor,
                                  // Phase 1 production control: remote kill switch (production_config) --
                                  // the actual booking call is additionally enforced server-side in
                                  // create-order.
                                  isDisabled: !FeatureFlags.parcelEnabled,
                                  disabledMessage: 'Parcel booking is temporarily unavailable. Please try again later.',
                                  onTap: () {
                                    if (!_isLocationServiceable) {
                                      return;
                                    }
                                    // Navigate to a new screen layout using Flutter's Navigator router
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ParcelDetailsScreen(
                                          orderType: 'local_parcel',
                                          pickupAddress:
                                              _currentAddress.isNotEmpty &&
                                                  _currentAddress !=
                                                      'Location services disabled' &&
                                                  _currentAddress !=
                                                      'Location permission off' &&
                                                  _currentAddress !=
                                                      'Fetching location...'
                                              ? _currentAddress
                                              : null,
                                          pickupLat: _currentLat,
                                          pickupLng: _currentLng,
                                          pickupCity: LocationCacheService.cachedCity,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                _buildServiceBubble(
                                  label: 'Intercity',
                                  imagePath: 'assets/images/intercity.png',
                                  icon: Icons.explore_rounded,
                                  color: const Color(0xFF7C3AED),
                                  isDark: isDark,
                                  textColor: textColor,
                                  borderColor: borderColor,
                                  badgeText: 'New',
                                  // Phase 1 production control: covers both intercity_ride and
                                  // intercity_parcel -- the actual booking call is additionally
                                  // enforced server-side in create-order.
                                  isDisabled: !FeatureFlags.intercityEnabled,
                                  disabledMessage: 'Intercity booking is temporarily unavailable. Please try again later.',
                                  onTap: () {
                                    _showIntercityBookingChooser(context, isDark);
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                        160,
                        disableAnimations,
                      ),
                      const SizedBox(height: 20),

                      // ── Rider Hero Card ───────────────────────────────────
                      _animateEntrance(
                        _buildDynamicRiderCard(kycStatus, hasKyc),
                        240,
                        disableAnimations,
                      ),
                      const SizedBox(height: 20),

                      // ── Recent Activity / Your First Journey Awaits ───────
                      _animateEntrance(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Recent Activity',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900,
                                    color: textColor,
                                    letterSpacing: -0.5,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                                if (recentOrders.isNotEmpty)
                                  TextButton(
                                    onPressed: () {
                                      context
                                          .findAncestorStateOfType<
                                            MainNavigationScreenState
                                          >()
                                          ?.setIndex(2);
                                    },
                                    child: const Text(
                                      'View All',
                                      style: TextStyle(
                                        color: Color(0xFF10B981),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (recentOrders.isEmpty) ...[
                              _buildFirstRideCard(isDark, textColor),
                            ] else ...[
                              SizedBox(
                                height: 155,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  physics: const ClampingScrollPhysics(),
                                  itemCount: recentOrders.length,
                                  separatorBuilder: (_, index) =>
                                      const SizedBox(width: 14),
                                  itemBuilder: (context, index) {
                                    final order = recentOrders[index];
                                    return _buildRecentRideCard(
                                      context,
                                      order,
                                      isDark,
                                      textColor,
                                    );
                                  },
                                ),
                              ),
                            ],
                          ],
                        ),
                        320,
                        disableAnimations,
                      ),
                      const SizedBox(height: 20),

                      const SizedBox(
                        height: 120,
                      ), // padding for navigation capsule
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  void _selectLocation() {
    final currentAddr = _currentAddress;
    final isGenericText =
        currentAddr == 'Location services disabled' ||
        currentAddr == 'Location permission off' ||
        currentAddr == 'Fetching location...' ||
        currentAddr.isEmpty;

    // Navigate to a new screen layout using Flutter's Navigator router
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HomeLocationScreen(
          prefillAddress: isGenericText ? null : currentAddr,
          prefillLat: _currentLat,
          prefillLng: _currentLng,
        ),
      ),
    ).then((result) {
      if (result != null && result is Map<String, dynamic>) {
        _updateMockLocation(
          result['latitude'],
          result['longitude'],
          result['address'],
        ).then((_) {
          _updateServiceability();
        });
      }
    });
  }

  Widget _buildLocationSelectorBar(
    bool isDark,
    Color textColor,
    Color borderColor,
  ) {
    String displayAddress = _currentAddress;

    final bool isUnserviceableOrGpsUnavailable = _mockAddress == null
        ? (!_gpsEnabled || !_hasLocationPermission || !_isLocationServiceable)
        : !_isLocationServiceable;

    final bool isGenericAddress =
        displayAddress == 'Location services disabled' ||
        displayAddress == 'Location permission off' ||
        displayAddress == 'Fetching location...' ||
        displayAddress.isEmpty;

    if (_mockAddress == null && isGenericAddress) {
      displayAddress = 'Select pickup point';
    }

    final pinColor = isUnserviceableOrGpsUnavailable
        ? const Color(0xFFEF4444)
        : const Color(0xFF10B981);

    return WayDropCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      borderRadius: 18,
      onTap: _selectLocation,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // Large glowing circle pin like Google Maps (Compact)
              Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: pinColor.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: pinColor.withValues(alpha: 0.25),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Icon(
                    Icons.location_pin,
                    color: isUnserviceableOrGpsUnavailable
                        ? const Color(0xFFEF4444)
                        : WayDropColors.primaryEmerald,
                    size: 16,
                  ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pickup Location',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark ? const Color(0xFF94A3B8) : WayDropColors.secondaryText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      displayAddress,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: textColor,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _locationElapsedText,
                      style: TextStyle(
                        fontSize: 9.5,
                        color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Divider(
            height: 1,
            thickness: 1,
            color: isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.edit_rounded,
                size: 12,
                color: isDark ? Colors.white70 : WayDropColors.primaryEmerald,
              ),
              const SizedBox(width: 4),
              Text(
                'Change',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white70 : WayDropColors.primaryEmerald,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNotServiceableView(
    bool isDark,
    Color textColor,
    Color borderColor,
  ) {
    final subtitleColor = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);
    final hasKyc = kycProfile != null;
    final isBlocked =
        kycProfile?['blocked_until'] != null &&
        DateTime.tryParse(
              kycProfile?['blocked_until'],
            )?.isAfter(DateTime.now()) ==
            true;
    final kycStatus = isBlocked
        ? 'blocked'
        : kycProfile?['kyc_status']?.toString();
    final isApprovedRider =
        hasKyc && kycStatus == 'approved' && riderProfile != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        // Premium custom bike animation
        const Center(child: WayDropBikeAnimation(size: 110)),
        const SizedBox(height: 24),
        Text(
          "We're Not Here Yet!",
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w900,
            color: textColor,
            letterSpacing: -0.8,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: 10),
        // Try changing location action
        Center(
          child: InkWell(
            onTap: _selectLocation,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFF10B981).withValues(alpha: 0.2),
                  width: 1.2,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.edit_location_alt_rounded,
                    color: Color(0xFF10B981),
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "Try changing your location",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF10B981),
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          "WayDrop local rides and instant parcel deliveries are not active in your selected location yet. We are expanding rapidly to serve you!",
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13.5,
            color: subtitleColor,
            fontWeight: FontWeight.w500,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 28),

        // Launch Status Board
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF171A21) : Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: borderColor, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.02),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.explore_rounded,
                    color: Color(0xFF7C3AED),
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Intercity Services',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w900,
                                color: textColor,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF7C3AED,
                                ).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'ACTIVE',
                                style: TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF7C3AED),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'You can still book intercity rides or deliver packages across cities anytime.',
                          style: TextStyle(
                            fontSize: 12,
                            color: subtitleColor,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  context
                      .findAncestorStateOfType<MainNavigationScreenState>()
                      ?.setIndex(1);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7C3AED),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  'Explore Intercity Services',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // Become a Rider / Switch to Rider Banner
        GestureDetector(
          onTap: () {
            if (isApprovedRider) {
              _switchToRider();
            } else {
              // Navigate to a new screen layout using Flutter's Navigator router
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const RiderEntryHandler()),
              ).then((_) => _load());
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              gradient: isApprovedRider
                  ? const LinearGradient(
                      colors: [Color(0xFF0D1527), Color(0xFF062D24)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : const LinearGradient(
                      colors: [Color(0xFF10B981), Color(0xFF059669)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isApprovedRider
                    ? const Color(0xFF10B981).withValues(alpha: 0.35)
                    : Colors.transparent,
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color:
                      (isApprovedRider
                              ? const Color(0xFF10B981)
                              : const Color(0xFF059669))
                          .withValues(alpha: 0.15),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                // Glowing Circle Icon
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isApprovedRider
                        ? const Color(0xFF10B981).withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isApprovedRider
                        ? Icons.sports_motorsports_rounded
                        : Icons.assignment_ind_rounded,
                    color: isApprovedRider
                        ? const Color(0xFF10B981)
                        : Colors.white,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                // Text details
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        children: [
                          Text(
                            isApprovedRider
                                ? 'Drop Partner Mode Available'
                                : 'Become a Drop Partner',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                              letterSpacing: -0.2,
                            ),
                          ),
                          if (isApprovedRider)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF10B981,
                                ).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'READY',
                                style: TextStyle(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF10B981),
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        isApprovedRider
                            ? 'Switch online to accept rides & deliveries.'
                            : 'Submit KYC & start earning on intercity routes.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isApprovedRider
                              ? const Color(0xFF94A3B8)
                              : Colors.white.withValues(alpha: 0.85),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Pill CTA Button or Arrow
                if (isApprovedRider)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFC5FF30), Color(0xFFA3E635)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFC5FF30).withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Switch',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w900,
                            color: Colors.black,
                          ),
                        ),
                        SizedBox(width: 3),
                        Icon(Icons.bolt_rounded, color: Colors.black, size: 14),
                      ],
                    ),
                  )
                else
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 120),
      ],
    );
  }

  Widget _buildDynamicRiderCard(String? status, bool hasKyc) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color textColor = isDark ? Colors.white : WayDropColors.primaryText;

    final bool isApproved =
        hasKyc && status == 'approved' && riderProfile != null;

    IconData icon;
    String title;
    String subtitle;
    String? badgeText;
    Color? badgeColor;
    // [PERF] Issue #1B: live blocked-cooldown text — only this rebuilds per second.
    Widget? countdownSubtitle;
    final subtitleStyle = TextStyle(
      fontSize: 12.5,
      color: isDark ? const Color(0xFF94A3B8) : WayDropColors.secondaryText,
      fontWeight: FontWeight.w500,
    );

    final String? blockedUntilStr = kycProfile?['blocked_until'];
    bool isBlocked = false;
    if (blockedUntilStr != null) {
      final blockedUntil = DateTime.tryParse(blockedUntilStr);
      if (blockedUntil != null && blockedUntil.isAfter(DateTime.now())) {
        isBlocked = true;
      }
    }

    final activeStatus = isBlocked ? 'blocked' : (hasKyc ? status : 'none');

    switch (activeStatus) {
      case 'none':
        icon = Icons.assignment_ind_outlined;
        title = 'Become a Partner';
        subtitle = 'Submit KYC documents to start earning!';
        badgeText = null;
        badgeColor = null;
        break;

      case 'pending':
      case 'under_review':
      case 'resubmitted':
        icon = Icons.hourglass_top_outlined;
        title = 'Verification In Progress';
        subtitle = 'Your documents are currently under review.';
        badgeText = 'UNDER REVIEW';
        badgeColor = const Color(0xFFD97706);
        break;

      case 'blocked':
        icon = Icons.block_flipped;
        title = 'Access Restricted';
        // [PERF] Issue #1B: live countdown — only this text rebuilds each second.
        final blockedUntilParsed = DateTime.tryParse(blockedUntilStr ?? '');
        countdownSubtitle = ValueListenableBuilder<DateTime>(
          valueListenable: _cooldownTicker,
          builder: (context, now, _) {
            final t = blockedUntilParsed == null
                ? ''
                : _formatCooldownRemaining(blockedUntilParsed, now);
            return Text(
              t.isNotEmpty
                  ? 'Cooldown active: $t'
                  : 'This partner account is suspended.',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: subtitleStyle,
            );
          },
        );
        subtitle = 'This partner account is suspended.';
        badgeText = 'RESTRICTED';
        badgeColor = const Color(0xFFEF4444);
        break;

      case 'rejected':
        icon = Icons.error_outline_rounded;
        title = 'Verification Update Required';
        subtitle = 'Verification could not be completed. Tap to update.';
        badgeText = 'ACTION REQUIRED';
        badgeColor = const Color(0xFFEF4444);
        break;

      case 'approved':
      default:
        if (isApproved) {
          icon = Icons.sports_motorsports_outlined;
          title = 'Drop Partner';
          subtitle = 'Switch online & start accepting jobs.';
          badgeText = 'ACTIVE';
          badgeColor = const Color(0xFF10B981);
        } else {
          icon = Icons.hourglass_top_outlined;
          title = 'Verification In Progress';
          subtitle = 'Setting up your rider profile...';
          badgeText = 'UNDER REVIEW';
          badgeColor = const Color(0xFFD97706);
        }
        break;
    }

    return WayDropCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(20),
      borderRadius: 24,
      onTap: () {
        if (isApproved) {
          _switchToRider();
        } else {
          // Navigate to a new screen layout using Flutter's Navigator router
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const RiderEntryHandler()),
          ).then((_) => _load());
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF334155).withValues(alpha: 0.4)
                      : WayDropColors.primaryEmerald.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: isDark ? Colors.white : WayDropColors.primaryEmerald,
                  size: 22,
                ),
              ),
              if (badgeText != null && badgeColor != null)
                Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: isDark ? 0.15 : 0.08),
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(
                      color: badgeColor.withValues(alpha: 0.2),
                      width: 1.2,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    badgeText,
                    style: TextStyle(
                      color: badgeColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: textColor,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    countdownSubtitle ??
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: subtitleStyle,
                        ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF334155).withValues(alpha: 0.4)
                      : WayDropColors.primaryEmerald.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isApproved
                      ? Icons.swap_horiz_rounded
                      : Icons.chevron_right_rounded,
                  color: isDark ? Colors.white : WayDropColors.primaryEmerald,
                  size: 18,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // [PERF] Issue #1B: verbatim extraction of the old blocked-case formatting so
  // the countdown output stays byte-identical. Pure function of (blockedUntil, now).
  String _formatCooldownRemaining(DateTime blockedUntil, DateTime now) {
    final diff = blockedUntil.difference(now);
    if (diff.isNegative) return 'Expired';
    final days = diff.inDays;
    final hours = diff.inHours.remainder(24);
    final minutes = diff.inMinutes.remainder(60);
    final seconds = diff.inSeconds.remainder(60);
    final parts = <String>[];
    if (days > 0) parts.add('${days}d');
    if (hours > 0 || days > 0) parts.add('${hours}h');
    if (minutes > 0 || hours > 0 || days > 0) parts.add('${minutes}m');
    parts.add('${seconds}s');
    return parts.join(' ');
  }

  void _showIntercityBookingChooser(BuildContext context, bool isDark) {
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF171A21) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetCtx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'What would you like to book?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 24),
              _buildIntercityChoiceTile(
                sheetCtx: sheetCtx,
                isDark: isDark,
                emoji: '📦',
                label: 'Send Parcel',
                iconColor: const Color(0xFF059669),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const IntercityParcelsScreen(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 14),
              _buildIntercityChoiceTile(
                sheetCtx: sheetCtx,
                isDark: isDark,
                emoji: '🚗',
                label: 'Passenger Booking',
                iconColor: const Color(0xFF7C3AED),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const IntercityRidesScreen(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 14),
              _buildIntercityChoiceTile(
                sheetCtx: sheetCtx,
                isDark: isDark,
                emoji: '🛵',
                label: 'Become a Drop Partner',
                iconColor: const Color(0xFF10B981),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const RiderEntryHandler(),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildIntercityChoiceTile({
    required BuildContext sheetCtx,
    required bool isDark,
    required String emoji,
    required String label,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E222B) : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? const Color(0xFF2A2F3A) : const Color(0xFFE2E8F0),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Text(emoji, style: const TextStyle(fontSize: 22)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildServiceBubble({
    required String label,
    String? imagePath,
    IconData? icon,
    required Color color,
    required bool isDark,
    required Color textColor,
    required Color borderColor,
    required VoidCallback onTap,
    String? badgeText,
    bool isDisabled = false,
    // Phase 1 production control: overrides the default location-serviceability disabled message
    // when this tile is disabled for a different reason (a remote feature flag). Null keeps the
    // pre-existing serviceability wording unchanged.
    String? disabledMessage,
  }) {
    final bubbleContent = Container(
      width: 116,
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFEAF7EF),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: isDark ? 0.12 : 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // The soft colored circle background
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      color.withValues(alpha: 0.16),
                      color.withValues(alpha: 0.04),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                ),
              ),
              // The image/icon positioned on top, slightly larger to pop out!
              imagePath != null
                  ? Image.asset(
                      imagePath,
                      width: 90,
                      height: 90,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        return Icon(icon, color: color, size: 28);
                      },
                    )
                  : Icon(icon, color: color, size: 28),
              if (badgeText != null)
                Positioned(
                  top: -4,
                  right: -8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEA580C),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      badgeText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w900,
              color: isDisabled ? Colors.grey : textColor,
            ),
          ),
        ],
      ),
    );

    return GestureDetector(
      onTap: isDisabled
          ? () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    disabledMessage ??
                        'WayDrop local ${label.toLowerCase()}s are not active in your current location.',
                  ),
                  backgroundColor: const Color(0xFFEF4444),
                ),
              );
            }
          : onTap,
      child: isDisabled
          ? ColorFiltered(
              colorFilter: const ColorFilter.mode(
                Colors.grey,
                BlendMode.saturation,
              ),
              child: bubbleContent,
            )
          : bubbleContent,
    );
  }

  Widget _buildRecentRideCard(
    BuildContext context,
    Map<String, dynamic> order,
    bool isDark,
    Color textColor,
  ) {
    final destination = order['destination_address'] ?? 'Destination';
    final type = order['order_type'] ?? 'ride';
    final rawStatus = order['order_status'] ?? 'completed';
    final status = rawStatus;
    final isActive = [
      'created',
      'searching',
      'accepted',
      'rider_arrived',
      'picked_up',
      'ongoing',
      'rider_at_drop',
      'payment_pending',
    ].contains(rawStatus);

    final isLocalParcel = type == 'local_parcel';
    final isIntercityParcel = type == 'intercity_parcel' || type == 'intercity';
    final isParcel = isLocalParcel || isIntercityParcel;

    final String typeLabel = isParcel ? 'Parcel' : 'Ride';

    Color statusTextColor = const Color(0xFF10B981);
    String statusLabel = 'Completed';

    if (status == 'created' || status == 'searching') {
      statusLabel = 'Searching';
      statusTextColor = const Color(0xFF10B981);
    } else if (status == 'accepted') {
      statusLabel = 'Accepted';
      statusTextColor = const Color(0xFF2563EB);
    } else if (status == 'rider_arrived' || status == 'rider_at_pickup') {
      statusLabel = 'Drop Partner Arrived';
      statusTextColor = const Color(0xFF7C3AED);
    } else if (status == 'ongoing' || status == 'picked_up') {
      statusLabel = 'On Trip';
      statusTextColor = const Color(0xFFEA580C);
    } else if (status == 'rider_at_drop') {
      statusLabel = 'At Dropoff';
      statusTextColor = const Color(0xFF7C3AED);
    } else if (status == 'payment_pending') {
      statusLabel = 'Awaiting Payment';
      statusTextColor = const Color(0xFF10B981);
    } else if (status == 'delivered') {
      statusLabel = 'Delivered';
      statusTextColor = const Color(0xFF10B981);
    } else if (status == 'cancelled') {
      statusLabel = 'Cancelled';
      statusTextColor = const Color(0xFFEF4444);
    } else if (status == 'expired') {
      statusLabel = 'Expired';
      statusTextColor = const Color(0xFF64748B);
    }

    String timeStr = 'Recent';
    try {
      final createdAtStr = order['created_at'];
      if (createdAtStr != null) {
        final dateTime = DateTime.tryParse(createdAtStr)?.toLocal();
        if (dateTime != null) {
          final now = DateTime.now();
          final diff = now.difference(dateTime);

          final hour = dateTime.hour > 12 ? dateTime.hour - 12 : (dateTime.hour == 0 ? 12 : dateTime.hour);
          final ampm = dateTime.hour >= 12 ? 'PM' : 'AM';
          final minuteStr = dateTime.minute.toString().padLeft(2, '0');

          if (dateTime.year == now.year && dateTime.month == now.month && dateTime.day == now.day) {
            timeStr = 'Today • $hour:$minuteStr $ampm';
          } else if (diff.inDays == 1 || (now.day - dateTime.day == 1 && diff.inHours < 48)) {
            timeStr = 'Yesterday • $hour:$minuteStr $ampm';
          } else {
            final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
            timeStr = '${months[dateTime.month - 1]} ${dateTime.day} • $hour:$minuteStr $ampm';
          }
        }
      }
    } catch (e) {
      debugPrint('Error formatting time: $e');
    }

    final fareVal = double.tryParse(order['final_fare']?.toString() ?? order['current_fare']?.toString() ?? '0') ?? 0.0;
    final fareText = '₹${fareVal.toStringAsFixed(0)}';

    void handleCardTap() {
      if (isActive) {
        final isLocalParcel = type == 'local_parcel';
        final distanceMeters =
            double.tryParse(order['distance_meters']?.toString() ?? '') ??
            0.0;
        final isIntercityRide =
            type == 'intercity_ride' ||
            (type == 'ride' && distanceMeters > 20000);
        final isIntercityParcel = type == 'intercity_parcel';
        if (status == 'searching' || status == 'created') {
          // Navigate to a new screen layout using Flutter's Navigator router
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) {
                if (isLocalParcel) {
                  return ParcelSearchingScreen(orderId: order['id']);
                }
                if (isIntercityParcel) {
                  return IntercitySearchingScreen(orderId: order['id']);
                }
                if (isIntercityRide) {
                  return IntercitySearchingScreen(orderId: order['id']);
                }
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
                if (isLocalParcel) {
                  return ParcelTrackingScreen(orderId: order['id']);
                }
                if (isIntercityParcel || isIntercityRide) {
                  return IntercityTrackingScreen(orderId: order['id']);
                }
                return RideTrackingScreen(orderId: order['id']);
              },
            ),
          );
        }
      } else {
        // Re-order / Re-book
        final isLocalParcel = type == 'local_parcel';
        final isIntercityParcel = type == 'intercity_parcel';

        // Navigate to a new screen layout using Flutter's Navigator router
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) {
              if (isLocalParcel) {
                return ParcelDetailsScreen(
                  orderType: 'local_parcel',
                  pickupAddress: order['pickup_address']?.toString(),
                  destinationAddress: order['destination_address']?.toString(),
                  pickupLat: double.tryParse(order['pickup_lat']?.toString() ?? ''),
                  pickupLng: double.tryParse(order['pickup_lng']?.toString() ?? ''),
                  destinationLat: double.tryParse(order['destination_lat']?.toString() ?? ''),
                  destinationLng: double.tryParse(order['destination_lng']?.toString() ?? ''),
                  totalDistanceMeters: double.tryParse(order['distance_meters']?.toString() ?? ''),
                  durationSeconds: order['time_taken_seconds'] != null
                      ? double.tryParse(order['time_taken_seconds'].toString())
                      : (order['estimated_duration_min'] != null
                          ? (double.tryParse(order['estimated_duration_min'].toString()) ?? 0.0) * 60.0
                          : null),
                  routePoints: const [],
                  receiverName: order['receiver_name']?.toString(),
                  receiverPhone: order['receiver_phone']?.toString(),
                  parcelType: order['parcel_type']?.toString(),
                  weightCategory: order['weight_category']?.toString(),
                  specialInstructions: order['special_instructions']?.toString(),
                );
              }
              if (isIntercityParcel) {
                return IntercityDetailsScreen(
                  orderType: 'intercity_parcel',
                  pickupAddress: order['pickup_address']?.toString(),
                  destinationAddress: order['destination_address']?.toString(),
                  pickupLat: double.tryParse(order['pickup_lat']?.toString() ?? ''),
                  pickupLng: double.tryParse(order['pickup_lng']?.toString() ?? ''),
                  destinationLat: double.tryParse(order['destination_lat']?.toString() ?? ''),
                  destinationLng: double.tryParse(order['destination_lng']?.toString() ?? ''),
                  totalDistanceMeters: double.tryParse(order['distance_meters']?.toString() ?? ''),
                  durationSeconds: order['time_taken_seconds'] != null
                      ? double.tryParse(order['time_taken_seconds'].toString())
                      : (order['estimated_duration_min'] != null
                          ? (double.tryParse(order['estimated_duration_min'].toString()) ?? 0.0) * 60.0
                          : null),
                  routePoints: const [],
                  receiverName: order['receiver_name']?.toString(),
                  receiverPhone: order['receiver_phone']?.toString(),
                  parcelType: order['parcel_type']?.toString(),
                  weightCategory: order['weight_category']?.toString(),
                  specialInstructions: order['special_instructions']?.toString(),
                );
              }
              return RideLocationScreen(
                orderType: type,
                prefillPickupAddress: order['pickup_address']?.toString(),
                prefillDestinationAddress: order['destination_address']?.toString(),
                prefillPickupLat: double.tryParse(order['pickup_lat']?.toString() ?? ''),
                prefillPickupLng: double.tryParse(order['pickup_lng']?.toString() ?? ''),
                prefillDestinationLat: double.tryParse(order['destination_lat']?.toString() ?? ''),
                prefillDestinationLng: double.tryParse(order['destination_lng']?.toString() ?? ''),
              );
            },
          ),
        );
      }
    }

    return GestureDetector(
      onTap: handleCardTap,
      child: WayDropCard(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        borderRadius: 18,
        child: SizedBox(
          width: 260,
          height: 122,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    typeLabel,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w900,
                      color: textColor,
                    ),
                  ),
                  Text(
                    fareText,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w900,
                      color: textColor,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusTextColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w900,
                        color: statusTextColor,
                      ),
                    ),
                  ),
                ],
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          timeStr,
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark ? const Color(0xFF94A3B8) : WayDropColors.secondaryText,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'To: $destination',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400,
                            fontWeight: FontWeight.w500,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: handleCardTap,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isActive ? const Color(0xFF2563EB) : const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(
                      isActive ? 'Track' : (isParcel ? 'Send Again' : 'Ride Again'),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFirstRideCard(bool isDark, Color textColor) {
    return GestureDetector(
      onTap: () {
        // Navigate to a new screen layout using Flutter's Navigator router
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const RideLocationScreen(orderType: 'ride'),
          ),
        );
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF171A21) : Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.12 : 0.02),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF1E293B)
                    : const Color(0xFFF1F5F9),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Icon(
                  Icons.route_outlined,
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF64748B),
                  size: 24,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Plan Your First Journey',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w900,
                      color: textColor,
                      letterSpacing: -0.1,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Book rides, schedule deliveries, and explore intercity transport.',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: isDark
                          ? const Color(0xFF64748B)
                          : Colors.grey.shade600,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              color: isDark ? const Color(0xFF475569) : Colors.grey.shade400,
              size: 24,
            ),
          ],
        ),
      ),
    );
  }

  // [PERF] Rebuild-scope reduction (Issue #1A): play the staggered 400 ms
  // entrance animations only on the first build that renders real content.
  // Every later rebuild (location updates, 30 s refresh, realtime events)
  // would otherwise re-run the fade/slide sequences across the whole page.
  // Gated on _contentBuildCount (incremented before the section reads) so all
  // sections agree within one build: first content build → animate, later → skip.
  bool get disableAnimations => _contentBuildCount > 1;

  Widget _animateEntrance(Widget child, int delayMs, bool disable) {
    if (disable) return child;
    return child.animate().fade(duration: 400.ms, delay: delayMs.ms).slideY(
          begin: 0.15,
          end: 0.0,
          curve: Curves.easeOutCubic,
          duration: 400.ms,
          delay: delayMs.ms,
        );
  }
}
