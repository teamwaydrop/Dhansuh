// Regression guard for Issue 4: when a User/passenger cancels an intercity booking, the
// Traveller's push notification correctly named the actor ("The passenger cancelled the trip.")
// but never included the actual, already-stored cancellation reason.
//
// ROOT CAUSE: orders.cancel_reason was collected (intercity_tracking_screen.dart's cancellation
// flow -> update-order-status/index.ts -> orders.cancel_reason) and already sat on the very row
// on_order_status_update() fires from, but neither that trigger nor
// send_order_status_notifications_core() ever threaded it through to the traveller's notification
// body.
//
// FIX (20260901000028_intercity_cancel_reason_in_traveller_notification.sql), PROVEN via real
// execution against a local Supabase/Docker instance:
//   - p_cancelled_by='user', a real reason        -> "The passenger cancelled this booking.
//                                                      Reason: <reason>."
//   - p_cancelled_by='user', reason NULL           -> "...Reason: not specified." (never a literal
//                                                      "null" or an empty "Reason: .")
//   - p_cancelled_by='rider' (traveller self-cancel) -> zero notifications inserted (unchanged
//                                                      self-notify suppression)
//   - non-intercity order_type='ride', any actor    -> unchanged generic wording, byte-for-byte
//
// Migration 24 (cancelled_by_actor='user' on intercity_requests, notifying the PASSENGER with
// self-attributed "You cancelled this request.") and Migration 25 (local_parcel "Drop Partner"
// wording) are both left completely untouched -- this fix only threads one new string into the
// TRAVELLER's existing cancellation notification body.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read('supabase/migrations/20260901000028_intercity_cancel_reason_in_traveller_notification.sql');
  final migration24 = _read('supabase/migrations/20260901000024_intercity_request_cancel_actor_column_and_wording.sql');
  final migration25 = _read('supabase/migrations/20260901000025_local_parcel_partner_notification_wording.sql');

  group('1. THE FIX: traveller notification names the actual stored cancellation reason', () {
    test('send_order_status_notifications_core() gains p_cancel_reason and uses it in the '
        'existing v_is_intercity AND p_cancelled_by = \'user\' branch', () {
      expect(migration.contains('p_cancel_reason text DEFAULT NULL::text'), isTrue);
      expect(
        migration.contains(
          "'The passenger cancelled this booking. Reason: '\n"
          '                            || COALESCE(NULLIF(btrim(p_cancel_reason), \'\'), \'not specified\')\n'
          "                            || '.'",
        ),
        isTrue,
      );
    });

    test('a null/blank reason falls back to \'not specified\' -- never renders a literal "null"', () {
      expect(migration.contains("COALESCE(NULLIF(btrim(p_cancel_reason), ''), 'not specified')"), isTrue);
    });

    test('on_order_status_update() threads NEW.cancel_reason through as p_cancel_reason to the '
        'RPC call -- the reason was already on the row, just never forwarded', () {
      expect(migration.contains("'p_cancel_reason', NEW.cancel_reason"), isTrue);
    });

    test('the stale 10-parameter overload is dropped before the 11-parameter replacement is '
        'created, so PostgREST RPC dispatch is never ambiguous', () {
      final dropIdx = migration.indexOf('DROP FUNCTION IF EXISTS public.send_order_status_notifications_core(');
      final createIdx = migration.indexOf('CREATE OR REPLACE FUNCTION public.send_order_status_notifications_core(');
      expect(dropIdx, greaterThan(-1));
      expect(createIdx, greaterThan(dropIdx));
    });
  });

  group('2. Unrelated behavior is completely unchanged', () {
    test('the traveller-cancelled-their-own-trip self-notify skip is preserved byte-for-byte', () {
      expect(
        migration.contains(
          "IF p_new_status = 'cancelled' AND p_rider_id IS NOT NULL\n"
          "           AND NOT (v_is_intercity AND p_cancelled_by = 'rider') THEN",
        ),
        isTrue,
      );
    });

    test('the non-intercity ELSE wording for the rider-cancellation notification is unchanged', () {
      expect(
        migration.contains("ELSE 'The order you accepted has been cancelled by the customer.'"),
        isTrue,
      );
    });

    test('Migration 24 (cancelled_by_actor=\'user\' self-attributed passenger wording) is not '
        'modified by this fix', () {
      expect(migration24.contains("IF NEW.cancelled_by_actor = 'user' THEN"), isTrue);
      expect(migration24.contains("v_body := 'You cancelled this request.';"), isTrue);
    });

    test('Migration 25 (local_parcel "Drop Partner" wording) is not modified by this fix', () {
      expect(migration25.contains('Drop Partner'), isTrue);
    });
  });
}
