/// ============================================================================
/// File: ola_map_service.dart
///
/// Module:
/// Core → Services → Maps
///
/// Purpose:
/// Integrates Ola Maps API and handles routing/geocoding.
///
/// Responsibilities:
/// • Fetch place autocomplete suggestions and place details.
/// • Fetch routes, durations, and polylines between coordinates.
///
/// Related:
/// app_start_screen.dart
/// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:waydrop/core/config/env.dart';


class RouteModel {

  final double distanceMeters;

  final double durationSeconds;

  final List<Map<String, double>>
      polylinePoints;

  final Map<String, double>
      bounds;

  const RouteModel({

    required this.distanceMeters,

    required this.durationSeconds,

    required this.polylinePoints,

    required this.bounds,
  });
}

/// Result of [OlaMapService.getMultiStopRoute] -- one combined [RouteModel] stitched from N-1
/// consecutive origin->via->...->destination legs, plus the cumulative along-route distance (km)
/// at each stop.
///
/// [cumulativeKm] has exactly one entry per input stop, in the same order: `cumulativeKm[0]` is
/// always 0 (the origin), and `cumulativeKm.last` equals `route.distanceMeters / 1000` (the
/// destination). These are the traveller's declared-route waypoint `along_track_km` values used
/// by the Intercity selected-route matcher -- see docs/13_Business_Logic.md section 5.
class MultiStopRoute {
  final RouteModel route;
  final List<double> cumulativeKm;

  const MultiStopRoute({required this.route, required this.cumulativeKm});
}

class OlaMapService {

  // =====================================================
  // DIO
  // =====================================================

  static final Dio dio = Dio(

    BaseOptions(

      connectTimeout:
          const Duration(
        seconds: 15,
      ),

      receiveTimeout:
          const Duration(
        seconds: 15,
      ),

      sendTimeout:
          const Duration(
        seconds: 15,
      ),
    ),
  )..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.extra['_perfStart'] = DateTime.now().millisecondsSinceEpoch;
          handler.next(options);
        },
        onResponse: (response, handler) {
          final int? start = response.requestOptions.extra['_perfStart'] as int?;
          if (start != null) {
            final int ms = DateTime.now().millisecondsSinceEpoch - start;
            debugPrint('[PERF_MAPS] ${response.requestOptions.method} ${response.requestOptions.path} status=${response.statusCode} ${ms}ms epoch=${DateTime.now().millisecondsSinceEpoch}');
          }
          handler.next(response);
        },
        onError: (error, handler) {
          final int? start = error.requestOptions.extra['_perfStart'] as int?;
          if (start != null) {
            final int ms = DateTime.now().millisecondsSinceEpoch - start;
            debugPrint('[PERF_MAPS] ${error.requestOptions.method} ${error.requestOptions.path} ERROR ${ms}ms');
          }
          handler.next(error);
        },
      ),
    );

  // =====================================================
  // API KEY
  // =====================================================

  static String get apiKey => Env.olaMapsApiKey;

  // =====================================================
  // CACHE
  // =====================================================

  static final Map<String, List<dynamic>>
      _autocompleteCache = {};

  static final Map<String, Map<String, dynamic>>
      _reverseGeocodeCache = {};

  static String? _extractCityFromComponents(List<dynamic>? components) {
    if (components == null) return null;
    
    const priorityTypes = [
      'locality',
      'city',
      'town',
      'municipality',
      'village',
      'administrative_area_level_3',
      'administrative_area_level_2'
    ];

    for (final type in priorityTypes) {
      for (final component in components) {
        if (component is Map) {
          final types = component['types'];
          if (types is List && types.contains(type)) {
            final name = component['long_name']?.toString();
            if (name != null && name.isNotEmpty) return name;
          }
        }
      }
    }
    return null;
  }

  static String getCityFromDescription(String mainText, String secondaryText) {
    if (secondaryText.isEmpty) return '';
    final parts = secondaryText.split(',');
    if (parts.isEmpty) return '';
    
    final ignored = {
      'india', 'andhra pradesh', 'telangana', 'karnataka', 'tamil nadu', 'maharashtra', 
      'ap', 'ts', 'mh', 'ka', 'tn', 'state'
    };
    
    for (int i = parts.length - 1; i >= 0; i--) {
      final part = parts[i].trim();
      final lower = part.toLowerCase();
      if (ignored.any((ig) => lower.contains(ig) || ig.contains(lower))) {
        continue;
      }
      return part;
    }
    return parts.first.trim();
  }

  static final Map<String,
      Map<String, dynamic>?>

      _geocodeCache = {};

  static final Map<String, RouteModel>
      _routeCache = {};

  static final Map<String, Map<String, dynamic>?>
      _placeDetailsCache = {};

  // Caps each cache above at a fixed size instead of growing for the entire app process lifetime.
  // WayDrop Progressive Degradation Audit, finding CLIENT-2: these 5 maps had no eviction, and
  // clearCaches() below (the only eviction path that existed) was never called anywhere in the
  // app -- unbounded heap growth across a session was the direct, evidence-backed cause of "the
  // whole app generally feels slower the longer it's been running". Every read call site
  // (`.containsKey`/`[key]`) is unchanged; only writes now go through this bounded insert, which
  // evicts the least-recently-inserted entry once a cache exceeds _maxCacheEntries.
  static const int _maxCacheEntries = 200;

  static void _putBounded<K, V>(Map<K, V> cache, K key, V value) {
    cache.remove(key);
    cache[key] = value;
    if (cache.length > _maxCacheEntries) {
      cache.remove(cache.keys.first);
    }
  }

  // =====================================================
  // REQUEST CONTROL
  // =====================================================

  static CancelToken?
      _autocompleteCancelToken;

  static DateTime?
      _lastAutocompleteRequest;

  // =====================================================
  // LOGGING
  // =====================================================

  static bool enableLogs = true;

  static void log(dynamic value) {

    if (enableLogs) {

      debugPrint(
        value.toString(),
      );
    }
  }

  // =====================================================
  // AUTOCOMPLETE
  // =====================================================

  // WayDrop Ola egress reduction (2026-08-22): a single-character query is fired on every screen
  // that uses this shared service whenever a user pauses >=400ms right after their first keystroke
  // (a common typing pattern) -- Ola's autocomplete API call for a 1-character input is essentially
  // never decisive (too many broad matches to be useful) and is pure waste. Below this length the
  // call is skipped entirely, exactly as if it returned no results -- callers already handle an
  // empty prediction list identically to "still typing", so this is invisible to the UI.
  static const int _minAutocompleteQueryLength = 2;

  static Future<List<dynamic>>
      autocomplete(
    String input,
  ) async {

    final query =

        input
            .trim()
            .toLowerCase();

    if (query.length < _minAutocompleteQueryLength) {

      return [];
    }

    // CACHE

    if (
      _autocompleteCache
          .containsKey(query)
    ) {

      return
          _autocompleteCache[
              query]!;
    }

    // THROTTLE

    final now =
        DateTime.now();

    if (
      _lastAutocompleteRequest !=
          null
    ) {

      final diff =

          now.difference(
        _lastAutocompleteRequest!,
      );

      if (
        diff.inMilliseconds <
            200
      ) {

        await Future.delayed(

          Duration(

            milliseconds:

                200 -
                diff.inMilliseconds,
          ),
        );
      }
    }

    _lastAutocompleteRequest =
        DateTime.now();

    // CANCEL PREVIOUS

    _autocompleteCancelToken
        ?.cancel();

    _autocompleteCancelToken =
        CancelToken();

    try {

      final response =
          await dio.get(

        'https://api.olamaps.io/places/v1/autocomplete',

        queryParameters: {

          'input': input,

          'api_key': apiKey,
        },

        cancelToken:
            _autocompleteCancelToken,
      );

      if (
        response.statusCode != 200
      ) {

        return [];
      }

      var responseData = response.data;
      if (responseData is String) {
        responseData = jsonDecode(responseData);
      }

      final predictions =
          responseData['predictions']
              ??
              [];

      if (
        predictions is! List
      ) {

        return [];
      }

      _putBounded(
          _autocompleteCache, query, predictions);

      return predictions;

    } catch (e) {

      if (
        e is DioException
      ) {

        if (
          CancelToken.isCancel(e)
        ) {

          return [];
        }
      }

      log(
        'AUTOCOMPLETE ERROR => $e',
      );

      return [];
    }
  }

  // =====================================================
  // REVERSE GEOCODE
  // =====================================================

  // WayDrop Ola egress reduction (2026-08-22): the exact-key cache above only dedupes a
  // byte-for-byte repeat of the same 5-decimal (~1.1m) coordinate. Fine pin-adjustment drags (the
  // location-picker "drag to confirm exact spot" flow) routinely land a few meters from the
  // previous drag-end point -- a different cache key every time, but the same real-world address
  // in the overwhelming majority of cases. This threshold lets a new request reuse the nearest
  // already-cached result instead of firing a fresh Ola call for what is very likely an identical
  // address. Only the DISPLAYED address label can be up to this far behind the pin's true
  // position; the coordinates actually recorded for the order are always the exact dragged
  // lat/lng, never the cached address's original point, so this cannot affect pickup/drop accuracy.
  static const double _reverseGeocodeProximityMeters = 35.0;

  static double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
    const double earthRadiusMeters = 6371000.0;
    final double dLat = (lat2 - lat1) * pi / 180.0;
    final double dLng = (lng2 - lng1) * pi / 180.0;
    final double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) * sin(dLng / 2) * sin(dLng / 2);
    final double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  static Map<String, dynamic>? _findNearbyReverseGeocodeResult(double latitude, double longitude) {
    for (final entry in _reverseGeocodeCache.entries) {
      final parts = entry.key.split(',');
      if (parts.length != 2) continue;
      final cachedLat = double.tryParse(parts[0]);
      final cachedLng = double.tryParse(parts[1]);
      if (cachedLat == null || cachedLng == null) continue;
      if (_haversineMeters(latitude, longitude, cachedLat, cachedLng) <= _reverseGeocodeProximityMeters) {
        return entry.value;
      }
    }
    return null;
  }

  static Future<Map<String, dynamic>>
      reverseGeocode({

    required double latitude,

    required double longitude,
  }) async {

    final key =

        '${latitude.toStringAsFixed(5)},'
        '${longitude.toStringAsFixed(5)}';

    if (
      _reverseGeocodeCache
          .containsKey(key)
    ) {

      return
          _reverseGeocodeCache[
              key]!;
    }

    final nearbyResult = _findNearbyReverseGeocodeResult(latitude, longitude);
    if (nearbyResult != null) {
      return nearbyResult;
    }

    try {

      final response =
          await dio.get(

        'https://api.olamaps.io/places/v1/reverse-geocode',

        queryParameters: {

          'latlng':
              '$latitude,$longitude',

          'api_key':
              apiKey,
        },
      );

      if (
        response.statusCode != 200
      ) {

        return {
          'formatted_address': 'Selected Location',
          'city': 'Other',
        };
      }

      var responseData = response.data;
      if (responseData is String) {
        responseData = jsonDecode(responseData);
      }

      final results =
          responseData[
              'results'];

      if (

        results == null

        ||

        results is! List

        ||

        results.isEmpty

      ) {

        return {
          'formatted_address': 'Selected Location',
          'city': 'Other',
        };
      }

      final address =

          results[0][
                  'formatted_address']
              ?.toString()

          ??

          'Selected Location';

      final city = _extractCityFromComponents(results[0]['address_components']) ?? '';

      final data = {
        'formatted_address': address,
        'city': city,
      };

      _putBounded(
          _reverseGeocodeCache, key, data);

      return data;

    } catch (e) {

      log(
        'REVERSE GEOCODE ERROR => $e',
      );

      return {
        'formatted_address': 'Selected Location',
        'city': 'Other',
      };
    }
  }

  // =====================================================
  // GEOCODE
  // =====================================================

  static Future<Map<String, dynamic>?>
      getCoordinatesFromAddress(
    String address,
  ) async {

    final key =

        address
            .trim()
            .toLowerCase();

    if (key.isEmpty) {

      return null;
    }

    if (
      _geocodeCache
          .containsKey(key)
    ) {

      return
          _geocodeCache[key];
    }

    try {

      final response =
          await dio.get(

        'https://api.olamaps.io/places/v1/geocode',

        queryParameters: {

          'address':
              address,

          'api_key':
              apiKey,
        },
      );

      if (
        response.statusCode != 200
      ) {

        return null;
      }

      var responseData = response.data;
      if (responseData is String) {
        responseData = jsonDecode(responseData);
      }

      final results =

          responseData[
              'geocodingResults'];

      if (

        results == null

        ||

        results is! List

        ||

        results.isEmpty

      ) {

        return null;
      }

      final location =
          results.first;

      final lat =

          location['geometry']
                  ?['location']
              ?['lat'];

      final lng =

          location['geometry']
                  ?['location']
              ?['lng'];

      if (
        lat == null ||
        lng == null
      ) {

        return null;
      }

      final formattedAddress = location['formatted_address']?.toString() ?? '';
      final city = _extractCityFromComponents(location['address_components']) ?? '';

      final data = {

        'latitude':
            (lat as num)
                .toDouble(),

        'longitude':
            (lng as num)
                .toDouble(),

        'formatted_address':
            formattedAddress,

        'city':
            city,
      };

      _putBounded(
          _geocodeCache, key, data);

      return data;

    } catch (e) {

      log(
        'GEOCODE ERROR => $e',
      );

      return null;
    }
  }

  // =====================================================
  // PLACE DETAILS
  // =====================================================

  static Future<Map<String, dynamic>?>
      getCoordinatesFromPlaceId(
    String placeId,
  ) async {
    final key = placeId.trim();
    if (key.isEmpty) {
      return null;
    }

    if (_placeDetailsCache.containsKey(key)) {
      return _placeDetailsCache[key];
    }

    try {
      final response = await dio.get(
        'https://api.olamaps.io/places/v1/details',
        queryParameters: {
          'place_id': placeId,
          'api_key': apiKey,
        },
      );

      if (response.statusCode != 200) {
        return null;
      }

      var responseData = response.data;
      if (responseData is String) {
        responseData = jsonDecode(responseData);
      }

      final result = responseData['result'];
      if (result == null) {
        return null;
      }

      final geometry = result['geometry'];
      if (geometry == null) {
        return null;
      }

      final location = geometry['location'];
      if (location == null) {
        return null;
      }

      final lat = location['lat'];
      final lng = location['lng'];

      if (lat == null || lng == null) {
        return null;
      }

      final formattedAddress = result['formatted_address']?.toString() ?? '';
      final city = _extractCityFromComponents(result['address_components']) ?? '';

      final data = {
        'latitude': (lat as num).toDouble(),
        'longitude': (lng as num).toDouble(),
        'formatted_address': formattedAddress,
        'city': city,
      };

      _putBounded(_placeDetailsCache, key, data);
      return data;
    } catch (e) {
      log('PLACE DETAILS ERROR => $e');
      return null;
    }
  }

  // =====================================================
  // DIRECTIONS
  // =====================================================

  // [timeout] (optional, opt-in): when supplied, the underlying HTTP request is *actually
  // cancelled* the moment this Duration elapses, instead of being left running against the shared
  // Dio's 15s connect/receive/send ceiling. This closes the window where a caller that stopped
  // waiting (its own `.timeout(...)`) had released its in-flight guard while the request kept
  // burning for several more seconds -- long enough for a second, overlapping Directions request
  // to start. Callers that pass nothing get byte-for-byte the previous behavior (single POST,
  // shared 15s Dio ceiling, no CancelToken). The per-call CancelToken is created here, never
  // shared, and only ever cancelled by this method's own timeout -- it can never cancel a request
  // another caller still needs. getDirections() has no other in-flight de-duplication (only the
  // exact-key [_routeCache] below); that is unchanged.
  static Future<RouteModel?>
      getDirections({

    required double originLat,

    required double originLng,

    required double destinationLat,

    required double destinationLng,

    Duration? timeout,
  }) async {

    final cacheKey =

        '${originLat.toStringAsFixed(5)},'
        '${originLng.toStringAsFixed(5)}_'
        '${destinationLat.toStringAsFixed(5)},'
        '${destinationLng.toStringAsFixed(5)}';

    // CACHE

    if (
      _routeCache
          .containsKey(cacheKey)
    ) {

      return
          _routeCache[
              cacheKey];
    }

    final cancelToken = CancelToken();
    Timer? timeoutTimer;
    if (timeout != null) {
      timeoutTimer = Timer(timeout, () {
        if (!cancelToken.isCancelled) {
          cancelToken.cancel(
            'getDirections: caller timeout (${timeout.inMilliseconds}ms) elapsed',
          );
        }
      });
    }

    try {

      final response =
          await dio.post(

        'https://api.olamaps.io/routing/v1/directions',

        queryParameters: {

          'origin':
              '$originLat,$originLng',

          'destination':

              '$destinationLat,$destinationLng',

          'api_key':
              apiKey,
        },

        cancelToken: cancelToken,
      );

      if (
        response.statusCode != 200
      ) {

        return null;
      }

      var responseData = response.data;
      if (responseData is String) {
        responseData = jsonDecode(responseData);
      }

      final routes =
          responseData[
              'routes'];

      if (

        routes == null

        ||

        routes is! List

        ||

        routes.isEmpty

      ) {

        return null;
      }

      final firstRoute =
          routes.first;

      final legs =
          firstRoute['legs'];

      if (

        legs == null

        ||

        legs is! List

        ||

        legs.isEmpty

      ) {

        return null;
      }

      final firstLeg =
          legs.first;

      final distanceMeters =

          (firstLeg['distance']
                  as num?)

              ?.toDouble()

          ??

          0;

      final durationSeconds =

          (firstLeg['duration']
                  as num?)

              ?.toDouble()

          ??

          0;

      // POLYLINE

      final overviewPolyline = firstRoute['overview_polyline'];
      String encodedPolyline = '';
      if (overviewPolyline is String) {
        encodedPolyline = overviewPolyline;
      } else if (overviewPolyline is Map) {
        encodedPolyline = overviewPolyline['points']?.toString() ?? '';
      }

      final polylinePoints =

          decodePolyline(
        encodedPolyline,
      );

      if (
        polylinePoints.isEmpty
      ) {

        return null;
      }

      final bounds =
          calculateBounds(
        polylinePoints,
      );

      final route = RouteModel(

        distanceMeters:
            distanceMeters,

        durationSeconds:
            durationSeconds,

        polylinePoints:
            polylinePoints,

        bounds:
            bounds,
      );

      _putBounded(
          _routeCache, cacheKey, route);

      return route;

    } on DioException catch (e) {

      // A caller-timeout cancellation is NOT an API failure -- the caller has simply stopped
      // waiting. Surface it as "no route" (identical downstream handling to a genuine failure)
      // but keep it distinct from a real Ola error in the logs, and never poison the cache.
      if (CancelToken.isCancel(e)) {

        log(
          'DIRECTIONS CANCELLED => ${e.message}',
        );

        return null;
      }

      log(
        'DIRECTIONS ERROR => $e',
      );

      return null;

    } catch (e) {

      log(
        'DIRECTIONS ERROR => $e',
      );

      return null;

    } finally {

      timeoutTimer?.cancel();
    }
  }

  // =====================================================
  // MULTI-STOP ROUTE (additive -- does NOT change getDirections()'s signature/behavior; every
  // existing caller of getDirections() is unaffected. This method is only used by the Intercity
  // "Post Travel Plan" declared-route / Via-locations feature -- see docs/13_Business_Logic.md
  // section 5.)
  // =====================================================
  //
  // Builds ONE ordered route through a traveller-declared sequence of stops
  // (origin -> via 1 -> via 2 -> ... -> destination) by requesting each consecutive pair as a
  // SEPARATE leg through the existing, proven getDirections() call, then stitching the legs
  // together. This deliberately does NOT use any Ola multi-waypoint/`waypoints` request
  // parameter: only the origin->destination directions behavior that getDirections() already
  // relies on in production is used, so there is no dependency on an unverified API parameter.
  //
  // Returns null (never throws) if [stops] has fewer than 2 entries, or if ANY single leg fails
  // to resolve -- the caller MUST treat null as "could not build the declared route" and must
  // not persist a partial/corrupted route (docs/13_Business_Logic.md section 5.1).
  static Future<MultiStopRoute?> getMultiStopRoute({
    required List<Map<String, double>> stops,
  }) async {
    if (stops.length < 2) return null;

    final combinedPoints = <Map<String, double>>[];
    final cumulativeKm = <double>[0.0];
    double totalDistanceMeters = 0;
    double totalDurationSeconds = 0;

    for (var i = 0; i < stops.length - 1; i++) {
      final from = stops[i];
      final to = stops[i + 1];
      final originLat = from['lat'];
      final originLng = from['lng'];
      final destLat = to['lat'];
      final destLng = to['lng'];
      if (originLat == null || originLng == null || destLat == null || destLng == null) {
        return null;
      }

      final leg = await getDirections(
        originLat: originLat,
        originLng: originLng,
        destinationLat: destLat,
        destinationLng: destLng,
      );
      // A single failed leg invalidates the whole declared route -- never stitch a route with a
      // hole in it.
      if (leg == null || leg.polylinePoints.isEmpty) {
        return null;
      }

      // Stitch: drop this leg's first point when it coincides with the previous leg's last
      // point (consecutive legs share the intermediate stop), otherwise keep every point.
      var legPoints = leg.polylinePoints;
      if (combinedPoints.isNotEmpty && legPoints.isNotEmpty) {
        final prev = combinedPoints.last;
        final first = legPoints.first;
        final samePoint = (prev['lat']! - first['lat']!).abs() < 1e-6 &&
            (prev['lng']! - first['lng']!).abs() < 1e-6;
        if (samePoint) {
          legPoints = legPoints.sublist(1);
        }
      }
      combinedPoints.addAll(legPoints);

      totalDistanceMeters += leg.distanceMeters;
      totalDurationSeconds += leg.durationSeconds;
      cumulativeKm.add(totalDistanceMeters / 1000);
    }

    if (combinedPoints.length < 2) return null;

    return MultiStopRoute(
      route: RouteModel(
        distanceMeters: totalDistanceMeters,
        durationSeconds: totalDurationSeconds,
        polylinePoints: combinedPoints,
        bounds: calculateBounds(combinedPoints),
      ),
      cumulativeKm: cumulativeKm,
    );
  }

  // =====================================================
  // POLYLINE DECODER
  // =====================================================

  static List<Map<String, double>>
      decodePolyline(
    String encoded,
  ) {

    List<Map<String, double>>
        poly = [];

    int index = 0;

    int lat = 0;

    int lng = 0;

    while (
      index < encoded.length
    ) {

      int b;

      int shift = 0;

      int result = 0;

      do {

        b =
            encoded.codeUnitAt(
                  index++,
                ) -
                63;

        result |=
            (b & 0x1f)
                << shift;

        shift += 5;

      } while (b >= 0x20);

      final dlat =

          ((result & 1) != 0)

              ? ~(result >> 1)

              : (result >> 1);

      lat += dlat;

      shift = 0;

      result = 0;

      do {

        b =
            encoded.codeUnitAt(
                  index++,
                ) -
                63;

        result |=
            (b & 0x1f)
                << shift;

        shift += 5;

      } while (b >= 0x20);

      final dlng =

          ((result & 1) != 0)

              ? ~(result >> 1)

              : (result >> 1);

      lng += dlng;

      poly.add({

        'lat':
            lat / 1E5,

        'lng':
            lng / 1E5,
      });
    }

    return poly;
  }

  // =====================================================
  // BOUNDS
  // =====================================================

  static Map<String, double>
      calculateBounds(

    List<Map<String, double>>
        points,
  ) {

    double minLat =
        points.first['lat']!;

    double maxLat =
        points.first['lat']!;

    double minLng =
        points.first['lng']!;

    double maxLng =
        points.first['lng']!;

    for (final point in points) {

      minLat =
          min(
        minLat,
        point['lat']!,
      );

      maxLat =
          max(
        maxLat,
        point['lat']!,
      );

      minLng =
          min(
        minLng,
        point['lng']!,
      );

      maxLng =
          max(
        maxLng,
        point['lng']!,
      );
    }

    return {

      'minLat': minLat,
      'maxLat': maxLat,

      'minLng': minLng,
      'maxLng': maxLng,
    };
  }

  // =====================================================
  // CLEAR CACHE
  // =====================================================

  static void clearCaches() {

    _autocompleteCache.clear();

    _reverseGeocodeCache.clear();

    _geocodeCache.clear();

    _routeCache.clear();

    _placeDetailsCache.clear();
  }
}