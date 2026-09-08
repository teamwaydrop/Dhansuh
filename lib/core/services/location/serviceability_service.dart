import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/core/location/models/cached_zone.dart';
import 'package:waydrop/core/location/models/serviceability_result.dart';
import 'package:waydrop/core/location/resolvers/zone_resolver.dart';
import 'package:waydrop/core/location/resolvers/geofence_zone_resolver.dart';
import 'package:waydrop/core/services/developer/developer_mode_service.dart';

class ServiceabilityService {
  static List<Map<String, dynamic>>? _cachedActiveZones;
  static List<CachedZone>? _cachedZones;
  static bool _isLoadingZones = false;
  static DateTime? _lastLoadedTime;

  static const Duration zoneCacheTtl = Duration(minutes: 15);

  static List<Map<String, dynamic>>? get cachedActiveZones => _cachedActiveZones;
  static List<CachedZone>? get cachedZones => _cachedZones;

  static ZoneResolver _zoneResolver = GeofenceZoneResolver([]);
  static ZoneResolver get zoneResolver => _zoneResolver;

  /// Loads active pricing zones from the database to dynamically determine serviceability.
  /// Enforces a 15-minute Cache TTL unless forceRefresh is true.
  static Future<void> loadActiveZones({bool forceRefresh = false}) async {
    final now = DateTime.now();
    if (_cachedActiveZones != null && 
        !forceRefresh && 
        _lastLoadedTime != null && 
        now.difference(_lastLoadedTime!) < zoneCacheTtl) {
      return;
    }
    if (_isLoadingZones) return;
    _isLoadingZones = true;
    try {
      final supabase = Supabase.instance.client;
      final response = await supabase
          .from('pricing_zones')
          .select('id, zone_code, zone_name, zone_type, cities, center_lat, center_lng, radius_km, zone_shape')
          .eq('is_active', true);
      
      final rawList = List<Map<String, dynamic>>.from(response);
      _cachedActiveZones = rawList;
      _lastLoadedTime = now;

      final parsed = <CachedZone>[];
      for (final zone in rawList) {
        final id = zone['id']?.toString() ?? '';
        final code = zone['zone_code']?.toString() ?? '';
        final name = zone['zone_name']?.toString() ?? '';
        final citiesVal = zone['cities'];
        final citiesList = <String>[];

        if (citiesVal is List) {
          citiesList.addAll(citiesVal.map((e) => e.toString().trim()));
        } else if (citiesVal is String) {
          final cleanVal = citiesVal.trim();
          if (cleanVal.isNotEmpty) {
            final stripped = cleanVal
                .replaceAll('[', '')
                .replaceAll(']', '')
                .replaceAll('{', '')
                .replaceAll('}', '')
                .replaceAll('"', '')
                .replaceAll("'", '');
            citiesList.addAll(stripped.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty));
          }
        }

        final centerLat = double.tryParse(zone['center_lat']?.toString() ?? '');
        final centerLng = double.tryParse(zone['center_lng']?.toString() ?? '');
        final radiusKm = double.tryParse(zone['radius_km']?.toString() ?? '');
        final zoneShape = zone['zone_shape']?.toString();
        
        parsed.add(CachedZone(
          id: id,
          code: code,
          name: name,
          cities: citiesList,
          centerLat: centerLat,
          centerLng: centerLng,
          radiusKm: radiusKm,
          zoneShape: zoneShape,
          loadedAt: now,
        ));
      }
      _cachedZones = parsed;
      _zoneResolver = GeofenceZoneResolver(parsed);

      debugPrint('Loaded ${parsed.length} active pricing zones from DB with TTL stamp.');
      
      // Notify location cache of new loading
      LocationCacheService.updateServiceability();
    } catch (e) {
      debugPrint('Error loading active zones: $e');
    } finally {
      _isLoadingZones = false;
    }
  }

  /// Refreshes pricing zones, bypassing the TTL check.
  static Future<void> refreshZones() async {
    await loadActiveZones(forceRefresh: true);
  }

  /// Helper to resolve the matching zone for a specific city.
  static CachedZone? findMatchingZone({double? lat, double? lng}) {
    if (lat == null || lng == null) return null;
    final match = _zoneResolver.resolveZone(lat: lat, lng: lng);
    return match?.zone;
  }

  /// Determines if the given location (address and/or coordinates) is serviceable.
  /// If location information is not yet loaded, it returns a placeholder result with isServiceable = true
  /// to avoid false-positive blocking.
  static Future<ServiceabilityResult> isLocationServiceable({
    String? address,
    double? latitude,
    double? longitude,
    String? city,
  }) async {
    // Developer Test Mode: flagged/admin accounts bypass service-area
    // restrictions entirely so they can test booking flows anywhere.
    if (DeveloperModeService.instance.isDeveloperTestModeEnabled) {
      return ServiceabilityResult(isServiceable: true, city: city ?? '');
    }

    final bool hasNoAddress = address == null ||
        address.trim().isEmpty ||
        address == 'Fetching location...' ||
        address == 'Selected Location';
    final bool hasNoCoords = latitude == null || longitude == null;

    if (hasNoAddress && hasNoCoords) {
      return ServiceabilityResult(isServiceable: true, city: '');
    }

    if (_cachedActiveZones == null) {
      await loadActiveZones();
      // If still loading or failed, return true to avoid premature SnackBar blocks
      if (_cachedActiveZones == null) {
        return ServiceabilityResult(isServiceable: true, city: '');
      }
    }

    if (latitude == null || longitude == null) {
      return ServiceabilityResult(isServiceable: true, city: '');
    }

    final match = _zoneResolver.resolveZone(lat: latitude, lng: longitude);
    bool isServiceable = match != null;
    CachedZone? resolvedZone = match?.zone;
    double? resolvedDistance = match?.distanceKm;

    if (!isServiceable && city != null && city.trim().isNotEmpty) {
      final cleanCity = city.trim().toLowerCase();
      if (_cachedZones != null) {
        for (final zone in _cachedZones!) {
          if (zone.cities.any((c) => c.toLowerCase() == cleanCity)) {
            isServiceable = true;
            resolvedZone = zone;
            resolvedDistance = 0.0;
            break;
          }
        }
      }
    }

    // Secondary fallback: if the city check above didn't match but we have an address, check if the address string contains any city in the zone
    if (!isServiceable && address != null && address.isNotEmpty && _cachedZones != null) {
      final cleanAddress = address.toLowerCase();
      for (final zone in _cachedZones!) {
        for (final c in zone.cities) {
          if (c.isNotEmpty && cleanAddress.contains(c.toLowerCase())) {
            isServiceable = true;
            resolvedZone = zone;
            resolvedDistance = 0.0;
            break;
          }
        }
        if (isServiceable) break;
      }
    }

    debugPrint('[Serviceability Check] Coordinates: ($latitude, $longitude)');
    debugPrint('[Serviceability Check] Zone Match: "${resolvedZone?.name ?? 'None'}"');
    debugPrint('[Serviceability Check] Distance: $resolvedDistance km');
    debugPrint('[Serviceability Check] Serviceable: $isServiceable');

    return ServiceabilityResult(
      isServiceable: isServiceable,
      zone: resolvedZone,
      distanceKm: resolvedDistance,
      city: resolvedZone?.name ?? city ?? '',
    );
  }
}
