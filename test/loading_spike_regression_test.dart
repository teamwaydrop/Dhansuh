import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/modules/chat/services/chat_message_delivery.dart';
import 'package:waydrop/modules/notifications/services/notification_count_events.dart';
import 'package:waydrop/features/user/home/profile_refresh_window.dart';
import 'package:waydrop/core/services/diagnostics/performance_trace.dart';
import 'package:waydrop/core/services/diagnostics/api_metrics_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = '00000000-0000-4000-8000-000000000051';
  late SupabaseClient client;
  late ChatMessageDelivery delivery;
  late DateTime now;
  late Future<http.Response> Function(http.Request) handle;
  final posts = <Map<String, dynamic>>[];
  Map<String, dynamic> message() => ChatMessageDelivery.prepare({
    'id': 'temp_${ChatMessageDelivery.newMessageId()}',
    'sender_id': uid,
    'sender_type': 'user',
    'message': 'synthetic text',
    'order_id': '00000000-0000-4000-8000-000000000052',
    'is_offline': true,
  });
  http.Response response(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    posts.clear();
    now = DateTime.utc(2026, 11, 1);
    String enc(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final jwt =
        '${enc({'alg': 'HS256'})}.${enc({'sub': uid, 'exp': DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000})}.test';
    handle = (r) async => response(posts.last);
    client = SupabaseClient(
      'https://example.test',
      'public-test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        if (r.url.path.endsWith('/token')) {
          return response({
            'access_token': jwt,
            'refresh_token': 'test',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': uid,
              'aud': 'authenticated',
              'created_at': '2026-01-01T00:00:00Z',
            },
          });
        }
        if (r.method == 'POST') {
          posts.add(jsonDecode(r.body) as Map<String, dynamic>);
        }
        final result = await handle(r);
        return http.Response(
          result.body,
          result.statusCode,
          request: r,
          headers: result.headers,
        );
      }),
    );
    await client.auth.setSession('test');
    delivery = ChatMessageDelivery(client, now: () => now);
  });
  tearDown(() async => client.dispose());

  test(
    'slow outstanding POST holds account lane; no replacement at UI timeout',
    () async {
      final blocked = Completer<void>();
      handle = (r) async {
        await blocked.future;
        return response(jsonDecode(r.body));
      };
      final first = delivery.send(message());
      await Future<void>.delayed(Duration.zero);
      final second = delivery.send(message());
      now = now.add(const Duration(seconds: 50));
      await Future<void>.delayed(Duration.zero);
      expect(posts, hasLength(1));
      blocked.complete();
      await Future.wait([first, second]);
      expect(posts, hasLength(2));
    },
  );
  test(
    'unknown commit replays same UUID and recovers existing own row',
    () async {
      final msg = message();
      Map<String, dynamic>? committed;
      handle = (r) async {
        if (r.method == 'GET') {
          expect(r.url.queryParameters['sender_id'], 'eq.$uid');
          return response(committed);
        }
        if (committed == null) {
          committed = Map.of(posts.last);
          throw http.ClientException('synthetic lost response');
        }
        return response({'code': '23505', 'message': 'duplicate'}, 409);
      };
      await expectLater(
        delivery.send(msg),
        throwsA(isA<http.ClientException>()),
      );
      now = now.add(const Duration(seconds: 8));
      final row = await delivery.send(msg);
      expect(row['id'], msg['client_message_id']);
      expect(posts.map((p) => p['id']).toSet(), hasLength(1));
      expect(posts.first.containsKey('client_message_id'), isFalse);
      expect(posts.first.containsKey('is_offline'), isFalse);
    },
  );
  test(
    'timer replay joins the identical pending message instead of sending another POST',
    () async {
      final blocked = Completer<void>();
      handle = (r) async {
        await blocked.future;
        return response(jsonDecode(r.body));
      };
      final msg = message();
      final direct = delivery.send(msg);
      final replay = delivery.send(Map.of(msg));
      await Future<void>.delayed(Duration.zero);
      expect(posts, hasLength(1));
      await expectLater(
        delivery.send({...msg, 'message': 'changed'}),
        throwsArgumentError,
      );
      blocked.complete();
      await Future.wait([direct, replay]);
      expect(posts, hasLength(1));
    },
  );
  for (final code in ['57014', 'PGRST003', '503']) {
    test('$code backs off 8 then 16 seconds without new HTTP sends', () async {
      handle = (_) async => response({
        'code': code,
        'message': 'synthetic failure',
      }, code == '503' ? 503 : 500);
      final msg = message();
      await expectLater(delivery.send(msg), throwsA(isA<PostgrestException>()));
      await expectLater(delivery.send(msg), throwsA(isA<ChatRetryLater>()));
      expect(posts, hasLength(1));
      now = now.add(const Duration(seconds: 8));
      await expectLater(delivery.send(msg), throwsA(isA<PostgrestException>()));
      now = now.add(const Duration(seconds: 15));
      expect(delivery.canAttempt(uid), isFalse);
      now = now.add(const Duration(seconds: 1));
      handle = (_) async => response(posts.last);
      await delivery.send(msg);
      expect(delivery.canAttempt(uid), isTrue);
    });
  }
  test(
    'pool timeout drains a queued burst without issuing more HTTP writes',
    () async {
      final blocked = Completer<void>();
      handle = (_) async {
        await blocked.future;
        return response({'code': 'PGRST003', 'message': 'pool busy'}, 504);
      };
      final messages = List.generate(8, (_) => message());
      final outcomes = messages
          .map(
            (msg) => delivery
                .send(msg)
                .then<String>(
                  (_) => 'sent',
                  onError: (Object error) => error is ChatRetryLater
                      ? 'cooldown'
                      : error is PostgrestException
                      ? error.code!
                      : 'unexpected',
                ),
          )
          .toList();
      await Future<void>.delayed(Duration.zero);
      expect(posts, hasLength(1));
      blocked.complete();
      expect(await Future.wait(outcomes), [
        'PGRST003',
        ...List.filled(7, 'cooldown'),
      ]);
      expect(posts, hasLength(1));
      now = now.add(const Duration(seconds: 8));
      handle = (_) async => response(posts.last);
      await delivery.send(messages.first);
      expect(posts, hasLength(2));
      expect(posts[0]['id'], posts[1]['id']);
    },
  );

  test(
    'repeated database timeouts cap backoff and never retry on their own',
    () async {
      final msg = message();
      for (final seconds in [8, 16, 32, 64, 120, 120]) {
        final before = posts.length;
        handle = (_) async =>
            response({'code': '57014', 'message': 'statement timeout'}, 500);
        await expectLater(
          delivery.send(msg),
          throwsA(isA<PostgrestException>()),
        );
        now = now.add(Duration(seconds: seconds - 1));
        await expectLater(delivery.send(msg), throwsA(isA<ChatRetryLater>()));
        expect(posts, hasLength(before + 1));
        now = now.add(const Duration(seconds: 1));
        expect(delivery.canAttempt(uid), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(posts, hasLength(before + 1));
      }
      handle = (_) async => response(posts.last);
      await delivery.send(msg);
      expect(delivery.canAttempt(uid), isTrue);
      expect(posts.map((row) => row['id']).toSet(), {msg['client_message_id']});
    },
  );

  test(
    'authorization rejection is permanent and actor mismatch never writes',
    () async {
      handle = (_) async =>
          response({'code': '42501', 'message': 'denied'}, 403);
      try {
        await delivery.send(message());
        fail('expected denial');
      } catch (e) {
        expect(ChatMessageDelivery.retryable(e), isFalse);
      }
      await expectLater(
        delivery.send({...message(), 'sender_id': 'other'}),
        throwsA(isA<AuthException>()),
      );
      expect(posts, hasLength(1));
    },
  );
  test('duplicate row with different content is never acknowledged', () async {
    handle = (r) async => r.method == 'POST'
        ? response({'code': '23505', 'message': 'duplicate'}, 409)
        : response({...posts.last, 'message': 'different'});
    await expectLater(
      delivery.send(message()),
      throwsA(isA<PostgrestException>()),
    );
  });
  test(
    'acknowledgement preserves a message appended while a send was pending',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final first = message(), second = message();
      await ChatMessageDelivery.enqueue(prefs, 'queue', first);
      await ChatMessageDelivery.enqueue(prefs, 'queue', second);
      await ChatMessageDelivery.acknowledge(prefs, 'queue', first['id']);
      expect(prefs.getStringList('queue')!.map((s) => jsonDecode(s)['id']), [
        second['id'],
      ]);
    },
  );
  test(
    'legacy migration persists UUID across replay without losing later append',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final legacy = {'id': 'temp_123', 'sender_id': uid};
      await ChatMessageDelivery.enqueue(prefs, 'queue', legacy);
      final prepared = ChatMessageDelivery.prepare(legacy);
      await ChatMessageDelivery.replaceQueued(prefs, 'queue', prepared);
      final restored =
          jsonDecode(prefs.getStringList('queue')!.single)
              as Map<String, dynamic>;
      expect(
        ChatMessageDelivery.prepare(restored)['client_message_id'],
        prepared['client_message_id'],
      );
    },
  );
  test(
    'notification metadata updates skip counts; read transitions and unknowns refresh',
    () {
      final events = NotificationCountEvents();
      expect(
        events.needsRefresh('UPDATE', {'id': 'a', 'is_read': false}),
        isTrue,
      );
      for (var i = 0; i < 20; i++) {
        expect(
          events.needsRefresh('UPDATE', {
            'id': 'a',
            'is_read': false,
            'delivery_status': '$i',
          }),
          isFalse,
        );
      }
      expect(
        events.needsRefresh('UPDATE', {'id': 'a', 'is_read': true}),
        isTrue,
      );
      expect(events.needsRefresh('UPDATE', {'id': 'unknown'}), isTrue);
      expect(events.needsRefresh('DELETE', {'id': 'a'}), isTrue);
      events.clear();
      expect(
        events.needsRefresh('UPDATE', {'id': 'a', 'is_read': true}),
        isTrue,
      );
    },
  );
  test(
    'Home profile reuse expires, is account scoped and never applies to full refresh',
    () {
      final window = ProfileRefreshWindow();
      expect(window.reuseFor(uid, ordersOnly: true, now: now), isFalse);
      window.recordSuccess(uid, now);
      expect(window.reuseFor(uid, ordersOnly: true, now: now), isTrue);
      expect(window.reuseFor(uid, ordersOnly: false, now: now), isFalse);
      expect(window.reuseFor('other', ordersOnly: true, now: now), isFalse);
      expect(
        window.reuseFor(
          uid,
          ordersOnly: true,
          now: now.add(const Duration(seconds: 30)),
        ),
        isFalse,
      );
      expect(
        window.reuseFor(
          uid,
          ordersOnly: true,
          now: now.subtract(const Duration(seconds: 1)),
        ),
        isFalse,
      );
    },
  );
  test(
    'timing records screen, headers and completed body without private query data',
    () async {
      PerformanceTrace.samples.clear();
      final metrics = ApiMetricsClient(
        MockClient((r) async => http.Response('synthetic', 200, request: r)),
      );
      final result = await PerformanceTrace.measure(
        'chat',
        () => metrics.get(
          Uri.parse('https://example.test/rest/v1/orders?user_id=private'),
          headers: {'Authorization': 'Bearer secret'},
        ),
      );
      expect(result.body, 'synthetic');
      expect(
        PerformanceTrace.samples.map((e) => e['kind']),
        containsAll(['api_headers', 'api_complete', 'screen_work']),
      );
      expect(
        PerformanceTrace.samples
            .where((e) => e['kind'] == 'api_headers')
            .single['screen'],
        'chat',
      );
      expect(PerformanceTrace.samples.toString(), isNot(contains('secret')));
      expect(PerformanceTrace.samples.toString(), isNot(contains('private')));
      metrics.close();
    },
  );
}
