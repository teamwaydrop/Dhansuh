import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';

class TestChannel extends RealtimeChannel {
  TestChannel(String name)
    : super(name, RealtimeClient('wss://example.invalid/realtime/v1'));
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

class TestClient extends SupabaseClient {
  TestClient() : super('https://example.invalid', 'offline-test-key');
  final created = <TestChannel>[];
  final removed = <RealtimeChannel>[];
  @override
  RealtimeChannel channel(
    String name, {
    RealtimeChannelConfig opts = const RealtimeChannelConfig(),
  }) {
    final channel = TestChannel(name);
    created.add(channel);
    return channel;
  }

  @override
  Future<String> removeChannel(RealtimeChannel channel) async {
    removed.add(channel);
    return 'ok';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestClient client;
  late RealtimeManager manager;
  final payload = PostgresChangePayload(
    schema: 'public',
    table: 'orders',
    commitTimestamp: DateTime(2026),
    eventType: PostgresChangeEvent.update,
    newRecord: {'id': 'order-a'},
    oldRecord: {},
    errors: null,
  );
  setUp(() {
    client = TestClient();
    manager = RealtimeManager.forClient(client);
  });
  tearDown(() async {
    manager.dispose();
    await client.dispose();
  });
  String listen(
    String owner,
    void Function(PostgresChangePayload) callback, {
    String order = 'a',
  }) => manager.subscribe(
    channelName: 'orders',
    table: 'orders',
    owner: owner,
    filterColumn: 'id',
    filterValue: order,
    callback: callback,
  );
  test(
    'matching owners pool; releasing one keeps the remaining owner live',
    () {
      var a = 0, b = 0;
      final aId = listen('a', (_) => a++);
      final bId = listen('b', (_) => b++);
      expect(client.created, hasLength(1));
      client.created.single.deliver(payload);
      expect([a, b], [1, 1]);
      manager.unsubscribe('orders', aId);
      client.created.single.deliver(payload);
      expect([a, b], [1, 2]);
      expect(client.removed, isEmpty);
      manager.unsubscribe('orders', bId);
      expect(manager.activeChannelCount, 0);
      expect(client.removed, hasLength(1));
    },
  );
  test(
    'different order filters isolate streams and unsubscribe through original key',
    () {
      var a = 0, b = 0;
      listen('a', (_) => a++);
      final bId = listen('b', (_) => b++, order: 'b');
      expect(client.created, hasLength(2));
      client.created.last.deliver(payload);
      expect([a, b], [0, 1]);
      manager.unsubscribe('orders', bId);
      expect(manager.activeChannelCount, 1);
      expect(client.removed.single, same(client.created.last));
    },
  );
  test('a throwing owner does not suppress another listener', () {
    var delivered = 0;
    listen('broken', (_) => throw StateError('owner disposed'));
    listen('healthy', (_) => delivered++);
    client.created.single.deliver(payload);
    expect(delivered, 1);
  });
  test('queued messages after manager disposal never reach former owners', () {
    var delivered = 0;
    listen('screen', (_) => delivered++);
    final oldChannel = client.created.single;
    manager.dispose();
    oldChannel.deliver(payload);
    expect(delivered, 0);
  });
}
