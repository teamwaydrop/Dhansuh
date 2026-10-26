import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/user/home/home_refresh_coordinator.dart';

void main() {
  group('HomeRefreshCoordinator', () {
    test('coalesces overlapping triggers into one active and one follow-up', () async {
      final first = Completer<void>();
      final second = Completer<void>();
      var calls = 0;
      var active = 0;
      var maxActive = 0;

      final coordinator = HomeRefreshCoordinator((_) async {
        calls++;
        active++;
        if (active > maxActive) maxActive = active;
        await (calls == 1 ? first.future : second.future);
        active--;
      });

      final activeRequest = coordinator.request();
      await coordinator.request();
      await coordinator.request();
      expect(calls, 1);

      first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      expect(maxActive, 1);

      second.complete();
      await activeRequest;
      expect(calls, 2);
    });

    test('queued refresh reconciles the latest order and terminal state', () async {
      final first = Completer<void>();
      var latestStatus = 'searching';
      final appliedStatuses = <String>[];
      var calls = 0;
      final coordinator = HomeRefreshCoordinator((_) async {
        calls++;
        if (calls == 1) await first.future;
        appliedStatuses.add(latestStatus);
      });

      final activeRequest = coordinator.request();
      latestStatus = 'accepted';
      await coordinator.request();
      latestStatus = 'completed';
      await coordinator.request();
      first.complete();
      await activeRequest;

      expect(calls, 2);
      expect(appliedStatuses.last, 'completed');
    });

    test('failure releases the guard for a subsequent refresh', () async {
      var calls = 0;
      final coordinator = HomeRefreshCoordinator((_) async {
        calls++;
        if (calls == 1) throw StateError('controlled failure');
      });

      await expectLater(coordinator.request(), throwsStateError);
      await coordinator.request();
      expect(calls, 2);
    });

    test('dispose suppresses a queued refresh and future requests', () async {
      final first = Completer<void>();
      var calls = 0;
      final coordinator = HomeRefreshCoordinator((_) async {
        calls++;
        await first.future;
      });

      final activeRequest = coordinator.request();
      await coordinator.request();
      coordinator.dispose();
      first.complete();
      await activeRequest;
      await coordinator.request();

      expect(calls, 1);
    });

    test('seeded initial request remains seeded without another trigger', () async {
      final modes = <bool>[];
      final coordinator = HomeRefreshCoordinator((useInitialData) async {
        modes.add(useInitialData);
      });

      await coordinator.request(useInitialData: true);
      expect(modes, [true]);
    });

    test('normal queued refresh wins and keeps the newest data together', () async {
      final first = Completer<void>();
      final modes = <bool>[];
      final snapshots = <Map<String, Object>>[];
      var latest = <String, Object>{
        'rider': 'rider-v1',
        'kyc': 'verified',
        'orders': 'searching',
      };
      final coordinator = HomeRefreshCoordinator((useInitialData) async {
        modes.add(useInitialData);
        if (modes.length == 1) await first.future;
        snapshots.add(Map<String, Object>.of(latest));
      });

      final activeRequest = coordinator.request(useInitialData: true);
      latest = <String, Object>{
        'rider': 'rider-v2',
        'kyc': 'approved',
        'orders': 'completed',
      };
      await coordinator.request();
      first.complete();
      await activeRequest;

      expect(modes, [true, false]);
      expect(snapshots.last, latest);
    });
  });
}
