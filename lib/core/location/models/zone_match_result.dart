import 'package:waydrop/core/location/models/cached_zone.dart';

class ZoneMatchResult {
  final CachedZone zone;
  final double distanceKm;

  const ZoneMatchResult({
    required this.zone,
    required this.distanceKm,
  });
}
