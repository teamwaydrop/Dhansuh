class CachedZone {
  final String id;
  final String code;
  final String name;
  final List<String> cities;
  final double? centerLat;
  final double? centerLng;
  final double? radiusKm;
  final String? zoneShape;
  final DateTime loadedAt;

  const CachedZone({
    required this.id,
    required this.code,
    required this.name,
    required this.cities,
    this.centerLat,
    this.centerLng,
    this.radiusKm,
    this.zoneShape,
    required this.loadedAt,
  });
}
