// Regression guard: a 'new_rating' notification's own body already carries the complete rating
// direction sentence + full written feedback (see 20260901000032_rating_notification_full_feedback.sql
// and rating_notification_full_feedback_regression_test.dart) -- but tapping it did NOTHING in the
// real, tested release APK.
//
// TRUE ROOT CAUSE (proven against real production data, 2026-08-24 -- the FIRST attempted fix,
// covered by the superseded assertions below, was wrong): on_rider_review_insert() always stamps a
// real 'order_id' into the notification payload (jsonb_build_object(..., 'order_id', NEW.order_id,
// ...)) -- a rating is always tied to a completed order, so `data['order_id']` is NEVER null/empty
// for a real new_rating notification (confirmed live: 5/5 most recent production new_rating rows
// all have a non-null reference_id/payload order_id). handleNotificationTap()'s control flow is:
//   if (orderId != null && orderId.isNotEmpty) { ... only intercity_request/chat_message/
//     support_message/order_status are handled inside here ... }
//   else if (type == 'cod_settlement') { ... }
//   else if (type == 'new_rating') { ... }      <-- the FIRST fix's location
// Because orderId is always present for a real rating, control always enters the first `if` block,
// matches none of its type checks, and silently falls through doing nothing -- the `else if (type ==
// 'new_rating')` branch was structurally unreachable dead code for every real tap. This is exactly
// why the first fix (confirmed present in the built APK via source grep) still produced no
// navigation when tested on a real device: grepping for `NotificationDetailScreen(` in the file
// proves the code exists, not that the branch is reachable.
//
// REAL FIX: 'new_rating' is now checked as its own unconditional, early `if` -- BEFORE the orderId
// gate -- exactly mirroring the existing order_assignment/travel_partners_available early-return
// pattern immediately above it. Unlike intercity_request (which genuinely needs the order lookup
// for its rider-mode Travel Plan Details routing), new_rating never reads orderId/orderType at all,
// so gating it behind that lookup was never necessary. This makes the branch reachable regardless of
// whether orderId is present -- true for both the in-app inbox tap path
// (notifications_inbox_screen.dart's _onTapNotification, which sets
// data['order_id'] = notification['reference_id'] ?? payload['order_id']) and a raw FCM/local
// notification tap (same payload shape), for both rating directions, and in every app state
// (foreground onMessage tap, onMessageOpenedApp, getInitialMessage/killed-app tap, and the
// FlutterLocalNotificationsPlugin onDidReceiveNotificationResponse callback) -- all four converge on
// the exact same handleNotificationTap(data) entrypoint, so fixing it once fixes every tap surface.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final notificationService =
      _read('lib/modules/notifications/services/notification_service.dart');
  final detailScreen = _read('lib/modules/notifications/screens/notification_detail_screen.dart');
  final inboxScreen = _read('lib/modules/notifications/screens/notifications_inbox_screen.dart');
  final ratingTrigger =
      _read('supabase/migrations/20260901000032_rating_notification_full_feedback.sql');

  group('0. Proves the TRUE root cause: order_id is always present for a real new_rating '
      'notification, so any fix gated behind "orderId == null" is unreachable', () {
    test('on_rider_review_insert() always includes order_id in the notification payload', () {
      expect(ratingTrigger.contains("'order_id', NEW.order_id"), isTrue);
    });

    test('the in-app inbox tap handler derives order_id from reference_id/payload for EVERY '
        'notification, not conditionally', () {
      expect(
        inboxScreen.contains("'order_id': notification['reference_id'] ?? payload['order_id'],"),
        isTrue,
      );
    });
  });

  group('1/2/3. new_rating tap routes to NotificationDetailScreen unconditionally -- BEFORE the '
      'orderId gate, not as its dead tail else-if -- for either recipient', () {
    late int newRatingStart;
    late int orderIdGateStart;
    late String newRatingBranch;

    setUpAll(() {
      newRatingStart = notificationService.indexOf("if (type == 'new_rating') {");
      expect(newRatingStart, greaterThan(-1), reason: 'the new_rating branch must still exist');
      orderIdGateStart = notificationService.indexOf(
          'if (orderId != null && orderId.isNotEmpty) {', newRatingStart);
      expect(orderIdGateStart, greaterThan(-1));
      final end = notificationService.indexOf('\n      }', newRatingStart);
      expect(end, greaterThan(newRatingStart));
      newRatingBranch = notificationService.substring(newRatingStart, end);
    });

    test('THE ACTUAL FIX: new_rating is checked BEFORE the orderId gate, so it can never be '
        'skipped by a real notification carrying a non-null order_id', () {
      expect(orderIdGateStart, greaterThan(newRatingStart));
    });

    test('is NOT written as `} else if (type == \'new_rating\')` (the unreachable, previously '
        'broken form -- the tail of the orderId-gated if/else chain)', () {
      expect(notificationService.contains("} else if (type == 'new_rating') {"), isFalse);
    });

    test('routes to NotificationDetailScreen', () {
      expect(newRatingBranch.contains('builder: (_) => NotificationDetailScreen('), isTrue);
    });

    test('returns immediately after navigating (does not fall through into the orderId-gated '
        'block or any other branch)', () {
      expect(newRatingBranch.trim().endsWith('return;'), isTrue);
    });

    test('does NOT route to RiderMainNavigationScreen (the old rider-side History/Reviews tab '
        'destination)', () {
      expect(newRatingBranch.contains('RiderMainNavigationScreen('), isFalse);
    });

    test('does NOT route to ActivityTab (the old passenger-side destination)', () {
      expect(newRatingBranch.contains('ActivityTab()'), isFalse);
    });

    test('the fix is direction-agnostic -- no appMode/AppMode.rider branch inside new_rating '
        'routing anymore (both recipients get the identical, correct treatment)', () {
      expect(newRatingBranch.contains('appMode'), isFalse);
      expect(newRatingBranch.contains('AppMode.rider'), isFalse);
    });

    test('the now-unused ActivityTab import was removed, not left dangling', () {
      expect(notificationService.contains("import 'package:waydrop/features/user/activity/activity_tab.dart';"), isFalse);
    });
  });

  group('4. Full notification body is preserved when navigating (same pattern as '
      "intercity_request's own, already-working NotificationDetailScreen push)", () {
    test('notificationId and the full tap payload (tapData) are both passed through, exactly '
        'like the intercity_request branch', () {
      final start = notificationService.indexOf("if (type == 'new_rating') {");
      final end = notificationService.indexOf('\n      }', start);
      final branch = notificationService.substring(start, end);
      expect(branch.contains("notificationId: data['notification_id']?.toString(),"), isTrue);
      expect(branch.contains('tapData: data,'), isTrue);
    });

    test('NotificationDetailScreen re-fetches the complete, authoritative title/body/'
        'notification_type straight from the notifications row by id -- never re-derives or '
        'truncates it', () {
      expect(detailScreen.contains(".select('title,body,notification_type,created_at')"), isTrue);
      expect(detailScreen.contains("_body = row['body']?.toString() ?? _body;"), isTrue);
    });

    test('NotificationDetailScreen already recognizes new_rating for its type label (no change '
        'needed here -- this file is untouched by this fix)', () {
      expect(detailScreen.contains("case 'new_rating':"), isTrue);
      expect(detailScreen.contains("return 'Rating';"), isTrue);
    });
  });

  group('5/6/7. The detail screen shows the complete body -- no maxLines/overflow -- for long, '
      'short, and empty-feedback cases alike', () {
    test('the body Text widget has no maxLines/TextOverflow constraint', () {
      final anchor = detailScreen.indexOf('SelectableText(');
      expect(anchor, greaterThan(-1));
      final block = detailScreen.substring(anchor, anchor + 300);
      expect(block.contains('maxLines'), isFalse);
      expect(block.contains('TextOverflow'), isFalse);
      expect(block.contains('_body'), isTrue);
    });

    test('nothing in NotificationDetailScreen calls substring()/truncates the body it displays', () {
      expect(detailScreen.contains('.substring('), isFalse);
    });
  });

  group('8. The notification inbox list preview is completely unchanged (intentional 2-line '
      'preview, full text remains reachable via the detail screen only)', () {
    test('the inbox list item still uses maxLines: 2 and TextOverflow.ellipsis', () {
      expect(inboxScreen.contains('maxLines: 2,'), isTrue);
      expect(inboxScreen.contains('overflow: TextOverflow.ellipsis,'), isTrue);
    });

    test('the inbox list tap still routes through the single shared handleNotificationTap() -- '
        'not a second, duplicated implementation', () {
      expect(inboxScreen.contains('await NotificationService().handleNotificationTap(data);'), isTrue);
    });
  });

  group('9. Every other notification type\'s routing is untouched', () {
    test('order_assignment/travel_partners_available (the two other unconditional early '
        'branches) are still present and still precede the orderId gate', () {
      expect(notificationService.contains("if (type == 'order_assignment') {"), isTrue);
      expect(
        notificationService.contains(
          "if (type == 'travel_partners_available' || type == 'traveller_available') {",
        ),
        isTrue,
      );
    });

    test('intercity_request still routes to NotificationDetailScreen from inside the orderId-'
        'gated block, unaffected -- it genuinely needs the order lookup', () {
      expect(notificationService.contains("if (type == 'intercity_request') {"), isTrue);
      final start = notificationService.indexOf("if (type == 'intercity_request') {");
      final block = notificationService.substring(start, start + 400);
      expect(block.contains('NotificationDetailScreen('), isTrue);
    });

    test('chat_message/support_message, order_status, order_assignment, cod_settlement, and '
        'subscription_* routing are all still present, unchanged', () {
      expect(notificationService.contains("if (type == 'chat_message' || type == 'support_message') {"), isTrue);
      expect(notificationService.contains("} else if (type == 'order_status') {"), isTrue);
      expect(notificationService.contains("if (type == 'order_assignment') {"), isTrue);
      expect(notificationService.contains("} else if (type == 'cod_settlement') {"), isTrue);
      expect(notificationService.contains("} else if (type == 'subscription_expired' || type == 'subscription_expiring') {"), isTrue);
    });

    test('the orderId-gated if/else chain\'s tail is now cod_settlement/subscription_*, not '
        'new_rating', () {
      final tailStart = notificationService.indexOf("} else if (type == 'cod_settlement') {");
      expect(tailStart, greaterThan(-1));
      final tailEnd = notificationService.indexOf('\n    } catch (e) {', tailStart);
      final tail = notificationService.substring(tailStart, tailEnd);
      expect(tail.contains("type == 'new_rating'"), isFalse);
    });
  });
}
