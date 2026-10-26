import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/modules/notifications/screens/notifications_inbox_screen.dart';

class _Read {
  _Read(this.request);
  final http.Request request;
  final result = Completer<http.Response>();
  void complete(List<Map<String, dynamic>> rows, {bool fail = false}) => result.complete(
      http.Response(jsonEncode(fail ? {'code': 'TEST', 'message': 'synthetic'} : rows),
          fail ? 400 : 200, request: request, headers: {'content-type': 'application/json'}));
}

List<Map<String, dynamic>> _rows(String prefix, int from, int count) => List.generate(count, (i) => {
  'id': '$prefix-${from + i}', 'title': '$prefix-${from + i}', 'body': 'Synthetic notification',
  'is_read': false, 'payload': <String, dynamic>{}, 'notification_type': 'synthetic',
  'reference_id': null, 'created_at': DateTime.utc(2026, 10, 14).subtract(Duration(minutes: from + i)).toIso8601String(),
});

Future<void> _identity(String id) async {
  final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, Object> value) => base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  await Supabase.instance.client.auth.recoverSession(jsonEncode({
    'access_token': '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': id, 'exp': exp, 'role': 'authenticated'})}.synthetic',
    'refresh_token': 'synthetic', 'token_type': 'bearer', 'expires_in': 3600,
    'user': {'id': id, 'aud': 'authenticated', 'app_metadata': {}, 'user_metadata': {}, 'created_at': '2026-10-14T00:00:00Z'},
  }));
}

List<ListTile> _tiles(WidgetTester tester) {
  final finder = find.byType(ListView);
  final list = tester.widget<ListView>(finder);
  final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
  return [for (var i = 0; i < delegate.childCount!; i += 2)
    if (delegate.builder(tester.element(finder), i) case final ListTile tile) tile];
}
List<String> _titles(WidgetTester tester) => _tiles(tester).map((tile) => (tile.title as Text).data!).toList();

Future<List<_Read>> _setup(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const links = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
  for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
  final reads = <_Read>[];
  final client = MockClient((request) {
    final read = _Read(request); reads.add(read); return read.result.future;
  });
  await tester.runAsync(() async {
    await Supabase.initialize(url: 'http://127.0.0.1:1', anonKey: 'synthetic', httpClient: client,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    await _identity('A');
  });
  addTearDown(() async {
    for (final read in reads) { if (!read.result.isCompleted) read.complete([]); }
    await tester.runAsync(() => Supabase.instance.dispose());
    client.close();
    for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), null); }
  });
  await tester.pumpWidget(const MaterialApp(home: NotificationsInboxScreen()));
  await tester.pump();
  return reads;
}

Future<void> _scrollForMore(WidgetTester tester) async {
  final controller = tester.widget<ListView>(find.byType(ListView)).controller!;
  controller.jumpTo(controller.position.maxScrollExtent - 20);
  controller.jumpTo(controller.position.maxScrollExtent);
  await tester.pump();
}

void main() {
  testWidgets('page-one reset rejects old page-more; overlapping pagination, errors and disposal are safe', (tester) async {
    final reads = await _setup(tester);
    expect(reads, hasLength(1));
    reads[0].complete(_rows('old', 0, 30)); await tester.pump();
    await _scrollForMore(tester); expect(reads, hasLength(2));
    await _scrollForMore(tester); expect(reads, hasLength(2)); // One page-more GET.
    final reset = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await tester.pump(); expect(reads, hasLength(3));
    await _scrollForMore(tester); expect(reads, hasLength(3)); // No paging during reset.
    reads[2].complete(_rows('new', 0, 30)); await tester.pump(); await reset;
    reads[1].complete(_rows('old', 30, 30)); await tester.pump();
    expect(_titles(tester), List.generate(30, (i) => 'new-$i'));
    await _scrollForMore(tester); expect(reads, hasLength(4));
    await _scrollForMore(tester); expect(reads, hasLength(4));
    reads[3].complete(_rows('new', 30, 5)); await tester.pump();
    final titles = _titles(tester);
    expect(titles, List.generate(35, (i) => 'new-$i'));
    expect(titles.toSet(), hasLength(35));
    // Reset failure retains the same account's valid history and releases flags.
    final failure = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await tester.pump(); reads[4].complete([], fail: true); await tester.pump(); await failure;
    expect(_titles(tester), titles);
    final retry = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await tester.pump(); reads[5].complete(_rows('retry', 0, 30)); await tester.pump(); await retry;
    await _scrollForMore(tester); reads[6].complete([], fail: true); await tester.pump();
    await _scrollForMore(tester); expect(reads, hasLength(8));
    reads[7].complete([]); await tester.pump();
    expect(_titles(tester), List.generate(30, (i) => 'retry-$i'));
    final late = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await tester.pump(); expect(reads, hasLength(9));
    await tester.pumpWidget(const SizedBox());
    reads[8].complete(_rows('disposed', 0, 1)); await tester.pump(); await late;
    expect(tester.takeException(), isNull);
    for (final read in reads) {
      expect(read.request.method, 'GET');
      final query = read.request.url.queryParameters;
      expect(query['user_id'], 'eq.A');
      expect(query['select'], 'id,payload,notification_type,reference_id,is_read,created_at,title,body');
      expect(query['order'], 'created_at.desc.nullslast');
      expect(query['limit'], '30');
    }
    expect(reads[1].request.url.queryParameters['offset'], '30');
    expect(reads[2].request.url.queryParameters['offset'], '0');
    expect(reads[3].request.url.queryParameters['offset'], '30');
  });
  testWidgets('retained inbox automatically rebinds A to B to A, fencing old responses and stale taps', (tester) async {
    final reads = await _setup(tester);
    final state = tester.state(find.byType(NotificationsInboxScreen));
    await tester.runAsync(() => _identity('B')); await tester.pump();
    expect(reads, hasLength(2));
    reads[1].complete(_rows('B', 0, 1)); await tester.pump();
    expect(_titles(tester), ['B-0']);
    final staleTap = _tiles(tester).single.onTap!;
    await tester.runAsync(() => _identity('A')); await tester.pump();
    expect(reads, hasLength(3));
    staleTap(); await tester.pump(); expect(reads, hasLength(3)); // No obsolete mark-read write.
    reads[2].complete(_rows('A-new', 0, 1)); await tester.pump();
    reads[0].complete(_rows('A-old', 0, 1)); await tester.pump();
    expect(_titles(tester), ['A-new-0']);
    expect(identical(state, tester.state(find.byType(NotificationsInboxScreen))), isTrue);
    await tester.runAsync(() => _identity('B')); await tester.pump();
    reads[3].complete([], fail: true); await tester.pump();
    expect(find.text('No notifications yet.'), findsOneWidget);
    await tester.runAsync(() => _identity('A')); await tester.pump();
    expect(reads, hasLength(5));
    await tester.pumpWidget(const SizedBox());
    reads[4].complete(_rows('disposed', 0, 1)); await tester.pump();
    expect(tester.takeException(), isNull);
    expect(reads.map((r) => r.request.url.queryParameters['user_id']), ['eq.A', 'eq.B', 'eq.A', 'eq.B', 'eq.A']);
  });
}
