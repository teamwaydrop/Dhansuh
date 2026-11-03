import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/core/services/realtime/rider_update_filter.dart';

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

class _Client extends SupabaseClient {
  _Client()
    : super(
        'https://example.invalid',
        'test-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
  final created = <_Channel>[];
  final removed = <RealtimeChannel>[];
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
  Future<String> removeChannel(RealtimeChannel channel) async {
    removed.add(channel);
    return 'ok';
  }
}

void main() {
  for (final recovery in ['backoff', 'connectivity', 'none', 'disposed']) {
    test('fallback reconnect respects SDK recovery: $recovery', () async {
      final client = _Client();
      final online = Completer<bool>();
      var probes = 0;
      final manager = RealtimeManager.forClient(
        client,
        connectivityCheck: () {
          probes++;
          return online.future;
        },
      );
      addTearDown(() async {
        manager.dispose();
        await client.dispose();
      });
      final id = manager.subscribe(
        channelName: 'rider',
        table: 'riders',
        owner: 'tracking',
        callback: (_) {},
      );
      final original = client.created.single;
      original.status!(RealtimeSubscribeStatus.channelError, null);
      if (recovery == 'backoff') {
        original.status!(RealtimeSubscribeStatus.subscribed, null);
      }
      if (recovery == 'disposed') manager.unsubscribe('rider', id);
      await Future<void>.delayed(const Duration(milliseconds: 2400));
      if (recovery == 'connectivity') {
        original.status!(RealtimeSubscribeStatus.subscribed, null);
      }
      online.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(probes, recovery == 'backoff' || recovery == 'disposed' ? 0 : 1);
      expect(client.created.length, recovery == 'none' ? 2 : 1);
      expect(
        client.removed.length,
        recovery == 'none' || recovery == 'disposed' ? 1 : 0,
      );
      manager.dispose();
    });
  }

  const fields = {'current_lat', 'current_lng', 'last_location_updated_at'};
  const before = {
    'id': 'rider-a',
    'account_status': 'online',
    'service_mode': 'local',
    'current_lat': 17,
  };
  test(
    'complete old row skips GPS only, preserves eligibility and availability changes',
    () {
      expect(
        isLocationOnlyRiderUpdate(before, {
          ...before,
          'current_lat': 18,
        }, fields),
        isTrue,
      );
      for (final business in [
        {'account_status': 'offline'},
        {'service_mode': 'intercity'},
        {'cod_limit': 100},
      ]) {
        expect(
          isLocationOnlyRiderUpdate(before, {...before, ...business}, fields),
          isFalse,
        );
      }
    },
  );
  test('missing old fields never classify a business update as GPS only', () {
    expect(
      isLocationOnlyRiderUpdate(
        {'id': 'rider-a'},
        {...before, 'account_status': 'offline'},
        fields,
      ),
      isFalse,
    );
    expect(isLocationOnlyRiderUpdate({}, before, fields), isFalse);
    expect(isLocationOnlyRiderUpdate(before, {}, fields), isFalse);
    // A partial row containing only known location fields still has a proven safe scope.
    expect(
      isLocationOnlyRiderUpdate(before, {
        'id': 'rider-a',
        'current_lat': 18,
      }, fields),
      isTrue,
    );
  });
}
