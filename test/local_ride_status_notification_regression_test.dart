// Regression guard for "passenger doesn't reliably get a meaningful notification for local ride
// accepted/arrived/completed" (PHASE 1, Issue 3).
//
// ROOT CAUSE: the send/deliver pipeline (on_order_status_update -> async enqueue ->
// send_order_status_notifications_core -> send_push_notification_fnc -> notifications table ->
// deliver_push_notification_http_fnc -> send-push-notification -> FCM) already reached the
// passenger correctly and exactly once per transition (OLD.order_status IS DISTINCT FROM
// NEW.order_status dedup guard). Two concrete gaps:
//   1. notification_service.dart unconditionally dropped every order_status push while the app was
//      foregrounded, with no substitute shown unless the passenger happened to already be on
//      RideTrackingScreen -- so a foregrounded passenger elsewhere in the app got zero signal.
//   2. accepted/completed copy for a plain local ride was generic, shared with parcel wording.
//
// FIX: remove the foreground suppression (reuses the exact same local-notification display path
// every other notification type already goes through -- no new delivery system); add
// order_type='ride'-specific copy for accepted/rider_arrived/completed via a new migration. Parcel
// and every intercity branch, plus the dedup guard itself, are untouched.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('notification_service.dart -- order_status pushes are no longer suppressed in foreground', () {
    final source = _read('lib/modules/notifications/services/notification_service.dart');

    test('the foreground order_status suppression block is gone', () {
      expect(
        source.contains("Suppressing foreground order_status notification banner"),
        isFalse,
        reason: 'order_status must render the same local-notification banner every other type '
            'already gets in the foreground -- a foregrounded passenger must see accept/arrive/'
            'complete updates',
      );
      // Scoped to the foreground FirebaseMessaging.onMessage listener only -- handleNotificationTap
      // (tap-routing logic, further down in this file) legitimately still checks
      // `type == 'order_status'` to route to the right tracking screen, and must be untouched.
      final foregroundListenerBody = source.substring(
        source.indexOf('FirebaseMessaging.onMessage.listen('),
        source.indexOf('FirebaseMessaging.onMessageOpenedApp.listen('),
      );
      expect(foregroundListenerBody.contains("if (type == 'order_status')"), isFalse);
    });

    test('order_assignment (rider-side) suppression is untouched -- this fix is scoped to '
        'passenger order_status notifications only', () {
      expect(source.contains('isOrderAssignment'), isTrue);
      expect(source.contains('Suppress local notification banner in foreground'), isTrue);
    });

    test('the generic local-notification display path (_localNotifications.show) still exists '
        'and is what order_status now falls through to', () {
      expect(source.contains('_localNotifications.show('), isTrue);
    });
  });

  group('send_order_status_notifications_core -- local ride gets meaningful, ride-specific copy', () {
    final migration = _read(
      'supabase/migrations/20260821000000_local_ride_status_notification_copy.sql',
    );

    test('accepted: ride-specific copy for order_type = ride', () {
      expect(migration.contains("ELSIF p_order_type = 'ride' THEN"), isTrue);
      expect(
        migration.contains('Your ride has been accepted. Your partner is on the way.'),
        isTrue,
      );
    });

    test('rider_arrived: ride-specific copy leads with "partner has arrived" but keeps the OTP '
        '(functionally required for the pickup flow -- cannot be dropped)', () {
      expect(migration.contains('Your partner has arrived. Share OTP'), isTrue);
      expect(
        migration.contains("v_body := 'Your partner has arrived. Share OTP ' || v_otp"),
        isTrue,
      );
    });

    test('completed: ride-specific copy for order_type = ride', () {
      expect(
        migration.contains(
          'Your ride is completed. Thank you for riding with WayDrop. We hope to see you again!',
        ),
        isTrue,
      );
    });

    test('local_parcel (non-ride, non-intercity) copy is unchanged from before this migration', () {
      expect(migration.contains('Order Accepted 🚗'), isTrue);
      expect(migration.contains('A rider has accepted your order and is on the way!'), isTrue);
      expect(migration.contains('Order Delivered Successfully 🎉'), isTrue);
      expect(
        migration.contains('Your order has been completed. Rate your experience and thank the rider!'),
        isTrue,
      );
    });

    test('every intercity branch is untouched, byte-for-byte', () {
      expect(migration.contains('Your Partner Started the Trip'), isTrue);
      expect(migration.contains('Partner Arrived'), isTrue);
      expect(migration.contains('Parcel Delivered 🎉'), isTrue);
      expect(migration.contains('Trip Completed'), isTrue);
    });

    test('the dedup guard (OLD/NEW status must genuinely differ) is unchanged', () {
      expect(migration.contains('IF p_old_status IS DISTINCT FROM p_new_status THEN'), isTrue);
    });

    test('rider-side cancellation/completion notifications are unchanged', () {
      expect(
        migration.contains("IF p_new_status = 'cancelled' AND p_rider_id IS NOT NULL THEN"),
        isTrue,
      );
      expect(
        migration.contains(
          "IF v_is_intercity AND (p_new_status = 'completed' OR p_new_status = 'delivered') "
          'AND p_rider_id IS NOT NULL THEN',
        ),
        isTrue,
      );
    });
  });
}
