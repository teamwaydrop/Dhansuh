import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/user/activity/activity_tab.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';

void main() {
  testWidgets('Passenger Activity shares compatible page-one reads and retains fresh invalidation', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const links = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
    var gate = Completer<void>();
    var reads = 0;
    final client = MockClient((request) async {
      expect(request.url.path, '/rest/v1/orders');
      expect(request.url.queryParameters['user_id'], 'eq.A');
      reads++;
      await gate.future;
      return http.Response('[]', 200, request: request, headers: {'content-type': 'application/json'});
    });
    late HttpServer server;
    final sockets = <WebSocket>[];
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (!WebSocketTransformer.isUpgradeRequest(request)) { request.response.statusCode = 404; await request.response.close(); return; }
        final socket = await WebSocketTransformer.upgrade(request); sockets.add(socket);
        socket.listen((message) {
          final frame = jsonDecode(message as String) as Map;
          socket.add(jsonEncode({'topic': frame['topic'], 'event': 'phx_reply', 'ref': frame['ref'],
            'payload': {'status': 'ok', 'response': {'postgres_changes': []}}}));
        });
      });
      await Supabase.initialize(url: 'http://127.0.0.1:${server.port}', anonKey: 'synthetic-local-key',
          httpClient: client, authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
      final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
      String encode(Map<String, Object> value) => base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      final token = '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': 'A', 'exp': exp, 'role': 'authenticated'})}.synthetic';
      await Supabase.instance.client.auth.recoverSession(jsonEncode({
        'access_token': token, 'refresh_token': 'synthetic', 'token_type': 'bearer', 'expires_in': 3600,
        'user': {'id': 'A', 'aud': 'authenticated', 'app_metadata': {}, 'user_metadata': {},
          'created_at': DateTime.now().toUtc().toIso8601String()},
      }));
    });
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      RealtimeManager.instance.dispose();
      await tester.runAsync(() async {
        await Supabase.instance.dispose();
        for (final socket in sockets) { await socket.close(); }
        await server.close(force: true);
      });
      client.close();
      for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), null); }
    });
    await tester.pumpWidget(const MaterialApp(home: ActivityTab()));
    await tester.pump();
    final state = tester.state<ActivityTabState>(find.byType(ActivityTab));
    final ordinary = List.generate(5, (_) => state.loadOrders());
    await tester.pump();
    expect(reads, 3); // Six triggers share one active/rides/parcels batch.
    Supabase.instance.client.getChannels().single.trigger('UPDATE', {
      'schema': 'public', 'table': 'orders', 'type': 'UPDATE', 'commit_timestamp': '2026-10-13T00:00:00Z',
      'columns': [{'name': 'user_id', 'type': 'text'}], 'record': {'user_id': 'A'}, 'old_record': {}, 'errors': null,
    });
    final postWrite = state.loadOrders(fresh: true);
    final postWriteDuplicate = state.loadOrders();
    final old = gate;
    gate = Completer<void>();
    await tester.runAsync(() async { old.complete(); });
    await tester.pump();
    await Future.wait(ordinary);
    expect(state.loading, isTrue);
    expect(reads, 6);
    await tester.runAsync(() async { gate.complete(); });
    await tester.pump();
    await Future.wait([postWrite, postWriteDuplicate]);
    expect(state.loading, isFalse);
    final before = reads;
    await tester.pumpWidget(const SizedBox());
    await state.loadOrders();
    expect(reads, before);
    expect(tester.takeException(), isNull);
    RealtimeManager.instance.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
