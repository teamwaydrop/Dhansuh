import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/vehicles/screens/my_vehicles_screen.dart';

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


Future<void> _flush(WidgetTester tester) async { await tester.pump(); await tester.pump(); }

void main() {
  testWidgets('Vehicles verifies seed ownership and fences retained A-B-A, navigation, failures, logout and disposal', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const links = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
    for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
    final reads = <_Read>[];
    final client = MockClient((request) {
      if (request.url.path.startsWith('/auth/')) return Future.value(http.Response('{}', 200));
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
      for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
    });
    const seed = {'vehicle_type': 'bike', 'vehicle_number': 'Synthetic seed A'};
    await tester.pumpWidget(const MaterialApp(home: MyVehiclesScreen(
      riderId: 'RA', accountId: 'A', kycId: 'KA', kyc: seed)));
    await _flush(tester);
    final state = tester.state(find.byType(MyVehiclesScreen));
    expect(reads[0].request.url.queryParameters, {'select': 'id,kyc_id', 'user_id': 'eq.A', 'id': 'eq.RA'});
    reads[0].complete({'id': 'RA', 'kyc_id': 'KA'}); await _flush(tester);
    expect(reads[1].request.url.queryParameters, {'select': 'vehicle_type,vehicle_number,status,rejection_reason',
      'rider_id': 'eq.RA', 'order': 'created_at.desc.nullslast'});
    expect(reads.where((r) => r.request.url.path.endsWith('/rider_kyc')), isEmpty); // Scoped seed retained.
    await tester.runAsync(() => _identity('B')); await _flush(tester);
    expect(tester.state(find.byType(MyVehiclesScreen)), same(state));
    expect(find.text('Synthetic seed A'), findsNothing);
    expect(reads[2].request.url.queryParameters, {'select': 'id,kyc_id', 'user_id': 'eq.B'});
    reads[2].complete({'id': 'RB', 'kyc_id': 'KB'}); await _flush(tester);
    expect(reads[3].request.url.queryParameters, {'select': 'full_name,vehicle_number,vehicle_type,rider_image', 'id': 'eq.KB'});
    await tester.runAsync(() => _identity('A')); await _flush(tester);
    reads[4].complete({'id': 'RA', 'kyc_id': 'KA'}); await _flush(tester);
    reads[3].complete({'vehicle_type': 'cab', 'vehicle_number': 'Obsolete B'});
    reads[1].complete([{'vehicle_type': 'cab', 'vehicle_number': 'Obsolete first A'}]); await _flush(tester);
    expect(reads, hasLength(6));
    expect(find.text('Obsolete B'), findsNothing); expect(find.text('Obsolete first A'), findsNothing);
    reads[5].complete({'vehicle_type': 'bike', 'vehicle_number': 'Fresh A'}); await _flush(tester);
    reads[6].complete([]); await _flush(tester);
    expect(find.text('Fresh A'), findsOneWidget); expect(find.text('Synthetic seed A'), findsNothing);
    // Same-account refresh must not reread or reinterpret the KYC seed.
    final refresh = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await _flush(tester); reads[7].complete([], fail: true); await _flush(tester); await refresh;
    expect(find.text('Fresh A'), findsOneWidget);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    await tester.tap(find.text('Add Vehicle'));
    await tester.runAsync(() => _identity('B')); navigator.pop(true); await _flush(tester);
    await tester.pump(const Duration(milliseconds: 350));
    expect(reads, hasLength(9)); // B ownership lookup only; A navigation callback retired.
    reads[8].complete({'id': 'RB', 'kyc_id': 'KB'}); await _flush(tester);
    reads[9].complete({}, fail: true); await _flush(tester);
    expect(find.text('Fresh A'), findsNothing);
    final retry = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await _flush(tester); reads[10].complete({'id': 'RB', 'kyc_id': 'KB'}); await _flush(tester);
    reads[11].complete({'vehicle_type': 'cab', 'vehicle_number': 'Fresh B'}); await _flush(tester);
    reads[12].complete([]); await _flush(tester); await retry;
    expect(find.text('Fresh B'), findsOneWidget);
    await tester.runAsync(() => Supabase.instance.client.auth.signOut(scope: SignOutScope.local)); await _flush(tester);
    expect(find.text('Fresh B'), findsNothing);
    expect(tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Add Vehicle')).onPressed, isNull);
    await tester.runAsync(() => _identity('A')); await _flush(tester);
    reads[13].complete({'id': 'RA', 'kyc_id': 'KA'}); await _flush(tester);
    await tester.pumpWidget(const SizedBox()); reads[14].complete({'vehicle_type': 'bike'}); await _flush(tester);
    expect(reads, hasLength(15)); // No vehicle follow-up after disposed KYC read.
    expect(tester.takeException(), isNull);
  });
  testWidgets('Vehicles replaces rider and KYC scope; legacy seed mismatch and older refresh cannot publish', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const links = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
    for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
    final reads = <_Read>[];
    final client = MockClient((request) {
      if (request.url.path.startsWith('/auth/')) return Future.value(http.Response('{}', 200));
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
      for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
    });
    await tester.pumpWidget(const MaterialApp(home: MyVehiclesScreen(
      riderId: 'RA', accountId: 'A', kycId: 'wrong', kyc: {'vehicle_number': 'Wrong seed', 'vehicle_type': 'bike'})));
    await _flush(tester);
    final state = tester.state(find.byType(MyVehiclesScreen));
    reads[0].complete({'id': 'RA', 'kyc_id': 'KA'}); await _flush(tester);
    expect(reads[1].request.url.queryParameters['id'], 'eq.KA');
    await tester.pumpWidget(const MaterialApp(home: MyVehiclesScreen(
      riderId: 'RA2', accountId: 'A', kycId: 'KA2',
      kyc: {'vehicle_number': 'Scoped replacement', 'vehicle_type': 'cab'})));
    await _flush(tester);
    expect(tester.state(find.byType(MyVehiclesScreen)), same(state));
    expect(reads[2].request.url.queryParameters['id'], 'eq.RA2');
    reads[1].complete({'vehicle_number': 'Obsolete KYC', 'vehicle_type': 'bike'}); await _flush(tester);
    expect(reads, hasLength(3));
    reads[2].complete({'id': 'RA2', 'kyc_id': 'KA2'}); await _flush(tester);
    expect(reads[3].request.url.queryParameters['rider_id'], 'eq.RA2');
    reads[3].complete([]); await _flush(tester);
    expect(find.text('Scoped replacement'), findsOneWidget);
    expect(find.text('Wrong seed'), findsNothing); expect(find.text('Obsolete KYC'), findsNothing);
    final callback = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh;
    final older = callback(); final newer = callback(); await _flush(tester);
    reads[5].complete([{'vehicle_number': 'Newest extra', 'vehicle_type': 'bike', 'status': 'approved'}]);
    await _flush(tester); await newer;
    reads[4].complete([{'vehicle_number': 'Old extra', 'vehicle_type': 'bike', 'status': 'approved'}]);
    await _flush(tester); await older;
    expect(find.text('Newest extra'), findsOneWidget); expect(find.text('Old extra'), findsNothing);
    expect(find.text('Scoped replacement'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); expect(tester.takeException(), isNull);
  });
}
