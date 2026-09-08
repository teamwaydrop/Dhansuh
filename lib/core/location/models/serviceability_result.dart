import 'package:waydrop/core/location/models/cached_zone.dart';

class ServiceabilityResult {
  final bool isServiceable;
  final CachedZone? zone;
  final double? distanceKm;
  final String city;

  ServiceabilityResult({
    required this.isServiceable,
    this.zone,
    this.distanceKm,
    required this.city,
  });

  String? get zoneCode => zone?.code;
}
