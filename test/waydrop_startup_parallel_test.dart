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
import 'package:waydrop/app_start_screen.dart';
import 'package:waydrop/shared/screens/maintenance_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const userId = '00000000-0000-4000-8000-000000000051';
  final requests = <http.Request>[];
  final profile = Completer<http.Response>();
  String encode(Object v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
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
      httpClient: MockClient((r) async {
        requests.add(r);
        Object? body;
        if (r.url.path.endsWith('/token')) {
          body = {
            'access_token': token,
            'refresh_token': 'synthetic',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': userId,
              'aud': 'authenticated',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': {},
              'user_metadata': {},
            },
          };
        } else if (r.url.path.endsWith('/user')) {
          body = {'id':userId,'aud':'authenticated','created_at':'2026-01-01T00:00:00Z','app_metadata':{},'user_metadata':{}};
        } else if (r.url.path.endsWith('/production_config')) {
          body = {
            'maintenance_mode': true,
            'maintenance_message': 'Synthetic maintenance',
            'force_update': false,
          };
        } else if (r.url.path.endsWith('/users')) {
          return profile.future;
        } else {
          throw StateError('Unexpected test request ${r.url.path}');
        }
        return http.Response(
          jsonEncode(body),
          200,
          request: r,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await Supabase.instance.client.auth.setSession('synthetic');
  });
  tearDownAll(() async {
    await Supabase.instance.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/package_info'),
          null,
        );
  });
  testWidgets(
    'maintenance is displayed without waiting for a stalled parallel profile request',
    (tester) async {
      try {
        await tester.pumpWidget(
          const ProviderScope(child: MaterialApp(home: AppStartScreen())),
        );
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(
          requests
              .where((r) => r.url.path.endsWith('/production_config'))
              .length,
          1,
        );
        expect(requests.where((r) => r.url.path.endsWith('/users')).length, 1);
        expect(profile.isCompleted, isFalse);
        expect(find.byType(MaintenanceScreen), findsOneWidget);
      } finally {
        final request = requests.firstWhere(
          (r) => r.url.path.endsWith('/users'),
        );
        profile.complete(
          http.Response(
            'null',
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          ),
        );
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
}
