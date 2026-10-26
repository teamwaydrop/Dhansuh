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
import 'package:waydrop/core/providers/initial_data_provider.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/features/rider/profile/rider_profile_tab.dart';
import 'package:waydrop/main.dart';

void main() {
  testWidgets('profile async boundaries, replacement loads and owned subscription teardown', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const appLinks = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
    for (final name in appLinks) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    var userGate = Completer<void>();
    var suspendUser = true;
    final oldKyc = Completer<void>();
    var suspendKyc = false;
    var kycReads = 0;
    var riderReads = 0;
    var rating = 4;
    var fixtureUser = 'A';
    final oldRole = Completer<void>();
    final oldReward = Completer<void>();
    final sockets = <WebSocket>[];
    late HttpServer server;
    final client = MockClient((request) async {
      Object body = {'enabled': false};
      if (request.url.path.endsWith('/users')) {
        if (request.url.queryParameters['select'] == 'user_code') {
          if (suspendUser) await userGate.future;
          body = {'user_code': 'synthetic'};
        } else {
          final account = fixtureUser;
          if (account == 'A') await oldRole.future;
          body = {'role': account == 'A' ? 'admin' : 'user'};
        }
      } else if (request.url.path.endsWith('/get_reward_status')) {
        final account = fixtureUser;
        if (account == 'A') await oldReward.future;
        body = {'enabled': false};
      } else if (request.url.path.endsWith('/riders')) {
        riderReads++;
        body = {'id': 'R', 'kyc_id': 'K', 'rating': rating, 'account_status': 'offline'};
      } else if (request.url.path.endsWith('/rider_kyc')) {
        kycReads++;
        final captured = rating;
        if (suspendKyc) { suspendKyc = false; await oldKyc.future; }
        body = {'full_name': 'Synthetic $captured', 'vehicle_type': 'bike', 'vehicle_number': 'TEST'};
      }
      return http.Response(jsonEncode(body), 200, request: request,
          headers: {'content-type': 'application/json'});
    });
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
          httpClient: client, authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    });
    Future<void> identity(String id) async {
      fixtureUser = id;
      final expires = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
      String encode(Map<String, Object> value) => base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      final token = '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': id, 'exp': expires, 'role': 'authenticated'})}.synthetic';
      await Supabase.instance.client.auth.recoverSession(jsonEncode({
        'access_token': token, 'refresh_token': 'synthetic', 'token_type': 'bearer', 'expires_in': 3600,
        'user': {'id': id, 'aud': 'authenticated', 'app_metadata': {}, 'user_metadata': {},
          'created_at': DateTime.now().toUtc().toIso8601String()},
      }));
    }
    addTearDown(() async {
      if (!userGate.isCompleted) userGate.complete();
      if (!oldKyc.isCompleted) oldKyc.complete();
      if (!oldRole.isCompleted) oldRole.complete();
      if (!oldReward.isCompleted) oldReward.complete();
      providerContainer.read(initialRiderDataProvider.notifier).state = null;
      RealtimeManager.instance.dispose();
      await tester.runAsync(() async {
        await Supabase.instance.dispose();
        for (final socket in sockets) { await socket.close(); }
        await server.close(force: true);
      });
      client.close();
      for (final name in appLinks) {
        messenger.setMockMethodCallHandler(MethodChannel(name), null);
      }
    });
    await tester.runAsync(() => identity('A'));
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: RiderProfileTab())));
    await tester.pump();
    final dynamic disposedState = tester.state(find.byType(RiderProfileTab));
    await tester.pumpWidget(const SizedBox());
    suspendUser = false;
    userGate.complete();
    await tester.pump();
    await disposedState.loadProfileData();
    expect(riderReads, 0);
    expect(kycReads, 0);
    expect(RealtimeManager.instance.activeChannelCount, 0);

    // The first seed is held at KYC while a newer complete batch applies.
    providerContainer.read(initialRiderDataProvider.notifier).state = InitialRiderData(
      userId: 'A', rider: {'id': 'R', 'kyc_id': 'K', 'rating': 1, 'account_status': 'offline'});
    suspendKyc = true;
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: RiderProfileTab())));
    await tester.pump();
    final dynamic state = tester.state(find.byType(RiderProfileTab));
    expect(kycReads, 1);
    rating = 5;
    final newer = state.loadProfileData() as Future<void>;
    await tester.pump();
    await newer;
    expect(state.rider['rating'], 5);
    expect(state.kyc['full_name'], 'Synthetic 5');
    expect(RealtimeManager.instance.activeChannelCount, 1);
    final retiredChannel = Supabase.instance.client.getChannels().first;
    oldKyc.complete();
    await tester.pump();
    expect(state.rider['rating'], 5);
    expect(state.kyc['full_name'], 'Synthetic 5');

    // A change of authenticated account fences old work before subsequent reads.
    // Hold A at its first await, then replace the identity and complete B.
    userGate = Completer<void>();
    suspendUser = true;
    final obsolete = state.loadProfileData() as Future<void>;
    await tester.pump();
    await tester.runAsync(() => identity('B'));
    suspendUser = false;
    final replacement = state.loadProfileData() as Future<void>;
    await tester.pump();
    await replacement;
    oldRole.complete();
    oldReward.complete();
    await tester.pump();
    expect(find.text('Admin Support Panel'), findsNothing);
    final readsBeforeOldRelease = riderReads;
    userGate.complete();
    await tester.pump();
    await obsolete;
    expect(riderReads, readsBeforeOldRelease);
    // Replay through the actual SDK/manager dispatcher of the retired channel.
    retiredChannel.trigger('UPDATE', {
      'columns': [{'name': 'id', 'type': 'text'}, {'name': 'rating', 'type': 'int4'}],
      'schema': 'public', 'table': 'riders', 'commit_timestamp': '2026-10-13T00:00:00Z',
      'type': 'UPDATE', 'record': {'id': 'R', 'rating': 1}, 'old_record': {'id': 'R', 'rating': 5},
      'errors': null,
    });
    await tester.pump();
    expect(riderReads, readsBeforeOldRelease);
    expect(state.rider['rating'], 5);
    expect(RealtimeManager.instance.activeChannelCount, 1);
    final sharedId = RealtimeManager.instance.subscribe(
      channelName: 'rider-home-R', table: 'riders', owner: 'SyntheticOtherOwner',
      event: PostgresChangeEvent.update, schema: 'public', filterColumn: 'id',
      filterValue: 'R', callback: (_) {});
    // Hide then dispose: repeated teardown must not remove another owner.
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: RiderProfileTab(isActive: false))));
    expect(RealtimeManager.instance.getDebugMetrics()['rider-home-R'], ['SyntheticOtherOwner']);
    await tester.pumpWidget(const SizedBox());
    final readsAfterTeardown = riderReads;
    retiredChannel.trigger('UPDATE', {
      'columns': [{'name': 'id', 'type': 'text'}, {'name': 'rating', 'type': 'int4'}],
      'schema': 'public', 'table': 'riders', 'commit_timestamp': '2026-10-13T00:00:00Z',
      'type': 'UPDATE', 'record': {'id': 'R', 'rating': 1}, 'old_record': {}, 'errors': null,
    });
    await tester.pump();
    expect(riderReads, readsAfterTeardown);
    expect(RealtimeManager.instance.getDebugMetrics()['rider-home-R'], ['SyntheticOtherOwner']);
    RealtimeManager.instance.unsubscribe('rider-home-R', sharedId);
    expect(RealtimeManager.instance.activeChannelCount, 0);
    expect(tester.takeException(), isNull);
    RealtimeManager.instance.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
