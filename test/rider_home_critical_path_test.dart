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
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/features/rider/home/rider_home_tab.dart';
import 'package:waydrop/modules/notifications/services/notification_badge_service.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = '00000000-0000-4000-8000-000000000081';
  const rid = '00000000-0000-4000-8000-000000000082';
  late Completer<http.Response> earnings;
  final requests = <http.Request>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    for (final channel in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'xyz.luan/audioplayers',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        }
        return null;
      });
    }
    final token =
        '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': uid, 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000})}.synthetic';
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'synthetic-public-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        Object body = [];
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
        } else if (request.url.path.endsWith('/riders')) {
          body = {
            'id': rid,
            'user_id': uid,
            'account_status': 'offline',
            'service_mode': null,
            'wallet_balance': 25,
            'rider_kyc': {'full_name': 'Synthetic Rider'},
          };
        } else if (request.url.path.endsWith('/orders') &&
            request.url.queryParameters['select'] ==
                'final_fare,current_fare') {
          final response = await earnings.future;
          return http.Response(
            response.body,
            response.statusCode,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(body),
          200,
          request: request,
          headers: {'content-type': 'application/json', 'content-range': '*/0'},
        );
      }),
    );
    await Supabase.instance.client.auth.setSession('synthetic');
  });

  setUp(() {
    earnings = Completer<http.Response>();
    requests.clear();
  });
  tearDownAll(() async {
    NotificationBadgeService.instance.stopListening();
    RealtimeManager.instance.dispose();
    await Supabase.instance.dispose();
  });

  Future<void> showHome(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: RiderHomeTab(isActive: false)),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  void riderEvent(Map<String, dynamic> before, Map<String, dynamic> after) {
    final channel = Supabase.instance.client.getChannels().firstWhere(
      // ignore: invalid_use_of_internal_member
      (c) => c.topic.endsWith('rider-home-$rid'),
    );
    // Inject a synthetic wire frame into the pinned SDK, no production socket.
    // ignore: invalid_use_of_internal_member
    channel.trigger('UPDATE', {
      'schema': 'public',
      'table': 'riders',
      'type': 'UPDATE',
      'commit_timestamp': '2026-11-02T18:00:00Z',
      'errors': null,
      'columns': [],
      'record': {'id': rid, ...after},
      'old_record': {'id': rid, ...before},
    });
  }

  Future<void> finish(WidgetTester tester) async {
    if (!earnings.isCompleted) earnings.complete(http.Response('[]', 200));
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    NotificationBadgeService.instance.stopListening();
    RealtimeManager.instance.dispose();
    await tester.pump(const Duration(seconds: 9));
  }

  testWidgets(
    'Realtime wallet state publishes before held secondary earnings',
    (tester) async {
      try {
        await showHome(tester);
        riderEvent(
          {'wallet_balance': 25, 'account_status': 'offline'},
          {'wallet_balance': 50, 'account_status': 'offline'},
        );
        await tester.pump();
        final dynamic state = tester.state(find.byType(RiderHomeTab));
        expect(state.rider['wallet_balance'], 50);
        expect(earnings.isCompleted, isFalse);
      } finally {
        await finish(tester);
      }
    },
  );
  testWidgets(
    'late earnings never replays an older account status over a newer event',
    (tester) async {
      try {
        await showHome(tester);
        riderEvent(
          {'wallet_balance': 25, 'account_status': 'offline'},
          {'wallet_balance': 50, 'account_status': 'online'},
        );
        riderEvent(
          {'wallet_balance': 50, 'account_status': 'online'},
          {'wallet_balance': 50, 'account_status': 'offline'},
        );
        earnings.complete(http.Response('[{"final_fare":42}]', 200));
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        final dynamic state = tester.state(find.byType(RiderHomeTab));
        expect(state.isOnline, isFalse);
        expect(state.rider['account_status'], 'offline');
        expect(state.todayEarnings, 42);
      } finally {
        await finish(tester);
      }
    },
  );
  testWidgets(
    'Realtime earnings failure preserves last confirmed display value',
    (tester) async {
      try {
        await showHome(tester);
        final dynamic state = tester.state(find.byType(RiderHomeTab));
        state.todayEarnings = 17.0;
        riderEvent({'wallet_balance': 25}, {'wallet_balance': 50});
        earnings.complete(
          http.Response('{"message":"synthetic failure"}', 503),
        );
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        expect(state.todayEarnings, 17.0);
        expect(find.text('Unavailable'), findsOneWidget);
      } finally {
        await finish(tester);
      }
    },
  );
  testWidgets(
    'Home retry after earnings deadline retains the original transport',
    (tester) async {
      try {
        await showHome(tester);
        await tester.pump(const Duration(seconds: 8));
        await tester.pump();
        final dynamic state = tester.state(find.byType(RiderHomeTab));
        await state.loadRider();
        await tester.pump();
        expect(
          requests.where(
            (r) => r.url.queryParameters['select'] == 'final_fare,current_fare',
          ),
          hasLength(1),
        );
        expect(earnings.isCompleted, isFalse);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'pending earnings does not block Home or assignment reconciliation',
    (tester) async {
      try {
        await showHome(tester);
        expect(
          requests.where(
            (r) => r.url.queryParameters['select'] == 'final_fare,current_fare',
          ),
          hasLength(1),
        );
        expect(find.byType(SkeletonLoader), findsNothing);
        expect(
          requests.any((r) => r.url.path.endsWith('/rider_assignments')),
          isTrue,
        );
        earnings.complete(http.Response('[{"final_fare":42}]', 200));
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        await tester.pump();
        final dynamic state = tester.state(find.byType(RiderHomeTab));
        expect(state.todayEarnings, 42);
      } finally {
        if (!earnings.isCompleted) earnings.complete(http.Response('[]', 200));
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        NotificationBadgeService.instance.stopListening();
        RealtimeManager.instance.dispose();
        await tester.pump(const Duration(seconds: 9));
      }
    },
  );

  testWidgets(
    'earnings response after disposal does not update a disposed Home',
    (tester) async {
      await showHome(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      earnings.complete(http.Response('[{"final_fare":99}]', 200));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      NotificationBadgeService.instance.stopListening();
      RealtimeManager.instance.dispose();
      await tester.pump(const Duration(seconds: 9));
    },
  );

  testWidgets(
    'failed secondary refresh preserves the previous earnings value',
    (tester) async {
      await showHome(tester);
      final dynamic state = tester.state(find.byType(RiderHomeTab));
      state.todayEarnings = 17.0;
      earnings.complete(http.Response('{"message":"synthetic failure"}', 503));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump();
      expect(state.todayEarnings, 17.0);
      expect(find.byType(SkeletonLoader), findsNothing);
      expect(find.text('Unavailable'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      NotificationBadgeService.instance.stopListening();
      RealtimeManager.instance.dispose();
      await tester.pump(const Duration(seconds: 9));
    },
  );

  testWidgets('repeated Home refreshes share the pending earnings read', (
    tester,
  ) async {
    await showHome(tester);
    final dynamic state = tester.state(find.byType(RiderHomeTab));
    await state.loadRider();
    await state.loadRider();
    expect(
      requests.where(
        (r) => r.url.queryParameters['select'] == 'final_fare,current_fare',
      ),
      hasLength(1),
    );
    earnings.complete(http.Response('[{"current_fare":21}]', 200));
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(state.todayEarnings, 21.0);
    await tester.pumpWidget(const SizedBox.shrink());
    NotificationBadgeService.instance.stopListening();
    RealtimeManager.instance.dispose();
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets(
    'late earnings after sign-out cannot update the old account view',
    (tester) async {
      await showHome(tester);
      final dynamic state = tester.state(find.byType(RiderHomeTab));
      await tester.runAsync(
        () => Supabase.instance.client.auth.signOut(scope: SignOutScope.local),
      );
      earnings.complete(http.Response('[{"final_fare":99}]', 200));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(state.todayEarnings, 0.0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      NotificationBadgeService.instance.stopListening();
      RealtimeManager.instance.dispose();
      await tester.pump(const Duration(seconds: 9));
    },
  );
}
