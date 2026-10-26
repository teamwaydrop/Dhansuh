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
import 'package:waydrop/features/rider/activity/rider_activity_tab.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';

void main() {
  testWidgets('actual Activity consumers share reads; Realtime demands one fresh read; disposal fences results', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channels = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in channels) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
    var ordersGate = Completer<void>();
    var ordersReads = 0;
    var riderReads = 0;
    var fail = false;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/logout')) return http.Response('', 204, request: request);
      if (request.url.path.endsWith('/riders')) {
        riderReads++;
        final id = request.url.queryParameters['user_id'] == 'eq.B' ? 'synthetic-rider-B' : 'synthetic-rider';
        return http.Response(jsonEncode({'id': id}), 200, request: request,
            headers: {'content-type': 'application/json'});
      }
      ordersReads++;
      final riderFilter = request.url.queryParameters['rider_id'];
      expect(riderFilter, isIn(['eq.synthetic-rider', 'eq.synthetic-rider-B']));
      expect(request.url.queryParameters['limit'], '30');
      expect(request.url.queryParameters['order'], 'updated_at.desc.nullslast');
      final shouldFail = fail;
      await ordersGate.future;
      return http.Response(shouldFail ? '{"code":"TEST","message":"synthetic failure"}' :
          jsonEncode(riderFilter == 'eq.synthetic-rider-B' ? [{'id': 'B-order', 'order_code': 'B-TEST',
            'order_status': 'completed', 'order_type': 'ride', 'rider_earning': 10}] : []),
          shouldFail ? 400 : 200, request: request, headers: {'content-type': 'application/json'});
    });
    late HttpServer server;
    final sockets = <WebSocket>[];
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (!WebSocketTransformer.isUpgradeRequest(request)) { request.response.statusCode = 404; await request.response.close(); return; }
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((message) {
          final frame = jsonDecode(message as String) as Map;
          socket.add(jsonEncode({'topic': frame['topic'], 'event': 'phx_reply', 'ref': frame['ref'],
            'payload': {'status': 'ok', 'response': {'postgres_changes': []}}}));
        });
      });
      await Supabase.initialize(url: 'http://127.0.0.1:${server.port}', anonKey: 'synthetic-local-key',
          httpClient: client, authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
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
    await tester.runAsync(() => identity('A'));
    addTearDown(() async {
      if (!ordersGate.isCompleted) ordersGate.complete();
      RealtimeManager.instance.dispose();
      await tester.runAsync(() async {
        await Supabase.instance.dispose();
        for (final socket in sockets) { await socket.close(); }
        await server.close(force: true);
      });
      client.close();
      for (final name in channels) { messenger.setMockMethodCallHandler(MethodChannel(name), null); }
    });
    await tester.pumpWidget(const MaterialApp(home: RiderActivityTab()));
    await tester.pump();
    final dynamic state = tester.state(find.byType(RiderActivityTab));
    final overlapping = List.generate(5, (_) => state.loadActivity() as Future<void>);
    await tester.pump();
    expect(riderReads, 1);
    expect(ordersReads, 1); // Startup plus five refreshes formerly issued six GETs.
    final channel = Supabase.instance.client.getChannels().single;
    channel.trigger('UPDATE', {
      'schema': 'public', 'table': 'orders', 'type': 'UPDATE', 'commit_timestamp': '2026-10-13T00:00:00Z',
      'columns': [{'name': 'rider_id', 'type': 'text'}],
      'record': {'rider_id': 'synthetic-rider'}, 'old_record': {}, 'errors': null,
    });
    final fresh = state.loadActivity() as Future<void>;
    await tester.pump();
    final oldGate = ordersGate;
    ordersGate = Completer<void>();
    await tester.runAsync(() async { oldGate.complete(); });
    await tester.pump();
    await Future.wait(overlapping);
    expect(state.loading, isTrue); // Pre-event evidence was not published.
    expect(ordersReads, 2);
    await tester.runAsync(() async { ordersGate.complete(); });
    await tester.pump();
    await fresh;
    expect(state.loading, isFalse);
    expect(find.text('No Recent Trips'), findsOneWidget);
    // Failure releases the reader; the next explicit refresh can run.
    fail = true;
    final failed = state.loadActivity() as Future<void>;
    await tester.pump(); await failed;
    fail = false;
    final recovered = state.loadActivity() as Future<void>;
    await tester.pump(); await recovered;
    expect(ordersReads, 4);
    ordersGate = Completer<void>();
    final late = state.loadActivity() as Future<void>;
    await tester.pump();
    final heldA = ordersGate;
    final otherId = RealtimeManager.instance.subscribe(
        channelName: 'rider-activity-channel-synthetic-rider', table: 'orders',
        owner: 'SyntheticOtherOwner', event: PostgresChangeEvent.all,
        filterColumn: 'rider_id', filterValue: 'synthetic-rider', callback: (_) {});
    ordersGate = Completer<void>();
    await tester.runAsync(() => identity('B'));
    await tester.pump();
    await tester.pump();
    expect(RealtimeManager.instance.getDebugMetrics()['rider-activity-channel-synthetic-rider'], ['SyntheticOtherOwner']);
    expect(RealtimeManager.instance.getDebugMetrics()['rider-activity-channel-synthetic-rider-B'], ['RiderActivityTab']);
    final beforeReplay = ordersReads;
    channel.trigger('UPDATE', {
      'schema': 'public', 'table': 'orders', 'type': 'UPDATE', 'commit_timestamp': '2026-10-13T00:00:00Z',
      'columns': [{'name': 'rider_id', 'type': 'text'}],
      'record': {'rider_id': 'synthetic-rider'}, 'old_record': {}, 'errors': null,
    });
    await tester.pump(const Duration(milliseconds: 500));
    expect(ordersReads, beforeReplay);
    await tester.runAsync(() async { ordersGate.complete(); });
    await tester.pump();
    await tester.pump();
    expect(state.orders.single['id'], 'B-order');
    await tester.runAsync(() async { heldA.complete(); });
    await tester.pump(); await late;
    expect(state.orders.single['id'], 'B-order');
    await tester.runAsync(() => Supabase.instance.client.auth.signOut(scope: SignOutScope.local));
    await tester.pump();
    expect(state.orders, isEmpty);
    expect(RealtimeManager.instance.getDebugMetrics().containsKey('rider-activity-channel-synthetic-rider-B'), isFalse);
    expect(RealtimeManager.instance.getDebugMetrics()['rider-activity-channel-synthetic-rider'], ['SyntheticOtherOwner']);
    await tester.pumpWidget(const SizedBox());
    final afterDispose = ordersReads;
    await tester.runAsync(() => identity('A'));
    await state.loadActivity();
    expect(ordersReads, afterDispose);
    expect(RealtimeManager.instance.getDebugMetrics()['rider-activity-channel-synthetic-rider'], ['SyntheticOtherOwner']);
    RealtimeManager.instance.unsubscribe('rider-activity-channel-synthetic-rider', otherId);
    expect(RealtimeManager.instance.activeChannelCount, 0);
    expect(tester.takeException(), isNull);
    RealtimeManager.instance.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
