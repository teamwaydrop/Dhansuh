import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/features/rider/orders/screens/rider_active_order_screen.dart';
import 'package:waydrop/shared/screens/connection_error_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const user = '00000000-0000-4000-8000-000000000701',
      rider = '00000000-0000-4000-8000-000000000702',
      order = '00000000-0000-4000-8000-000000000703';
  late Directory dir;
  late File photo;
  late RealtimeManager realtime;
  var proofCommitted = false,
      holdRefresh = false,
      posts = 0,
      refreshError = false,
      holdUser = false;
  var failOrder = false, orderReads = 0;
  var intercityReads = 0, holdIntercity = false;
  late Completer<void> intercityGate;
  late Completer<void> refreshStarted, refreshGate;
  late Completer<void> userStarted, userGate;
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('waydrop-proof-wait-');
    photo = await File(
      '${dir.path}/synthetic.jpg',
    ).writeAsBytes([255, 216, 255, 1, 2, 3]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/image_picker'),
          (call) async => photo.path,
        );
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'synthetic-public',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        http.Response reply(
          String body,
          int status, {
          Map<String, String>? headers,
        }) => http.Response(
          body,
          status,
          request: request,
          headers: headers ?? {},
        );
        if (request.url.path.endsWith('/orders')) {
          orderReads++;
          return reply(
            failOrder
                ? '{"message":"synthetic backend failure"}'
                : jsonEncode({
                    'id': order,
                    'rider_id': rider,
                    'order_type': 'local_parcel',
                    'order_status': 'rider_arrived',
                    'current_fare': 50,
                  }),
            failOrder ? 503 : 200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/intercity_requests')) {
          intercityReads++;
          if (holdIntercity) await intercityGate.future;
          return reply(
            '[]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/users') && holdUser) {
          if (!userStarted.isCompleted) userStarted.complete();
          await userGate.future;
          return reply(
            '{"full_name":"Synthetic Passenger"}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/token')) {
          return reply(
            jsonEncode({
              'access_token':
                  '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': user, 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000})}.synthetic',
              'refresh_token': 'synthetic',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': user,
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
        if (request.url.path.endsWith('/process-verification-photo')) {
          posts++;
          proofCommitted = true;
          return reply(
            '{"success":true}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.contains('/object/parcel_images/')) {
          return request.method == 'GET'
              ? reply('missing', 404)
              : reply(
                  '{"Key":"synthetic"}',
                  200,
                  headers: {'content-type': 'application/json'},
                );
        }
        if (request.url.path.endsWith('/order_verifications')) {
          final snapshot = proofCommitted
              ? [
                  {
                    'verification_type': 'pickup',
                    'verification_status': 'verified',
                  },
                ]
              : [];
          if (holdRefresh) {
            if (!refreshStarted.isCompleted) refreshStarted.complete();
            await refreshGate.future;
          }
          if (refreshError) {
            return reply(
              '{"message":"synthetic unavailable"}',
              503,
              headers: {'content-type': 'application/json'},
            );
          }
          return reply(
            jsonEncode(snapshot),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return reply('[]', 200, headers: {'content-type': 'application/json'});
      }),
    );
    await Supabase.instance.client.auth.setSession('synthetic-refresh');
    realtime = RealtimeManager.instance;
  });
  tearDownAll(() async {
    realtime.dispose();
    await Supabase.instance.dispose();
    final base = Directory.systemTemp.resolveSymbolicLinksSync();
    expect(
      dir.resolveSymbolicLinksSync().startsWith(
        '$base${Platform.pathSeparator}waydrop-proof-wait-',
      ),
      isTrue,
    );
    await dir.delete(recursive: true);
  });
  for (final failRefresh in [false, true]) {
    testWidgets(
      'successful proof unlocks UI before refresh (failure=$failRefresh)',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        proofCommitted = false;
        holdRefresh = false;
        holdUser = false;
        refreshError = false;
        posts = 0;
        refreshStarted = Completer<void>();
        refreshGate = Completer<void>();
        LocationCacheService.cachedPosition = Position(
          longitude: 0,
          latitude: 0,
          timestamp: DateTime.now(),
          accuracy: 1,
          altitude: 0,
          heading: 0,
          speed: 0,
          speedAccuracy: 0,
          altitudeAccuracy: 0,
          headingAccuracy: 0,
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: RiderActiveOrderScreen(
                orderId: order,
                initialOrder: {
                  'id': order,
                  'rider_id': rider,
                  'order_type': 'local_parcel',
                  'order_status': 'rider_arrived',
                  'pickup_address': 'Synthetic pickup',
                  'destination_address': 'Synthetic drop',
                  'current_fare': 50,
                  'final_fare': 50,
                },
                initialRiderProfile: {'id': rider, 'user_id': user},
                initialTodayEarnings: 0,
              ),
            ),
          );
          for (
            var n = 0;
            n < 20 &&
                find.text('SWIPE TO TAKE PARCEL PHOTO').evaluate().isEmpty;
            n++
          ) {
            await tester.pump(const Duration(milliseconds: 10));
          }
          expect(find.text('SWIPE TO TAKE PARCEL PHOTO'), findsOneWidget);
          holdRefresh = true;
          final button = tester.widget<SwipeToConfirmButton>(
            find.byType(SwipeToConfirmButton).first,
          );
          button.onSwipeComplete();
          for (var n = 0; n < 100 && !refreshStarted.isCompleted; n++) {
            await tester.pump();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          expect(
            refreshStarted.isCompleted,
            isTrue,
            reason: 'Actual proof POST and reconciliation read must start',
          );
          await tester.pump();
          expect(posts, 1);
          expect(proofCommitted, isTrue);
          expect(refreshGate.isCompleted, isFalse);
          expect(find.text('UPLOADING PHOTO...'), findsNothing);
          expect(
            find.text('Pickup verification photo uploaded successfully!'),
            findsOneWidget,
          );
          refreshError = failRefresh;
          refreshGate.complete();
          for (var n = 0; n < 5; n++) {
            await tester.pump();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          expect(find.text('SWIPE TO TAKE PARCEL PHOTO'), findsNothing);
        } finally {
          if (!refreshGate.isCompleted) refreshGate.complete();
          await tester.pump();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(
            () => Supabase.instance.client.removeAllChannels(),
          );
          await Supabase.instance.client.realtime.disconnect();
          await tester.pump(const Duration(seconds: 5));
          LocationCacheService.cachedPosition = null;
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
  testWidgets(
    'accepted order renders while passenger display enrichment is pending',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      proofCommitted = false;
      holdRefresh = false;
      refreshError = false;
      holdUser = true;
      userStarted = Completer<void>();
      userGate = Completer<void>();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: RiderActiveOrderScreen(
              orderId: order,
              initialOrder: {
                'id': order,
                'rider_id': rider,
                'user_id': user,
                'order_type': 'local_parcel',
                'order_status': 'rider_arrived',
                'pickup_address': 'Synthetic pickup',
                'destination_address': 'Synthetic drop',
                'current_fare': 50,
                'final_fare': 50,
              },
              initialRiderProfile: {'id': rider, 'user_id': user},
              initialTodayEarnings: 0,
            ),
          ),
        );
        for (var n = 0; n < 20; n++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(userStarted.isCompleted, isTrue);
        expect(userGate.isCompleted, isFalse);
        expect(find.text('SWIPE TO TAKE PARCEL PHOTO'), findsOneWidget);
      } finally {
        userGate.complete();
        for (var n = 0; n < 3; n++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        holdUser = false;
        debugDefaultTargetPlatformOverride = null;
        await tester.runAsync(
          () => Supabase.instance.client.removeAllChannels(),
        );
        await Supabase.instance.client.realtime.disconnect();
        await tester.pump(const Duration(seconds: 5));
      }
    },
  );
  for (final disposed in [true, false]) {
    testWidgets(
      'late passenger enrichment ignores ${disposed ? 'disposal' : 'account change'}',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        proofCommitted = false;
        holdRefresh = false;
        refreshError = false;
        holdUser = true;
        userStarted = Completer<void>();
        userGate = Completer<void>();
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: RiderActiveOrderScreen(
                orderId: order,
                initialOrder: {
                  'id': order,
                  'rider_id': rider,
                  'user_id': user,
                  'order_type': 'local_parcel',
                  'order_status': 'rider_arrived',
                  'current_fare': 50,
                },
                initialRiderProfile: {'id': rider, 'user_id': user},
                initialTodayEarnings: 0,
              ),
            ),
          );
          for (var n = 0; n < 20; n++) {
            await tester.pump();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          expect(userStarted.isCompleted, isTrue);
          final dynamic state = tester.state(
            find.byType(RiderActiveOrderScreen),
          );
          if (disposed) {
            await tester.pumpWidget(const SizedBox.shrink());
          } else {
            await tester.runAsync(
              () => Supabase.instance.client.auth.signOut(
                scope: SignOutScope.local,
              ),
            );
          }
          userGate.complete();
          for (var n = 0; n < 5; n++) {
            await tester.pump();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          expect(state.order['users'], isNull);
        } finally {
          if (!userGate.isCompleted) userGate.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          holdUser = false;
          await tester.runAsync(
            () => Supabase.instance.client.removeAllChannels(),
          );
          await Supabase.instance.client.realtime.disconnect();
          await tester.pump(const Duration(seconds: 5));
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
  testWidgets(
    'pending proof read cannot authorize old account state after sign-out',
    (tester) async {
      await tester.runAsync(
        () => Supabase.instance.client.auth.setSession('synthetic-refresh'),
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      proofCommitted = true;
      holdRefresh = true;
      refreshError = false;
      holdUser = false;
      refreshStarted = Completer<void>();
      refreshGate = Completer<void>();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: RiderActiveOrderScreen(
              orderId: order,
              initialOrder: {
                'id': order,
                'rider_id': rider,
                'order_type': 'local_parcel',
                'order_status': 'rider_arrived',
                'current_fare': 50,
              },
              initialRiderProfile: {'id': rider, 'user_id': user},
              initialTodayEarnings: 0,
            ),
          ),
        );
        for (var n = 0; n < 20 && !refreshStarted.isCompleted; n++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(refreshStarted.isCompleted, isTrue);
        final dynamic state = tester.state(find.byType(RiderActiveOrderScreen));
        await tester.runAsync(
          () =>
              Supabase.instance.client.auth.signOut(scope: SignOutScope.local),
        );
        refreshGate.complete();
        for (var n = 0; n < 5; n++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(state.pickupPhotoCompleted, isFalse);
        expect(state.dropoffPhotoCompleted, isFalse);
      } finally {
        if (!refreshGate.isCompleted) refreshGate.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        holdRefresh = false;
        await tester.runAsync(
          () => Supabase.instance.client.removeAllChannels(),
        );
        await Supabase.instance.client.realtime.disconnect();
        await tester.pump(const Duration(seconds: 5));
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
  testWidgets(
    'failed order request exits loader; rapid manual retry starts one fresh read',
    (tester) async {
      await tester.runAsync(
        () => Supabase.instance.client.auth.setSession('synthetic-refresh'),
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      failOrder = true;
      orderReads = 0;
      holdRefresh = false;
      holdUser = false;
      refreshError = false;
      proofCommitted = false;
      try {
        await tester.pumpWidget(
          const MaterialApp(
            home: RiderActiveOrderScreen(
              orderId: order,
              initialRiderProfile: {'id': rider, 'user_id': user},
              initialTodayEarnings: 0,
            ),
          ),
        );
        for (var n = 0; n < 20; n++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(orderReads, 1);
        expect(find.byType(ConnectionErrorScreen), findsOneWidget);
        failOrder = false;
        final retry = tester
            .widget<ConnectionErrorScreen>(find.byType(ConnectionErrorScreen))
            .onRetry;
        retry();
        retry();
        for (var n = 0; n < 20; n++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(orderReads, 2);
        expect(find.byType(ConnectionErrorScreen), findsNothing);
        expect(find.text('SWIPE TO TAKE PARCEL PHOTO'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        failOrder = false;
        await tester.runAsync(
          () => Supabase.instance.client.removeAllChannels(),
        );
        await Supabase.instance.client.realtime.disconnect();
        await tester.pump(const Duration(seconds: 5));
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
  for (final item in [
    (type: 'local_parcel', meters: 1000, expected: 0),
    (type: 'ride', meters: 10000, expected: 0),
    (type: 'intercity_parcel', meters: 1000, expected: 1),
    (type: 'ride', meters: 25000, expected: 1),
  ]) {
    testWidgets('metadata query parity ${item.type} ${item.meters}m', (
      tester,
    ) async {
      await tester.runAsync(
        () => Supabase.instance.client.auth.setSession('synthetic-refresh'),
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      failOrder = false;
      holdRefresh = false;
      holdUser = false;
      refreshError = false;
      proofCommitted = false;
      intercityReads = 0;
      holdIntercity = true;
      intercityGate = Completer<void>();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: RiderActiveOrderScreen(
              orderId: order,
              initialOrder: {
                'id': order,
                'rider_id': rider,
                'order_type': item.type,
                'order_status': 'rider_arrived',
                'distance_meters': item.meters,
                'current_fare': 50,
              },
              initialRiderProfile: const {'id': rider, 'user_id': user},
              initialTodayEarnings: 0,
            ),
          ),
        );
        for (var n = 0; n < 20; n++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(intercityReads, item.expected);
        final dynamic state = tester.state(find.byType(RiderActiveOrderScreen));
        expect(state.loading, item.expected == 1);
      } finally {
        intercityGate.complete();
        for (var n = 0; n < 3; n++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        holdIntercity = false;
        await tester.runAsync(
          () => Supabase.instance.client.removeAllChannels(),
        );
        await Supabase.instance.client.realtime.disconnect();
        await tester.pump(const Duration(seconds: 5));
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
  testWidgets('pre-commit read cannot overwrite newly confirmed proof', (
    tester,
  ) async {
    await tester.runAsync(
      () => Supabase.instance.client.auth.setSession('synthetic-refresh'),
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    failOrder = false;
    holdRefresh = false;
    holdUser = false;
    refreshError = false;
    proofCommitted = false;
    holdIntercity = false;
    posts = 0;
    refreshStarted = Completer<void>();
    refreshGate = Completer<void>();
    LocationCacheService.cachedPosition = Position(
      longitude: 0,
      latitude: 0,
      timestamp: DateTime.now(),
      accuracy: 1,
      altitude: 0,
      heading: 0,
      speed: 0,
      speedAccuracy: 0,
      altitudeAccuracy: 0,
      headingAccuracy: 0,
    );
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: RiderActiveOrderScreen(
            orderId: order,
            initialOrder: {
              'id': order,
              'rider_id': rider,
              'order_type': 'local_parcel',
              'order_status': 'rider_arrived',
              'current_fare': 50,
            },
            initialRiderProfile: {'id': rider, 'user_id': user},
            initialTodayEarnings: 0,
          ),
        ),
      );
      for (var n = 0; n < 20; n++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      final dynamic state = tester.state(find.byType(RiderActiveOrderScreen));
      holdRefresh = true;
      final Future<void> oldRead = state.loadVerifications();
      for (var n = 0; n < 20 && !refreshStarted.isCompleted; n++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(refreshStarted.isCompleted, isTrue);
      holdRefresh = false;
      tester
          .widget<SwipeToConfirmButton>(find.byType(SwipeToConfirmButton).first)
          .onSwipeComplete();
      for (var n = 0; n < 100 && posts == 0; n++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pump();
      expect(posts, 1);
      expect(state.pickupPhotoCompleted, isTrue);
      refreshGate.complete();
      await oldRead;
      await tester.pump();
      expect(state.pickupPhotoCompleted, isTrue);
    } finally {
      if (!refreshGate.isCompleted) refreshGate.complete();
      holdRefresh = false;
      await tester.pumpWidget(const SizedBox.shrink());
      LocationCacheService.cachedPosition = null;
      await tester.runAsync(() => Supabase.instance.client.removeAllChannels());
      await Supabase.instance.client.realtime.disconnect();
      await tester.pump(const Duration(seconds: 5));
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
