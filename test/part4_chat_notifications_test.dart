import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/modules/chat/services/chat_message_delivery.dart';
import 'package:waydrop/modules/chat/services/chat_message_merge.dart';
import 'package:waydrop/modules/notifications/services/notification_badge_service.dart';

const _uid = '00000000-0000-4000-8000-000000000051';
http.Response _json(Object data, [int status = 200]) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json'},
);
Future<SupabaseClient> _client(
  Future<http.Response> Function(http.Request) handle,
) async {
  String enc(Object data) =>
      base64Url.encode(utf8.encode(jsonEncode(data))).replaceAll('=', '');
  final jwt =
      '${enc({'alg': 'HS256'})}.${enc({'sub': _uid, 'exp': DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000})}.test';
  final client = SupabaseClient(
    'https://example.test',
    'public-test-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((r) async {
      if (r.url.path.endsWith('/token')) {
        return _json({
          'access_token': jwt,
          'refresh_token': 'test',
          'token_type': 'bearer',
          'expires_in': 3600,
          'user': {
            'id': _uid,
            'aud': 'authenticated',
            'created_at': '2026-01-01T00:00:00Z',
          },
        });
      }
        final response = await handle(r);
        return http.Response(response.body, response.statusCode,
            headers: response.headers, request: r);
    }),
  );
  await client.auth.setSession('test');
  return client;
}

Map<String, dynamic> _message(String id, int second, {bool pending = false}) =>
    {
      'id': id,
      'sender_id': _uid,
      'message': 'synthetic',
      'created_at': DateTime.utc(2026, 11, 1, 0, 0, second).toIso8601String(),
      if (pending) 'is_offline': true,
    };

class _Channel extends RealtimeChannel {
  _Channel(String name) : super(name, RealtimeClient('wss://example.invalid'));
  void Function(RealtimeSubscribeStatus, Object?)? status;
  @override
  RealtimeChannel subscribe([
    void Function(RealtimeSubscribeStatus, Object?)? callback,
    Duration? timeout,
  ]) {
    status = callback;
    status?.call(RealtimeSubscribeStatus.subscribed, null);
    return this;
  }
}

class _RealtimeClient extends SupabaseClient {
  _RealtimeClient()
    : super(
        'https://example.invalid',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
  final created = <_Channel>[];
  @override
  RealtimeChannel channel(
    String name, {
    RealtimeChannelConfig opts = const RealtimeChannelConfig(),
  }) {
    final channel = _Channel(name);
    created.add(channel);
    return channel;
  }

  @override
  Future<String> removeChannel(RealtimeChannel channel) async => 'ok';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('delayed history preserves optimistic and newer realtime messages', () {
    final result = mergeChatMessages(
      [_message('temp_local', 3, pending: true), _message('socket', 2)],
      [_message('history', 1)],
    );
    expect(result.map((m) => m['id']), ['history', 'socket', 'temp_local']);
  });
  test(
    'confirmed UUID replaces outbox and cannot be downgraded by late outbox load',
    () {
      final pending = {
        ..._message('temp_stable', 1, pending: true),
        'client_message_id': 'stable',
      };
      final result = mergeChatMessages([pending], [_message('stable', 2)]);
      expect(result.single['id'], 'stable');
      expect(mergeChatMessages(result, [pending]).single['id'], 'stable');
      expect(result.single['is_offline'], isNot(true));
    },
  );
  test(
    'equal server timestamps use deterministic UUID order after reconnect',
    () {
      expect(
        mergeChatMessages(
          [_message('z', 1)],
          [_message('a', 1)],
        ).map((m) => m['id']),
        ['a', 'z'],
      );
    },
  );
  test(
    'partial legacy rows preserve insertion order without mutating input',
    () {
      final first = {'id': 'z'};
      expect(
        mergeChatMessages(
          [first],
          [
            {'id': 'a'},
          ],
        ).map((m) => m['id']),
        ['z', 'a'],
      );
      expect(first, {'id': 'z'});
    },
  );
  test(
    '23505 recovery refuses same UUID with a different message type',
    () async {
      final msg = ChatMessageDelivery.prepare({
        'id': 'temp_${ChatMessageDelivery.newMessageId()}',
        'sender_id': _uid,
        'sender_type': 'user',
        'order_id': 'order-a',
        'message': 'synthetic',
        'message_type': 'image',
      });
      final client = await _client(
        (r) async => r.method == 'POST'
            ? _json({'code': '23505', 'message': 'synthetic duplicate'}, 409)
            : _json({
                ...msg,
                'id': msg['client_message_id'],
                'message_type': 'text',
              }),
      );
      addTearDown(client.dispose);
      await expectLater(
        ChatMessageDelivery(client).send(msg),
        throwsA(isA<PostgrestException>()),
      );
    },
  );
  test(
    'failed count burst makes one HEAD and waits 8 then 16 seconds; success clears backoff',
    () async {
      var calls = 0;
      var now = DateTime.utc(2026, 11, 1);
      var fail = true;
      final client = await _client((r) async {
        expect(r.method, 'HEAD');
        expect(r.url.queryParameters['user_id'], 'eq.$_uid');
        expect(r.url.queryParameters['is_read'], 'eq.false');
        calls++;
        await Future<void>.delayed(Duration.zero);
        return fail
            ? _json({
                'code': 'PGRST003',
                'message': 'synthetic pool timeout',
              }, 504)
            : http.Response('', 200, headers: {'content-range': '0-0/3'});
      });
      addTearDown(client.dispose);
      final badge = NotificationBadgeService.forClient(client, now: () => now);
      addTearDown(badge.stopListening);
      await Future.wait(List.generate(20, (_) => badge.refresh()));
      expect(calls, 1);
      await badge.refresh();
      expect(calls, 1);
      now = now.add(const Duration(seconds: 8));
      await badge.refresh();
      expect(calls, 2);
      now = now.add(const Duration(seconds: 15));
      await badge.refresh();
      expect(calls, 2);
      now = now.add(const Duration(seconds: 1));
      fail = false;
      await badge.refresh();
      await badge.refresh();
      expect(calls, 4);
    },
  );
  test(
    'stop clears cooldown so a new owner can reconcile immediately',
    () async {
      var calls = 0;
      final client = await _client((r) async {
        calls++;
        return _json({
          'code': '57014',
          'message': 'synthetic statement timeout',
        }, 500);
      });
      addTearDown(client.dispose);
      final badge = NotificationBadgeService.forClient(client);
      await badge.refresh();
      badge.stopListening();
      await badge.refresh();
      expect(calls, 2);
      badge.stopListening();
    },
  );
  test(
    'rejoin notifies once per transition; disposed owner receives no catchup',
    () async {
      final client = _RealtimeClient();
      final manager = RealtimeManager.forClient(
        client,
        connectivityCheck: () async => false,
      );
      addTearDown(() async {
        manager.dispose();
        await client.dispose();
      });
      var joins = 0;
      final id = manager.subscribe(
        channelName: 'chat',
        table: 'order_chat_messages',
        owner: 'chat',
        callback: (_) {},
        onSubscribed: () => joins++,
      );
      expect(joins, 0);
      await Future<void>.delayed(Duration.zero);
      expect(joins, 1);
      final status = client.created.single.status!;
      status(RealtimeSubscribeStatus.subscribed, null);
      await Future<void>.delayed(Duration.zero);
      expect(joins, 1);
      status(RealtimeSubscribeStatus.channelError, null);
      status(RealtimeSubscribeStatus.subscribed, null);
      await Future<void>.delayed(Duration.zero);
      expect(joins, 2);
      status(RealtimeSubscribeStatus.channelError, null);
      status(RealtimeSubscribeStatus.subscribed, null);
      manager.unsubscribe('chat', id);
      await Future<void>.delayed(Duration.zero);
      expect(joins, 2);
      expect(client.created.length, 1);
    },
  );
  test(
    'pooled new owner catches up and unsubscribe cancels its pending join callback',
    () async {
      final client = _RealtimeClient();
      final manager = RealtimeManager.forClient(client);
      addTearDown(() async {
        manager.dispose();
        await client.dispose();
      });
      manager.subscribe(
        channelName: 'chat',
        table: 'order_chat_messages',
        owner: 'a',
        callback: (_) {},
      );
      var joins = 0;
      final id = manager.subscribe(
        channelName: 'chat',
        table: 'order_chat_messages',
        owner: 'b',
        callback: (_) {},
        onSubscribed: () => joins++,
      );
      manager.unsubscribe('chat', id);
      await Future<void>.delayed(Duration.zero);
      expect(joins, 0);
      expect(client.created.length, 1);
    },
  );
}
