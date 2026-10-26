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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/features/intercity/parcels/dashboard/intercity_parcels_screen.dart';

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


class _Binding {
  _Binding(this.account, this.callback);
  final String account;
  final VoidCallback callback;
  int retired = 0;
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('retained A-B-A rejects delayed Orders/KYC and retired callbacks; logout/disposal retire once', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const links = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
    for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
    final reads = <_Read>[];
    final bindings = <_Binding>[];
    final client = MockClient((request) {
      if (request.url.path.startsWith('/auth/')) return Future.value(http.Response('{}', 200));
      final read = _Read(request); reads.add(read); return read.result.future;
    });
    late HttpServer server;
    final sockets = <WebSocket>[];
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = 404; await request.response.close(); return;
        }
        final socket = await WebSocketTransformer.upgrade(request); sockets.add(socket);
        socket.listen((message) {
          final frame = jsonDecode(message as String) as Map;
          socket.add(jsonEncode({'topic': frame['topic'], 'event': 'phx_reply', 'ref': frame['ref'],
            'payload': {'status': 'ok', 'response': {'postgres_changes': []}}}));
        });
      });
      await Supabase.initialize(url: 'http://127.0.0.1:${server.port}', anonKey: 'synthetic', httpClient: client,
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
      await _identity('A');
    });
    addTearDown(() async {
      for (final read in reads) { if (!read.result.isCompleted) read.complete([]); }
      RealtimeManager.instance.dispose();
      await tester.runAsync(() async {
        await Supabase.instance.dispose();
        for (final socket in sockets) { await socket.close(); }
        await server.close(force: true);
      });
      client.close();
      for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), null); }
    });
    final container = ProviderContainer();
    final bind = container.read(intercityParcelsOrdersBindingProvider);
    container.dispose();
    await tester.pumpWidget(ProviderScope(overrides: [
      intercityParcelsOrdersBindingProvider.overrideWithValue((account, callback) {
        final binding = _Binding(account, callback); bindings.add(binding);
        final retire = bind(account, callback);
        return () { binding.retired++; retire(); };
      }),
    ], child: const MaterialApp(home: IntercityParcelsScreen())));
    await _flush(tester);
    final state = tester.state(find.byType(IntercityParcelsScreen));
    expect(reads, hasLength(1));
    final query = reads[0].request.url.queryParameters;
    expect(query['user_id'], 'eq.A');
    expect(query['order_type'], 'eq.intercity_parcel');
    expect(query['order'], 'created_at.desc.nullslast');
    expect(query['select'], 'id,order_status,order_type,pickup_city,pickup_address,destination_city,destination_address,final_fare,current_fare,actual_fare,parcel_type,weight_category,travel_date,receiver_name,created_at');

    expect(RealtimeManager.instance.activeChannelCount, 1);
    expect(bindings.map((b) => b.account), ['A']);
    reads[0].complete([]); await _flush(tester); // A is now suspended on KYC.
    expect(reads[1].request.url.path, endsWith('/rider_kyc'));
    bindings[0].callback(); // Pending debounce must be retired on replacement.
    await tester.runAsync(() => _identity('B')); await _flush(tester);
    expect(tester.state(find.byType(IntercityParcelsScreen)), same(state));
    expect(bindings[0].retired, 1);
    expect(bindings.map((b) => b.account), ['A', 'B']);
    expect(RealtimeManager.instance.getDebugMetrics().keys, ['intercity-parcels-orders-B']);
    expect(RealtimeManager.instance.activeChannelCount, 1);
    expect(reads, hasLength(3));
    bindings[0].callback(); await tester.pump(const Duration(milliseconds: 501));
    expect(reads, hasLength(3)); // Old callback cannot start B's read.
    await tester.runAsync(() => _identity('A')); await _flush(tester);
    expect(reads, hasLength(4)); expect(bindings[1].retired, 1);
    expect(bindings.map((b) => b.account), ['A', 'B', 'A']);
    expect(RealtimeManager.instance.getDebugMetrics().keys, ['intercity-parcels-orders-A']);
    expect(RealtimeManager.instance.activeChannelCount, 1);
    reads[2].complete([{'id': 'obsoleteB', 'order_status': 'completed'}]); await _flush(tester);
    expect(reads, hasLength(4)); // No obsolete KYC follow-up.
    reads[1].complete({'kyc_status': 'rejected'}); await _flush(tester);
    expect(find.text('Become a Delivery Partner'), findsNothing);
    reads[3].complete([]); await _flush(tester);
    expect(reads, hasLength(5));
    reads[4].complete({'kyc_status': 'rejected'}); await _flush(tester);
    expect(find.text('Become a Delivery Partner'), findsOneWidget);
    // Capture the real navigation-return continuation without building the child route.
    // The tap pushes synchronously; account replacement and pop precede its first frame.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    await tester.tap(find.text('Create Shipment'));
    await tester.runAsync(() => _identity('B'));
    navigator.pop();
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 350));
    expect(reads, hasLength(6)); // B's binding only; no old navigation-return batch.
    reads[5].complete([{'id': 'currentB', 'order_status': 'completed',
      'pickup_city': 'Synthetic origin', 'destination_city': 'Synthetic destination',
      'created_at': '2026-10-14T00:00:00Z', 'final_fare': 10}]); await _flush(tester);
    reads[6].complete({'kyc_status': 'approved'}); await _flush(tester);
    expect(find.text('Become a Delivery Partner'), findsNothing);
    expect((state as dynamic).historyOrders.single['id'], 'currentB');

    // A current callback starts a normal fresh batch; logout invalidates its Orders response.
    bindings[3].callback(); await tester.pump(const Duration(milliseconds: 501));
    expect(reads, hasLength(8));
    await tester.runAsync(() => Supabase.instance.client.auth.signOut(scope: SignOutScope.local));
    await _flush(tester); expect(bindings[3].retired, 1);
    expect(RealtimeManager.instance.activeChannelCount, 0);
    expect((state as dynamic).historyOrders, isEmpty);
    expect((state as dynamic).activeOrders, isEmpty);
    reads[7].complete([]); await _flush(tester); expect(reads, hasLength(8));
    await tester.runAsync(() => _identity('B')); await _flush(tester);
    expect(bindings, hasLength(5)); expect(reads, hasLength(9));
    reads[8].complete([], fail: true); await _flush(tester);
    expect((state as dynamic).loading, isFalse);
    expect((state as dynamic).historyOrders, isEmpty);
    bindings[4].callback(); await tester.pump(const Duration(milliseconds: 501));
    reads[9].complete([]); await _flush(tester);
    expect(reads[10].request.url.path, endsWith('/rider_kyc'));
    reads[10].complete({}, fail: true); await _flush(tester);
    expect((state as dynamic).loading, isFalse);
    expect((state as dynamic).historyOrders, isEmpty);
    bindings[4].callback(); await tester.pump(const Duration(milliseconds: 501));
    expect(reads, hasLength(12)); // Recovery after both Orders and KYC errors.
    await tester.pumpWidget(const SizedBox());
    expect(bindings.map((b) => b.retired), everyElement(1));
    expect(RealtimeManager.instance.activeChannelCount, 0);
    bindings[4].callback(); reads[11].complete([]); await _flush(tester);
    await tester.pump(const Duration(milliseconds: 501));
    expect(reads, hasLength(12)); expect(tester.takeException(), isNull);
    // The app-wide manager owns its heartbeat, not the dashboard.
    RealtimeManager.instance.dispose();
  });
  testWidgets('Orders overlap uses one trailing GET; KYC stays independent; failure, navigation and disposal', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const links = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
    for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
    final reads = <_Read>[];
    final bindings = <_Binding>[];
    final client = MockClient((request) {
      if (request.url.path.startsWith('/auth/')) return Future.value(http.Response('{}', 200));
      final read = _Read(request); reads.add(read); return read.result.future;
    });
    late HttpServer server;
    final sockets = <WebSocket>[];
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = 404; await request.response.close(); return;
        }
        final socket = await WebSocketTransformer.upgrade(request); sockets.add(socket);
        socket.listen((message) {
          final frame = jsonDecode(message as String) as Map;
          socket.add(jsonEncode({'topic': frame['topic'], 'event': 'phx_reply', 'ref': frame['ref'],
            'payload': {'status': 'ok', 'response': {'postgres_changes': []}}}));
        });
      });
      await Supabase.initialize(url: 'http://127.0.0.1:${server.port}', anonKey: 'synthetic', httpClient: client,
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
      await _identity('A');
    });
    addTearDown(() async {
      for (final read in reads) { if (!read.result.isCompleted) read.complete([]); }
      RealtimeManager.instance.dispose();
      await tester.runAsync(() async {
        await Supabase.instance.dispose();
        for (final socket in sockets) { await socket.close(); }
        await server.close(force: true);
      });
      client.close();
      for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), null); }
    });
    final container = ProviderContainer();
    final bind = container.read(intercityParcelsOrdersBindingProvider);
    container.dispose();
    await tester.pumpWidget(ProviderScope(overrides: [
      intercityParcelsOrdersBindingProvider.overrideWithValue((account, callback) {
        final binding = _Binding(account, callback); bindings.add(binding);
        final retire = bind(account, callback);
        return () { binding.retired++; retire(); };
      }),
    ], child: const MaterialApp(home: IntercityParcelsScreen())));
    await _flush(tester);
    List<_Read> orders() => reads.where((r) => r.request.url.path.endsWith('/orders')).toList();
    List<_Read> kyc() => reads.where((r) => r.request.url.path.endsWith('/rider_kyc')).toList();
    final state = tester.state(find.byType(IntercityParcelsScreen)) as dynamic;
    for (var i = 0; i < 3; i++) {
      bindings.single.callback(); await tester.pump(const Duration(milliseconds: 501));
    }
    expect(orders(), hasLength(1)); // Previously four independent Orders GETs.
    orders()[0].complete([], fail: true); await _flush(tester);
    expect(orders(), hasLength(2)); // Failure does not lose the fresh trailing attempt.
    orders()[1].complete([]); await _flush(tester);
    expect(kyc(), hasLength(3)); // Each of the three fresh callers still reads KYC.
    kyc()[2].complete({'kyc_status': 'approved'}); await _flush(tester);
    kyc()[0].complete({'kyc_status': 'rejected'});
    kyc()[1].complete({'kyc_status': 'rejected'}); await _flush(tester);
    expect(state.kycCompleted, isTrue); // Older KYC completions cannot replace this batch.
    final query = orders()[1].request.url.queryParameters;
    expect(query['select'], 'id,order_status,order_type,pickup_city,pickup_address,destination_city,destination_address,final_fare,current_fare,actual_fare,parcel_type,weight_category,travel_date,receiver_name,created_at');
    expect(query['user_id'], 'eq.A');
    expect(query['order_type'], 'eq.intercity_parcel');
    expect(query.containsKey('or'), isFalse);
    expect(query['order'], 'created_at.desc.nullslast');
    expect(query.containsKey('limit'), isFalse);

    bindings.single.callback(); await tester.pump(const Duration(milliseconds: 501));
    expect(orders(), hasLength(3));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    await tester.tap(find.text('Create Shipment')); navigator.pop(); await _flush(tester);
    bindings.single.callback(); await tester.pump(const Duration(milliseconds: 501));
    expect(orders(), hasLength(3)); // Navigation return + Realtime queue the same trailing GET.
    orders()[2].complete([{'id': 'stale', 'order_status': 'completed'}]);
    await _flush(tester);
    expect(orders(), hasLength(4)); expect(kyc(), hasLength(4));
    kyc()[3].complete({'kyc_status': 'rejected'}); await _flush(tester);
    expect(state.historyOrders, isEmpty); // Invalidated Orders never publish with their KYC.
    orders()[3].complete([]); await _flush(tester);
    expect(kyc(), hasLength(6)); // Both trailing callers get independent KYC.
    kyc()[5].complete({'kyc_status': 'approved'}); await _flush(tester);
    kyc()[4].complete({'kyc_status': 'rejected'}); await _flush(tester);
    expect(state.kycCompleted, isTrue);

    bindings.single.callback(); await tester.pump(const Duration(milliseconds: 501));
    expect(orders(), hasLength(5));
    // Resolve and invalidate before the completion microtask drains: no lost wake-up.
    orders()[4].complete([]);
    await tester.tap(find.text('Create Shipment')); navigator.pop(); await _flush(tester);
    expect(orders(), hasLength(6));
    bindings.single.callback(); await tester.pump(const Duration(milliseconds: 501));
    expect(orders(), hasLength(6)); // A queued trailing attempt must not start after disposal.
    await tester.pumpWidget(const SizedBox());
    orders()[5].complete([]); await _flush(tester);
    expect(orders(), hasLength(6));
    expect(kyc(), hasLength(7)); // Only the pre-disposal current read reached KYC.
    expect(bindings.single.retired, 1);
    expect(tester.takeException(), isNull);
    RealtimeManager.instance.dispose();
  });
}
