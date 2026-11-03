import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';

class _ClosingGps extends GeolocatorPlatform {
  var positions = StreamController<Position>.broadcast();
  final status = StreamController<ServiceStatus>.broadcast();
  int starts = 0;
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;
  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => Position(
    latitude: 17,
    longitude: 79,
    timestamp: DateTime.now(),
    accuracy: 2,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    starts++;
    return positions.stream;
  }

  @override
  Stream<ServiceStatus> getServiceStatusStream() => status.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'normal GPS stream completion releases its handle so tracking can restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final original = GeolocatorPlatform.instance;
      final gps = _ClosingGps();
      GeolocatorPlatform.instance = gps;
      await Supabase.initialize(
        url: 'https://example.invalid',
        anonKey: 'test-public-key',
        httpClient: MockClient(
          (request) async => http.Response(
            '[]',
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          ),
        ),
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      );
      try {
        await LocationCacheService.startRiderLiveTracking();
        expect(gps.starts, 1);
        await gps.positions.close();
        await Future<void>.delayed(Duration.zero);
        expect(LocationCacheService.riderLocationStream, isNull);
        gps.positions = StreamController<Position>.broadcast();
        await LocationCacheService.startRiderLiveTracking();
        expect(gps.starts, 2);
        expect(LocationCacheService.riderLocationStream, isNotNull);
      } finally {
        await LocationCacheService.stopRiderLiveTracking();
        GeolocatorPlatform.instance = original;
        await gps.positions.close();
        await gps.status.close();
        await Supabase.instance.dispose();
      }
    },
  );
}
