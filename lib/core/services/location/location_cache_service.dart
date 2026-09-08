import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:waydrop/core/services/location/serviceability_service.dart';
import 'package:waydrop/core/location/models/cached_zone.dart';
import 'package:waydrop/core/location/enums/serviceability_status.dart';

class LocationCacheService {
  static Duration serverClockSkew = Duration.zero;

  // =====================================================
  // CACHE
  // =====================================================

  static Position? cachedPosition;

  static String? cachedAddress;

  static String? cachedCity;

  static DateTime? lastUpdated;

  static bool isFetching = false;
  static Completer<void>? _fetchCompleter;
  static final List<VoidCallback> _listeners = [];

  static void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  static void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  static void _notifyListeners() {
    for (final listener in _listeners) {
      try {
        listener();
      } catch (e) {
        debugPrint('Error in LocationCacheService listener: $e');
      }
    }
  }

  static bool isInitialized = false;

  // =====================================================
  // LIVE TRACKING
  // =====================================================

  static StreamSubscription<Position>?
      riderLocationStream;

  static StreamSubscription<ServiceStatus>?
      gpsStatusStream;

  static DateTime?
      lastDbUpdateTime;

  static Position?
      lastUploadedPosition;

  static bool isUpdatingDb = false;

  static Timer? riderHeartbeatTimer;

  // =====================================================
  // CACHE SETTINGS
  // =====================================================

  static const int cacheValidityMinutes =
      5;

  // PHASE A (A3) — rider GPS write throttle.
  //
  // The Flutter writer still updates ONLY public.riders (see updateRiderLocation
  // below); the A1 DB bridge trigger trg_riders_gps_bridge_to_rider_locations
  // mirrors every one of those writes into public.rider_locations, which is the
  // lean (REPLICA IDENTITY DEFAULT) high-frequency table the passenger tracking
  // stream now subscribes to (realtime_order_controller._subscribeRider).
  //
  // riders carries REPLICA IDENTITY FULL + 13 indexes + the bridge/near-dest
  // triggers, so every GPS UPDATE is a full-row WAL record fanned out to the
  // logical-decode pipeline. Widening the write cadence from 10 m / 30 s to
  // 150 m / 60 s cuts the steady-state riders GPS write rate to ~1/min per
  // online rider (~65-80% fewer writes) — the dominant contributor to the
  // Realtime WAL-decode overload traced in
  // docs/PERF_slowdown_after_few_rides_analysis.md — while still refreshing the
  // passenger map about every ~60 s / ~150 m of rider movement and keeping
  // dispatch's very lenient staleness gate (>= now()-24h OR NULL) satisfied.
  static const int movementThresholdMeters =
      150;

  static const int heartbeatSeconds =
      60;

  // Kept explicit (was heartbeatSeconds * 4) so raising heartbeatSeconds to 60
  // above does not also widen the "is the cached position too stale to trust in
  // the heartbeat path" tolerance — it stays at ~2 min, unchanged from before.
  static const int _heartbeatStaleCacheToleranceSeconds =
      120;

  // =====================================================
  // INITIALIZE LOCATION
  // =====================================================

  static Future<void>
      initializeLocation({bool requestPermission = false})
      async {

    if (isFetching) {
      if (_fetchCompleter != null) {
        await _fetchCompleter!.future;
      }
      return;
    }

    _fetchCompleter = Completer<void>();
    isFetching = true;

    await loadMockLocationFromPrefs();

    try {

      // =========================================
      // GPS ENABLED
      // =========================================

      final serviceEnabled =
          await Geolocator
              .isLocationServiceEnabled();

      if (!serviceEnabled) {

        return;
      }

      // =========================================
      // PERMISSION
      // =========================================

      final permissionGranted =
          await _ensurePermission(request: requestPermission);

      if (!permissionGranted) {

        return;
      }

      // =========================================
      // LAST KNOWN POSITION
      // =========================================

      Position? position;

      try {

        position =
            await Geolocator
                .getLastKnownPosition();

      } catch (e) {

        debugPrint(
          'LAST KNOWN POSITION ERROR => $e',
        );
      }

      // =========================================
      // FALLBACK LIVE POSITION
      // =========================================

      position ??=
          await Geolocator
              .getCurrentPosition(
        desiredAccuracy:
            LocationAccuracy.low,
        timeLimit:
            const Duration(
          seconds: 4,
        ),
      );

      // =========================================
      // CACHE POSITION
      // =========================================

      _cachePosition(position);

      // =========================================
      // ADDRESS FETCH
      // =========================================

      await _updateAddress(position);

      // =========================================
      // DYNAMIC ZONES LOAD
      // =========================================
      try {
        await ServiceabilityService.loadActiveZones();
      } catch (e) {
        debugPrint('DYNAMIC ZONES LOAD ERROR => $e');
      }

      // =========================================
      // UPDATE SERVICEABILITY
      // =========================================
      await updateServiceability();

      isInitialized = true;

    } catch (e) {

      isInitialized = false;
      debugPrint(
        'INITIALIZE LOCATION ERROR => $e',
      );

    } finally {

      isFetching = false;
      final tempCompleter = _fetchCompleter;
      _fetchCompleter = null;
      if (tempCompleter != null && !tempCompleter.isCompleted) {
        tempCompleter.complete();
      }
    }
  }

  // =====================================================
  // ENSURE PERMISSION
  // =====================================================

  static Future<bool>
      _ensurePermission({bool request = true})
      async {

    try {

      LocationPermission permission =
          await Geolocator
              .checkPermission();

      if (permission ==
          LocationPermission.denied && request) {

        permission =
            await Geolocator
                .requestPermission();
      }

      if (permission ==
              LocationPermission
                  .denied ||

          permission ==
              LocationPermission
                  .deniedForever) {

        return false;
      }

      return true;

    } catch (e) {

      debugPrint(
        'PERMISSION ERROR => $e',
      );

      return false;
    }
  }

  // =====================================================
  // CACHE POSITION
  // =====================================================

  static void _cachePosition(
    Position position,
  ) {

    cachedPosition = position;

    lastUpdated =
        DateTime.now();
    _updateServiceableNotifier();
    _notifyListeners();
  }

  // =====================================================
  // ADDRESS UPDATE
  // =====================================================

  static Future<void>
      _updateAddress(
    Position position,
  ) async {

    try {

      final result =
          await OlaMapService
              .reverseGeocode(

        latitude:
            position.latitude,

        longitude:
            position.longitude,
      );

      final address = result['formatted_address']?.toString() ?? '';
      final city = result['city']?.toString() ?? '';

      if (address.trim().isNotEmpty) {

        cachedAddress =
            address;
        cachedCity =
            city;
        _notifyListeners();
      }

    } catch (e) {

      debugPrint(
        'ADDRESS UPDATE ERROR => $e',
      );
    }
  }

  // =====================================================
  // PERFORM HEARTBEAT UPDATE
  // =====================================================

  static Future<void> _performHeartbeatUpdate() async {
    try {
      Position? position;
      try {
        // BUG FIX: this used to trust `cachedPosition` unconditionally regardless of age. If the
        // live position stream had died (permission revoked mid-session, GPS toggled off, a
        // stream error -- see the onError handlers below), cachedPosition would sit frozen at
        // whatever it last was, and this function would keep re-uploading that stale value with
        // a FRESH `last_location_updated_at` timestamp every heartbeat -- masking a dead stream
        // as "just updated" indefinitely, with no way for dispatch/anything else watching that
        // column to tell the difference from a genuinely live, stationary rider. Only trust the
        // cache if it was actually refreshed recently (a few heartbeat intervals' worth of
        // tolerance for a stationary rider, whose distanceFilter:5m stream legitimately won't
        // emit new positions) -- otherwise treat it as stale and fall through to a real read.
        final cacheAge = lastUpdated == null ? null : DateTime.now().difference(lastUpdated!);
        position = (cacheAge != null &&
                cacheAge < const Duration(seconds: _heartbeatStaleCacheToleranceSeconds))
            ? cachedPosition
            : null;
        position ??= await Geolocator.getLastKnownPosition();

        if (position == null) {
          position = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.low,
            timeLimit: const Duration(seconds: 5),
          );
        }
      } catch (e) {
        debugPrint('HEARTBEAT GET POSITION ERROR => $e');
        position ??= cachedPosition;
      }

      if (position == null) {
        return;
      }

      _cachePosition(position);
      // P0 PERFORMANCE FIX: this used to also call _updateAddress(position) (an OLA
      // reverse-geocode) on every heartbeat. Confirmed unnecessary: updateRiderLocation() below
      // (the actual riders-table UPDATE dispatch/matching reads) never writes an address column at
      // all, and cachedAddress/cachedCity are only ever consumed for the rider's own in-app label,
      // which initializeLocation() already resolves once at startup. Removing this generated up to
      // ~2 avoidable OLA calls/minute per online rider with no functional loss -- lat/lng/heading
      // update, DB write, and dispatch/matching below are completely unchanged.

      if (isUpdatingDb) {
        return;
      }
      isUpdatingDb = true;

      try {
        await updateRiderLocation(position);
        lastUploadedPosition = position;
        lastDbUpdateTime = DateTime.now();
      } finally {
        isUpdatingDb = false;
      }
    } catch (e) {
      debugPrint('HEARTBEAT UPDATE PROCESS ERROR => $e');
    }
  }

  // =====================================================
  // START TRACKING
  // =====================================================

  static Future<void>
      startRiderLiveTracking()
      async {

    try {

      // =========================================
      // PREVENT DUPLICATES
      // =========================================

      if (riderLocationStream !=
          null) {

        return;
      }

      // =========================================
      // GPS ENABLED
      // =========================================

      final serviceEnabled =
          await Geolocator
              .isLocationServiceEnabled();

      if (!serviceEnabled) {

        return;
      }

      // =========================================
      // PERMISSION
      // =========================================

      final permissionGranted =
          await _ensurePermission();

      if (!permissionGranted) {

        return;
      }

      // =========================================
      // START STREAM
      // =========================================

      LocationSettings locationSettings;
      if (defaultTargetPlatform == TargetPlatform.android) {
        locationSettings = AndroidSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 5,
          intervalDuration: const Duration(seconds: 10),
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationText: "WayDrop tracks your location in the background for dispatch matching.",
            notificationTitle: "WayDrop Drop Partner Online",
            enableWakeLock: true,
            // Without this, geolocator_android defaults to AndroidResource(name:
            // 'ic_launcher', defType: 'mipmap') — the full-color launcher icon. Android
            // flattens every status-bar smallIcon to its alpha channel on API 21+, so a
            // solid-opacity color icon renders as a meaningless filled blob instead of the
            // monochrome car silhouette used everywhere else (see ic_stat_notify.xml).
            notificationIcon: AndroidResource(name: 'ic_stat_notify', defType: 'drawable'),
            color: Color(0xFF01205F),
          ),
        );
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        locationSettings = AppleSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 5,
          activityType: ActivityType.otherNavigation,
          pauseLocationUpdatesAutomatically: false,
          showBackgroundLocationIndicator: true,
        );
      } else {
        locationSettings = const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 5,
        );
      }

      try {
        riderLocationStream = Geolocator.getPositionStream(
          locationSettings: locationSettings,
        ).listen(
          _handlePositionUpdate,
          onError: (error) {
            debugPrint('LOCATION STREAM ERROR => $error');
            // BUG FIX: this used to only log -- riderLocationStream was never nulled out on a
            // stream error (permission revoked mid-session, GPS disabled), so
            // startRiderLiveTracking()'s own "already running" dedup guard (line ~376, checks
            // `riderLocationStream != null`) permanently blocked every future restart attempt,
            // including the app-resume path. Once tracking died this way it stayed dead until a
            // manual offline->online toggle, with the rider still shown as online the whole time.
            riderLocationStream = null;
          },
        );
      } catch (streamError) {
        debugPrint('Failed to start location stream with foreground settings: $streamError. Falling back to basic LocationSettings.');
        try {
          const fallbackSettings = LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 5,
          );
          riderLocationStream = Geolocator.getPositionStream(
            locationSettings: fallbackSettings,
          ).listen(
            _handlePositionUpdate,
            onError: (error) {
              debugPrint('LOCATION STREAM FALLBACK ERROR => $error');
              riderLocationStream = null;
            },
          );
        } catch (fallbackError) {
          debugPrint('Critical: Failed to start fallback location stream: $fallbackError');
        }
      }

      // =========================================
      // START HEARTBEAT TIMER
      // =========================================

      riderHeartbeatTimer?.cancel();
      riderHeartbeatTimer = Timer.periodic(
        const Duration(seconds: heartbeatSeconds),
        (_) => _performHeartbeatUpdate(),
      );

      // Trigger an immediate initial update in the background
      unawaited(_performHeartbeatUpdate());

      // BUG FIX: monitorGpsStatus() (forces the rider offline and stops tracking when GPS is
      // disabled at the OS level, not just a permission issue) existed but was never called from
      // anywhere in the app -- confirmed via grep. Turning GPS off mid-trip was previously
      // undetected except by the (also-buggy, now-fixed) stream error path above.
      monitorGpsStatus();

    } catch (e) {

      debugPrint(
        'START TRACKING ERROR => $e',
      );
    }
  }

  // =====================================================
  // HANDLE POSITION
  // =====================================================

  static Future<void>
      _handlePositionUpdate(
    Position position,
  ) async {

    try {

      // =========================================
      // CACHE POSITION
      // =========================================

      _cachePosition(position);

      // =========================================
      // SHOULD UPLOAD
      // =========================================

      final shouldUpload =
          _shouldUploadPosition(
        position,
      );

      if (!shouldUpload) {

        return;
      }

      // =========================================
      // PREVENT OVERLAPPING REQUESTS
      // =========================================

      if (isUpdatingDb) {

        return;
      }

      isUpdatingDb = true;

      // =========================================
      // UPDATE DB
      // =========================================

      await updateRiderLocation(
        position,
      );

      lastUploadedPosition =
          position;

      lastDbUpdateTime =
          DateTime.now();

    } catch (e) {

      debugPrint(
        'POSITION UPDATE ERROR => $e',
      );

    } finally {

      isUpdatingDb = false;
    }
  }

  // =====================================================
  // SHOULD UPLOAD
  // =====================================================

  static bool _shouldUploadPosition(
    Position position,
  ) {

    // FIRST UPDATE

    if (

      lastUploadedPosition == null

      ||

      lastDbUpdateTime == null

    ) {

      return true;
    }

    // DISTANCE CHECK

    final movedDistance =
        Geolocator.distanceBetween(

      lastUploadedPosition!
          .latitude,

      lastUploadedPosition!
          .longitude,

      position.latitude,

      position.longitude,
    );

    if (

      movedDistance >=
          movementThresholdMeters

    ) {

      return true;
    }

    // HEARTBEAT CHECK

    final secondsPassed =
        DateTime.now()

            .difference(
              lastDbUpdateTime!,
            )

            .inSeconds;

    if (

      secondsPassed >=
          heartbeatSeconds

    ) {

      return true;
    }

    return false;
  }

  // =====================================================
  // STOP TRACKING
  // =====================================================

  static Future<void>
      stopRiderLiveTracking()
      async {

    try {

      await riderLocationStream
          ?.cancel();

      riderLocationStream = null;

      riderHeartbeatTimer?.cancel();

      riderHeartbeatTimer = null;

    } catch (e) {

      debugPrint(
        'STOP TRACKING ERROR => $e',
      );
    }
  }

  // =====================================================
  // UPDATE DB
  // =====================================================

  static Future<void>
      updateRiderLocation(
    Position position,
  ) async {

    try {

      final supabase =
          Supabase.instance.client;

      final user =
          supabase.auth.currentUser;

      if (user == null) {

        return;
      }

      // =========================================
      // UPDATE
      // =========================================

      final now =
          DateTime.now()
              .toIso8601String();

      await supabase

          .from('riders')

          .update({

        'current_lat':
            position.latitude,

        'current_lng':
            position.longitude,

        'current_heading':

            position.heading.isNaN

                ? 0

                : position.heading,

        'last_location_updated_at':
            now,

        'last_active_at':
            now,

        'updated_at':
            now,
      })

          .eq(
            'user_id',
            user.id,
          )
          .eq(
            'account_status',
            'online',
          );

    } catch (e) {

      debugPrint(
        'UPDATE RIDER LOCATION ERROR => $e',
      );
    }
  }

  // =====================================================
  // GPS STATUS MONITOR
  // =====================================================

  static void monitorGpsStatus() {

    gpsStatusStream ??=

        Geolocator
            .getServiceStatusStream()

            .listen(

      (status) async {

        try {

          if (
            status ==
                ServiceStatus
                    .disabled
          ) {

            final supabase =
                Supabase
                    .instance
                    .client;

            final user =
                supabase
                    .auth
                    .currentUser;

            if (user == null) {

              return;
            }

            // =====================================
            // FORCE OFFLINE
            // =====================================

            await supabase

                .from('riders')

                .update({

              'account_status':
                  'offline',

              'updated_at':

                  DateTime.now()
                      .toIso8601String(),
            })

                .eq(
                  'user_id',
                  user.id,
                );

            await stopRiderLiveTracking();
          }

        } catch (e) {

          debugPrint(
            'GPS STATUS ERROR => $e',
          );
        }
      },
    );
  }

  // =====================================================
  // STOP GPS MONITOR
  // =====================================================

  static Future<void>
      stopGpsMonitor()
      async {

    await gpsStatusStream
        ?.cancel();

    gpsStatusStream = null;
  }

  // =====================================================
  // CACHE VALIDITY
  // =====================================================

  static bool get hasValidCache {

    if (

      cachedPosition == null

      ||

      lastUpdated == null

    ) {

      return false;
    }

    final difference =
        DateTime.now().difference(
      lastUpdated!,
    );

    return difference.inMinutes <
        cacheValidityMinutes;
  }

  // =====================================================
  // CURRENT LAT
  // =====================================================

  static double? get currentLat {

    return cachedPosition
        ?.latitude;
  }

  // =====================================================
  // CURRENT LNG
  // =====================================================

  static double? get currentLng {

    return cachedPosition
        ?.longitude;
  }

  // =====================================================
  // CURRENT ADDRESS
  // =====================================================

  static String get currentAddress {

    return cachedAddress ??
        'Fetching location...';
  }

  static String get currentCity {
    return cachedCity ?? 'Other';
  }

  static double? manualMockLat;
  static double? manualMockLng;
  static String? manualMockAddress;

  static CachedZone? cachedZone;
  static ServiceabilityStatus serviceabilityStatus = ServiceabilityStatus.unknown;
  static bool _isServiceableVal = true;

  static final ValueNotifier<bool> isServiceableNotifier = ValueNotifier<bool>(true);

  static void _updateServiceableNotifier() {
    updateServiceability();
  }

  static bool get isServiceable => _isServiceableVal;

  // Guards against out-of-order responses: updateServiceability() can be
  // triggered concurrently from several call sites (position updates, mock
  // location changes, zone reloads). Without this, a slower earlier call
  // can resolve after a faster later call and overwrite it with stale data.
  static int _serviceabilityRequestId = 0;

  static Future<void> updateServiceability() async {
    final requestId = ++_serviceabilityRequestId;

    final lat = manualMockLat ?? currentLat;
    final lng = manualMockLng ?? currentLng;
    final address = manualMockAddress ?? currentAddress;
    final city = manualMockAddress != null ? '' : (cachedCity ?? '');

    if (lat == null || lng == null) {
      _isServiceableVal = true;
      serviceabilityStatus = ServiceabilityStatus.unknown;
      isServiceableNotifier.value = true;
      return;
    }

    serviceabilityStatus = ServiceabilityStatus.loading;

    final result = await ServiceabilityService.isLocationServiceable(
      address: address,
      latitude: lat,
      longitude: lng,
      city: city.isEmpty ? null : city,
    );

    // A newer call already started while this one was in flight - drop this
    // stale result instead of letting it overwrite the newer state.
    if (requestId != _serviceabilityRequestId) return;

    _isServiceableVal = result.isServiceable;
    cachedZone = result.zone;
    serviceabilityStatus = result.isServiceable
        ? ServiceabilityStatus.serviceable
        : (result.city.isEmpty
            ? ServiceabilityStatus.unknown
            : ServiceabilityStatus.notServiceable);

    isServiceableNotifier.value = _isServiceableVal;
    _notifyListeners();
  }

  static Future<void> loadMockLocationFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mockLat = prefs.getDouble('manual_mock_lat');
      final mockLng = prefs.getDouble('manual_mock_lng');
      final mockAddr = prefs.getString('manual_mock_address');
      if (mockLat != null && mockLng != null && mockAddr != null) {
        manualMockLat = mockLat;
        manualMockLng = mockLng;
        manualMockAddress = mockAddr;
      }
      _updateServiceableNotifier();
    } catch (e) {
      debugPrint('Error loading mock location: $e');
    }
  }

  static Future<void> saveMockLocationToPrefs({
    double? lat,
    double? lng,
    String? address,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      manualMockLat = lat;
      manualMockLng = lng;
      manualMockAddress = address;

      if (lat != null && lng != null && address != null) {
        await prefs.setDouble('manual_mock_lat', lat);
        await prefs.setDouble('manual_mock_lng', lng);
        await prefs.setString('manual_mock_address', address);
      } else {
        await prefs.remove('manual_mock_lat');
        await prefs.remove('manual_mock_lng');
        await prefs.remove('manual_mock_address');
      }
      _updateServiceableNotifier();
    } catch (e) {
      debugPrint('Error saving mock location: $e');
    }
  }

  // =====================================================
  // CLEAR CACHE
  // =====================================================

  static void clearCache() {

    cachedPosition = null;

    cachedAddress = null;

    lastUpdated = null;

    lastUploadedPosition = null;

    lastDbUpdateTime = null;
    _updateServiceableNotifier();
  }
}