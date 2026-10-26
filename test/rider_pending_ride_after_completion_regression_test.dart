// Regression guard for PHASE 3, Issue 1: "Rider A completes Ride A but Ride B (still pending,
// eligible) never appears on the Orders screen without a manual workaround."
//
// A fresh, skeptical re-trace (this investigation, not assumed from prior conclusions) confirmed:
//   - The prior client fix (wasBusy && !hasActiveOrder -> fetchSearchingOrders(), in
//     rider_orders_screen.dart's _pollActiveOrderFallback()) is present, correctly wired, and is
//     the ONLY place hasActiveOrder is ever set (both the 30s poll and the realtime callback funnel
//     through it) -- re-asserted here so it can never silently regress.
//   - The backend rematch trigger chain (assign_nearby_searching_orders_on_rider_freed ->
//     assign_nearby_searching_orders_core, via an async service-role-authenticated PostgREST RPC
//     call) has its WHEN clause and matching rules intact.
//   - The one concrete, checkable gap found: assign_nearby_searching_orders_core had no explicit
//     GRANT EXECUTE statement anywhere in the migration history, unlike its sibling
//     send_order_status_notifications_core, which needed one after an identical gap was found live
//     for that function. A defensive, idempotent grant was added.
//
// Full resolution could not be verified end-to-end without live production log/permission access
// (see the Phase 3 report) -- this guard locks in what IS verifiable from source.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('rider_orders_screen.dart -- busy->free forced refetch still intact', () {
    final source = _read('lib/features/rider/orders/rider_orders_screen.dart');
    final pollStart = source.indexOf('Future<void> _pollActiveOrderFallback() async {');
    final pollEnd = source.indexOf('void startActiveOrderPollTimer() {');
    final pollBody = source.substring(pollStart, pollEnd);

    test('_pollActiveOrderFallback() still snapshots wasBusy and forces a refetch on the '
        'busy->free transition', () {
      expect(pollBody.contains('final wasBusy = hasActiveOrder;'), isTrue);
      final ifIndex = pollBody.indexOf('if ((wasBusy || isFirstPollForThisInstance) && !hasActiveOrder)');
      final catchIndex = pollBody.indexOf('} catch (_) {', ifIndex);
      expect(ifIndex, greaterThanOrEqualTo(0));
      expect(catchIndex, greaterThan(ifIndex));
      expect(pollBody.substring(ifIndex, catchIndex).contains('fetchSearchingOrders();'), isTrue);
      final recovery = pollBody.substring(ifIndex, catchIndex);
      expect(recovery, contains("await supabase.rpc('rider_self_rematch')"));
      expect(recovery, contains('catch (e, stackTrace)'));
      expect(recovery.indexOf('fetchSearchingOrders();'), greaterThan(recovery.indexOf('catch (e, stackTrace)')));
    });

    test('hasActiveOrder is only ever written inside _pollActiveOrderFallback() -- no other path '
        'can bypass the forced-refetch fix', () {
      final assignments = RegExp(r'hasActiveOrder\s*=\s*(true|false);').allMatches(source).length;
      // The field's own `bool hasActiveOrder = false;` declaration, plus the two branches
      // (active.isNotEmpty / else) inside _pollActiveOrderFallback -- exactly 3, nowhere else.
      expect(assignments, 3);
    });
  });

  group('Backend rider-freed rematch pipeline -- WHEN clause and matching rules intact, plus '
      'defensive grant added', () {
    final freedTrigger = _read(
      'supabase/migrations/20260808000000_reassign_orders_when_rider_freed.sql',
    );
    final freedTriggerAsyncBody = _read(
      'supabase/migrations/20260809000001_async_rider_freed_rematch.sql',
    );
    final phase3Migration = _read(
      'supabase/migrations/20260823000000_phase3_intercity_fixes.sql',
    );

    test('the rider-freed trigger still fires exactly on "left an active order status"', () {
      expect(freedTrigger.contains("WHEN (\n    OLD.order_status IN ('accepted', 'rider_arrived', "
          "'picked_up', 'ongoing')\n    AND NEW.order_status NOT IN ('accepted', 'rider_arrived', "
          "'picked_up', 'ongoing')\n    AND NEW.rider_id IS NOT NULL\n)"), isTrue);
    });

    test('the async enqueue still only fires for a confirmed-online rider, and never blocks the '
        "order's own completion on failure", () {
      expect(
        freedTriggerAsyncBody.contains(
          "v_rider.account_status IS DISTINCT FROM 'online'::public.rider_account_status_enum",
        ),
        isTrue,
      );
      expect(freedTriggerAsyncBody.contains('EXCEPTION WHEN OTHERS THEN'), isTrue);
    });

    test('Phase 3 migration adds the defensive GRANT EXECUTE on '
        'assign_nearby_searching_orders_core to service_role', () {
      expect(
        phase3Migration.contains(
          'GRANT EXECUTE ON FUNCTION public.assign_nearby_searching_orders_core(\n'
          '    uuid, uuid, double precision, double precision, public.partner_service_mode_enum\n'
          ') TO service_role;',
        ),
        isTrue,
      );
    });
  });
}
