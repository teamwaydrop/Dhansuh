import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/features/user/home/home_tab.dart';
import 'package:waydrop/modules/notifications/services/notification_badge_service.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = '00000000-0000-4000-8000-000000000091';
  late Completer<void> ordersGate;
  var failOrders = false;
  var orderReads = 0;
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/geolocator'),
          (call) async => call.method == 'isLocationServiceEnabled' ? false : 0,
        );
    final token =
        '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': uid, 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000})}.synthetic';
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'synthetic-public-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        Object? body = [];
        var status = 200;
        if (request.url.path.endsWith('/token')) {
          body = {
            'access_token': token,
            'refresh_token': 'synthetic',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': uid,
              'aud': 'authenticated',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': {},
              'user_metadata': {},
            },
          };
        } else if (request.url.path.endsWith('/users')) {
          body = {'full_name': 'Synthetic Passenger'};
        } else if (request.url.path.endsWith('/riders') ||
            request.url.path.endsWith('/rider_kyc')) {
          body = null;
        } else if (request.url.path.endsWith('/orders')) {
          orderReads++;
          await ordersGate.future;
          if (failOrders) {
            status = 503;
            body = {'message': 'Synthetic failure'};
          }
        }
        return http.Response(
          jsonEncode(body),
          status,
          request: request,
          headers: {'content-type': 'application/json', 'content-range': '*/0'},
        );
      }),
    );
    await Supabase.instance.client.auth.setSession('synthetic');
  });
  setUp(() {
    ordersGate = Completer<void>();
    failOrders = false;
    orderReads = 0;
    LocationCacheService.isInitialized = false;
    LocationCacheService.cachedPosition = null;
  });
  tearDownAll(() async {
    await Supabase.instance.dispose();
  });

  Future<void> showHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: HomeTab(isActive: false))),
    );
    await tester.pump();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> finish(WidgetTester tester) async {
    if (!ordersGate.isCompleted) ordersGate.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    NotificationBadgeService.instance.stopListening();
    RealtimeManager.instance.dispose();
    await tester.pump(const Duration(seconds: 9));
  }

  testWidgets(
    'completed Home data clears skeleton even when GPS is unavailable',
    (tester) async {
      try {
        await showHome(tester);
        expect(
          find.byType(SkeletonLoader, skipOffstage: false),
          findsOneWidget,
        );
        expect(orderReads, 1);
        ordersGate.complete();
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        await tester.pump();
        final dynamic state = tester.state(find.byType(HomeTab));
        expect(state.loading, isFalse);
        expect(LocationCacheService.isInitialized, isFalse);
        expect(find.byType(SkeletonLoader, skipOffstage: false), findsNothing);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'failed Home API cannot leave a permanent GPS-dependent skeleton',
    (tester) async {
      try {
        failOrders = true;
        await showHome(tester);
        ordersGate.complete();
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        await tester.pump();
        final dynamic state = tester.state(find.byType(HomeTab));
        expect(state.loading, isFalse);
        expect(LocationCacheService.cachedPosition, isNull);
        expect(find.byType(SkeletonLoader, skipOffstage: false), findsNothing);
        expect(orderReads, 1);
      } finally {
        await finish(tester);
      }
    },
  );
}
