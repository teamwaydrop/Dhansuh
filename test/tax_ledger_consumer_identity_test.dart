import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/database/government_tax_ledger_cache.dart';
import 'package:waydrop/shared/widgets/identity_fenced_future_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockClient transport;
  const channels = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    for (final name in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    transport = MockClient((request) async => http.Response('[]', 200, request: request));
    await Supabase.initialize(url: 'http://127.0.0.1:1', anonKey: 'synthetic-local-key',
        httpClient: transport, authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
  });
  setUp(GovernmentTaxLedgerCache.clearAll);
  tearDown(GovernmentTaxLedgerCache.clearAll);
  tearDownAll(() async {
    await Supabase.instance.dispose(); transport.close();
    for (final name in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });
  Future<void> identity(String id) async {
    final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
    String encode(Map<String, Object> value) => base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token = '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': id, 'exp': exp, 'role': 'authenticated'})}.synthetic';
    await Supabase.instance.client.auth.recoverSession(jsonEncode({
      'access_token': token, 'refresh_token': 'synthetic', 'token_type': 'bearer', 'expires_in': 3600,
      'user': {'id': id, 'aud': 'authenticated', 'app_metadata': {}, 'user_metadata': {},
        'created_at': DateTime.now().toUtc().toIso8601String()},
    }));
  }
  for (final scenario in ['identity', 'disposal', 'success', 'already-resolved']) {
    testWidgets('production tax display fence: $scenario', (tester) async {
      await tester.runAsync(() => identity('A'));
      final response = Completer<Map<String, dynamic>?>();
      final value = GovernmentTaxLedgerCache.get('synthetic-order', () => response.future);
      var applied = 0;
      await tester.pumpWidget(MaterialApp(home: IdentityFencedFutureBuilder<Map<String, dynamic>?>(
        ownerUserId: 'A', future: value, builder: (_, snapshot) {
          if (!snapshot.hasData) return const Text('pending');
          applied++;
          return Text('tax:${snapshot.data!['amount']}');
        })));
      if (scenario == 'already-resolved') {
        response.complete({'amount': 7, 'rate_percent': 1});
        await tester.pump(); await tester.pump();
        expect(find.text('tax:7'), findsOneWidget);
      }
      final before = applied;
      if (scenario == 'identity' || scenario == 'already-resolved') {
        await tester.runAsync(() => identity('B'));
        await tester.pump();
      }
      if (scenario == 'disposal') await tester.pumpWidget(const SizedBox());
      if (!response.isCompleted) response.complete({'amount': 7, 'rate_percent': 1});
      await tester.pump(); await tester.pump();
      if (scenario == 'success') {
        expect(find.text('tax:7'), findsOneWidget);
        expect(applied, greaterThan(before));
      } else {
        expect(find.text('tax:7'), findsNothing);
        expect(applied, before);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
