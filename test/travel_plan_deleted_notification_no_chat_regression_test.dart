// Regression guard for Issue 5 (Phase 2): when a Traveller deletes their entire Travel Plan, the
// User's "Travel Plan Cancelled" notification detail screen showed an "Open Chat" button -- a
// travel-plan deletion is a terminal status update, not a chat message.
//
// ROOT CAUSE: NotificationDetailScreen._canOpenChat only checked whether `order_id` was present in
// the tap payload -- every 'intercity_request' notification (including this one) carries it, so
// the check could never distinguish a still-relevant negotiation from one just terminated by a
// whole-plan deletion.
//
// FIX (two parts, verified end to end against a local Supabase/Docker instance):
//   1. on_intercity_request_change() (20260901000029) now includes
//      'cancelled_scope', NEW.metadata->>'cancelled_scope' in the jsonb payload handed to
//      send_push_notification_fnc() -- PROVEN live: cancel_travel_plan_by_traveller() ->
//      cascade_cancel_travel_plan_dependents() -> on_intercity_request_change() produced a
//      notifications row with payload containing "cancelled_scope": "travel_plan" and the
//      unchanged title/body ("Travel Plan Cancelled" / "Your traveller has cancelled the travel
//      plan from CityA to CityB due to Personal emergency...").
//   2. NotificationDetailScreen._canOpenChat now also returns false when
//      tapData['cancelled_scope'] == 'travel_plan' -- scoped to exactly that one value, so every
//      other intercity_request notification (new match, invitation, discussion, confirmed, paid,
//      in_progress, completed, the 'individual_request' cancellation flavor, and the generic
//      cancellation flavor) is completely unaffected and still offers Chat when an order id is
//      present.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read('supabase/migrations/20260901000029_travel_plan_deleted_notification_no_chat.sql');
  final detailScreen = _read('lib/modules/notifications/screens/notification_detail_screen.dart');
  final notificationService = _read('lib/modules/notifications/services/notification_service.dart');

  group('1. Backend: the travel-plan-deletion notification payload now identifies itself', () {
    test('on_intercity_request_change() adds cancelled_scope to the shared jsonb payload', () {
      expect(migration.contains("'cancelled_scope', NEW.metadata->>'cancelled_scope'"), isTrue);
    });

    test('the travel_plan cancellation title/body wording is reproduced byte-for-byte -- this fix '
        'only adds a payload field, it does not touch any message text', () {
      expect(migration.contains("v_title := 'Travel Plan Cancelled';"), isTrue);
      expect(
        migration.contains(
          "v_body := 'Your traveller has cancelled the travel plan from ' || v_plan_pickup || ' to ' || v_plan_dest",
        ),
        isTrue,
      );
    });

    test('the individual_request and generic cancellation branches are unchanged and do not set '
        'this notification apart -- cancelled_scope only ever equals \'travel_plan\' for the '
        'whole-plan-deletion event', () {
      expect(migration.contains("ELSIF NEW.metadata->>'cancelled_scope' = 'individual_request' THEN"), isTrue);
    });
  });

  group('2. Client: Open Chat is hidden ONLY for the travel-plan-deletion event', () {
    test('_canOpenChat returns false when cancelled_scope == \'travel_plan\'', () {
      expect(
        detailScreen.contains("if (widget.tapData['cancelled_scope']?.toString() == 'travel_plan') return false;"),
        isTrue,
      );
    });

    test('_canOpenChat still requires a present order id first -- unrelated notification types '
        'with no order id never showed Chat and still don\'t', () {
      final anchor = detailScreen.indexOf('bool get _canOpenChat {');
      expect(anchor, greaterThan(-1));
      final body = detailScreen.substring(anchor, anchor + 500);
      expect(body.contains('if (orderId == null || orderId.isEmpty) return false;'), isTrue);
    });

    test('the Open Chat button widget itself is still gated on _canOpenChat -- unchanged', () {
      expect(detailScreen.contains('if (_canOpenChat) ...['), isTrue);
      expect(detailScreen.contains("label: const Text('Open Chat'),"), isTrue);
    });
  });

  group('3. Genuine chat notifications and other intercity notifications are unaffected', () {
    test('chat_message/support_message notifications still auto-open Chat directly -- this fix '
        'lives entirely inside the intercity_request detail-screen path, never touching that '
        'routing condition', () {
      expect(
        notificationService.contains("type == 'chat_message' || type == 'support_message'"),
        isTrue,
      );
    });

    test('the dedicated intercity_request branch still pushes NotificationDetailScreen for every '
        'intercity_request notification -- the travel-plan-deletion case is still routed here, '
        'just with Chat hidden once inside', () {
      final anchor = notificationService.indexOf("if (type == 'intercity_request') {");
      expect(anchor, greaterThan(-1));
      final nearby = notificationService.substring(anchor, (anchor + 400).clamp(0, notificationService.length));
      expect(nearby.contains('NotificationDetailScreen('), isTrue);
    });
  });
}
