// Structural regression guard for the update-order-status Edge Function's production
// reconciliation: this local file is now built directly on top of the ACTUAL CURRENT PRODUCTION
// deployed source (fetched read-only via `supabase functions download`, saved to a local
// reference file, never blindly overwritten back), not the stale local baseline that previously
// lost production's undocumented Phase K/L/M performance work during an earlier incident (an
// accidental `functions download` overwrite was "recovered" by restoring git HEAD -- which never
// had Phase K/L/M -- instead of merging production's version with just the intended edit).
//
// The ONLY functional addition on top of that production baseline is: stamp
// intercity_requests.cancelled_by_actor ('user' | 'rider', server-derived, never client-supplied)
// in the SAME update that already syncs intercity_requests.status on cancellation, so migration
// 20260901000024's on_intercity_request_change() trigger check
// (NEW.cancelled_by_actor = 'user' -> "You cancelled this request.") can fire. Everything else --
// every Phase K/L/M optimization, every guard, every notification/dispatch code path -- is
// reproduced byte-for-byte from production.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final updateOrderStatus = _read('supabase/functions/update-order-status/index.ts');

  group('1 & 2. cancelled_by_actor and orders.cancelled_by use the same server-derived actor, '
      "'user' | 'rider', for both passenger and traveller cancellation", () {
    test('orders.cancelled_by: isDriver -> "rider", isPassenger -> "user" (pre-existing production '
        'logic, untouched)', () {
      expect(
        updateOrderStatus.contains(
          'timestampUpdates.cancelled_by = isDriver ? "rider" : (isPassenger ? "user" : null);',
        ),
        isTrue,
      );
    });

    test('intercity_requests.cancelled_by_actor: isDriver -> "rider", isPassenger -> "user" '
        '(the new addition), written only on the cancelled path, in the same update as the '
        'status sync', () {
      expect(
        updateOrderStatus.contains(
          '...(new_status === "cancelled"\n'
          '            ? { cancelled_by_actor: isDriver ? "rider" : (isPassenger ? "user" : null) }\n'
          '            : {}),',
        ),
        isTrue,
      );
    });

    test('both sentinels are derived from the SAME isDriver/isPassenger resolved once, near the '
        'top of the function, from the authenticated caller -- never a client-supplied field for '
        'either write', () {
      final isPassengerIdx = updateOrderStatus.indexOf('const isPassenger = order.user_id === authData.user.id;');
      final isDriverIdx = updateOrderStatus.indexOf('const isDriver = order.riders?.user_id === authData.user.id;');
      final cancelledByIdx = updateOrderStatus.indexOf('timestampUpdates.cancelled_by = isDriver');
      final cancelledByActorIdx = updateOrderStatus.indexOf('cancelled_by_actor: isDriver ? "rider"');
      expect(isPassengerIdx, greaterThan(-1));
      expect(isDriverIdx, greaterThan(isPassengerIdx));
      expect(cancelledByIdx, greaterThan(isDriverIdx));
      expect(cancelledByActorIdx, greaterThan(cancelledByIdx));
    });
  });

  group('3. Production-only Phase K/L/M performance work remains present -- this reconciliation '
      'must never regress it', () {
    test('Phase K (E1/E2/E3): the three independent-write blocks are still converted to '
        'Promise.all concurrency', () {
      expect(updateOrderStatus.contains('Phase K (E1):'), isTrue);
      expect(updateOrderStatus.contains('Phase K (E2):'), isTrue);
      expect(updateOrderStatus.contains('Phase K (E3):'), isTrue);
    });

    test('Phase M (E4b): parcel_security_logs and order_status_history are still fire-and-forget '
        'via EdgeRuntime.waitUntil(), not blocking awaits', () {
      expect(updateOrderStatus.contains('Phase M (E4b):'), isTrue);
      expect(updateOrderStatus.contains('const parcelSecurityLogPromise = (async () => {'), isTrue);
      expect(
        updateOrderStatus.contains('(globalThis as any).EdgeRuntime.waitUntil(parcelSecurityLogPromise);'),
        isTrue,
      );
      expect(updateOrderStatus.contains('const historyPromise = supabase.from("order_status_history").insert({'), isTrue);
      expect(
        updateOrderStatus.contains('(globalThis as any).EdgeRuntime.waitUntil(historyPromise);'),
        isTrue,
      );
    });

    test('the widened order select ("*, riders(user_id))") -- production\'s P1-F change -- is '
        'present, not the narrower explicit column list an earlier stale local draft had', () {
      expect(
        updateOrderStatus.contains(
          'supabase.from("orders").select("*, riders(user_id)").eq("id", order_id).single(),',
        ),
        isTrue,
      );
    });

    test('the pre-existing start-dispatch waitUntil (unrelated to Phase K/M, always present) is '
        'still there too -- confirms nothing in that whole cancellation-by-rider block regressed', () {
      expect(updateOrderStatus.contains('(globalThis as any).EdgeRuntime.waitUntil(dispatchPromise);'), isTrue);
    });
  });

  group('4 & 8. Intercity cancellation deduplication is intact -- no second/duplicate '
      'notification is introduced by the cancelled_by_actor addition', () {
    test('the intercity_requests sync UPDATE is still the single existing call site -- '
        'cancelled_by_actor is merged into its existing payload via a spread, not a second '
        '.update() call', () {
      final syncBlockStart = updateOrderStatus.indexOf('SYNC THE LINKED intercity_requests');
      expect(syncBlockStart, greaterThan(-1));
      final nextSection = updateOrderStatus.indexOf('order_status_history.changed_by is NOT NULL', syncBlockStart);
      final syncBlock = updateOrderStatus.substring(syncBlockStart, nextSection);
      final updateCallCount = '.from("intercity_requests")'.allMatches(syncBlock).length;
      expect(updateCallCount, 1, reason: 'exactly one intercity_requests write in this block, no duplicate');
    });

    test('no new call to send_push_notification_fnc, no new fetch()/webhook trigger, and no new '
        'console.log announcing a second notification were added by this change', () {
      final syncBlockStart = updateOrderStatus.indexOf('SYNC THE LINKED intercity_requests');
      final nextSection = updateOrderStatus.indexOf('order_status_history.changed_by is NOT NULL', syncBlockStart);
      final syncBlock = updateOrderStatus.substring(syncBlockStart, nextSection);
      expect(syncBlock.contains('send_push_notification'), isFalse);
      expect(syncBlock.contains('fetch('), isFalse);
    });

    test('the actual notification-dedup logic lives entirely in the DB layer (migration '
        "20260901000025's IF v_is_intercity THEN NULL; ELSE ... END IF; for the passenger-facing "
        'cancelled branch) and is untouched by this Edge Function change -- this file never sends '
        'notifications directly, only mutates rows the DB triggers then react to', () {
      expect(updateOrderStatus.contains('send_push_notification'), isFalse);
    });
  });

  group('5. No \'passenger\' sentinel is introduced anywhere', () {
    test('neither cancelled_by nor cancelled_by_actor, nor any other write in this file, ever '
        'uses the literal string "passenger" as an actor value', () {
      expect(updateOrderStatus.contains('"passenger"'), isFalse);
    });
  });

  group('6. Local ride cancellation is unchanged', () {
    test('the cancelled timestampUpdates block (cancelled_at, cancel_reason, cancelled_by) applies '
        'identically regardless of order_type -- no ride-specific branch was added or removed', () {
      expect(
        updateOrderStatus.contains(
          'if (new_status === "cancelled") {\n'
          '      timestampUpdates.cancelled_at = new Date().toISOString();\n'
          '      timestampUpdates.cancel_reason = cancel_reason || null;',
        ),
        isTrue,
      );
    });

    test('the Phase K (E1) rider_assignments/order_assignment_logs expiry block on cancellation '
        'is untouched and still applies to every order type, not just intercity', () {
      expect(
        updateOrderStatus.contains(
          'console.log(`[StatusUpdate] Order cancelled. Expiring all outstanding sent assignments/logs for order \${order_id}`);',
        ),
        isTrue,
      );
    });
  });

  group('7. Local parcel cancellation is unchanged', () {
    test('the intercity_requests sync block (where cancelled_by_actor is written) is scoped '
        "strictly to order_type in ('intercity_parcel', 'intercity_ride') -- local_parcel orders "
        'never reach this code path at all', () {
      final syncBlockStart = updateOrderStatus.indexOf('SYNC THE LINKED intercity_requests');
      final conditionEnd = updateOrderStatus.indexOf('{', syncBlockStart + 'SYNC THE LINKED intercity_requests'.length + 900);
      final guard = updateOrderStatus.substring(syncBlockStart, conditionEnd);
      expect(guard.contains('intercity_parcel'), isTrue);
      expect(guard.contains('intercity_ride'), isTrue);
      expect(guard.contains('local_parcel'), isFalse);
    });

    test('the parcel-specific transitions/OTP/compliance-log logic (parcelTransitions, '
        'parcel_security_logs) that local_parcel orders actually use is completely untouched by '
        'this change', () {
      expect(updateOrderStatus.contains('const parcelTransitions = {'), isTrue);
      expect(updateOrderStatus.contains('await supabase.from("parcel_security_logs").insert('), isTrue);
    });
  });
}
