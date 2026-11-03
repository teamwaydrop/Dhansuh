import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/modules/payments/controllers/pricing_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <Map<String, dynamic>>[];
  final gates = <String, Completer<void>>{};
  final failed = <String>{};
  final pending = <Future<void>>[];
  final controllers = <PricingController>[];
  final disposed = <PricingController>{};
  var authUid = '00000000-0000-4000-8000-000000000511';
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  late StreamController<int> started;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'synthetic-public',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        if (r.url.path.endsWith('/logout')) return http.Response('', 204);
        if (r.url.path.endsWith('/token')) {
          return http.Response(
            jsonEncode({
              'access_token':
                  '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': authUid, 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000})}.synthetic',
              'refresh_token': 'synthetic',
              'expires_in': 3600,
              'token_type': 'bearer',
              'user': {
                'id': authUid,
                'aud': 'authenticated',
                'created_at': '2026-01-01T00:00:00Z',
                'app_metadata': {},
                'user_metadata': {},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        final token = (r.headers['authorization'] ?? '').split(' ').last;
        final tokenParts = token.split('.');
        final owner = tokenParts.length == 3
            ? (jsonDecode(
                    utf8.decode(
                      base64Url.decode(base64Url.normalize(tokenParts[1])),
                    ),
                  )
                  as Map)['sub']
            : null;
        requests.add(body);
        started.add(requests.length);
        final address = body['pickup_address'] as String;
        final gate = gates['$address|$owner'] ?? gates[address];
        await gate?.future;
        return http.Response(
          jsonEncode(
            failed.contains(address)
                ? {'message': 'synthetic unavailable'}
                : {
                    'pricing': {
                      'final_fare': body['distance_km'],
                      'vehicle_type': body['vehicle_type'],
                      'quoted_for': owner,
                    },
                  },
          ),
          failed.contains(address) ? 503 : 200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
  });
  setUp(() async {
    if (Supabase.instance.client.auth.currentUser != null) {
      await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
    }
    requests.clear();
    gates.clear();
    failed.clear();
    pending.clear();
    controllers.clear();
    disposed.clear();
    started = StreamController<int>.broadcast(sync: true);
  });
  tearDown(() async {
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await Future.wait(pending.map((f) => f.catchError((Object _) {})));
    for (final c in controllers) {
      if (!disposed.contains(c)) c.dispose();
    }
    await started.close();
  });
  tearDownAll(() async => Supabase.instance.dispose());
  PricingController controller() {
    final c = PricingController();
    controllers.add(c);
    return c;
  }

  Future<void> fetch(
    PricingController c, {
    String address = 'synthetic',
    double distance = 5,
    double lat = 17.1,
  }) {
    final f = c.fetchMultiplePricing(
      orderType: 'intercity_parcel',
      distanceKm: distance,
      pickupAddress: address,
      maxBoostAmount: 0,
      weightCategory: '2',
      pickupLat: lat,
      pickupLng: 78.1,
    );
    f.ignore();
    pending.add(f);
    return f;
  }

  Future<void> count(int n) async {
    if (requests.length >= n) return;
    await started.stream
        .firstWhere((v) => v >= n)
        .timeout(const Duration(seconds: 5));
  }

  test(
    'successful quote completes without an artificial half-second wait',
    () async {
      final c = controller();
      final work = fetch(c);
      final timed = Completer<bool>();
      final timer = Timer(
        const Duration(milliseconds: 200),
        () => timed.complete(false),
      );
      work.then((_) {
        if (!timed.isCompleted) timed.complete(true);
      });
      try {
        expect(await timed.future, isTrue);
        expect(c.loading, isFalse);
        expect(c.getFinalFare('bike'), 5);
      } finally {
        timer.cancel();
        await work;
      }
    },
  );
  test('older quote completion cannot overwrite a newer request', () async {
    final c = controller();
    gates['old'] = Completer<void>();
    final old = fetch(c, address: 'old', distance: 1);
    await count(1);
    await fetch(c, address: 'fresh', distance: 9);
    expect(c.getFinalFare('bike'), 9);
    gates['old']!.complete();
    await old;
    expect(c.getFinalFare('bike'), 9);
  });
  test(
    'older failure cannot clear loading or set error for a pending newer quote',
    () async {
      final c = controller();
      gates['old'] = Completer<void>();
      gates['fresh'] = Completer<void>();
      failed.add('old');
      final old = fetch(c, address: 'old');
      await count(1);
      final fresh = fetch(c, address: 'fresh');
      await count(2);
      gates['old']!.complete();
      await old;
      expect(c.loading, isTrue);
      expect(c.error, isEmpty);
      gates['fresh']!.complete();
      await fresh;
    },
  );
  test('reset invalidates an unfinished quote', () async {
    final c = controller();
    gates['synthetic'] = Completer<void>();
    final work = fetch(c);
    await count(1);
    c.reset();
    gates['synthetic']!.complete();
    await work;
    expect(c.pricingData, isEmpty);
    expect(c.loading, isFalse);
    expect(c.error, isEmpty);
  });
  test('disposed controller never publishes late quote state', () async {
    final c = controller();
    gates['synthetic'] = Completer<void>();
    final work = fetch(c);
    await count(1);
    c.dispose();
    disposed.add(c);
    gates['synthetic']!.complete();
    await expectLater(work, completes);
    expect(c.pricingData, isEmpty);
  });
  test('distinct exact distance inputs cannot share a rounded quote', () async {
    final c = controller();
    gates['synthetic'] = Completer<void>();
    final one = fetch(c, distance: 5.001);
    final two = fetch(c, distance: 5.004);
    await count(1);
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(2));
    gates['synthetic']!.complete();
    await Future.wait([one, two]);
    expect(c.getFinalFare('bike'), 5.004);
  });
  test('distinct exact coordinates cannot share a rounded quote', () async {
    final c = controller();
    gates['synthetic'] = Completer<void>();
    final one = fetch(c, lat: 17.100001);
    final two = fetch(c, lat: 17.100004);
    await count(1);
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(2));
    gates['synthetic']!.complete();
    await Future.wait([one, two]);
  });
  test(
    'identical requests still share pending work and completed work revalidates',
    () async {
      final c = controller();
      gates['synthetic'] = Completer<void>();
      final work = List.generate(5, (_) => fetch(c));
      await count(1);
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(1));
      gates['synthetic']!.complete();
      await Future.wait(work);
      await fetch(c);
      expect(requests, hasLength(2));
    },
  );
  test(
    'account switch cannot share or publish the earlier account quote',
    () async {
      final c = controller();
      authUid = '00000000-0000-4000-8000-000000000511';
      await Supabase.instance.client.auth.setSession('synthetic-A');
      final oldOwner = authUid;
      gates['synthetic|$oldOwner'] = Completer<void>();
      final old = fetch(c);
      await count(1);
      authUid = '00000000-0000-4000-8000-000000000512';
      await Supabase.instance.client.auth.setSession('synthetic-B');
      await fetch(c);
      expect(requests, hasLength(2));
      expect(c.getVehiclePricing('bike')?['quoted_for'], authUid);
      gates['synthetic|$oldOwner']!.complete();
      await old;
      expect(c.getVehiclePricing('bike')?['quoted_for'], authUid);
    },
  );
  test(
    'retry after timeout retains an outstanding raw pricing request',
    () async {
      final c = controller();
      gates['synthetic'] = Completer<void>();
      await fetch(c);
      final retry = fetch(c);
      gates['synthetic']!.complete();
      await retry;
      expect(requests, hasLength(1));
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
