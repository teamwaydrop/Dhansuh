import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/modules/chat/screens/order_chat_screen.dart';
import 'package:waydrop/modules/chat/services/chat_message_delivery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = '00000000-0000-4000-8000-000000000071';
  const queueKey = 'offline_chat_messages_support_$uid';
  final posts = <http.Request>[];
  Completer<http.Response>? history;
  Completer<http.Response>? firstPost;
  String enc(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final jwt =
      '${enc({'alg': 'HS256'})}.${enc({'sub': uid, 'exp': DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000})}.test';
  http.Response json(Object value, http.Request r) => http.Response(
    jsonEncode(value),
    200,
    request: r,
    headers: {'content-type': 'application/json'},
  );
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'test-public-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        if (r.url.path.endsWith('/token'))
          return json({
            'access_token': jwt,
            'refresh_token': 'test',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': uid,
              'aud': 'authenticated',
              'created_at': '2026-01-01T00:00:00Z',
            },
          }, r);
        if (r.url.path.endsWith('/users'))
          return json({'role': 'user', 'preferred_mode': 'user'}, r);
        if (r.url.path.endsWith('/order_chat_messages') && r.method == 'GET')
          return history!.future;
        if (r.url.path.endsWith('/order_chat_messages') && r.method == 'POST') {
          posts.add(r);
          if (posts.length == 1) return firstPost!.future;
          return json(jsonDecode(r.body), r);
        }
        return json({}, r);
      }),
    );
    await Supabase.instance.client.auth.setSession('test');
  });
  tearDownAll(() async => Supabase.instance.dispose());
  for (final action in ['dispose', 'pause']) {
    testWidgets(
      'outbox stops starting POSTs after $action; retains the unsent message',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        posts.clear();
        history = Completer();
        firstPost = Completer();
        final prefs = await SharedPreferences.getInstance();
        final messages = List.generate(
          2,
          (i) => ChatMessageDelivery.prepare({
            'id': 'temp_${ChatMessageDelivery.newMessageId()}',
            'sender_id': uid,
            'sender_type': 'user',
            'message': 'synthetic $i',
            'user_id': uid,
            'is_support': true,
            'created_at': DateTime.utc(2026, 11, 1, 0, 0, i).toIso8601String(),
            'is_offline': true,
          }),
        );
        await prefs.setStringList(queueKey, messages.map(jsonEncode).toList());
        await tester.pumpWidget(
          const MaterialApp(
            home: OrderChatScreen(
              orderId: '',
              chatTitle: 'Synthetic support',
              isSupport: true,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 8));
        await tester.pump();
        expect(posts.length, 1);
        if (action == 'dispose') {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        }
        firstPost!.complete(json(jsonDecode(posts.single.body), posts.single));
        await tester.pump();
        await tester.pump();
        expect(posts.length, 1);
        final remaining = prefs
            .getStringList(queueKey)!
            .map((s) => jsonDecode(s) as Map)
            .toList();
        expect(
          remaining.single['client_message_id'],
          messages[1]['client_message_id'],
        );
        // Paused bindings do not schedule a disposal frame. Resume before
        // removing the screen, while the history response is still blocked.
        if (action == 'pause') {
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        history!.complete(
          http.Response(
            '[]',
            200,
            headers: {'content-type': 'application/json'},
            request: http.Request(
              'GET',
              Uri.parse(
                'https://example.supabase.co/rest/v1/order_chat_messages',
              ),
            ),
          ),
        );
        await tester.pump();
      },
    );
  }
}
