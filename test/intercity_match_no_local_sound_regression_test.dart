// Regression guard for: an intercity parcel match (rider-initiated manual offer, delivered via
// the shared rider_assignments ledger) incorrectly plays the LOCAL incoming-ride
// haptic+order_nearby_sound alert on the traveller's phone, as if it were a local dispatch.
//
// ROOT CAUSE (traced, not assumed): rider_assignments has no order_type column of its own -- it's
// a shared "offer" ledger for BOTH local dispatch AND intercity rider-initiated manual offers.
// RiderHomeTab._showIncomingOrder() played the local haptic+sound unconditionally for every row,
// via two entry points that both lacked order_type: (1) the realtime INSERT handler in
// subscribeAssignments(), whose payload is the raw rider_assignments row with no join, and (2)
// _reconcilePendingAssignments()/_fetchPendingSentAssignments(), whose select joined only
// order_status, not order_type. A parallel backend gap existed too: the
// on_rider_assignment_change() Postgres trigger sent every 'sent' assignment's push notification
// with type: 'order_assignment' regardless of order_type, and send-push-notification/index.ts
// forces the local order_nearby_sound for any type === 'order_assignment' push -- so even a
// backgrounded/killed-app traveller phone would get the local sound for an intercity match.
//
// FIX (three call sites, all order_type-gated, LOCAL ride/local parcel behavior completely
// unchanged in every case):
//   1. _fetchPendingSentAssignments() now also joins orders(order_type).
//   2. subscribeAssignments()'s realtime INSERT handler resolves order_type via a small lookup
//      (_resolveOrderTypeAndShowIncomingOrder) before calling _showIncomingOrder().
//   3. _showIncomingOrder() only fires the haptic+sound when the resolved order_type is NOT a
//      confirmed intercity_ride/intercity_parcel -- an unresolved/unknown type defaults to
//      treating it as local, so a lookup failure can never suppress the existing local sound.
//   4. on_rider_assignment_change() (new migration 20260901000020) now looks up the matched
//      order's order_type and sends type: 'intercity_order_assignment' instead of
//      'order_assignment' for intercity_ride/intercity_parcel -- falling through to
//      send-push-notification's existing default-sound branch (same as intercity_request
//      notifications already use) instead of the local order_nearby_sound.
//
// This is a structural regression guard: it reads the real Dart/SQL source rather than executing
// a live realtime/push pipeline, matching the pattern used throughout this suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final homeTab = _read('lib/features/rider/home/rider_home_tab.dart');
  final triggerMigration = _read(
    'supabase/migrations/20260901000020_intercity_assignment_push_no_local_sound.sql',
  );
  final sendPushFn = _read('supabase/functions/send-push-notification/index.ts');

  group('Foreground/realtime path (RiderHomeTab)', () {
    test('_fetchPendingSentAssignments() joins order_type alongside order_status', () {
      expect(
        homeTab.contains("select('order_id, expires_at, orders(order_status, order_type)')"),
        isTrue,
      );
    });

    test('the realtime INSERT handler resolves order_type before announcing, instead of calling '
        '_showIncomingOrder() directly with the raw (order_type-less) payload', () {
      final subscribeStart = homeTab.indexOf('void subscribeAssignments(String riderId)');
      final subscribeEnd = homeTab.indexOf('void subscribeActiveOrder(String riderId)');
      expect(subscribeStart, greaterThan(-1));
      final body = homeTab.substring(subscribeStart, subscribeEnd);
      expect(body.contains("assignment['assignment_status'] == 'sent' && !alreadyAnnounced"), isTrue);
      expect(body.contains('_resolveOrderTypeAndShowIncomingOrder(assignment)'), isTrue);
    });

    test('_resolveOrderTypeAndShowIncomingOrder looks up orders.order_type by the assignment\'s '
        'order_id, then still respects mounted before showing', () {
      final start = homeTab.indexOf('Future<void> _resolveOrderTypeAndShowIncomingOrder(');
      expect(start, greaterThan(-1));
      final body = homeTab.substring(start, start + 900);
      expect(body.contains("supabase.from('orders').select('order_type').eq('id', orderId).maybeSingle()"), isTrue);
      expect(body.contains('if (!mounted) return;'), isTrue);
      expect(body.contains('_showIncomingOrder(assignment, orderType: orderType);'), isTrue);
    });

    test('_showIncomingOrder() only skips the haptic+sound for a CONFIRMED intercity order_type '
        '-- an unknown/unresolved type still plays it, matching pre-fix (safe) behavior', () {
      final start = homeTab.indexOf('void _showIncomingOrder(Map<String, dynamic> assignment');
      expect(start, greaterThan(-1));
      final end = homeTab.indexOf('void _playOrderNearbySoundThrottled()');
      final body = homeTab.substring(start, end);
      expect(
        body.contains(
          "final isKnownIntercity = resolvedOrderType == 'intercity_ride' || resolvedOrderType == 'intercity_parcel';",
        ),
        isTrue,
      );
      expect(body.contains('if (isKnownIntercity)'), isTrue);
      // The skip branch must return before reaching the haptic/sound calls.
      final skipIdx = body.indexOf('if (isKnownIntercity)');
      final hapticIdx = body.indexOf('HapticFeedback.heavyImpact();');
      final soundIdx = body.indexOf('_playOrderNearbySoundThrottled();');
      expect(skipIdx, lessThan(hapticIdx));
      expect(skipIdx, lessThan(soundIdx));
    });

    test('local ride ("ride") and local parcel ("local_parcel") are never treated as intercity '
        '-- only the two intercity order_type values gate the sound', () {
      final start = homeTab.indexOf('final isKnownIntercity =');
      final line = homeTab.substring(start, homeTab.indexOf(';', start) + 1);
      expect(line.contains("'ride'"), isFalse);
      expect(line.contains("'local_parcel'"), isFalse);
    });

    test('_showIncomingOrder still unconditionally dedupes via _announcedOrders and the busy-rider '
        'guard BEFORE evaluating order_type -- the intercity skip only affects the haptic/sound, '
        'never the announcement bookkeeping other code relies on', () {
      final start = homeTab.indexOf('void _showIncomingOrder(Map<String, dynamic> assignment');
      final end = homeTab.indexOf('void _playOrderNearbySoundThrottled()');
      final body = homeTab.substring(start, end);
      final activeOrdersGuardIdx = body.indexOf('if (activeOrders.isNotEmpty)');
      final announcedAddIdx = body.indexOf('_announcedOrders.add(orderId);');
      final intercityCheckIdx = body.indexOf('final isKnownIntercity');
      expect(activeOrdersGuardIdx, greaterThan(-1));
      expect(announcedAddIdx, greaterThan(activeOrdersGuardIdx));
      expect(intercityCheckIdx, greaterThan(announcedAddIdx));
    });
  });

  group('Background/killed-app push path (on_rider_assignment_change trigger)', () {
    test('the trigger looks up the matched order\'s order_type before choosing the notification '
        'type', () {
      expect(
        triggerMigration.contains(
          "SELECT order_type::text INTO v_order_type FROM public.orders WHERE id = NEW.order_id;",
        ),
        isTrue,
      );
    });

    test('intercity_ride/intercity_parcel matches send a distinct notification type, never '
        "'order_assignment'", () {
      expect(
        triggerMigration.contains(
          "IF v_order_type IN ('intercity_ride', 'intercity_parcel') THEN",
        ),
        isTrue,
      );
      expect(triggerMigration.contains("v_notification_type := 'intercity_order_assignment';"), isTrue);
    });

    test('the default notification_type is still order_assignment, so local ride/parcel matches '
        'are completely unaffected', () {
      expect(triggerMigration.contains("v_notification_type text := 'order_assignment';"), isTrue);
      expect(
        triggerMigration.contains("'type', v_notification_type,"),
        isTrue,
        reason: 'the push payload must use the resolved variable, not a hardcoded order_assignment literal',
      );
    });

    test('send-push-notification/index.ts needs no change: only type === "order_assignment" gets '
        'the local order_nearby_sound -- any other type (including the new '
        'intercity_order_assignment) already falls through to the default/high_importance_channel '
        'branch', () {
      expect(sendPushFn.contains('const isOrderAssignment = notificationType === "order_assignment";'), isTrue);
      expect(sendPushFn.contains('sound: isOrderAssignment ? "order_nearby_sound" : "default"'), isTrue);
    });
  });
}
