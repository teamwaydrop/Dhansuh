import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/orders/screens/rider_active_order_screen.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('actual active-order callers share reads and renderer consumes stored earnings', (tester) async {
    // Entirely synthetic local session and transport; no Supabase project or
    // authentication endpoint is contacted. Never output the synthetic token.
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final channels = ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events', 'com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
    for (final name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    final profileStarted = Completer<void>();
    final netStarted = Completer<void>();
    final profileResponse = Completer<void>();
    final netResponse = Completer<void>();
    var profiles = 0;
    var netReads = 0;
    var wallet = 80;
    var exactNetCount = 1;
    Object netValue = 18;
    var netStatus = 200;
    var verificationReads = 0;
    var verificationResponse = Completer<Object?>();
    final transport = MockClient((request) async {
      if (request.method == 'GET' && request.url.path.endsWith('/order_verifications')) {
        verificationReads++;
        final body = await verificationResponse.future;
        return http.Response(jsonEncode(body), 200, request: request,
          headers: {'content-type': 'application/json'});
      }
      if (request.method == 'GET' && request.url.path.endsWith('/riders')) {
        profiles++;
        if (!profileStarted.isCompleted) profileStarted.complete();
        await profileResponse.future;
        return http.Response(jsonEncode({'id': 'R', 'wallet_balance': wallet, 'total_completed_orders': 1}),
          200, request: request, headers: {'content-type': 'application/json'});
      }
      if (request.method == 'GET' && request.url.path.endsWith('/orders') &&
          request.url.queryParameters['select'] == 'rider_earning') {
        netReads++;
        if (!netStarted.isCompleted) netStarted.complete();
        await netResponse.future;
        return http.Response(netStatus == 200 ? jsonEncode([{'rider_earning': netValue}]) :
            '{"message":"synthetic_failure","code":"SYNTHETIC"}', netStatus, request: request,
          headers: {'content-type': 'application/json', 'content-range': '0-0/$exactNetCount'});
      }
      if (request.method == 'GET') {
        return http.Response('[]', 200, request: request, headers: {'content-type': 'application/json'});
      }
      // Read-only route/tax integrations are unavailable in this fixture.
      return http.Response('{"error":"synthetic_unavailable"}', 503,
        request: request, headers: {'content-type': 'application/json'});
    });
    late HttpServer server;
    final sockets = <WebSocket>[];
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((message) {
          final frame = jsonDecode(message as String) as Map;
          socket.add(jsonEncode({'topic': frame['topic'], 'event': 'phx_reply', 'ref': frame['ref'],
            'payload': {'status': 'ok', 'response': {'postgres_changes': []}}}));
        });
      });
      await Supabase.initialize(url: 'http://127.0.0.1:${server.port}', anonKey: 'synthetic-local-key',
          httpClient: transport, authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
      final expires = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
      String encode(Map<String, Object> value) => base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      final token = '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': 'A', 'exp': expires, 'role': 'authenticated'})}.synthetic';
      await Supabase.instance.client.auth.recoverSession(jsonEncode({
        'access_token': token, 'refresh_token': 'synthetic', 'token_type': 'bearer', 'expires_in': 3600,
        'user': {'id': 'A', 'aud': 'authenticated', 'app_metadata': {}, 'user_metadata': {},
          'created_at': DateTime.now().toUtc().toIso8601String()},
      }));
    });
    addTearDown(() async {
      if (!profileResponse.isCompleted) profileResponse.complete();
      if (!netResponse.isCompleted) netResponse.complete();
      if (!verificationResponse.isCompleted) verificationResponse.complete([]);
      await tester.runAsync(() async {
        await Supabase.instance.dispose();
        for (final socket in sockets) { await socket.close(); }
        await server.close(force: true); // Only this fixture's ephemeral server.
      });
      transport.close();
      debugDefaultTargetPlatformOverride = null;
      for (final name in channels) {
        messenger.setMockMethodCallHandler(MethodChannel(name), null);
      }
    });
    await tester.pumpWidget(MaterialApp(home: RiderActiveOrderScreen(orderId: 'O', initialOrder: {
      'id': 'O', 'rider_id': 'R', 'order_status': 'ongoing', 'order_type': 'ride',
      // Coordinates deliberately absent: routing is outside this read fixture.
      'current_fare': 21, 'final_fare': 21, 'rider_earning': 18,
    })));
    await tester.pump();
    expect(profileStarted.isCompleted, isTrue);
    final dynamic state = tester.state(find.byType(RiderActiveOrderScreen));
    final extraA = state.fetchRiderProfile() as Future<void>;
    final extraB = state.fetchRiderProfile() as Future<void>;
    expect(profiles, 1);
    profileResponse.complete();
    await tester.pump();
    expect(netStarted.isCompleted, isTrue);
    expect(netReads, 1);
    // Exercise the real consumer: compatible reads share, an authoritative
    // invalidation fences the pre-write observation and demands one trailing read.
    final v1 = state.loadVerifications() as Future<void>;
    final v2 = state.loadVerifications() as Future<void>;
    await tester.pump();
    final before = verificationReads;
    final fresh = state.loadVerifications(fresh: true) as Future<void>;
    final oldResponse = verificationResponse;
    verificationResponse = Completer<Object?>();
    oldResponse.complete([{'verification_type': 'pickup', 'verification_status': 'verified'}]);
    await tester.pump();
    await Future.wait([v1, v2]);
    expect(state.pickupPhotoCompleted, isFalse);
    expect(verificationReads, before + 1);
    verificationResponse.complete([{'verification_type': 'dropoff', 'verification_status': 'bypassed'}]);
    await tester.pump();
    await fresh;
    expect(state.pickupPhotoCompleted, isFalse);
    expect(state.dropoffPhotoCompleted, isTrue);
    verificationResponse = Completer<Object?>()..complete([{}]);
    final malformed = state.loadVerifications() as Future<void>;
    await tester.pump();
    await malformed;
    expect(state.dropoffPhotoCompleted, isTrue);
    verificationResponse = Completer<Object?>();
    final obsoleteIdentity = state.loadVerifications() as Future<void>;
    await tester.pump();
    state.order['rider_id'] = 'replacement-rider';
    verificationResponse.complete([{'verification_type': 'pickup', 'verification_status': 'verified'}]);
    await tester.pump();
    await obsoleteIdentity;
    expect(state.pickupPhotoCompleted, isFalse);
    state.order['rider_id'] = 'R';
    netResponse.complete();
    await tester.pump();
    await Future.wait([extraA, extraB]);
    expect(state.riderProfile['wallet_balance'], 80);
    expect(profiles, 1);
    expect(netReads, 1);
    // The real consumer must update a valid profile independently and retain
    // its last stored total across incomplete, malformed and failed reads.
    for (final failure in ['incomplete', 'malformed', 'request']) {
      wallet += 20;
      exactNetCount = failure == 'incomplete' ? 2 : 1;
      netValue = failure == 'malformed' ? 'bad' : 18;
      netStatus = failure == 'request' ? 400 : 200;
      final refresh = state.fetchRiderProfile() as Future<void>;
      await tester.pump();
      await refresh;
      expect(state.riderProfile['wallet_balance'], wallet);
    }
    expect(profiles, 4);
    expect(netReads, 4);
    // Render the real screen's completion builder, not a duplicate test formatter.
    final Widget completion = state.buildCompletionScreen();
    verificationResponse = Completer<Object?>();
    final lateVerification = state.loadVerifications() as Future<void>;
    await tester.pump();
    await tester.pumpWidget(MaterialApp(home: completion));
    verificationResponse.complete([]);
    await tester.pump();
    await lateVerification;
    final label = find.text("Today's Total Earnings");
    expect(label, findsOneWidget);
    final row = tester.widget<Row>(find.ancestor(of: label, matching: find.byType(Row)).first);
    expect(row.children.whereType<Text>().map((text) => text.data), contains('₹18.00'));
    expect(tester.takeException(), isNull);
    RealtimeManager.instance.dispose(); // Fixture-owned app-level heartbeat.
    debugDefaultTargetPlatformOverride = null;
  }, timeout: const Timeout(Duration(seconds: 30)));
}
