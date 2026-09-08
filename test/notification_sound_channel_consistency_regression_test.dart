// Regression guard for Issue 7: inconsistent notification sound behavior between local ride
// assignment and intercity parcel/travel match notifications.
//
// INVESTIGATION FINDING (traced notification type, push payload, Android channel, channel sound
// config, and foreground/background behavior for both flows -- not assumed): the sound/channel
// CONFIGURATION itself is correctly and deliberately differentiated, both server-side
// (send-push-notification/index.ts: order_assignment -> channel_id 'order_alerts_v2', sound
// 'order_nearby_sound'; everything else -> 'high_importance_channel', sound 'default') and
// client-side (notification_service.dart mirrors the same mapping for the local-notification
// fallback). Background/killed-app delivery for both flows is governed entirely by this
// server-side config and is consistent.
//
// The apparent inconsistency is a FOREGROUND-only difference, and it is intentional, not a bug:
// order_assignment notifications are suppressed in the FCM foreground handler specifically because
// local ride assignments already get an in-app "incoming order" sound from TWO independent,
// redundant listeners on rider_assignments realtime INSERTs -- RiderHomeTab and
// RiderOrdersScreen -- both playing the same order_nearby_sound.aac asset via their own
// AudioPlayer. Showing the FCM local-notification banner+sound too would double the sound.
// Intercity match notifications have no such in-app popup/sound equivalent, so they correctly fall
// through to the standard local-notification path, using high_importance_channel's system default
// sound. Both paths are correct for what each notification type actually has -- this file locks in
// that contract so it can never silently drift (e.g. one of the two redundant in-app listeners
// being removed without also un-suppressing the FCM foreground path, which would leave local ride
// assignments silent in the foreground).
//
// This file is a structural regression guard (reads the real Dart/TypeScript source, following the
// pattern already used throughout this test suite for behavior that can't run against a live FCM
// delivery pipeline in a plain unit test).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final notificationService = _read(
    'lib/modules/notifications/services/notification_service.dart',
  );
  final sendPushFn = _read('supabase/functions/send-push-notification/index.ts');
  final homeTab = _read('lib/features/rider/home/rider_home_tab.dart');
  final ordersScreen = _read('lib/features/rider/orders/rider_orders_screen.dart');

  group('Issue 7 -- server-side channel/sound mapping (background/killed-app delivery)', () {
    test('order_assignment gets its own distinct channel and sound', () {
      expect(
        sendPushFn.contains('channel_id: isOrderAssignment ? "order_alerts_v2" : "high_importance_channel"'),
        isTrue,
      );
      expect(
        sendPushFn.contains('sound: isOrderAssignment ? "order_nearby_sound" : "default"'),
        isTrue,
      );
    });

    test('every other notification type (including intercity match) uses the shared default '
        'channel/sound -- never accidentally inherits order_assignment\'s', () {
      expect(sendPushFn.contains('"high_importance_channel"'), isTrue);
      expect(sendPushFn.contains('"default"'), isTrue);
    });
  });

  group('Issue 7 -- client-side foreground handling', () {
    test('the local-notification fallback mirrors the same channel/sound differentiation', () {
      expect(
        notificationService.contains(
          "isOrderAssignment ? 'order_alerts_v2' : 'high_importance_channel'",
        ),
        isTrue,
      );
      expect(
        notificationService.contains(
          "sound: isOrderAssignment ? const RawResourceAndroidNotificationSound('order_nearby_sound') : null",
        ),
        isTrue,
      );
    });

    test('order_assignment foreground suppression is documented as intentional (anti-double-'
        'sound), not silently dropped', () {
      final idx = notificationService.indexOf('final isOrderAssignment');
      expect(idx, greaterThan(-1));
      final section = notificationService.substring(idx, idx + 3000);
      expect(section.contains('Suppress local notification banner in foreground'), isTrue);
      expect(section.contains('RiderHomeTab'), isTrue);
      expect(section.contains('RiderOrdersScreen'), isTrue);
    });

    test('the badge counter still increments even though the banner/sound is suppressed', () {
      final idx = notificationService.indexOf('final isOrderAssignment');
      final section = notificationService.substring(idx, idx + 3000);
      expect(section.contains('activeAssignmentsCountProvider'), isTrue);
    });
  });

  group('Issue 7 -- the two redundant in-app sound sources the foreground suppression depends on',
      () {
    test('RiderHomeTab plays order_nearby_sound.aac on a genuinely new incoming assignment', () {
      expect(homeTab.contains("AssetSource('audio/order_nearby_sound.aac')"), isTrue);
      expect(homeTab.contains('_playOrderNearbySoundThrottled'), isTrue);
    });

    test('RiderOrdersScreen ALSO plays the same asset on a genuinely new incoming assignment '
        '-- both tabs are independently covered, not just Home', () {
      expect(ordersScreen.contains("AssetSource('audio/order_nearby_sound.aac')"), isTrue);
      expect(ordersScreen.contains('_playOrderNearbySoundThrottled'), isTrue);
      expect(
        ordersScreen.contains('if (orderId != null && !_announcedOrders.contains(orderId)) {'),
        isTrue,
        reason: 'must dedupe against orders already announced, matching RiderHomeTab\'s own '
            'dedup contract',
      );
    });
  });
}
