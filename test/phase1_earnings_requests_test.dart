import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/features/rider/earnings/rider_earnings_tab.dart';

class _QuietChannel extends RealtimeChannel {
  _QuietChannel(String name)
    : super(name, RealtimeClient('wss://example.invalid/realtime/v1'));
  @override
  RealtimeChannel subscribe([
    void Function(RealtimeSubscribeStatus, Object?)? callback,
    Duration? timeout,
  ]) {
    callback?.call(RealtimeSubscribeStatus.subscribed, null);
    return this;
  }
}

class _Client extends SupabaseClient {
  _Client(http.Client client)
    : super(
        'https://example.invalid',
        'test-public-key',
        httpClient: client,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
  @override
  RealtimeChannel channel(
    String name, {
    RealtimeChannelConfig opts = const RealtimeChannelConfig(),
  }) => _QuietChannel(name);
  @override
  Future<String> removeChannel(RealtimeChannel channel) async => 'ok';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _Client? allocatedClient;
  tearDown(() async {
    await allocatedClient?.dispose();
  });
  testWidgets(
    'Earnings shares an in-flight batch and stops new queries after disposal',
    (tester) async {
      final requests = <http.Request>[];
      final riderGate = Completer<http.Response>();
      String encode(Object v) =>
          base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
      const uid = '00000000-0000-4000-8000-000000000021';
      final token = [
        encode({'alg': 'HS256', 'typ': 'JWT'}),
        encode({
          'sub': uid,
          'role': 'authenticated',
          'exp':
              DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
        }),
        'test',
      ].join('.');
      final client = (await tester.runAsync(
        () async => _Client(
          MockClient((request) async {
            requests.add(request);
            Object? body;
            if (request.url.path.contains('/auth/')) {
              body = {
                'access_token': token,
                'refresh_token': 'test',
                'expires_in': 3600,
                'token_type': 'bearer',
                'user': {
                  'id': uid,
                  'aud': 'authenticated',
                  'created_at': '2026-01-01T00:00:00Z',
                  'app_metadata': <String, dynamic>{},
                  'user_metadata': <String, dynamic>{},
                },
              };
            } else if (request.url.path.endsWith('/riders')) {
              final result = await riderGate.future;
              return http.Response(
                result.body,
                result.statusCode,
                request: request,
                headers: {'content-type': 'application/json'},
              );
            } else if (request.url.path.endsWith('/government_tax_config')) {
              body = null;
            } else if (request.url.path.endsWith('/create-rider-withdrawal')) {
              body = {'success': true};
            } else {
              throw StateError(
                'Unexpected request after disposal: ${request.url.path}',
              );
            }
            return http.Response(
              jsonEncode(body),
              200,
              request: request,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      ))!;
      allocatedClient = client;
      final manager = RealtimeManager.forClient(client);
      try {
        await tester.runAsync(() => client.auth.setSession('test-refresh'));
        await tester.pumpWidget(
          MaterialApp(
            home: RiderEarningsTab(client: client, realtime: manager),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        final dynamic state = tester.state(find.byType(RiderEarningsTab));
        final Future<void> second = state.fetchData();
        final Future<void> third = state.fetchData();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        expect(requests.where((r) => r.url.path.endsWith('/riders')).length, 1);
        expect(
          requests
              .where((r) => r.url.path.endsWith('/government_tax_config'))
              .length,
          1,
        );

        await tester.pumpWidget(const SizedBox());

        riderGate.complete(http.Response(jsonEncode({'id': 'rider-a'}), 200));

        var secondDone = false;
        var thirdDone = false;
        second.then((_) => secondDone = true);
        third.then((_) => thirdDone = true);
        for (var i = 0; i < 4; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump();
        }

        expect(secondDone, isTrue);
        expect(thirdDone, isTrue);
        expect(requests.where((r) => r.url.path.endsWith('/orders')).length, 0);
        expect(manager.activeChannelCount, 0);
        expect(tester.takeException(), isNull);
      } finally {
        manager.dispose();
      }
    },
  );
}
