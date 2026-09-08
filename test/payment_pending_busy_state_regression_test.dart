// Regression guard for the payment_pending busy-state fix (Issue 1 follow-up).
//
// BACKGROUND: a live controlled device test proved a rider sitting in payment_pending on Ride A
// could still be offered and accept Ride B, and that Ride A's own ongoing->payment_pending
// transition (not its actual payment_pending->completed/delivered finish) was what fired the
// rider-freed rematch. Investigation found the codebase already has a canonical "is this rider
// busy" predicate, rider_is_on_active_trip() (20260720000004), which correctly includes
// payment_pending and is already followed by RiderHomeTab._isOrderActivelyBusy() -- but
// find_nearby_riders() was silently reverted off it by 20260726000004 (a tax-due migration that
// appears to have re-created the function from an older base by accident), and
// trigger_assign_nearby_orders_on_rider_freed, prevent_local_ride_assignment_to_busy_rider,
// accept-order/index.ts, and RiderOrdersScreen each independently duplicated the resulting
// narrower, payment_pending-excluding list.
//
// FIX (20260825000000_payment_pending_busy_state_fix.sql + accept-order/index.ts +
// rider_orders_screen.dart + the still-undeployed 20260824000000 backstop): payment_pending joins
// the blocking set everywhere it was missing; find_nearby_riders() and accept-order now call the
// canonical rider_is_on_active_trip() instead of maintaining their own copies. Payment settlement
// logic itself (payment_pending->completed/delivered guards, Cashfree/Personal UPI/cash
// resolution) is completely untouched -- this only changes who can be newly assigned/accept a
// searching order while their own current order is at a given status.
//
// This file is a structural regression guard (reads the real migration/edge-function/Dart source,
// following the pattern already used throughout this test suite for backend correctness that
// can't run against a live Supabase instance in a plain unit test).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final busyStateFix = _read(
    'supabase/migrations/20260825000000_payment_pending_busy_state_fix.sql',
  );
  final backstop = _read(
    'supabase/migrations/20260824000000_backstop_redispatch_freed_riders.sql',
  );
  final acceptOrder = _read('supabase/functions/accept-order/index.ts');
  final riderOrdersScreen = _read(
    'lib/features/rider/orders/rider_orders_screen.dart',
  );
  final canonicalPredicate = _read(
    'supabase/migrations/20260724000002_upi_payment_pending_flow_support.sql',
  );

  group('payment_pending busy-state fix -- coordinated invariants', () {
    test('1. prevent_local_ride_assignment_to_busy_rider blocks a new assignment while '
        'payment_pending', () {
      final shape = RegExp(
        r"AND bo\.order_status IN \(\s*'accepted',\s*'rider_arrived',\s*'picked_up',\s*'ongoing',"
        r"\s*'payment_pending'\s*\)",
      );
      expect(
        shape.hasMatch(busyStateFix),
        isTrue,
        reason: 'the busy-rider INSERT guard must reject a new rider_assignments row while the '
            "rider's current local ride is at payment_pending",
      );
    });

    test('2. accept-order rejects acceptance of another ride while payment_pending, via the '
        'canonical predicate', () {
      // Format-tolerant: the PERF pass (parallelizing this RPC alongside the tax-due/COD-limit
      // checks via Promise.all) reformatted this call onto a single line, but it must still be the
      // exact same canonical RPC + param, not a reintroduced drifted copy.
      final callShape = RegExp(
        r'supabase\.rpc\(\s*"rider_is_on_active_trip",\s*\{\s*p_rider_id:\s*rider_id\s*\}\s*,?\s*\)',
      );
      expect(
        callShape.hasMatch(acceptOrder),
        isTrue,
        reason: 'accept-order must defer to the single canonical busy predicate instead of '
            'maintaining its own drifted copy',
      );
      // The drifted, payment_pending-excluding duplicate must be gone, not just supplemented.
      expect(acceptOrder.contains('alwaysActiveStatuses'), isFalse);
      // The canonical predicate itself must actually include payment_pending -- this is the fact
      // accept-order now depends on, so it must never silently regress out from under it.
      expect(
        canonicalPredicate.contains(
          "'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending'",
        ),
        isTrue,
      );
    });

    test('3. ongoing -> payment_pending does NOT trigger rider-freed rematch', () {
      // With payment_pending in both the OLD and NEW blocking lists, this specific transition can
      // never satisfy "NEW.order_status NOT IN (blocking set)" -- the trigger's own WHEN clause
      // structurally cannot fire for it.
      final whenClause = RegExp(
        r'WHEN \(\s*'
        r"OLD\.order_status IN \('accepted', 'rider_arrived', 'picked_up', 'ongoing', "
        r"'payment_pending'\)\s*"
        r"AND NEW\.order_status NOT IN \('accepted', 'rider_arrived', 'picked_up', 'ongoing', "
        r"'payment_pending'\)\s*"
        r'AND NEW\.rider_id IS NOT NULL\s*'
        r'\)',
      );
      expect(
        whenClause.hasMatch(busyStateFix),
        isTrue,
        reason: 'payment_pending must be in both sides of the WHEN clause so ongoing->'
            'payment_pending can never satisfy it',
      );
    });

    test('4. payment_pending -> completed DOES trigger rider-freed rematch', () {
      // 'completed' is absent from the NEW-side blocking list, and 'payment_pending' is present
      // on the OLD side (asserted above) -- so OLD IN blocking AND NEW NOT IN blocking holds for
      // this transition.
      expect(busyStateFix.contains("NEW.order_status NOT IN ('accepted', 'rider_arrived', "
          "'picked_up', 'ongoing', 'payment_pending')"), isTrue);
      expect(busyStateFix.contains("'completed'"), isFalse,
          reason: "'completed' must never appear inside the blocking-set literal itself -- it is "
              'a free/available status, not a busy one');
    });

    test('5. payment_pending -> delivered DOES trigger rematch (parcel completion)', () {
      // Same WHEN clause covers both ride ('completed') and parcel ('delivered') terminal
      // statuses -- neither is ever added to the blocking set literal.
      expect(busyStateFix.contains("'delivered'"), isFalse,
          reason: "'delivered' must never appear inside the blocking-set literal -- parcel "
              'delivery completion must free the rider exactly like ride completion does');
    });

    test('6. concurrent async trigger + backstop still cannot create duplicate assignments', () {
      // This fix does not touch assign_nearby_searching_orders_core() or the unique constraint
      // its INSERT relies on -- both must remain exactly as proven safe in the prior race-
      // condition review.
      expect(
        busyStateFix.contains('assign_nearby_searching_orders_core'),
        isFalse,
        reason: 'this fix must not touch assign_nearby_searching_orders_core() itself -- only '
            'the busy-check callers around it',
      );
      final uniqueConstraint = _read(
        'supabase/migrations/20260808000004_add_rider_assignments_unique_order_rider.sql',
      );
      expect(
        uniqueConstraint.contains(
          'ADD CONSTRAINT rider_assignments_order_id_rider_id_key UNIQUE (order_id, rider_id)',
        ),
        isTrue,
      );
    });

    test('7. existing busy states (accepted/rider_arrived/picked_up/ongoing) remain blocked', () {
      expect(busyStateFix.contains("'accepted', 'rider_arrived', 'picked_up', 'ongoing', "
          "'payment_pending'"), isTrue,
          reason: 'payment_pending must be ADDED to the existing blocking set, never replace any '
              'of the states already in it');
    });

    test('8. completed/delivered riders become eligible again (not in any blocking list here)',
        () {
      for (final blockingList in [
        // trigger WHEN clause (both sides use the same literal)
        RegExp(r"IN \('accepted', 'rider_arrived', 'picked_up', 'ongoing', 'payment_pending'\)"),
      ]) {
        final matches = blockingList.allMatches(busyStateFix).length;
        expect(matches, greaterThanOrEqualTo(2),
            reason: 'both the OLD and NEW sides of the WHEN clause must use the identical '
                '5-state blocking literal, with completed/delivered never included');
      }
    });

    test('find_nearby_riders() uses the canonical rider_is_on_active_trip() predicate, not a '
        'duplicated inline list', () {
      expect(
        busyStateFix.contains('AND NOT public.rider_is_on_active_trip(r.id)'),
        isTrue,
      );
      // The old, narrower inline NOT EXISTS block must be gone from the new definition, not left
      // alongside the canonical call.
      expect(
        RegExp(r"NOT EXISTS\s*\(\s*SELECT 1\s*FROM orders o\s*WHERE\s*o\.rider_id = r\.id\s*"
                r"AND o\.order_status IN \(\s*'accepted',")
            .hasMatch(busyStateFix),
        isFalse,
        reason: 'find_nearby_riders must not carry both the old inline list and the new '
            'canonical call -- only the canonical predicate should remain',
      );
    });

    test('rider_orders_screen.dart treats payment_pending as an active order, other polling '
        'behavior unchanged', () {
      expect(
        riderOrdersScreen.contains(
          ".inFilter('order_status', ['accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', "
          "'ongoing', 'payment_pending']);",
        ),
        isTrue,
      );
      // The 30s safety-net timer still exists on the same interval and still ultimately calls the
      // same query. WayDrop Phase J wrapped the call in a body that skips it while
      // RiderActiveOrderScreen is already covering this screen (redundant work, same class of fix
      // as RiderHomeTab's analogous gate) -- the timer itself, its 30s cadence, and the fallback
      // query it (still) calls are otherwise untouched.
      expect(
        riderOrdersScreen.contains(
            '_activeOrderPollTimer = Timer.periodic(const Duration(seconds: 30), (_) {'),
        isTrue,
      );
      final timerStart = riderOrdersScreen.indexOf('void startActiveOrderPollTimer() {');
      final timerEnd = riderOrdersScreen.indexOf('Future<void> listenActiveOrder() async {');
      final timerBody = riderOrdersScreen.substring(timerStart, timerEnd);
      expect(timerBody.contains('_pollActiveOrderFallback();'), isTrue);
    });

    test('the still-undeployed backstop (20260824000000) uses the exact same corrected blocking '
        'set as the main fix -- no drift between the two mechanisms', () {
      final backstopBlockingSet = RegExp(
        r"AND bo\.order_status IN \('accepted', 'rider_arrived', 'picked_up', 'ongoing', "
        r"'payment_pending'\)",
      );
      expect(backstopBlockingSet.hasMatch(backstop), isTrue);
    });

    test('payment settlement logic itself is untouched by this fix', () {
      // This fix must never appear in update-order-status -- it only changes matching/acceptance
      // eligibility, never how a payment_pending order actually resolves to completed/delivered.
      final updateOrderStatus = _read(
        'supabase/functions/update-order-status/index.ts',
      );
      expect(
        updateOrderStatus.contains('rider_is_on_active_trip'),
        isFalse,
        reason: 'this fix is scoped to rider-matching eligibility, not to payment settlement -- '
            'update-order-status must remain exactly as it was',
      );
    });
  });
}
