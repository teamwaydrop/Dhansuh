import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final manager = _read('lib/core/services/realtime/realtime_manager.dart');
  final badge = _read(
    'lib/modules/notifications/services/notification_badge_service.dart',
  );
  final appStart = _read('lib/app_start_screen.dart');

  group('Realtime reconnect lifecycle', () {
    test('revalidates channel ownership after every reconnect await', () {
      final start = manager.indexOf(
        'Future<void> _reconnectChannel(String channelName) async',
      );
      final end = manager.indexOf('Future<bool> _checkConnectivity()', start);
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final body = manager.substring(start, end);

      expect(
        body.contains('if (!_isCurrentChannel(channelName, managed)) return;'),
        isTrue,
      );
      expect(
        RegExp(
          r'_isCurrentChannel\(channelName, managed\)',
        ).allMatches(body).length,
        greaterThanOrEqualTo(4),
      );
      expect(
        body.contains('identical(_activeChannels[channelName], managed)'),
        isFalse,
        reason:
            'The identity rule should stay centralized in _isCurrentChannel.',
      );
    });

    test('channel removal futures are handled instead of discarded', () {
      expect(manager.contains('unawaited('), isTrue);
      expect(manager.contains('Future<void> _removeChannelSafely('), isTrue);
      expect(
        manager.contains('await supabase.removeChannel(channel);'),
        isTrue,
      );
    });
  });

  group('Account-scoped listener cleanup', () {
    test(
      'notification badge cleanup unsubscribes, clears identity, and resets count',
      () {
        final start = badge.indexOf('void stopListening()');
        expect(start, greaterThan(-1));
        final body = badge.substring(start);
        expect(body.contains('_subscribedUserId = null;'), isTrue);
        expect(body.contains('_subscriptionId = null;'), isTrue);
        expect(body.contains('RealtimeManager.instance.unsubscribe('), isTrue);
        expect(
          body.contains('unreadNotificationCountProvider.notifier).state = 0'),
          isTrue,
        );
      },
    );

    test(
      'AppStartScreen owns and cancels exactly one auth-state subscription',
      () {
        expect(
          appStart.contains(
            'StreamSubscription<AuthState>? _authStateSubscription;',
          ),
          isTrue,
        );
        expect(
          appStart.contains(
            '_authStateSubscription ??= supabase.auth.onAuthStateChange.listen(',
          ),
          isTrue,
        );
        expect(
          appStart.contains('unawaited(_authStateSubscription?.cancel());'),
          isTrue,
        );
      },
    );

    test('signed-out events stop account-scoped listeners', () {
      final start = appStart.indexOf('void listenAuthChanges()');
      final end = appStart.indexOf('Future<void> checkUserFlow()', start);
      final body = appStart.substring(start, end);
      expect(body.contains('AuthChangeEvent.signedOut'), isTrue);
      expect(
        body.contains('NotificationBadgeService.instance.stopListening();'),
        isTrue,
      );
      expect(body.contains('UserSessionService().stopListening();'), isTrue);
    });
  });
}
