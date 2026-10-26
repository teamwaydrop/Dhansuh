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
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/features/rider/intercity/intercity_bookings_screen.dart';

void main() {
  testWidgets('actual resume triggers issue six GETs not eighteen and reject old/disposed data', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const links = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
    for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
    final first = Completer<void>();
    final second = Completer<void>();
    var lateGate = Completer<void>()..complete();
    final counts = <String, int>{};
    var fixtureAccount = 'A';
    final filters = <Map<String, String>>[];
    final client = MockClient((request) async {
      final table = request.url.path.split('/').last;
      Object? body;
      if (table == 'riders') {
        body = {'id': fixtureAccount == 'A' ? 'R' : 'RB', 'service_mode': 'intercity'};
      } else {
        filters.add(Map<String, String>.from(request.url.queryParameters));
        final key = '$table:${request.url.queryParameters['status']}';
        final attempt = counts[key] = (counts[key] ?? 0) + 1;
        body = table == 'rider_travel_plans' && request.url.queryParameters['status']!.startsWith('in.')
            ? [{'id': 'P', 'travel_date': '2026-10-14T12:00:00Z', 'travel_plan_type': 'ride',
                'status': 'active', 'pickup_city': attempt == 1 ? 'Obsolete' : 'Latest',
                'destination_city': 'Synthetic destination'}] : [];
        if (attempt == 1) {
          await first.future;
        } else if (attempt == 2) {
          await second.future;
        } else {
          await lateGate.future;
        }
      }
      return http.Response(jsonEncode(body), 200, request: request, headers: {'content-type': 'application/json'});
    });
    late HttpServer server;
    final sockets = <WebSocket>[];
    Future<void> identity(String id) async {
      fixtureAccount = id;
      final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
      String encode(Map<String, Object> value) => base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      await Supabase.instance.client.auth.recoverSession(jsonEncode({
        'access_token': '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': id, 'exp': exp, 'role': 'authenticated'})}.synthetic',
        'refresh_token': 'synthetic', 'token_type': 'bearer', 'expires_in': 3600,
        'user': {'id': id, 'aud': 'authenticated', 'app_metadata': {}, 'user_metadata': {}, 'created_at': '2026-10-14T00:00:00Z'},
      }));
    }
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
      await identity('A');
    });
    addTearDown(() async {
      if (!first.isCompleted) first.complete();
      if (!second.isCompleted) second.complete();
      if (!lateGate.isCompleted) lateGate.complete();
      RealtimeManager.instance.dispose();
      await tester.runAsync(() async {
        await Supabase.instance.dispose();
        for (final socket in sockets) { await socket.close(); }
        await server.close(force: true);
      });
      client.close();
      for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), null); }
    });
    await tester.pumpWidget(const MaterialApp(home: IntercityBookingsScreen()));
    await tester.pump();
    final dynamic state = tester.state(find.byType(IntercityBookingsScreen));
    expect(counts.values.fold<int>(0, (a, b) => a + b), 3);
    for (var i = 0; i < 5; i++) { state.didChangeAppLifecycleState(AppLifecycleState.resumed); }
    expect(counts.values.fold<int>(0, (a, b) => a + b), 3);
    first.complete(); await tester.pump();
    expect(counts.values.fold<int>(0, (a, b) => a + b), 6);
    expect(find.textContaining('Obsolete'), findsNothing);
    second.complete(); await tester.pump(); await tester.pump();
    expect(find.textContaining('Latest'), findsOneWidget);
    expect(find.textContaining('Obsolete'), findsNothing);
    lateGate = Completer<void>();
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(counts.values.fold<int>(0, (a, b) => a + b), 9);
    await tester.runAsync(() => identity('B'));
    await tester.pump();
    expect(find.textContaining('Latest'), findsNothing);
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(counts.values.fold<int>(0, (a, b) => a + b), 9);
    // A's late response must not republish while the same widget still shows B.
    lateGate.complete(); await tester.pump(); await tester.pump();
    expect(find.textContaining('Latest'), findsNothing);
    expect(counts.values.fold<int>(0, (a, b) => a + b), 9);
    // The retired instance does not rebind; a new instance resolves B normally.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MaterialApp(home: IntercityBookingsScreen()));
    await tester.pump(); await tester.pump();
    expect(counts.values.fold<int>(0, (a, b) => a + b), 12);
    expect(find.textContaining('Latest'), findsOneWidget);
    final dynamic replacement = tester.state(find.byType(IntercityBookingsScreen));
    lateGate = Completer<void>();
    replacement.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(counts.values.fold<int>(0, (a, b) => a + b), 15);
    await tester.pumpWidget(const SizedBox());
    lateGate.complete(); await tester.pump();
    replacement.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(counts.values.fold<int>(0, (a, b) => a + b), 15);
    expect(tester.takeException(), isNull);
    expect(filters.where((row) => row['rider_id'] != null).every((row) => ['eq.R', 'eq.RB'].contains(row['rider_id'])), isTrue);
    expect(filters.where((row) => row['traveller_id'] != null).every((row) => ['eq.R', 'eq.RB'].contains(row['traveller_id'])), isTrue);
    RealtimeManager.instance.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
