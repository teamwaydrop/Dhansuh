// Regression guard for PHASE 2, Issues 5, 7, and 8.
//
// ISSUE 5 (verified already correct, no code change): the intercity 'rider_arrived' notification
// branch already existed, already targeted the passenger correctly, and already survived the
// local-ride-only wording migration (20260821000000). This file locks that in as a guard so a
// future change can't silently regress it.
//
// ISSUE 7 ROOT CAUSE: cancellation for an accepted intercity order is reachable by either the
// passenger or the assigned rider (both resolved server-side in update-order-status as isPassenger
// /isDriver), but send_order_status_notifications_core's 'cancelled' branch was actor-blind --
// passenger always got a generic message, and the rider was unconditionally told "cancelled...by
// the customer" even when the rider themselves cancelled. Fix: a new orders.cancelled_by column,
// derived server-side only (never client-trusted), written in the same UPDATE as order_status so
// the trigger sees it with no race, threaded through to the notification core -- gated to
// v_is_intercity so local ride/parcel wording is unchanged in every case.
//
// ISSUE 8: orders.cancel_reason already existed; only a client reason-picker UI was missing.
//
// Structural guard (reads the real source + migration SQL), matching the pattern used throughout
// this suite for backend correctness that can't run against a live Supabase instance here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read(
    'supabase/migrations/20260822000000_intercity_cancellation_actor_and_notification_copy.sql',
  );
  final updateOrderStatus = _read('supabase/functions/update-order-status/index.ts');

  group('Issue 5 -- intercity rider_arrived notification remains correct (no regression)', () {
    test('title/body still exist, unchanged, targeting the passenger', () {
      // Latest live definition of this function is now in the Issue 7/9 migration (this file) --
      // confirm the intercity rider_arrived branch survived byte-for-byte from 20260810000000 /
      // 20260821000000.
      expect(migration.contains("v_title := 'Partner Arrived';"), isTrue);
      expect(
        migration.contains(
          "v_body := 'Your travel partner has arrived at the pickup point. Please meet them. Share OTP ' || v_otp || ' to begin your trip.';",
        ),
        isTrue,
      );
    });
  });

  group('Issue 7 -- orders.cancelled_by, server-derived actor, threaded end to end', () {
    test('migration adds orders.cancelled_by (additive, nullable)', () {
      expect(
        migration.contains('ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS cancelled_by text;'),
        isTrue,
      );
    });

    test('update-order-status derives cancelled_by server-side from isDriver/isPassenger, never '
        'from client input, in the SAME update as order_status', () {
      final cancelBlockStart = updateOrderStatus.indexOf('if (new_status === "cancelled") {');
      final cancelBlockEnd = updateOrderStatus.indexOf('if (new_status === "searching") {', cancelBlockStart);
      final cancelBlock = updateOrderStatus.substring(cancelBlockStart, cancelBlockEnd);
      // RECONCILED AGAINST ACTUAL PRODUCTION (2026-08-23): orders.cancelled_by is the real
      // Postgres enum cancelled_by_enum ('user' | 'rider' | 'admin' | 'system') -- there is no
      // 'passenger' label, so a read-only audit of the linked production project's deployed edge
      // function confirmed production already writes 'user' here; this local file was stale
      // (see migration 20260901000025's header for the full reconciliation trace).
      expect(
        cancelBlock.contains(
          'timestampUpdates.cancelled_by = isDriver ? "rider" : (isPassenger ? "user" : null);',
        ),
        isTrue,
      );
    });

    test('on_order_status_update threads NEW.cancelled_by through as a new, trailing, '
        'DEFAULT-valued parameter (backward compatible)', () {
      expect(
        migration.contains('p_cancelled_by text DEFAULT NULL'),
        isTrue,
      );
      expect(migration.contains("'p_cancelled_by', NEW.cancelled_by"), isTrue);
    });

    test('passenger gets actor-correct wording only when the rider/traveller cancelled an '
        'intercity order; every other case falls back to the original generic copy', () {
      expect(
        migration.contains("IF v_is_intercity AND p_cancelled_by = 'rider' THEN"),
        isTrue,
      );
      expect(migration.contains("v_body := 'Sorry, your Traveller cancelled the trip.';"), isTrue);
      // The ELSE branch (non-intercity, or unknown actor) must be the exact original copy.
      expect(migration.contains("v_body := 'Your order has been cancelled.';"), isTrue);
    });

    test('rider self-cancellation is never self-notified for intercity; passenger-cancelled '
        'wording correctly names the passenger instead of the old generic "by the customer" text', () {
      expect(
        migration.contains('AND NOT (v_is_intercity AND p_cancelled_by = \'rider\')'),
        isTrue,
        reason: 'a traveller who cancels their own order must not get a push about their own action',
      );
      expect(
        migration.contains("WHEN v_is_intercity AND p_cancelled_by = 'passenger' THEN 'The passenger cancelled the trip.'"),
        isTrue,
      );
      // Fallback for every other combination must still be the original wording.
      expect(
        migration.contains("ELSE 'The order you accepted has been cancelled by the customer.'"),
        isTrue,
      );
    });

    test('local ride/parcel cancellation wording is untouched -- the new branches are gated to '
        'v_is_intercity, never reachable for a non-intercity order', () {
      // Every new conditional this migration adds for 'cancelled' wording is qualified by
      // v_is_intercity; a bare, ungated `p_cancelled_by = 'rider'` branch would be a scope leak
      // into local ride/parcel wording, which Phase 2 must never touch.
      final cancelledBranchStart = migration.indexOf("ELSIF p_new_status = 'cancelled' THEN");
      final cancelledBranchEnd = migration.indexOf("ELSIF p_new_status = 'expired' THEN");
      final cancelledBranch = migration.substring(cancelledBranchStart, cancelledBranchEnd);
      expect(cancelledBranch.contains("IF v_is_intercity AND p_cancelled_by = 'rider' THEN"), isTrue);
      // The only actor check in this branch is the gated one above -- confirm there's exactly one
      // occurrence of the raw comparison, and it's the gated form (no separate, un-gated check).
      expect("p_cancelled_by = 'rider'".allMatches(cancelledBranch).length, 1);
    });

    test('cascade_cancel_travel_plan_dependents tags its direct orders update with '
        "cancelled_by = 'rider' (the travel-plan-cancelling traveller is the actor)", () {
      expect(migration.contains("cancelled_by = 'rider',"), isTrue);
      expect(
        migration.contains("cancel_reason = 'Traveller cancelled the travel plan.',"),
        isTrue,
        reason: 'pre-existing cancel_reason text must survive unchanged alongside the new column',
      );
    });
  });

  group('Issue 8 -- cancellation reason picker (User/Passenger cancel flow)', () {
    final source = _read('lib/features/intercity/shared/screens/intercity_tracking_screen.dart');

    test('a reasonable, non-empty list of cancellation reasons exists, ending with Other', () {
      final listStart = source.indexOf('static const List<String> _cancellationReasons = [');
      final listEnd = source.indexOf('];', listStart);
      final list = source.substring(listStart, listEnd);
      expect(list.contains('Plans changed'), isTrue);
      expect(list.contains('Found another option'), isTrue);
      expect(list.contains('Other'), isTrue);
    });

    test('the selected reason (not a hardcoded literal) is sent as cancel_reason to cancel-order', () {
      final performCancelStart = source.indexOf('Future<void> _performCancel(');
      final performCancelBody = source.substring(performCancelStart, performCancelStart + 1600);
      expect(
        performCancelBody.contains("'cancel_reason': reason ?? 'Cancelled by user from tracking screen',"),
        isTrue,
      );
    });

    test('cancellation still proceeds even if no specific reason chip was picked (Other with no '
        'text, or dialog dismissed via the Yes button with nothing selected)', () {
      expect(
        source.contains("final reason = selectedReason == 'Other' && otherText.isNotEmpty"),
        isTrue,
      );
      expect(source.contains("(selectedReason ?? 'Other')"), isTrue);
    });
  });
}
