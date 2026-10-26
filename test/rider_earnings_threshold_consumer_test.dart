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
import 'package:waydrop/features/rider/earnings/rider_earnings_tab.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/core/services/database/rider_payout_account_cache.dart';

void main() {
  testWidgets('actual Earnings batches share scoped config/profile reads and preserve partial-failure UI', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const links = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
    RiderPayoutAccountCache.clear();
    var gate = Completer<void>();
    var thresholdReads = 0;
    var profileReads = 0;
    var activityReads = 0;
    var recentReads = 0;
    var withdrawalReads = 0;
    var activeTimestampReads = 0;
    final activeTimestampGate = Completer<void>();
    final activeTimestampFilters = <Map<String, String>>[];
    final withdrawalGate = Completer<void>();
    final withdrawalFilters = <Map<String, String>>[];
    final recentGate = Completer<void>();
    final recentFilters = <Map<String, String>>[];
    final activityGate = Completer<void>();
    final activityFilters = <Map<String, String>>[];
    final profileGate = Completer<void>();
    final profileFilters = <Map<String, String>>[];
    var failThreshold = false;
    var thresholdValue = 700;
    var fixtureUser = 'A';
    var failOrders = false;
    var ordersMode = 'complete';
    var ordersFare = 21;
    Completer<void>? ordersGate;
    final ordersFilters = <Map<String, String>>[];
    final ordersPreferences = <String?>[];
    final thresholdFilters = <Map<String, String>>[];
    final client = MockClient((request) async {
      final table = request.url.path.split('/').last;
      Object? body = [];
      var status = 200;
      final headers = {'content-type': 'application/json'};
      if (table == 'government_tax_config') {
        thresholdReads++;
        thresholdFilters.add(Map<String, String>.from(request.url.queryParameters));
        final failure = failThreshold;
        final capturedValue = thresholdValue;
        await gate.future;
        status = failure ? 400 : 200;
        body = failure ? {'code': 'TEST', 'message': 'synthetic'} : {'threshold_amount': capturedValue};
      } else if (table == 'riders') {
        profileReads++;
        profileFilters.add(Map<String, String>.from(request.url.queryParameters));
        body = {'id': fixtureUser == 'A' ? 'R' : 'RB', 'total_earnings': 0, 'wallet_balance': fixtureUser == 'A' ? 12 : 24,
          'cod_pending_amount': 0, 'cod_limit': 100, 'government_tax_due_balance': 0,
          'subscription_active': false};
        await profileGate.future;
      } else if (table == 'rider_withdrawals') {
        withdrawalReads++;
        withdrawalFilters.add(Map<String, String>.from(request.url.queryParameters));
        await withdrawalGate.future;
      } else if (table == 'rider_daily_activity') {
        activityReads++;
        activityFilters.add(Map<String, String>.from(request.url.queryParameters));
        await activityGate.future;
      } else if (table == 'orders' && request.url.queryParameters['limit'] == '3') {
        recentReads++;
        recentFilters.add(Map<String, String>.from(request.url.queryParameters));
        body = [
          {'id': 'latest', 'order_code': 'LATEST', 'order_type': 'local_ride', 'completed_at': '2026-10-14T02:00:00Z'},
          {'id': 'second', 'order_code': 'SECOND', 'order_type': 'local_ride', 'completed_at': '2026-10-13T02:00:00Z'},
          {'id': 'third', 'order_code': 'THIRD', 'order_type': 'local_ride', 'completed_at': '2026-10-12T02:00:00Z'},
        ];
        await recentGate.future;
      } else if (table == 'orders' && request.url.queryParameters['select'] == 'picked_up_at,accepted_at,created_at') {
        activeTimestampReads++;
        activeTimestampFilters.add(Map<String, String>.from(request.url.queryParameters));
        body = null;
        await activeTimestampGate.future;
      } else if (table == 'orders' && request.url.queryParameters.containsKey('completed_at')) {
        ordersFilters.add(Map<String, String>.from(request.url.queryParameters));
        ordersPreferences.add(request.headers['Prefer']);
        body = ordersMode == 'empty' ? [] : [{
          'id': 'complete-order', 'order_code': 'COMPLETE', 'order_type': 'local_ride',
          'completed_at': DateTime.now().toUtc().toIso8601String(),
          'final_fare': ordersFare, 'current_fare': ordersFare, 'rider_earning': 17.95,
        }];
        if (ordersMode != 'missing') {
          headers['content-range'] = switch (ordersMode) {
            'mismatch' => '0-0/2', 'malformed' => '0-0/*', 'empty' => '*/0', _ => '0-0/1',
          };
        }
        if (failOrders) {
          body = {'code': 'TEST', 'message': 'synthetic orders failure'};
          status = 400;
        }
        final heldOrders = ordersGate;
        if (heldOrders != null) await heldOrders.future;
      } else if (table == 'rider_payout_accounts') {
        body = null;
      } else if (table == 'create-rider-withdrawal') {
        body = {'success': true};
      }
      return http.Response(jsonEncode(body), status, request: request,
          headers: headers);
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
    });
    Future<void> identity(String id) async {
      fixtureUser = id;
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
      if (!gate.isCompleted) gate.complete();
      RealtimeManager.instance.dispose(); RiderPayoutAccountCache.clear();
      await tester.runAsync(() async {
        await Supabase.instance.dispose();
        for (final socket in sockets) { await socket.close(); }
        await server.close(force: true);
      });
      client.close();
      for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), null); }
    });
    await tester.pumpWidget(const MaterialApp(home: RiderEarningsTab()));
    await tester.pump();
    dynamic state = tester.state(find.byType(RiderEarningsTab));
    final pending = List.generate(5, (_) => state.fetchData() as Future<void>);
    await tester.pump();
    expect(thresholdReads, 1);
    expect(profileReads, 1); // Six screen batches, one identical profile GET.
    profileGate.complete();
    await tester.pump();
    expect(activityReads, 1); // Six batches share the exact rider/date projection.
    expect(recentReads, 1); // Six batches share only the latest-three read.
    expect(withdrawalReads, 1); // Six batches share only the recent-ten withdrawal read.
    expect(activeTimestampReads, 1); // Six batches, one timestamp-only GET.
    activityGate.complete();
    recentGate.complete();
    withdrawalGate.complete();
    activeTimestampGate.complete();
    thresholdValue = 800;
    expect(Supabase.instance.client.getChannels(), hasLength(2));
    Supabase.instance.client.getChannels().last.trigger('UPDATE', {
      'schema': 'public', 'table': 'riders', 'type': 'UPDATE', 'commit_timestamp': '2026-10-13T00:00:00Z',
      'columns': [{'name': 'wallet_balance', 'type': 'int4'}], 'record': {'wallet_balance': 13},
      'old_record': {'wallet_balance': 12}, 'errors': null,
    });
    final fresh = state.fetchData(fresh: true) as Future<void>;
    final oldGate = gate;
    gate = Completer<void>();
    await tester.runAsync(() async { oldGate.complete(); });
    await tester.pump(); await Future.wait(pending);
    expect(thresholdReads, 2);
    expect(state.taxDueThreshold, 100); // Invalidated 700 cannot publish.
    await tester.runAsync(() async { gate.complete(); });
    await tester.pump(); await fresh;
    expect(state.taxDueThreshold, 800);
    expect(state.rider['wallet_balance'], 12);
    expect(state.todayEarnings, 21);
    expect(state.recentOrders.single['id'], 'complete-order');
    for (final mode in ['mismatch', 'missing', 'malformed']) {
      ordersMode = mode;
      final before = ordersFilters.length;
      final refresh = state.fetchData(fresh: true) as Future<void>;
      await tester.pump(); await refresh; await tester.pump();
      expect(ordersFilters.length, before + 1); // Same GET; no HEAD/count query/retry.
      expect(state.todayEarnings, 21);
      expect(state.recentOrders.single['id'], 'complete-order');
      expect(find.text('30-day totals and history are stale. Refresh failed.'), findsOneWidget);
      expect(find.text('Unable to load'), findsOneWidget);
    }
    ordersMode = 'empty';
    final emptyRefresh = state.fetchData(fresh: true) as Future<void>;
    await tester.pump(); await emptyRefresh; await tester.pump();
    expect(state.todayEarnings, 0);
    expect(state.recentOrders, isEmpty);
    expect(find.text('Unable to load'), findsNothing);
    ordersMode = 'complete';
    final completeRefresh = state.fetchData(fresh: true) as Future<void>;
    await tester.pump(); await completeRefresh; await tester.pump();
    expect(state.todayEarnings, 21);
    expect(state.recentOrders.single['id'], 'complete-order');
    expect((state.recentCompletedRides as List).map((row) => row['id']), ['latest', 'second', 'third']);
    failThreshold = true;
    final partial = state.fetchData(fresh: true) as Future<void>;
    await tester.pump(); await partial;
    expect(state.taxDueThreshold, 100);
    expect(state.rider['wallet_balance'], 12);
    expect(thresholdReads, 8); // Includes the five explicit completeness refreshes.
    // Keep A's older complete response pending while a newer same-account batch publishes.
    ordersFare = 41;
    ordersGate = Completer<void>();
    final heldOrders = ordersGate;
    final olderBatch = state.fetchData() as Future<void>;
    await tester.pump();
    expect(state.todayEarnings, 21);
    expect(state.recentOrders.single['final_fare'], 21);
    ordersGate = null;
    ordersFare = 42;
    final newerBatch = state.fetchData() as Future<void>;
    await tester.pump(); await newerBatch; await tester.pump();
    expect(state.todayEarnings, 42);
    expect(state.recentOrders.single['final_fare'], 42);
    heldOrders.complete();
    await tester.pump(); await olderBatch; await tester.pump();
    expect(state.todayEarnings, 42);
    expect(state.recentOrders.single['final_fare'], 42);
    ordersFare = 21;
    // A's suspended result cannot become B's threshold or overwrite B's rider.
    failThreshold = false;
    gate = Completer<void>();
    final obsolete = state.fetchData() as Future<void>;
    await tester.pump();
    final heldA = gate;
    gate = Completer<void>();
    thresholdValue = 900;
    await tester.runAsync(() => identity('B'));
    await tester.pump();
    expect(state.recentOrders, isEmpty);
    expect(state.todayEarnings, 0);
    expect(find.text('30-day totals and history are unavailable.'), findsOneWidget);
    final b = state.fetchData() as Future<void>;
    await tester.pump();
    await tester.runAsync(() async { gate.complete(); });
    await tester.pump(); await b;
    expect(state.taxDueThreshold, 900);
    expect(state.rider['wallet_balance'], 24);
    await tester.runAsync(() async { heldA.complete(); });
    await tester.pump(); await obsolete;
    expect(state.taxDueThreshold, 900);
    expect(state.rider['wallet_balance'], 24);
    failOrders = true;
    final partialOrders = state.fetchData(fresh: true) as Future<void>;
    await tester.pump(); await partialOrders;
    await tester.pump();
    expect(find.text('Unable to load'), findsOneWidget);
    expect(state.rider['wallet_balance'], 24);
    failOrders = false;
    await tester.pumpWidget(const SizedBox());
    ordersMode = 'missing';
    await tester.pumpWidget(const MaterialApp(home: RiderEarningsTab()));
    await tester.pump();
    state = tester.state(find.byType(RiderEarningsTab));
    final firstFailure = state.fetchData() as Future<void>;
    await tester.pump(); await firstFailure; await tester.pump();
    expect(state.recentOrders, isEmpty);
    expect(find.text('Unable to load'), findsOneWidget);
    expect(find.text('30-day totals and history are unavailable.'), findsOneWidget);
    expect(find.text('Earnings Analytics'), findsNothing);
    ordersMode = 'complete';
    gate = Completer<void>();
    final late = state.fetchData() as Future<void>;
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async { gate.complete(); });
    await tester.pump(); await late;
    final count = thresholdReads;
    await state.fetchData();
    expect(thresholdReads, count);
    for (final filters in thresholdFilters) {
      expect(filters['select'], 'threshold_amount');
      expect(filters['is_active'], 'eq.true');
    }
    for (final filters in profileFilters) {
      expect(filters['select'], 'id,total_earnings,wallet_balance,cod_pending_amount,cod_limit,government_tax_due_balance,subscription_active');
      expect(filters['user_id'], anyOf('eq.A', 'eq.B'));
    }
    for (final filters in activityFilters) {
      expect(filters['select'], 'date,online_seconds,last_online_toggle_at');
      expect(filters['rider_id'], anyOf('eq.R', 'eq.RB'));
      expect(filters['date'], startsWith('gte.'));
      expect(filters['order'], 'date.asc.nullslast');
    }
    for (final filters in recentFilters) {
      expect(filters['select'], 'id,order_code,order_type,completed_at,created_at,picked_up_at,accepted_at,rider_earning,boost_amount,distance_km,time_taken_seconds,vehicle_type,final_fare,current_fare,gst_amount,gst_percentage,pg_charge_amount,commission_amount,commission_percentage,subscription_commission_waived,fare_payment_method,payment_mode,payment_status');
      expect(filters['rider_id'], anyOf('eq.R', 'eq.RB'));
      expect(filters['order_status'], 'in.("completed","delivered")');
      expect(filters['order'], 'completed_at.desc.nullslast');
      expect(filters['limit'], '3');
      expect(filters.containsKey('completed_at'), isFalse);
    }
    for (final filters in withdrawalFilters) {
      expect(filters['select'], 'amount,status,created_at,cashfree_response,transfer_id,cashfree_reference_id');
      expect(filters['rider_id'], anyOf('eq.R', 'eq.RB'));
      expect(filters['order'], 'created_at.desc.nullslast');
      expect(filters['limit'], '10');
      expect(filters.containsKey('status'), isFalse);
    }
    for (final filters in activeTimestampFilters) {
      expect(filters['select'], 'picked_up_at,accepted_at,created_at');
      expect(filters['rider_id'], anyOf('eq.R', 'eq.RB'));
      expect(filters['order_status'], 'in.("accepted","rider_arrived","picked_up","rider_at_drop","ongoing")');
      expect(filters.containsKey('limit'), isFalse);
      expect(filters.containsKey('order'), isFalse);
    }
    for (final filters in ordersFilters) {
      expect(filters['select'], recentFilters.first['select']);
      expect(filters['rider_id'], anyOf('eq.R', 'eq.RB'));
      expect(filters['order_status'], 'in.("completed","delivered")');
      expect(filters['order'], 'completed_at.desc.nullslast');
      expect(filters.containsKey('limit'), isFalse);
      expect(filters.containsKey('offset'), isFalse);
      final cutoff = DateTime.parse(filters['completed_at']!.substring(4));
      expect(cutoff.isUtc, isTrue);
      expect(DateTime.now().toUtc().difference(cutoff).inDays, 30);
    }
    for (final prefer in ordersPreferences) { expect(prefer, contains('count=exact')); }
    expect(tester.takeException(), isNull);
    RealtimeManager.instance.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
