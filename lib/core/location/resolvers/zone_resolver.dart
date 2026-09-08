import 'package:waydrop/core/location/models/zone_match_result.dart';

abstract class ZoneResolver {
  ZoneMatchResult? resolveZone({required double lat, required double lng});
}
