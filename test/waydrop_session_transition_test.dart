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
import 'package:waydrop/core/services/session/user_session_service.dart';
import 'package:waydrop/core/services/session/auth_routing_policy.dart';
import 'package:waydrop/features/auth/screens/login_screen.dart';
import 'package:waydrop/features/auth/screens/profile_setup_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_entry_handler.dart';
import 'package:waydrop/main.dart' show navigatorKey, providerContainer;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const userId = '00000000-0000-4000-8000-000000000041';
  final requests = <http.Request>[];
  var logoutFails = false;
  var activation = 'active';
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  Map<String, dynamic> getUser() => {
    'id': userId,
    'aud': 'authenticated',
    'created_at': '2026-01-01T00:00:00Z',
    'app_metadata': <String, dynamic>{},
    'user_metadata': <String, dynamic>{},
  };

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final cacheDirectory = Directory('.dart_tool/waydrop_test_cache');
    await cacheDirectory.create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => cacheDirectory.absolute.path,
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
    final token =
        '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': userId, 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000})}.test';
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'test-public-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        Object? body;
        if (request.url.path.endsWith('/logout')) {
          return http.Response(
            logoutFails ? '{"message":"temporarily unavailable"}' : '',
            logoutFails ? 503 : 204,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        } else if (request.url.path.endsWith('/user')) {
          body = getUser();
        } else if (request.url.path.endsWith('/token')) {
          body = {
            'access_token': token,
            'refresh_token': 'synthetic-refresh',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': getUser(),
          };
        } else if (request.url.path.endsWith('/production_config')) {
          body = {
            'maintenance_mode': false,
            'force_update': false,
            'minimum_android_version': '0.0.0',
            'latest_android_version': '1.0.0',
          };
        } else if (request.url.path.endsWith('/pricing_zones')) {
          body = [];
        } else if (request.url.path.endsWith('/users')) {
          body =
              null; // A newly authenticated account still needs its profile form.
        } else if (request.url.path.endsWith('/rider_kyc')) {
          body = {
            'kyc_status': 'approved',
            'activation_status': activation,
            'full_name': 'Synthetic Rider',
          };
        } else if (request.url.path.endsWith('/riders')) {
          body = {
            'id': 'rider-id',
            'user_id': userId,
            'service_mode': 'local',
            'account_status': 'offline',
          };
        } else if (request.url.path.endsWith('/rider_payout_accounts')) {
          body = {'id': 'active-payout'};
        } else {
          throw StateError(
            'Unexpected offline test request: ${request.method} ${request.url.path}',
          );
        }
        return http.Response(
          jsonEncode(body),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
  });
  tearDownAll(() async {
    UserSessionService().stopListening();
    await Supabase.instance.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/package_info'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets(
    'rider refresh keeps content and avoids new eligibility reads; logout and next login route once',
    (tester) async {
      await Supabase.instance.client.auth.setSession('synthetic-refresh');
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: RiderEntryHandler(
              readyScreen: Scaffold(body: Text('Eligible dashboard')),
            ),
          ),
        ),
      );
      await flush(tester);
      expect(find.text('Eligible dashboard'), findsOneWidget);
      final before = requests
          .where((r) => r.url.path.endsWith('/rider_kyc'))
          .length;
      await tester.runAsync(
        () => Supabase.instance.client.auth.refreshSession(),
      );
      await flush(tester);
      expect(find.text('Eligible dashboard'), findsOneWidget);
      expect(
        requests.where((r) => r.url.path.endsWith('/rider_kyc')).length,
        before,
      );
      await tester.runAsync(() => Supabase.instance.client.auth.signOut());
      await flush(tester);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('Eligible dashboard'), findsNothing);
      await tester.runAsync(
        () => Supabase.instance.client.auth.setSession('synthetic-refresh'),
      );
      await flush(tester);
      expect(find.text('Eligible dashboard'), findsOneWidget);
      expect(
        requests.where((r) => r.url.path.endsWith('/rider_kyc')).length,
        before + 1,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('approved but inactive rider cannot mount dashboard', (
    tester,
  ) async {
    activation = 'inactive';
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: RiderEntryHandler(
            readyScreen: Scaffold(body: Text('Forbidden dashboard')),
          ),
        ),
      ),
    );
    await flush(tester);
    expect(find.text('Forbidden dashboard'), findsNothing);
    expect(find.text('KYC Verified'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    activation = 'active';
  });

  testWidgets(
    'restriction with failed remote logout restores auth owner and next login removes pushed OTP route',
    (tester) async {
      logoutFails = true;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: providerContainer,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: Text('Mode route without auth owner')),
          ),
        ),
      );
      await tester.runAsync(
        () => UserSessionService().handleAccountRestriction(isDeleted: false),
      );
      await flush(tester);
      expect(Supabase.instance.client.auth.currentUser, isNull);
      expect(find.byType(AppStartScreen), findsOneWidget);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('Mode route without auth owner'), findsNothing);
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Pushed OTP route')),
        ),
      );
      await flush(tester);
      expect(find.text('Pushed OTP route'), findsOneWidget);
      await tester.runAsync(
        () => Supabase.instance.client.auth.setSession('synthetic-refresh'),
      );
      await flush(tester);
      await flush(tester);
      expect(find.byType(ProfileSetupScreen), findsOneWidget);
      expect(find.text('Pushed OTP route'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'auth policy suppresses routine refresh/duplicate logout but routes a restored identity',
    () {
      final session = Session.fromJson({
        'access_token': 'synthetic',
        'refresh_token': 'synthetic',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': getUser(),
      })!;
      final policy = AuthRoutingPolicy(null);
      expect(
        policy.shouldRecheck(AuthState(AuthChangeEvent.initialSession, null)),
        isFalse,
      );
      expect(
        policy.shouldRecheck(
          AuthState(AuthChangeEvent.tokenRefreshed, session),
        ),
        isTrue,
      );
      expect(
        policy.shouldRecheck(
          AuthState(AuthChangeEvent.tokenRefreshed, session),
        ),
        isFalse,
      );
      expect(
        policy.shouldRecheck(AuthState(AuthChangeEvent.userUpdated, session)),
        isTrue,
      );
      expect(
        policy.shouldRecheck(AuthState(AuthChangeEvent.signedOut, null)),
        isTrue,
      );
      expect(
        policy.shouldRecheck(AuthState(AuthChangeEvent.signedOut, null)),
        isFalse,
      );
    },
  );
}
