import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/core/services/realtime/realtime_order_controller.dart';

class _Channel extends RealtimeChannel {
  _Channel(this.requestedName)
    : super(requestedName, RealtimeClient('wss://example.invalid/realtime/v1'));
  final String requestedName;
  late void Function(PostgresChangePayload) deliver;
  @override
  RealtimeChannel onPostgresChanges({
    required PostgresChangeEvent event,
    String? schema,
    String? table,
    PostgresChangeFilter? filter,
    required void Function(PostgresChangePayload) callback,
  }) {
    deliver = callback;
    return this;
  }

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
  _Client(http.Client httpClient)
    : super(
        'https://example.invalid',
        'offline-public-key',
        httpClient: httpClient,
      );
  final channels = <_Channel>[];
  @override
  RealtimeChannel channel(
    String name, {
    RealtimeChannelConfig opts = const RealtimeChannelConfig(),
  }) {
    final c = _Channel(name);
    channels.add(c);
    return c;
  }

  @override
  Future<String> removeChannel(RealtimeChannel channel) async => 'ok';
  void emit(String name, Map<String, dynamic> row) => channels
      .lastWhere((c) => c.requestedName == name)
      .deliver(
        PostgresChangePayload(
          schema: 'public',
          table: name.contains('rider') ? 'riders' : 'orders',
          commitTimestamp: DateTime(2026),
          eventType: PostgresChangeEvent.update,
          newRecord: row,
          oldRecord: {},
          errors: null,
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Client client;
  late RealtimeManager manager;
  late RealtimeOrderController controller;
  late DateTime now;
  final requests = <http.Request>[];
  Completer<http.Response>? orderGate, liveGate, nameGate, oldRiderGate;
  String? assignedRider;
  var initialStatus = 'accepted';
  var metadataKyc = 'kyc-a';
  Map<String, dynamic> order([String status = 'accepted', String? rider]) => {
    'id': 'order-a',
    'user_id': 'user-a',
    'order_status': status,
    'order_type': 'ride',
    'rider_id': rider,
  };
  http.Response response(Object? row) => http.Response(
    jsonEncode(row),
    200,
    headers: {'content-type': 'application/json'},
  );
  int count(String suffix) =>
      requests.where((r) => r.url.path.endsWith(suffix)).length;
  Future<void> flush(WidgetTester tester) async {
    for (var pass = 0; pass < 2; pass++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
    }
  }

  setUp(() {
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    requests.clear();
    orderGate = null;
    liveGate = null;
    nameGate = null;
    oldRiderGate = null;
    assignedRider = null;
    initialStatus = 'accepted';
    metadataKyc = 'kyc-a';
    now = DateTime(2026, 11, 1);
    client = _Client(
      MockClient((request) async {
        requests.add(request);
        Future<http.Response> route() async {
          if (request.url.path.endsWith('/orders')) {
            return orderGate?.future ??
                response(order(initialStatus, assignedRider));
          }
          if (request.url.path.endsWith('/users')) {
            return nameGate?.future ?? response({'full_name': ''});
          }
          if (request.url.path.endsWith('/get-live-order-status')) {
            return liveGate?.future ?? response({'success': false});
          }
          if (request.url.path.endsWith('/riders')) {
            final id = request.url.queryParameters['id']!.substring(3);
            if (id == 'rider-a' && oldRiderGate != null) {
              final gate = oldRiderGate!;
              oldRiderGate = null;
              return gate.future;
            }
            return response({
              'id': id,
              'user_id': 'rider-user',
              'kyc_id': metadataKyc,
              'rating': 4.8,
              'users': {'full_name': id},
            });
          }
          if (request.url.path.endsWith('/rider_reliability_view')) {
            return response(null);
          }
          throw StateError('Unexpected mocked request: ${request.url.path}');
        }

        final result = await route();
        return http.Response(
          result.body,
          result.statusCode,
          headers: result.headers,
          request: request,
        );
      }),
    );
    manager = RealtimeManager.forClient(client);
    controller = RealtimeOrderController(
      orderId: 'order-a',
      client: client,
      realtime: manager,
      now: () => now,
    );
  });
  tearDown(() async {
    controller.dispose();
    manager.dispose();
    await client.dispose();
  });
  testWidgets(
    'concurrent and repeated starts share one order request, channel and live fetch',
    (tester) async {
      orderGate = Completer();
      final first = controller.start();
      final second = controller.start();
      await flush(tester);
      expect(count('/orders'), 1);
      orderGate!.complete(response(order()));
      await first;
      await second;
      await controller.start();
      await flush(tester);
      expect(count('/orders'), 1);
      expect(count('/get-live-order-status'), 1);
      expect(manager.activeChannelCount, 1);
      controller.dispose();
      await flush(tester);
    },
  );
  testWidgets(
    'event burst shares pending username and live requests without extra order reads',
    (tester) async {
      nameGate = Completer();
      liveGate = Completer();
      await controller.start();
      await flush(tester);
      for (var i = 0; i < 8; i++) {
        client.emit('realtime-order-order-a', order());
      }
      await flush(tester);
      expect(count('/users'), 1);
      expect(count('/get-live-order-status'), 1);
      liveGate!.complete(response({'success': false}));
      nameGate!.complete(response({'full_name': ''}));
      await flush(tester);
      expect(count('/orders'), 1);
      expect(count('/get-live-order-status'), 2);
      expect(count('/users'), 1);
      client.emit('realtime-order-order-a', order());
      await flush(tester);
      expect(count('/users'), 1);
      controller.dispose();
      await flush(tester);
    },
  );
  testWidgets('late REST order response cannot undo a realtime cancellation', (
    tester,
  ) async {
    await controller.start();
    await flush(tester);
    orderGate = Completer();
    final pending = controller.fetchOrder();
    await flush(tester);
    client.emit('realtime-order-order-a', order('cancelled'));
    expect(controller.orderNotifier.value!.isCancelled, isTrue);
    orderGate!.complete(response(order()));
    await pending;
    expect(controller.orderNotifier.value!.isCancelled, isTrue);
    controller.dispose();
    await flush(tester);
  });
  testWidgets(
    'disposal during initial fetch never registers channels or timers',
    (tester) async {
      orderGate = Completer();
      final pending = controller.start();
      await flush(tester);
      controller.dispose();
      orderGate!.complete(response(order()));
      await pending;
      expect(manager.activeChannelCount, 0);
      expect(count('/get-live-order-status'), 0);
    },
  );
  testWidgets(
    'background skips fallback and ETA enrichment; resume reconciles once',
    (tester) async {
      await controller.start();
      await flush(tester);
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 30));
      await flush(tester);
      client.emit('realtime-order-order-a', order('ongoing'));
      await flush(tester);
      expect(controller.orderNotifier.value!.orderStatus, 'ongoing');
      expect(count('/orders'), 1);
      expect(count('/get-live-order-status'), 1);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await flush(tester);
      expect(count('/orders'), 2);
      expect(count('/get-live-order-status'), 2);
      controller.dispose();
      await flush(tester);
    },
  );
  testWidgets(
    'GPS rider events avoid metadata reload; changed KYC refreshes it',
    (tester) async {
      assignedRider = 'rider-a';
      await controller.start();
      await flush(tester);
      expect(count('/riders'), 1);
      for (var i = 0; i < 5; i++) {
        client.emit('realtime-rider-rider-a', {
          'id': 'rider-a',
          'rating': 4.8,
          'kyc_id': 'kyc-a',
          'current_lat': 17.0 + i / 1000,
          'current_lng': 79.0,
        });
      }
      await flush(tester);
      expect(count('/riders'), 1);
      expect(controller.riderLocationNotifier.value!['lat'], 17.004);
      client.emit('realtime-rider-rider-a', {
        'id': 'rider-a',
        'rating': 4.8,
        'kyc_id': 'kyc-b',
      });
      await flush(tester);
      expect(count('/riders'), 2);
      controller.dispose();
      await flush(tester);
    },
  );
  testWidgets(
    'late metadata for replaced rider cannot overwrite the new rider',
    (tester) async {
      assignedRider = 'rider-a';
      final replacedRiderGate = Completer<http.Response>();
      oldRiderGate = replacedRiderGate;
      await controller.start();
      await flush(tester);
      client.emit('realtime-order-order-a', order('accepted', 'rider-b'));
      await flush(tester);
      expect(controller.riderNotifier.value!['id'], 'rider-b');
      replacedRiderGate.complete(
        response({'id': 'rider-a', 'kyc_id': 'kyc-a', 'rating': 4.8}),
      );
      await flush(tester);
      expect(controller.riderNotifier.value!['id'], 'rider-b');
      controller.dispose();
      await flush(tester);
    },
  );
  testWidgets('terminal startup order does not request live ETA', (
    tester,
  ) async {
    initialStatus = 'cancelled';
    await controller.start();
    await flush(tester);
    expect(controller.orderNotifier.value!.isCancelled, isTrue);
    expect(count('/get-live-order-status'), 0);
    controller.dispose();
    await flush(tester);
  });
  testWidgets('KYC change during a rider lookup gets one fresh follow-up', (
    tester,
  ) async {
    assignedRider = 'rider-a';
    await controller.start();
    await flush(tester);
    final gate = Completer<http.Response>();
    oldRiderGate = gate;
    client.emit('realtime-rider-rider-a', {
      'id': 'rider-a',
      'rating': 4.8,
      'kyc_id': 'kyc-b',
    });
    await flush(tester);
    expect(count('/riders'), 2);
    metadataKyc = 'kyc-c';
    client.emit('realtime-rider-rider-a', {
      'id': 'rider-a',
      'rating': 4.8,
      'kyc_id': 'kyc-c',
    });
    gate.complete(
      response({'id': 'rider-a', 'rating': 4.8, 'kyc_id': 'kyc-b'}),
    );
    await flush(tester);
    expect(count('/riders'), 3);
    expect(controller.riderNotifier.value!['kyc_id'], 'kyc-c');
    controller.dispose();
    await flush(tester);
  });
  testWidgets('manual order refreshes serialize with one fresh queued read', (
    tester,
  ) async {
    await controller.start();
    await flush(tester);
    final gate = Completer<http.Response>();
    orderGate = gate;
    final first = controller.fetchOrder();
    final second = controller.fetchOrder();
    await flush(tester);
    expect(count('/orders'), 2);
    orderGate = null;
    gate.complete(response(order()));
    await flush(tester);
    await first;
    await second;
    expect(count('/orders'), 3);
    controller.dispose();
    await flush(tester);
  });
  testWidgets('identical GPS heartbeats do not rebuild location listeners', (
    tester,
  ) async {
    assignedRider = 'rider-a';
    await controller.start();
    await flush(tester);
    var updates = 0;
    controller.riderLocationNotifier.addListener(() => updates++);
    final row = <String, dynamic>{
      'id': 'rider-a',
      'rating': 4.8,
      'kyc_id': 'kyc-a',
      'current_lat': 17.0,
      'current_lng': 79.0,
      'current_heading': 0.0,
    };
    for (var i = 0; i < 5; i++) {
      client.emit('realtime-rider-rider-a', row);
    }
    expect(updates, 1);
    client.emit('realtime-rider-rider-a', {...row, 'current_heading': 10.0});
    expect(updates, 2);
    client.emit('realtime-rider-rider-a', {...row, 'current_lat': 17.001});
    expect(updates, 3);
    expect(count('/riders'), 1);
    controller.dispose();
    await flush(tester);
  });
}
