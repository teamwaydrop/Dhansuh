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
import 'package:waydrop/core/providers/initial_data_provider.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/features/rider/home/rider_home_tab.dart';
import 'package:waydrop/features/rider/navigation/rider_main_navigation_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_entry_handler.dart';
import 'package:waydrop/modules/notifications/services/notification_badge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = '00000000-0000-4000-8000-000000000101';
  const rid = '00000000-0000-4000-8000-000000000102';
  late Completer<void> gate;
  var riderReads = 0;
  var kycStatus = 'approved';
  var failKyc = false;
  final row = <String, dynamic>{
    'id': rid,
    'user_id': uid,
    'account_status': 'offline',
    'service_mode': 'local',
    'wallet_balance': 42,
    'rider_kyc': {'full_name': 'Synthetic Rider'},
  };
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'xyz.luan/audioplayers',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
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
      httpClient: MockClient((r) async {
        Object? body = [];
        var status = 200;
        if (r.url.path.endsWith('/token')) {
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
        } else if (r.url.path.endsWith('/riders')) {
          riderReads++;
          body = Map<String, dynamic>.from(row);
        } else if (r.url.path.endsWith('/rider_kyc')) {
          await gate.future;
          if (failKyc) {
            status = 503;
            body = {'message': 'synthetic service unavailable'};
          } else {
            body = {'kyc_status': kycStatus, 'activation_status': 'active'};
          }
        } else if (r.url.path.endsWith('/rider_payout_accounts')) {
          body = {'id': 'synthetic-payout'};
        }
        return http.Response(
          jsonEncode(body),
          status,
          request: r,
          headers: {'content-type': 'application/json', 'content-range': '*/0'},
        );
      }),
    );
    await Supabase.instance.client.auth.setSession('synthetic');
  });
  setUp(() {
    gate = Completer<void>();
    riderReads = 0;
    kycStatus = 'approved';
    failKyc = false;
  });
  tearDownAll(() async => Supabase.instance.dispose());
  Future<void> flush(WidgetTester tester) async {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> cleanup(WidgetTester tester) async {
    if (!gate.isCompleted) gate.complete();
    await flush(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    NotificationBadgeService.instance.stopListening();
    RealtimeManager.instance.dispose();
    await tester.pump(const Duration(seconds: 9));
  }

  testWidgets(
    'pending partner revalidation keeps rider theme instead of a white page',
    (tester) async {
      try {
        await tester.pumpWidget(
          const ProviderScope(
            child: MaterialApp(
              home: RiderEntryHandler(readyScreen: Text('ready')),
            ),
          ),
        );
        await tester.pump();
        expect(
          find.text('ready'),
          findsNothing,
          reason: 'account verification must still gate Home',
        );
        final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
        expect(scaffold.backgroundColor, isNot(Colors.white));
        gate.complete();
        await flush(tester);
        expect(find.text('ready'), findsOneWidget);
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets(
    'backend failure retains retry instead of treating KYC as invalid',
    (tester) async {
      failKyc = true;
      gate.complete();
      try {
        await tester.pumpWidget(
          const ProviderScope(
            child: MaterialApp(
              home: RiderEntryHandler(readyScreen: Text('verified-ready')),
            ),
          ),
        );
        await flush(tester);
        expect(find.text('Server Error'), findsOneWidget);
        expect(find.text('verified-ready'), findsNothing);
        failKyc = false;
        await tester.tap(find.text('Try Again'));
        await flush(tester);
        expect(find.text('verified-ready'), findsOneWidget);
        expect(riderReads, 2);
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets(
    'timeout retry shares transport and late approval never opens Home',
    (tester) async {
      try {
        await tester.pumpWidget(
          const ProviderScope(
            child: MaterialApp(
              home: RiderEntryHandler(readyScreen: Text('verified-ready')),
            ),
          ),
        );
        await flush(tester);
        await tester.pump(const Duration(seconds: 8));
        expect(find.text('Server Error'), findsOneWidget);
        await tester.tap(find.text('Try Again'));
        await flush(tester);
        expect(riderReads, 1);
        gate.complete();
        await flush(tester);
        expect(find.text('verified-ready'), findsNothing);
        await tester.tap(find.text('Try Again'));
        await flush(tester);
        expect(find.text('verified-ready'), findsOneWidget);
        expect(riderReads, 2);
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets('a new validated seed is reused on a later Home recreation', (
    tester,
  ) async {
    final container = ProviderContainer();
    gate.complete();
    Future<void> show() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: RiderHomeTab(isActive: false)),
        ),
      );
      await flush(tester);
    }

    try {
      container.read(initialRiderDataProvider.notifier).state =
          InitialRiderData(rider: Map.from(row), todayEarnings: 0);
      await show();
      await tester.pumpWidget(const SizedBox.shrink());
      riderReads = 0;
      container.read(initialRiderDataProvider.notifier).state =
          InitialRiderData(rider: Map.from(row), todayEarnings: 0);
      await show();
      expect(
        riderReads,
        0,
        reason: 'a just-published gate response should not be fetched again',
      );
    } finally {
      await cleanup(tester);
      container.dispose();
    }
  });

  testWidgets(
    'new guarded dashboard uses its authoritative rider read without two duplicate reads',
    (tester) async {
      gate.complete();
      try {
        await tester.pumpWidget(
          const ProviderScope(
            child: MaterialApp(home: RiderMainNavigationScreen()),
          ),
        );
        await flush(tester);
        await flush(tester);
        expect(find.byType(RiderHomeTab), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        riderReads = 0;
        await tester.pumpWidget(
          const ProviderScope(
            child: MaterialApp(home: RiderMainNavigationScreen()),
          ),
        );
        await flush(tester);
        await flush(tester);
        expect(find.byType(RiderHomeTab), findsOneWidget);
        expect(
          riderReads,
          1,
          reason:
              'entry must validate once; dashboard and Home should reuse that fresh response',
        );
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets('pending KYC never reaches the guarded ready screen', (
    tester,
  ) async {
    gate.complete();
    kycStatus = 'pending';
    try {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: RiderEntryHandler(readyScreen: Text('must stay blocked')),
          ),
        ),
      );
      await flush(tester);
      expect(find.text('must stay blocked'), findsNothing);
    } finally {
      await cleanup(tester);
    }
  });
}
