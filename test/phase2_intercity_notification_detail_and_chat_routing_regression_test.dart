// Structural regression guard for Phase 2 / Issue 4: intercity notifications must not lose their
// full message behind UI truncation, and tapping one must never auto-open Chat.
//
// BUG REPORT: "Booking Cancelled / Your traveller cancelled this trip. Please choose another
// available partner..." -- the notification list showed the message cut off behind an ellipsis,
// and tapping the notification opened the Chat screen instead of showing the full message.
//
// ROOT CAUSE (traced end to end, not assumed):
//   1. TRUNCATION is presentation-only. public.notifications.title/body already store the
//      COMPLETE, untruncated message -- confirmed by tracing send_push_notification_fnc() (writes
//      p_title/p_body verbatim, no length limit), send-push-notification/index.ts (forwards
//      title/msgBody verbatim into the FCM `notification` block, never slices them), and
//      notifications_inbox_screen.dart's own SELECT (`title,body` columns, full values). The ONLY
//      truncation anywhere in this pipeline is notifications_inbox_screen.dart's list-row
//      `subtitle` Text widget: `maxLines: 2, overflow: TextOverflow.ellipsis` -- a compact list
//      preview with no way to see the rest, exactly the "hidden behind ..." symptom reported. The
//      message itself was never lost; it just had no expand/detail affordance.
//   2. CHAT-ON-TAP: notification_service.dart's handleNotificationTap() grouped
//      `type == 'intercity_request'` into the SAME "open Chat" condition as genuine
//      `chat_message`/`support_message` notifications. But 'intercity_request' notifications
//      (everything on_intercity_request_change() sends: new match, invitation, discussion
//      started, confirmed, rejected, paid, in_progress, completed, CANCELLED) are status updates
//      ABOUT a negotiation, never an actual chat message -- so tapping a cancellation
//      notification (type='intercity_request') fell straight into `OrderChatScreen`, which is
//      wrong for a notification tap and is exactly why "tap opens Chat instead of showing the
//      notification" happened. For a rider-mode viewer this was partially masked by an earlier
//      Travel Plan Details lookup that ran first and returned early on success -- but any lookup
//      failure, and every passenger-mode tap (the exact scenario in the bug report -- the
//      passenger receiving the traveller's cancellation), fell through to Chat every time.
//
// FIX: added lib/modules/notifications/screens/notification_detail_screen.dart -- a full-message
// view (complete body, no maxLines, plus notification type + timestamp) that fetches the
// complete, authoritative notifications row by id (never re-derives/duplicates the message text).
// 'intercity_request' is removed from the auto-chat-opening condition and now always opens this
// detail screen instead (falling through from -- not replacing -- the pre-existing rider-mode
// Travel Plan Details routing, which is unaffected). Chat is reachable from the detail screen only
// via an explicit "Open Chat" button, which calls the SAME single openChatForOrder() method the
// genuine chat_message/support_message auto-routing already uses -- no second implementation.
// local ride/local parcel ('order_status') routing, and every non-intercity notification type, is
// untouched.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final notificationService = _read('lib/modules/notifications/services/notification_service.dart');
  final detailScreen = _read('lib/modules/notifications/screens/notification_detail_screen.dart');
  final inboxScreen = _read('lib/modules/notifications/screens/notifications_inbox_screen.dart');
  final sendPushFn = _read('supabase/functions/send-push-notification/index.ts');

  group('1. The complete message already exists in storage/push -- this is a presentation/tap '
      'fix only, nothing was truncated before storage', () {
    test('send_push_notification_fnc() writes title/body verbatim into public.notifications -- '
        'no length limit, substring, or truncation of any kind', () {
      final fn = _read('supabase/migrations/20260718000002_fix_stale_send_push_notification_fnc.sql');
      expect(fn.contains('p_title,\n        p_body,'), isTrue);
      expect(fn.contains('LEFT('), isFalse);
      expect(fn.contains('substring('), isFalse);
    });

    test('send-push-notification/index.ts forwards the full title/body into the FCM notification '
        'block verbatim -- never sliced/truncated', () {
      final anchor = sendPushFn.indexOf('notification: {\n            title: title,\n            body: msgBody,\n          },');
      expect(anchor, greaterThan(-1));
      expect(sendPushFn.contains('.substring('), isFalse);
      expect(sendPushFn.contains('.slice('), isFalse);
    });

    test('the in-app inbox already selects the full title/body columns (not a preview column, not '
        'a truncated one)', () {
      expect(
        inboxScreen.contains("select('id,payload,notification_type,reference_id,is_read,created_at,title,body')"),
        isTrue,
      );
    });

    test('on_notification_insert() stamps notification_id into the push data payload, so a full-'
        'message fetch is possible from BOTH the in-app inbox tap and a real FCM/system-tray tap, '
        'not just one entry point', () {
      final fn = _read('supabase/migrations/20260718000004_reapply_search_path_hardening_batch.sql');
      final anchor = fn.indexOf('CREATE OR REPLACE FUNCTION public.on_notification_insert()');
      expect(anchor, greaterThan(-1));
      final body = fn.substring(anchor, (anchor + 700).clamp(0, fn.length));
      expect(body.contains("'notification_id', NEW.id,"), isTrue);
    });
  });

  group('2. NotificationDetailScreen shows the complete body -- no maxLines/overflow truncation', () {
    test('the body is rendered with SelectableText and no maxLines/overflow constraint '
        '(explicitly NOT "just increase maxLines")', () {
      final anchor = detailScreen.indexOf('SelectableText(\n                    _body');
      expect(anchor, greaterThan(-1));
      final nearby = detailScreen.substring(anchor, (anchor + 200).clamp(0, detailScreen.length));
      expect(nearby.contains('maxLines'), isFalse);
      expect(nearby.contains('overflow'), isFalse);
      expect(nearby.contains('TextOverflow.ellipsis'), isFalse);
    });

    test('notification type and timestamp both remain visible on the detail screen', () {
      expect(detailScreen.contains('_typeLabel(_notificationType)'), isTrue);
      expect(detailScreen.contains('TimeFormatHelper.formatDateTime12Hour(_createdAt!)'), isTrue);
    });

    test('the detail screen fetches the complete row by notification id -- single source of '
        'truth, never re-deriving/duplicating the message text', () {
      expect(
        detailScreen.contains("select('title,body,notification_type,created_at')"),
        isTrue,
      );
    });
  });

  group('3. Tapping an intercity notification opens the detail view, never Chat directly', () {
    test('intercity_request is no longer part of the auto-chat-opening condition', () {
      expect(
        notificationService.contains("type == 'chat_message' || type == 'support_message' || type == 'intercity_request'"),
        isFalse,
      );
      expect(
        notificationService.contains("type == 'chat_message' || type == 'support_message'"),
        isTrue,
      );
    });

    test('a dedicated intercity_request branch pushes NotificationDetailScreen', () {
      final anchor = notificationService.indexOf("if (type == 'intercity_request') {");
      expect(anchor, greaterThan(-1));
      final nearby = notificationService.substring(anchor, (anchor + 400).clamp(0, notificationService.length));
      expect(nearby.contains('NotificationDetailScreen('), isTrue);
      expect(nearby.contains('OrderChatScreen'), isFalse);
    });

    test('the rider-mode Travel Plan Details lookup for intercity_request still runs first and '
        'still returns early on success -- unaffected by this fix', () {
      expect(
        notificationService.contains("if (type == 'intercity_request' && isRiderMode) {"),
        isTrue,
      );
      expect(notificationService.contains('if (opened) return;'), isTrue);
      // The dedicated intercity_request detail-view branch must come AFTER (not replace) that
      // early-return, so a successful Travel Plan Details lookup still wins.
      final riderBlockIdx = notificationService.indexOf("if (type == 'intercity_request' && isRiderMode) {");
      final detailBlockIdx = notificationService.indexOf("if (type == 'intercity_request') {\n            NavTrace.begin");
      expect(detailBlockIdx, greaterThan(riderBlockIdx));
    });
  });

  group('4. Chat opens only through an explicit action, via one canonical method', () {
    test('openChatForOrder() is the single place Chat is ever pushed from a notification', () {
      expect(notificationService.contains('void openChatForOrder({'), isTrue);
      final occurrences = 'builder: (_) => OrderChatScreen('.allMatches(notificationService).length;
      expect(occurrences, 1); // only inside openChatForOrder -- no second inline push site
    });

    test('the genuine chat_message/support_message auto-routing calls openChatForOrder (not a '
        'duplicated inline push)', () {
      final anchor = notificationService.indexOf("if (type == 'chat_message' || type == 'support_message') {");
      expect(anchor, greaterThan(-1));
      final nearby = notificationService.substring(anchor, (anchor + 300).clamp(0, notificationService.length));
      expect(nearby.contains('openChatForOrder(orderId: orderId, riderId: riderId, isSupport: isSupport);'), isTrue);
    });

    test('NotificationDetailScreen\'s explicit "Open Chat" button calls the same '
        'NotificationService().openChatForOrder() method -- no second chat-opening implementation', () {
      expect(detailScreen.contains('NotificationService().openChatForOrder('), isTrue);
      expect(detailScreen.contains('OrderChatScreen('), isFalse);
    });

    test('the Open Chat button is conditional on a valid order id being present', () {
      expect(detailScreen.contains('bool get _canOpenChat'), isTrue);
      expect(detailScreen.contains('if (_canOpenChat) ...['), isTrue);
    });
  });

  group('5. Local ride and local parcel notification behavior is unchanged', () {
    test('order_status routing (local ride, local parcel, intercity ride/parcel tracking '
        'screens, rider active-order screen) is reproduced untouched', () {
      final anchor = notificationService.indexOf("} else if (type == 'order_status') {");
      expect(anchor, greaterThan(-1));
      final blockEnd = notificationService.indexOf("} else if (type == 'cod_settlement') {", anchor);
      expect(blockEnd, greaterThan(anchor));
      final nearby = notificationService.substring(anchor, blockEnd);
      expect(nearby.contains('RiderActiveOrderScreen(orderId: orderId)'), isTrue);
      expect(nearby.contains("orderType == 'local_parcel'"), isTrue);
      expect(nearby.contains('ParcelTrackingScreen(orderId: orderId)'), isTrue);
      expect(nearby.contains('IntercityTrackingScreen(orderId: orderId)'), isTrue);
      expect(nearby.contains('RideTrackingScreen(orderId: orderId)'), isTrue);
      // NotificationDetailScreen must never appear in the order_status branch -- that behavior is
      // completely untouched by the Issue 4 fix.
      expect(nearby.contains('NotificationDetailScreen'), isFalse);
    });

    test('order_assignment, cod_settlement, subscription_*, new_rating, and the aggregate match '
        'notification types are all reproduced untouched', () {
      expect(notificationService.contains("if (type == 'order_assignment') {"), isTrue);
      expect(notificationService.contains("} else if (type == 'cod_settlement') {"), isTrue);
      expect(notificationService.contains("} else if (type == 'subscription_expired' || type == 'subscription_expiring') {"), isTrue);
      // 2026-08-24 real-APK root-cause fix: new_rating moved to its own unconditional early `if`
      // (before the orderId gate) -- see rating_notification_tap_routing_regression_test.dart.
      // It is no longer the tail `else if` of the orderId-gated chain.
      expect(notificationService.contains("if (type == 'new_rating') {"), isTrue);
      expect(notificationService.contains("if (type == 'travel_partners_available' || type == 'traveller_available') {"), isTrue);
      // WayDrop Intercity is strictly User-initiated: 'new_travelers_available' (the aggregate
      // rider-side notification whose only destination was the removed Traveller-initiated
      // browse/invite screen) is gone -- see
      // reverse_traveller_invitation_removed_regression_test.dart.
      expect(notificationService.contains("if (type == 'new_travelers_available') {"), isFalse);
    });
  });

  group('6. Intercity notification type routing remains correct otherwise', () {
    test('intercity order_status notifications (trip started/completed for intercity_ride/'
        'intercity_parcel) still route through IntercityTrackingScreen, not the new detail view', () {
      final anchor = notificationService.indexOf(
        "orderType == 'intercity_parcel' || orderType == 'intercity_ride' || (orderType == 'ride' && distanceMeters > 20000)",
      );
      expect(anchor, greaterThan(-1));
    });

    test('the notifications inbox screen still routes every tap through the single shared '
        'handleNotificationTap() -- the Issue 4 fix lives in exactly one place, not duplicated '
        'between the inbox and the FCM tap handlers', () {
      expect(inboxScreen.contains('await NotificationService().handleNotificationTap(data);'), isTrue);
    });
  });
}
