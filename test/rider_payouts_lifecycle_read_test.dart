import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:waydrop/features/rider/payouts/rider_payouts_screen.dart';

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
  test('uncoalesced SDK control issues six identical withdrawal GETs', () async {
    var gets = 0;
    final httpClient = MockClient((request) async {
      gets++;
      expect(request.url.queryParameters['rider_id'], 'eq.RA');
      return http.Response('[]', 200, request: request, headers: {'content-type': 'application/json'});
    });
    final client = PostgrestClient('http://127.0.0.1:1/rest/v1', httpClient: httpClient);
    await Future.wait(List.generate(6, (_) async => await client.from('rider_withdrawals')
        .select('amount, status, created_at, cashfree_response, transfer_id, cashfree_reference_id')
        .eq('rider_id', 'RA').order('created_at', ascending: false).limit(50)));
    expect(gets, 6);
    httpClient.close();
  });
  testWidgets('Payouts scopes retained identity and coalesces only equivalent withdrawal GETs', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const links = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
    for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
    final reads = <_Read>[];
    final bindings = <_Binding>[];
    var syncs = 0;
    final sync = Completer<http.Response>();
    final client = MockClient((request) {
      if (request.url.path.startsWith('/auth/')) return Future.value(http.Response('{}', 200));
      if (request.url.path.startsWith('/functions/')) {
        syncs++;
        return syncs == 1 ? sync.future : Future.value(http.Response('{}', 200));
      }
      final read = _Read(request); reads.add(read); return read.result.future;
    });
    await tester.runAsync(() async {
      await Supabase.initialize(url: 'http://127.0.0.1:1', anonKey: 'synthetic', httpClient: client,
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
      await _identity('A');
    });
    addTearDown(() async {
      if (!sync.isCompleted) sync.complete(http.Response('{}', 200));
      for (final read in reads) { if (!read.result.isCompleted) read.complete([]); }
      await tester.runAsync(() => Supabase.instance.dispose()); client.close();
      for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), null); }
    });
    Future<void> render(String rider) async {
      await tester.pumpWidget(ProviderScope(overrides: [
        payoutsWithdrawalsBindingProvider.overrideWithValue((account, callback) {
          final binding = _Binding(account, callback); bindings.add(binding);
          return () { binding.retired++; };
        }),
      ], child: MaterialApp(home: RiderPayoutsScreen(key: const ValueKey('retained'), riderId: rider))));
      await _flush(tester);
    }
    List<_Read> withdrawals() => reads.where((r) => r.request.url.path.endsWith('/rider_withdrawals')).toList();
    await render('RA');
    expect(reads[0].request.url.queryParameters, {'select': 'id', 'user_id': 'eq.A', 'id': 'eq.RA'});
    reads[0].complete({'id': 'RA'}); await _flush(tester);
    final state = tester.state(find.byType(RiderPayoutsScreen)) as dynamic;
    expect(syncs, 1);
    bindings.single.callback(); await _flush(tester); // RT read while initial sync is pending.
    sync.complete(http.Response('{}', 200)); await _flush(tester); // Startup queues fresh read.
    for (var i = 0; i < 4; i++) { bindings.single.callback(); }
    await _flush(tester);
    expect(withdrawals(), hasLength(1)); // Six independent triggers previously made six GETs.
    withdrawals()[0].complete([], fail: true); await _flush(tester);
    expect(withdrawals(), hasLength(2));
    withdrawals()[1].complete([{'amount': 11, 'status': 'success', 'created_at': '2026-10-14T00:00:00Z'}]);
    await _flush(tester);
    expect(state.payoutTransactions.single['amount'], 11);
    expect(state.loading, isFalse);
    expect(syncs, 1); // Coalescing never repeats the withdrawal synchronization operation.
    final q = withdrawals()[1].request.url.queryParameters;
    expect(q, {'select': 'amount,status,created_at,cashfree_response,transfer_id,cashfree_reference_id',
      'rider_id': 'eq.RA', 'order': 'created_at.desc.nullslast', 'limit': '50'});

    bindings[0].callback(); await _flush(tester);
    final nearCompletion = withdrawals().last;
    nearCompletion.complete([{'amount': 777}]);
    bindings[0].callback(); // Invalidate before the HTTP future completion drains.
    await _flush(tester);
    expect(state.payoutTransactions.single['amount'], 11);
    expect(withdrawals(), hasLength(4));
    withdrawals().last.complete([]); await _flush(tester);
    expect(state.payoutTransactions, isEmpty);
    bindings[0].callback(); await _flush(tester);
    final obsolete = withdrawals().last;
    await tester.runAsync(() => _identity('B')); await _flush(tester);
    expect(state.payoutTransactions, isEmpty); expect(bindings[0].retired, 1);
    expect(state.loading, isTrue);
    final bLookup = reads.last;
    expect(bLookup.request.url.queryParameters, {'select': 'id', 'user_id': 'eq.B'});
    await tester.runAsync(() => _identity('A')); await _flush(tester);
    final aLookup = reads.last;
    bLookup.complete({'id': 'RB'}); obsolete.complete([{'amount': 999}]); await _flush(tester);
    expect(bindings, hasLength(1)); expect(state.payoutTransactions, isEmpty);
    aLookup.complete({'id': 'RA'}); await _flush(tester);
    expect(bindings.map((b) => b.account), ['A', 'A']);
    final newA = withdrawals().last;
    bindings[0].callback(); await _flush(tester);
    expect(withdrawals().last, same(newA)); // Retired callback cannot enqueue anything.
    newA.complete([]); await _flush(tester);
    expect(state.payoutTransactions, isEmpty);

    final beforeTokenRefresh = reads.length;
    await tester.runAsync(() => _identity('A')); await _flush(tester);
    expect(reads, hasLength(beforeTokenRefresh)); // Same-account auth events do not rebind.
    // An unowned replacement cannot attach a listener or run the synchronization call.
    final syncsBeforeMissing = syncs;
    await render('not-owned');
    reads.last.complete(null); await _flush(tester);
    expect(bindings, hasLength(2)); expect(syncs, syncsBeforeMissing);
    expect(state.payoutTransactions, isEmpty); expect(state.loading, isFalse);
    // Same State, explicit rider replacement: verify ownership before attaching anything.
    await render('RA2');
    expect(tester.state(find.byType(RiderPayoutsScreen)), same(state));
    expect(bindings[1].retired, 1);
    expect(reads.last.request.url.queryParameters['id'], 'eq.RA2');
    reads.last.complete({'id': 'RA2'}); await _flush(tester);
    expect(withdrawals().last.request.url.queryParameters['rider_id'], 'eq.RA2');
    final pending = withdrawals().last;
    bindings[2].callback(); await _flush(tester);
    final beforeDispose = withdrawals().length;
    await tester.pumpWidget(const SizedBox());
    pending.complete([]); bindings[2].callback(); await _flush(tester);
    expect(withdrawals(), hasLength(beforeDispose)); // No queued read after disposal.
    expect(bindings.map((b) => b.retired), everyElement(1));
    expect(tester.takeException(), isNull);
  });
}
