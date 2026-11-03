import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/modules/notifications/services/notification_badge_service.dart';
import 'package:waydrop/features/auth/screens/profile_setup_screen.dart';
import 'package:waydrop/shared/widgets/account_guard.dart';
import 'package:waydrop/main.dart';
import 'package:waydrop/core/providers/notification_badge_provider.dart';
import 'package:waydrop/core/services/session/rider_access_service.dart';

Position fix(double lat) => Position(
  latitude: lat,
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

class _Gps extends GeolocatorPlatform {
  final positions = StreamController<Position>.broadcast(sync: true);
  final status = StreamController<ServiceStatus>.broadcast();
  final permission = Completer<LocationPermission>();
  int starts = 0;
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Future<LocationPermission> checkPermission() => permission.future;
  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => fix(17);
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
  final gps = _Gps();
  final originalGps = GeolocatorPlatform.instance;
  final requests = <http.Request>[];
  Completer<http.Response>? upload;
  Completer<http.Response>? profileWrite;
  Completer<http.Response>? badgeCount;
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final userId = '00000000-0000-4000-8000-000000000001';
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    GeolocatorPlatform.instance = gps;
    final token =
        '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': userId, 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000})}.test';
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'test-public-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/user')) {
          return http.Response(jsonEncode({'id':userId,'aud':'authenticated','created_at':'2026-01-01T00:00:00Z','app_metadata':{},'user_metadata':{}}),200,request:request,headers:{'content-type':'application/json'});
        }
        if (request.url.path.contains('/auth/')) {
          return http.Response(
            jsonEncode({
              'access_token': token,
              'refresh_token': 'test',
              'expires_in': 3600,
              'token_type': 'bearer',
              'user': {
                'id': userId,
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
        if (request.url.path.endsWith('/notifications')) {
          if (badgeCount != null) {
            final response = await badgeCount!.future;
            return http.Response(response.body, response.statusCode,
                request: request, headers: response.headers);
          }
          return http.Response(
            '',
            200,
            request: request,
            headers: {'content-range': '0-0/7'},
          );
        }
        if (request.url.path.endsWith('/pricing_zones')) {
          return http.Response(
            '[]',
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/users')) {
          if (request.method == 'POST' && profileWrite != null) {
            return profileWrite!.future;
          }
          return http.Response(
            jsonEncode({'id': userId, 'role': 'user', 'deleted_at': null}),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/riders') && request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'id': 'rider-id',
              'user_id': userId,
              'service_mode': 'local',
              'account_status': 'online',
            }),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/rider_kyc')) {
          return http.Response(
            jsonEncode({
              'kyc_status': 'approved',
              'activation_status': 'active',
            }),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/rider_payout_accounts')) {
          return http.Response(
            jsonEncode({'id': 'active-payout'}),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'PATCH') {
          if (upload != null) {
            final response = await upload!.future;
            return http.Response(
              response.body,
              response.statusCode,
              request: request,
            );
          }
          return http.Response('', 204, request: request);
        }
        throw StateError(
          'Unexpected test request: ${request.method} ${request.url.path}',
        );
      }),
    );
    await Supabase.instance.client.auth.setSession('test-refresh');
  });
  tearDownAll(() async {
    await LocationCacheService.stopRiderLiveTracking();
    GeolocatorPlatform.instance = originalGps;
    await gps.positions.close();
    await gps.status.close();
    await Supabase.instance.dispose();
  });

  test(
    'concurrent starts open one stream; skipped fixes never release another upload lock',
    () async {
      upload = Completer<http.Response>();
      final first = LocationCacheService.startRiderLiveTracking();
      final second = LocationCacheService.startRiderLiveTracking();
      gps.permission.complete(LocationPermission.always);
      await Future.wait([first, second]);
      await Future<void>.delayed(Duration.zero);
      expect(gps.starts, 1);
      expect(LocationCacheService.isUpdatingDb, isTrue);
      gps.positions.add(fix(17.001));
      gps.positions.add(fix(17.002));
      await Future<void>.delayed(Duration.zero);
      expect(LocationCacheService.isUpdatingDb, isTrue);
      expect(requests.where((r) => r.method == 'PATCH').length, 1);
      upload!.complete(http.Response('', 204));
      await Future<void>.delayed(Duration.zero);
      expect(LocationCacheService.isUpdatingDb, isFalse);
      expect(LocationCacheService.successfulLocationUploads, 1);
      // Identical fixes inside the heartbeat window do not cause another write.
      gps.positions.add(fix(17));
      await Future<void>.delayed(Duration.zero);
      expect(requests.where((r) => r.method == 'PATCH').length, 1);
      await LocationCacheService.stopRiderLiveTracking();
      expect(LocationCacheService.riderLocationStream, isNull);
      expect(LocationCacheService.riderHeartbeatTimer, isNull);
      expect(LocationCacheService.gpsStatusStream, isNull);
    },
  );

  test(
    'unread badge requests an exact HEAD count, with no notification row body',
    () async {
      await NotificationBadgeService.instance.refresh();
      final request = requests.singleWhere(
        (r) => r.url.path.endsWith('/notifications'),
      );
      expect(request.method, 'HEAD');
      expect(request.url.queryParameters['is_read'], 'eq.false');
      expect(request.url.queryParameters['user_id'], 'eq.$userId');
      expect(request.headers['Prefer'], contains('count=exact'));
      expect(providerContainer.read(unreadNotificationCountProvider), 7);
    },
  );

  test(
    'stopped badge listener ignores its pending count and cancels queued refresh',
    () async {
      final service = NotificationBadgeService.instance;
      final before = requests.where((r) => r.url.path.endsWith('/notifications')).length;
      badgeCount = Completer<http.Response>();
      final pending = service.refresh();
      service.refresh();
      await Future<void>.delayed(Duration.zero);
      service.stopListening();
      expect(providerContainer.read(unreadNotificationCountProvider), 0);
      badgeCount!.complete(http.Response('', 200, headers: {'content-range': '0-0/9'}));
      try {
        await pending;
        expect(providerContainer.read(unreadNotificationCountProvider), 0);
        expect(requests.where((r) => r.url.path.endsWith('/notifications')).length, before + 1);
        badgeCount = null;
        await service.refresh();
        expect(providerContainer.read(unreadNotificationCountProvider), 7);
      } finally {
        badgeCount = null;
        service.stopListening();
      }
    },
  );

  test(
    'eligibility coalesces concurrent checks but revalidates the next entry',
    () async {
      final before = requests
          .where((r) => r.url.path.endsWith('/rider_kyc'))
          .length;
      final results = await Future.wait([
        RiderAccessService.instance.resolve(),
        RiderAccessService.instance.resolve(),
      ]);
      expect(results.map((r) => r.state), everyElement(RiderAccessState.ready));
      expect(
        requests.where((r) => r.url.path.endsWith('/rider_kyc')).length,
        before + 1,
      );
      await RiderAccessService.instance.resolve();
      expect(
        requests.where((r) => r.url.path.endsWith('/rider_kyc')).length,
        before + 2,
      );
    },
  );

  test(
    'failed uploads do not advance dedup state; a 30-second heartbeat remains eligible',
    () async {
      final completedBefore = LocationCacheService.successfulLocationUploads;
      upload = Completer<http.Response>()
        ..complete(http.Response('{"message":"denied","code":"42501"}', 403));
      await LocationCacheService.startRiderLiveTracking();
      await Future<void>.delayed(Duration.zero);
      expect(LocationCacheService.lastDbUpdateTime, isNull);
      expect(LocationCacheService.successfulLocationUploads, completedBefore);
      upload = null;
      gps.positions.add(fix(17));
      await Future<void>.delayed(Duration.zero);
      expect(
        LocationCacheService.successfulLocationUploads,
        completedBefore + 1,
      );
      LocationCacheService.lastDbUpdateTime = DateTime.now().subtract(
        const Duration(seconds: 31),
      );
      gps.positions.add(fix(17));
      await Future<void>.delayed(Duration.zero);
      expect(
        LocationCacheService.successfulLocationUploads,
        completedBefore + 2,
      );
      gps.positions.add(fix(17));
      await Future<void>.delayed(Duration.zero);
      expect(
        LocationCacheService.successfulLocationUploads,
        completedBefore + 2,
      );
      await LocationCacheService.stopRiderLiveTracking();
    },
  );

  testWidgets(
    'admin guard never mounts its protected child for a regular user',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: AccountGuard(
            adminOnly: true,
            child: Text('private admin content'),
          ),
        ),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(find.text('private admin content'), findsNothing);
      expect(find.text('Access denied'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'profile submit upserts only self-owned form fields and survives disposal',
    (tester) async {
      profileWrite = Completer<http.Response>();
      await tester.pumpWidget(const MaterialApp(home: ProfileSetupScreen()));
      await tester.enterText(find.byType(TextField).first, 'Test Passenger');
      await tester.enterText(find.byType(TextField).last, 'test@example.com');
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      final request = requests.singleWhere(
        (r) => r.url.path.endsWith('/users') && r.method == 'POST',
      );
      expect(request.url.queryParameters['on_conflict'], 'id');
      expect(jsonDecode(request.body), {
        'id': userId,
        'full_name': 'Test Passenger',
        'email': 'test@example.com',
        'profile_completed': true,
      });
      expect(
        request.headers['Prefer'],
        contains('resolution=merge-duplicates'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      profileWrite!.complete(
        http.Response(
          jsonEncode({'id': userId}),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        ),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
