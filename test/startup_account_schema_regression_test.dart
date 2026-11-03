import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/app_start_screen.dart';
import 'package:waydrop/core/services/session/account_profile_service.dart';
import 'package:waydrop/core/services/session/auth_routing_policy.dart';
import 'package:waydrop/core/services/session/rider_access_service.dart';
import 'package:waydrop/core/services/session/user_session_service.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/features/auth/screens/profile_setup_screen.dart';
import 'package:waydrop/features/auth/screens/login_screen.dart';
import 'package:waydrop/shared/screens/connection_error_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = '00000000-0000-4000-8000-000000000051';
  final cacheDirectory = Directory.systemTemp.createTempSync(
    'waydrop_startup_hotfix_',
  );
  final columns =
      (jsonDecode(
                    File(
                      'docs/startup-fix/PRODUCTION_PUBLIC_COLUMNS.json',
                    ).readAsStringSync(),
                  )
                  as List)
              .firstWhere((t) => t['table_name'] == 'users')['columns']
          as String;
  final userColumns = columns
      .substring(1, columns.length - 1)
      .split(',')
      .toSet();
  final waits = <Duration>[];
  var profileCalls = 0, authCalls = 0, failures = 0;
  String? forcedCode, authCode;
  int forcedStatus = 400;
  bool networkFailure = false;
  var tokenRevision = 0;
  Completer<void>? blocked;
  Completer<void>? blockedAuth;
  late Map<String, dynamic>? profile;
  late AccountProfileService loader;
  Map<String, dynamic> user() => {
    'id': uid,
    'aud': 'authenticated',
    'created_at': '2026-01-01T00:00:00Z',
    'app_metadata': {},
    'user_metadata': {},
  };
  String enc(Object x) =>
      base64Url.encode(utf8.encode(jsonEncode(x))).replaceAll('=', '');
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => cacheDirectory.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/package_info'),
          (_) async => {
            'appName': 'Waydrop',
            'packageName': 'test.waydrop',
            'version': '1.0.0',
            'buildNumber': '54',
            'buildSignature': '',
          },
        );
    String jwt() =>
        '${enc({'alg': 'HS256', 'typ': 'JWT'})}.${enc({'sub': uid, 'role': 'authenticated', 'revision': ++tokenRevision, 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000})}.synthetic';
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'test-public-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        Object? body;
        var status = 200;
        if (r.url.path.endsWith('/logout')) {
          return http.Response('', 204, request: r);
        } else if (r.url.path.endsWith('/token')) {
          body = {
            'access_token': jwt(),
            'refresh_token': 'test',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': user(),
          };
        } else if (r.url.path.endsWith('/user')) {
          authCalls++;
          await blockedAuth?.future;
          body = authCode == null
              ? user()
              : {
                  'code': authCode,
                  'error_code': authCode,
                  'msg': 'Auth verification failed',
                };
          status = authCode == null
              ? 200
              : authCode == 'temporarily_unavailable'
              ? 503
              : 403;
        } else if (r.url.path.endsWith('/users')) {
          profileCalls++;
          final projection = r.url.queryParameters['select'] ?? '*';
          final unknown = projection
              .split(',')
              .map((s) => s.trim())
              .where((s) => s != '*' && !userColumns.contains(s));
          if (unknown.isNotEmpty) {
            body = {
              'code': '42703',
              'message': 'column users.${unknown.first} does not exist',
            };
            status = 400;
          } else if (forcedCode != null || failures > 0) {
            if (failures > 0) failures--;
            if (networkFailure) {
              throw http.ClientException('Network unavailable');
            }
            body = {
              'code': forcedCode ?? forcedStatus.toString(),
              'message': 'Synthetic profile failure',
            };
            status = forcedStatus;
          } else {
            await blocked?.future;
            body = profile;
          }
        } else if (r.url.path.endsWith('/production_config')) {
          body = {
            'maintenance_mode': false,
            'force_update': false,
            'minimum_android_version': '0.0.0',
            'latest_android_version': '1.0.0',
          };
        } else if (r.url.path.endsWith('/pricing_zones')) {
          body = [];
        } else {
          throw StateError('Unexpected test endpoint ${r.url.path}');
        }
        return http.Response(
          jsonEncode(body),
          status,
          request: r,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await Supabase.instance.client.auth.setSession('test');
  });
  setUp(() {
    profileCalls = 0;
    authCalls = 0;
    failures = 0;
    forcedCode = null;
    authCode = null;
    forcedStatus = 400;
    blocked = null;
    blockedAuth = null;
    networkFailure = false;
    waits.clear();
    profile = {
      'id': uid,
      'full_name': 'Test Account',
      'deleted_at': null,
      'profile_completed': false,
      'onboarding_completed': false,
      'preferred_mode': 'user',
      'is_developer': false,
      'role': 'user',
    };
    loader = AccountProfileService(
      Supabase.instance.client,
      delay: (d) async {
        waits.add(d);
      },
    );
    AccountProfileService.instance.clear();
  });
  tearDown(() => UserSessionService().stopListening());
  tearDownAll(() async {
    await Supabase.instance.dispose();
  });
  for (final stage in ['Auth', 'profile']) {
    testWidgets(
      '$stage renewed credentials fence cleanup by an older hung owner',
      (tester) async {
        final oldGate = Completer<void>();
        final newGate = Completer<void>();
        if (stage == 'Auth') {
          blockedAuth = oldGate;
        } else {
          blocked = oldGate;
        }
        final errors = <Object>[];
        final values = <Map<String, dynamic>?>[];
        Future<void> watch() => loader
            .load(uid)
            .then<void>(
              values.add,
              onError: (Object e, StackTrace s) {
                errors.add(e);
              },
            );
        try {
          final old = watch();
          await tester.pump();
          await tester.pump(const Duration(seconds: 3));
          await tester.pump();
          expect(errors.single, isA<TimeoutException>());
          await tester.runAsync(
            () => Supabase.instance.client.auth.setSession('renewed-synthetic'),
          );
          if (stage == 'Auth') {
            blockedAuth = newGate;
          } else {
            blocked = newGate;
          }
          final replacement = watch();
          await tester.pump();
          expect(stage == 'Auth' ? authCalls : profileCalls, 2);
          oldGate.complete();
          await tester.pump();
          final joined = watch();
          await tester.pump();
          expect(stage == 'Auth' ? authCalls : profileCalls, 2);
          newGate.complete();
          await tester.pump();
          await Future.wait([old, replacement, joined]);
          expect(values, hasLength(2));
          expect(errors, hasLength(1));
        } finally {
          if (!oldGate.isCompleted) oldGate.complete();
          if (!newGate.isCompleted) newGate.complete();
          await tester.pump();
          await tester.pump(const Duration(seconds: 13));
        }
      },
    );

    testWidgets(
      '$stage manual retry retains raw request ownership after timeout',
      (tester) async {
        final gate = Completer<void>();
        if (stage == 'Auth') {
          blockedAuth = gate;
        } else {
          blocked = gate;
        }
        final errors = <Object>[];
        final values = <Map<String, dynamic>?>[];
        Future<void> watch() => loader
            .load(uid)
            .then<void>(
              values.add,
              onError: (Object e, StackTrace s) {
                errors.add(e);
              },
            );
        try {
          final first = watch();
          await tester.pump();
          await tester.pump(const Duration(seconds: 3));
          await tester.pump();
          expect(errors.single, isA<TimeoutException>());
          final retry = watch();
          await tester.pump();
          expect(stage == 'Auth' ? authCalls : profileCalls, 1);
          gate.complete();
          await tester.pump();
          await Future.wait([first, retry]);
          expect(
            values,
            isEmpty,
            reason: 'late success must never authorize startup',
          );
          expect(errors.length, 2);
          expect(await loader.load(uid), profile);
        } finally {
          if (!gate.isCompleted) gate.complete();
          await tester.pump();
          await tester.pump(const Duration(seconds: 13));
        }
      },
    );
    testWidgets('$stage timeout never retries an HTTP read still in flight', (
      tester,
    ) async {
      final gate = Completer<void>();
      if (stage == 'Auth') {
        blockedAuth = gate;
      } else {
        blocked = gate;
      }
      Object? failure;
      final pending = loader
          .load(uid)
          .then<void>(
            (_) {},
            onError: (Object error) {
              failure = error;
            },
          );
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      final requestsBeforeOriginalSettles = stage == 'Auth'
          ? authCalls
          : profileCalls;
      gate.complete();
      await tester.pump();
      await pending;
      expect(requestsBeforeOriginalSettles, 1);
      expect(failure, isA<TimeoutException>());
      expect(waits, isEmpty);
      if (stage == 'Auth') expect(profileCalls, 0);
    });
  }
  testWidgets(
    'startup and resume share one outstanding authoritative Auth read',
    (tester) async {
      final gate = Completer<void>();
      blockedAuth = gate;
      try {
        final startup = loader.load(uid);
        final resume = loader.verifyAuth(uid);
        await tester.pump();
        expect(authCalls, 1);
        gate.complete();
        await tester.pump();
        await Future.wait([startup, resume]);
        expect(profileCalls, 1);
        await loader.verifyAuth(uid);
        expect(
          authCalls,
          2,
          reason: 'completed Auth checks must not become a permission cache',
        );
      } finally {
        if (!gate.isCompleted) gate.complete();
        await tester.pump();
        await tester.pump(const Duration(seconds: 13));
      }
    },
  );
  test(
    'production-schema startup projection loads after authoritative Auth verification',
    () async {
      expect(
        AccountProfileService.projection
            .split(',')
            .map((s) => s.trim())
            .every(userColumns.contains),
        isTrue,
      );
      expect(await loader.load(uid), profile);
      expect(authCalls, 1);
      expect(profileCalls, 1);
    },
  );
  test(
    'fixture rejects the actual missing-column query rather than fabricating a suspension flag',
    () async {
      await expectLater(
        Supabase.instance.client
            .from('users')
            .select('id,is_suspended')
            .eq('id', uid)
            .maybeSingle(),
        throwsA(
          isA<PostgrestException>().having(
            AccountProfileService.postgrestCode,
            'code',
            '42703',
          ),
        ),
      );
    },
  );
  test(
    'missing-column failure is terminal and repeated loads do not reissue requests',
    () async {
      forcedCode = '42703';
      for (var i = 0; i < 3; i++) {
        await expectLater(
          loader.load(uid),
          throwsA(isA<AccountProfileSchemaException>()),
        );
      }
      expect(profileCalls, 1);
      expect(authCalls, 1);
      expect(waits, isEmpty);
    },
  );
  test('deterministic HTTP 400 input failure is not retried', () async {
    forcedCode = '22P02';
    await expectLater(loader.load(uid), throwsA(isA<PostgrestException>()));
    expect(profileCalls, 1);
    expect(waits, isEmpty);
  });
  test(
    'transient 503 retries at 500ms and 1000ms then loads successfully',
    () async {
      failures = 2;
      forcedStatus = 503;
      expect(await loader.load(uid), profile);
      expect(profileCalls, 3);
      expect(waits, [
        const Duration(milliseconds: 500),
        const Duration(seconds: 1),
      ]);
    },
  );
  test('persistent transient failure stops after three attempts', () async {
    forcedCode = '503';
    forcedStatus = 503;
    await expectLater(loader.load(uid), throwsA(isA<PostgrestException>()));
    expect(profileCalls, 3);
    expect(waits.length, 2);
  });
  test('network reads retry within the same bounded policy', () async {
    failures = 2;
    networkFailure = true;
    expect(await loader.load(uid), profile);
    expect(profileCalls, 3);
  });
  test(
    'Auth ban denies entry without querying a profile or assuming false',
    () async {
      authCode = 'user_banned';
      await expectLater(
        loader.load(uid),
        throwsA(isA<AccountRestrictedException>()),
      );
      expect(profileCalls, 0);
      expect(authCalls, 1);
      expect(waits, isEmpty);
    },
  );
  test(
    'unknown Auth/network state fails closed before profile loading',
    () async {
      authCode = 'temporarily_unavailable';
      await expectLater(loader.load(uid), throwsA(isA<AuthException>()));
      expect(profileCalls, 0);
      expect(authCalls, 3);
      expect(waits.length, 2);
    },
  );
  test(
    'deleted profile is restricted; a missing deletion field is not treated as null',
    () async {
      profile!['deleted_at'] = '2026-11-01T00:00:00Z';
      await expectLater(
        loader.load(uid),
        throwsA(
          isA<AccountRestrictedException>().having(
            (e) => e.deleted,
            'deleted',
            true,
          ),
        ),
      );
      profile!.remove('deleted_at');
      await expectLater(
        loader.load(uid),
        throwsA(isA<AccountProfileSchemaException>()),
      );
    },
  );
  test(
    'concurrent account loaders share server verification and profile read',
    () async {
      blocked = Completer<void>();
      final reads = List.generate(8, (_) => loader.load(uid));
      await Future<void>.delayed(Duration.zero);
      expect(profileCalls, 1);
      expect(authCalls, 1);
      blocked!.complete();
      expect((await Future.wait(reads)).length, 8);
    },
  );
  test(
    'rider suspension, block and KYC checks stay separate and restrictive',
    () {
      for (final entry in [
        {
          'kyc': {'kyc_status': 'approved', 'activation_status': 'suspended'},
          'rider': {'service_mode': 'local'},
        },
        {
          'kyc': {'kyc_status': 'approved', 'activation_status': 'active'},
          'rider': {'service_mode': 'local', 'account_status': 'blocked'},
        },
      ]) {
        expect(
          RiderAccessService.decide(
            authenticated: true,
            kyc: entry['kyc'],
            rider: entry['rider'],
            activePayout: true,
          ).state,
          RiderAccessState.blocked,
        );
      }
    },
  );
  test('duplicate same-identity signedIn does not restart account loading', () {
    final policy = AuthRoutingPolicy(uid);
    expect(
      policy.shouldRecheck(
        AuthState(
          AuthChangeEvent.signedIn,
          Supabase.instance.client.auth.currentSession,
        ),
      ),
      isFalse,
    );
  });
  Future<void> flush(WidgetTester tester) async {
    for (var n = 0; n < 4; n++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('real startup with valid schema reaches profile setup', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AppStartScreen())),
    );
    await flush(tester);
    expect(find.byType(ProfileSetupScreen), findsOneWidget);
    expect(find.byType(ConnectionErrorScreen), findsNothing);
    UserSessionService().stopListening();
    RealtimeManager.instance.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    // Drain the real manager's already scheduled reconnect backoff; disposal
    // makes its generation check return without recreating a channel.
    await tester.pump(const Duration(seconds: 5));
  });
  testWidgets(
    'schema error shows actionable update message and disables futile retry',
    (tester) async {
      forcedCode = '42703';
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: AppStartScreen())),
      );
      await flush(tester);
      expect(find.byType(ConnectionErrorScreen), findsOneWidget);
      expect(find.textContaining('out of sync'), findsOneWidget);
      expect(
        tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNull,
      );
      expect(profileCalls, 1);
      await tester.pump(const Duration(seconds: 5));
      expect(profileCalls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'server outage shows a meaningful retryable error after bounded attempts',
    (tester) async {
      forcedCode = '503';
      forcedStatus = 503;
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: AppStartScreen())),
      );
      for (var n = 0; n < 7; n++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 600));
      }
      expect(profileCalls, 3);
      expect(find.textContaining('temporarily unavailable'), findsOneWidget);
      expect(
        tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'banned Auth response routes startup to login without profile access',
    (tester) async {
      authCode = 'user_banned';
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: AppStartScreen())),
      );
      await flush(tester);
      // Restriction cleanup has an existing bounded eight-second cache timeout.
      // Advance it rather than weakening the cleanup or the login assertion.
      await tester.pump(const Duration(seconds: 9));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      expect(profileCalls, 0);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(Supabase.instance.client.auth.currentUser, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
