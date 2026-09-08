// Regression guard for the wrong/missing monochrome status-bar notification icon.
//
// ROOT CAUSE: there are THREE independent places that render an Android status-bar
// notification, and only two of them were ever pointed at the monochrome
// ic_stat_notify.xml silhouette:
//   1. Foreground FCM messages -> flutter_local_notifications (notification_service.dart) -- OK.
//   2. Background/killed-app FCM messages -> AndroidManifest default_notification_icon meta-data,
//      and the send-push-notification edge function's per-message android.notification.icon -- OK.
//   3. The rider "WayDrop Drop Partner Online" foreground LOCATION SERVICE notification, created
//      by geolocator via ForegroundNotificationConfig in location_cache_service.dart -- this one
//      never set `notificationIcon`, so geolocator_android defaulted it to
//      AndroidResource(name: 'ic_launcher', defType: 'mipmap'): the full-color launcher icon.
//      Android flattens every status-bar smallIcon to its alpha channel on API 21+, so a
//      solid-opacity color icon renders as a meaningless filled blob instead of the intended car
//      silhouette -- this is the notification riders see continuously while online, so it's the
//      one most likely to be noticed as "the wrong icon" even though the FCM paths were already
//      fixed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final manifest = _read('android/app/src/main/AndroidManifest.xml');
  final notificationService = _read('lib/modules/notifications/services/notification_service.dart');
  final locationCacheService = _read('lib/core/services/location/location_cache_service.dart');
  final pushFunction = _read('supabase/functions/send-push-notification/index.ts');

  group('Background/killed-app FCM notifications use the monochrome icon', () {
    test('AndroidManifest declares default_notification_icon pointing at ic_stat_notify', () {
      expect(manifest.contains('com.google.firebase.messaging.default_notification_icon'), isTrue);
      expect(manifest.contains('android:resource="@drawable/ic_stat_notify"'), isTrue);
    });

    test('the send-push-notification edge function sets an explicit per-message icon', () {
      expect(pushFunction.contains('icon: "ic_stat_notify"'), isTrue);
    });
  });

  group('Foreground FCM notifications use the monochrome icon', () {
    test('flutter_local_notifications is initialized with ic_stat_notify', () {
      expect(notificationService.contains("AndroidInitializationSettings('@drawable/ic_stat_notify')"), isTrue);
    });

    test('the foreground banner AndroidNotificationDetails sets icon: @drawable/ic_stat_notify', () {
      expect(notificationService.contains("icon: '@drawable/ic_stat_notify'"), isTrue);
    });
  });

  group('Rider "Drop Partner Online" foreground location-service notification uses the monochrome icon', () {
    test('ForegroundNotificationConfig sets an explicit notificationIcon, not the geolocator default', () {
      // Without this, geolocator_android silently falls back to
      // AndroidResource(name: 'ic_launcher', defType: 'mipmap') -- the full-color launcher icon.
      expect(locationCacheService.contains("notificationIcon: AndroidResource(name: 'ic_stat_notify'"), isTrue);
    });
  });
}
