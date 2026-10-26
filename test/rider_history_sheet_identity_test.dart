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


Future<void> _flush(WidgetTester tester) async { await tester.pump(); await tester.pump(); }

void main() {
  for (final kind in ['order', 'plan']) {
    testWidgets('History $kind sheet retires on account replacement, A-B-A, logout, dismissal and disposal', (tester) async {
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
        for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), null); }
      });
      await tester.pumpWidget(const MaterialApp(home: RiderOrderHistoryScreen(riderId: 'RA')));
      await _flush(tester);
      final state = tester.state(find.byType(RiderOrderHistoryScreen));
      Future<void> finishLoad(String account) async {
        reads.last.complete({'id': 'R$account'}); await _flush(tester);
        reads.last.complete([{'id': '$kind-$account', 'order_type': 'ride', 'order_code': 'Synthetic $account',
          'pickup_address': 'Origin $account', 'destination_address': 'Destination $account',
          'completed_at': '2026-10-14T00:00:00Z', 'rider_earning': 10, 'final_fare': 10}]); await _flush(tester);
        reads.last.complete([{'rider_id': 'R$account', 'pickup_city': 'City $account', 'destination_city': 'Destination $account',
          'status': 'completed', 'travel_date': '2026-10-14T00:00:00Z'}]); await _flush(tester);
      }
      Future<void> openSheet(String account) async {
        if (kind == 'plan') {
          await tester.tap(find.text('Travel Plans')); await tester.pumpAndSettle();
          await tester.tap(find.textContaining('City $account').first);
        } else {
          await tester.tap(find.text('Completed Orders')); await tester.pumpAndSettle();
          await tester.tap(find.textContaining('#Synthetic $account'));
        }
        await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(BottomSheet), findsOneWidget);
      }
      await finishLoad('A');
      await openSheet('A');
      final delayedSheet = reads.last;
      final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
      navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Unrelated route'))));
      await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(() => _identity('B')); await _flush(tester);
      expect(find.textContaining(kind == 'order' ? 'Order #SYNTHETIC A' : 'City A', skipOffstage: false), findsNothing);
      await tester.pump(const Duration(milliseconds: 400)); // Finish the unrelated covering route's transition.
      await _flush(tester);
      expect(find.byType(BottomSheet, skipOffstage: false), findsNothing);
      expect(find.text('Unrelated route'), findsOneWidget);
      expect(tester.state(find.byType(RiderOrderHistoryScreen, skipOffstage: false)), same(state));
      expect((state as dynamic).orderHistory, isEmpty);
      expect((state as dynamic).travelPlansHistory, isEmpty);
      final delayedB = reads.last;
      await tester.runAsync(() => _identity('A')); await _flush(tester);
      delayedSheet.complete(kind == 'order' ? {'amount': 999, 'rate_percent': 9} : [{'order_code': 'OBSOLETE'}]);
      delayedB.complete({'id': 'RB'}); await _flush(tester);
      expect(find.text('OBSOLETE'), findsNothing);
      navigator.pop(); await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
      await finishLoad('A'); await openSheet('A');
      // Reopening uses the existing tax cache or a fresh matched-orders read.
      if (kind == 'plan') { reads.last.complete([]); await _flush(tester); }
      await tester.runAsync(() => Supabase.instance.client.auth.signOut(scope: SignOutScope.local)); await _flush(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect((state as dynamic).orderHistory, isEmpty);
      await tester.runAsync(() => _identity('B')); await _flush(tester);
      await finishLoad('B'); await openSheet('B');
      final dismissedRead = reads.last;
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pump(); // Dismissal started, but the old sheet can still paint.
      await tester.runAsync(() => _identity('A')); await _flush(tester);
      expect(find.textContaining(kind == 'order' ? 'Order #SYNTHETIC B' : 'City B', skipOffstage: false), findsNothing);
      final retiringA = reads.last;
      await tester.pump(const Duration(milliseconds: 350));
      if (!dismissedRead.result.isCompleted) dismissedRead.complete(kind == 'order' ? {'amount': 0, 'rate_percent': 0} : []);
      await _flush(tester); expect(find.byType(BottomSheet), findsNothing);
      await tester.runAsync(() => _identity('B')); await _flush(tester);
      retiringA.complete({'id': 'RA'}); await _flush(tester);
      await finishLoad('B');
      await openSheet('B');
      final disposedRead = reads.last;
      await tester.pumpWidget(const SizedBox());
      if (!disposedRead.result.isCompleted) disposedRead.complete(kind == 'order' ? {'amount': 0, 'rate_percent': 0} : []);
      await _flush(tester); expect(tester.takeException(), isNull);
    });
  }
}
