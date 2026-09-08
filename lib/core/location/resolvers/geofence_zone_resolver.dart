import 'dart:math';
import 'package:waydrop/core/location/models/cached_zone.dart';
import 'package:waydrop/core/location/models/zone_match_result.dart';
import 'package:waydrop/core/location/resolvers/zone_resolver.dart';

class GeofenceZoneResolver implements ZoneResolver {
  final List<CachedZone> zones;

  GeofenceZoneResolver(this.zones);

  @override
  ZoneMatchResult? resolveZone({required double lat, required double lng}) {
    ZoneMatchResult? bestMatch;
    double? minDistance;

    for (final zone in zones) {
      if (zone.centerLat == null || zone.centerLng == null || zone.radiusKm == null) {
        continue;
      }

      final distance = _calculateHaversineDistance(
        lat,
        lng,
        zone.centerLat!,
        zone.centerLng!,
      );

      if (distance <= zone.radiusKm!) {
        if (minDistance == null || distance < minDistance) {
          minDistance = distance;
          bestMatch = ZoneMatchResult(
            zone: zone,
            distanceKm: distance,
          );
        }
      }
    }

    return bestMatch;
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
}
