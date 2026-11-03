import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/location/serviceability_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Completer<void> gate;
  var calls = 0;
  var status = 200;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'synthetic-public-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/rest/v1/pricing_zones');
        calls++;
        await gate.future;
        return http.Response(
          jsonEncode(
            status == 200
                ? [
                    {
                      'id': 'synthetic-zone',
                      'zone_code': 'SYNTHETIC',
                      'zone_name': 'Synthetic',
                      'cities': ['Synthetic'],
                      'center_lat': 16.5,
                      'center_lng': 80.6,
                      'radius_km': 10,
                    },
                  ]
                : {'message': 'synthetic failure'},
          ),
          status,
          request: request,
        );
      }),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());

  test('concurrent callers wait for the actual shared zone result', () async {
    gate = Completer<void>();
    var secondCompleted = false;
    final first = ServiceabilityService.loadActiveZones(forceRefresh: true);
    final second = ServiceabilityService.loadActiveZones().then(
      (_) => secondCompleted = true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    try {
      expect(secondCompleted, isFalse);
    } finally {
      gate.complete();
      await Future.wait([first, second]);
    }
    expect(ServiceabilityService.cachedZones?.single.id, 'synthetic-zone');
  });

  test(
    'TTL hit adds no query; a forced refresh is shared with a normal caller',
    () async {
      final before = calls;
      await ServiceabilityService.loadActiveZones();
      expect(calls, before);
      gate = Completer<void>();
      var joined = false;
      final forced = ServiceabilityService.refreshZones();
      final normal = ServiceabilityService.loadActiveZones().then(
        (_) => joined = true,
      );
      await Future<void>.delayed(Duration.zero);
      try {
        expect(calls, before + 1);
        expect(joined, isFalse);
      } finally {
        gate.complete();
        await Future.wait([forced, normal]);
      }
    },
  );

  test(
    'failure preserves zones and releases shared ownership for explicit retry',
    () async {
      final before = calls;
      status = 503;
      gate = Completer<void>()..complete();
      await ServiceabilityService.refreshZones();
      expect(ServiceabilityService.cachedZones?.single.id, 'synthetic-zone');
      status = 200;
      await ServiceabilityService.refreshZones();
      expect(calls, before + 2);
    },
  );
}
