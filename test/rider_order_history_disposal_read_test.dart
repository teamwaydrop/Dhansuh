import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/orders/screens/rider_order_history_screen.dart';

class _Read {
  _Read(this.request);
  final http.Request request;
  final result = Completer<http.Response>();
  void complete(dynamic rows, {bool fail = false}) => result.complete(
      http.Response(jsonEncode(fail ? {'code': 'TEST', 'message': 'synthetic'} : rows),
          fail ? 400 : 200, request: request, headers: {'content-type': 'application/json'}));
}

Future<void> _identity(String id) async {
  final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, Object> value) => base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  await Supabase.instance.client.auth.recoverSession(jsonEncode({
    'access_token': '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': id, 'exp': exp, 'role': 'authenticated'})}.synthetic',
    'refresh_token': 'synthetic', 'token_type': 'bearer', 'expires_in': 3600,
    'user': {'id': id, 'aud': 'authenticated', 'app_metadata': {}, 'user_metadata': {}, 'created_at': '2026-10-14T00:00:00Z'},
  }));
}


void main() {
  for (final disposeEarly in [false, true]) {
    testWidgets('Order History second GET respects disposal: $disposeEarly', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const links = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
      for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
      final reads = <_Read>[];
      final client = MockClient((request) {
        if (request.url.path.endsWith('/riders')) return Future.value(http.Response(jsonEncode({'id': 'RA'}), 200, request: request, headers: {'content-type': 'application/json'}));
        final read = _Read(request); reads.add(read); return read.result.future;
      });
      await tester.runAsync(() async {
        await Supabase.initialize(url: 'http://127.0.0.1:1', anonKey: 'synthetic', httpClient: client,
            authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
        await _identity('A');
      });
      addTearDown(() async {
        for (final read in reads) { if (!read.result.isCompleted) read.complete([]); }
        await tester.runAsync(() => Supabase.instance.dispose()); client.close();
        for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), null); }
      });
      await tester.pumpWidget(const MaterialApp(home: RiderOrderHistoryScreen(riderId: 'RA')));
      await tester.pump();
      expect(reads, hasLength(1));
      expect(reads[0].request.url.path, endsWith('/orders'));
      if (disposeEarly) await tester.pumpWidget(const SizedBox());
      reads[0].complete([]); await tester.pump(); await tester.pump();
      expect(reads, hasLength(disposeEarly ? 1 : 2));
      if (!disposeEarly) {
        expect(reads[1].request.url.path, endsWith('/rider_travel_plans'));
        expect(reads[1].request.url.queryParameters['rider_id'], 'eq.RA');
        reads[1].complete([]); await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
      expect(tester.takeException(), isNull);
    });
  }
}
