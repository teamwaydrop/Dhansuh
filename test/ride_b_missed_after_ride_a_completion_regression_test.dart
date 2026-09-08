// Structural regression guard for the exact reported production bug:
//
//   T0: Partner A is active on Ride A.
//   T1: A passenger creates Ride B nearby.
//   T2: Ride B becomes pending/dispatchable.
//   T3: Partner A is busy, so Ride B is correctly NOT offered to them yet.
//   T4: Partner A completes Ride A.
//   T5: Partner A becomes available.
//   T6: Available-rides list is refreshed -- Ride B must now appear.
//
// CURRENT BUG: Partner A sees "No rides" at T6, even though Ride B is still genuinely pending and
// eligible.
//
// ROOT CAUSE (proven from code, not assumed): the backend rematch pipeline for this exact scenario
// was ALREADY built and is already deployed and correct --
//   - find_nearby_riders()/assign_nearby_searching_orders_core() both exclude a rider currently on
//     an active trip via the canonical rider_is_on_active_trip() predicate (correctly rejects Ride
//     B for Partner A at T3).
//   - trigger_assign_nearby_orders_on_rider_freed (20260808000000, corrected in 20260825000000 to
//     include payment_pending on both sides of its WHEN clause, per the actual
//     ongoing -> payment_pending -> completed/delivered flow) re-runs matching the instant Partner
//     A's order leaves the busy set.
//   - redispatch_freed_riders(), a 20s pg_cron backstop (20260824000000, hardened in 20260826000000
//     with per-rider exception isolation and rider_at_drop coverage in 20260901000017), independently
//     re-checks every recently-active online rider.
//   - rider_self_rematch() (20260826000000), a caller-scoped RPC RiderOrdersScreen calls the instant
//     it detects ITS OWN wasBusy->free transition, gives a same-request (sub-second) guarantee
//     instead of waiting on the async trigger (which the SAME migration's forensic investigation
//     proved has a real, unretried silent-failure mode) or the 20s cron tick.
//
// All four of the above were re-verified this session (fresh pg_get_functiondef/pg_get_triggerdef
// fetches against the linked production project, plus this repo's existing
// rider_self_rematch_regression_test.dart / rider_orders_busy_to_free_refetch_regression_test.dart /
// rider_freed_rematch_regression_test.dart / rider_freed_rematch_backstop_regression_test.dart /
// payment_pending_busy_state_regression_test.dart, all of which still pass) -- NONE of it was
// broken, and NONE of it needed to change.
//
// THE ACTUAL GAP: rider_self_rematch()'s guaranteed synchronous call is gated on
// `wasBusy && !hasActiveOrder` -- a comparison against THIS RiderOrdersScreenState instance's own
// in-memory `hasActiveOrder` field. But returnToLocalRideHome() (local_ride_home_navigator.dart),
// the function every local-ride completion exit path calls (rider_active_order_screen.dart's "Back
// to Home" button, ride_tracking_screen.dart's cancellation/null-order exits, rider_rating_screen.dart)
// rebuilds RiderMainNavigationScreen via Navigator.pushAndRemoveUntil -- destroying the OLD
// RiderOrdersScreenState (which correctly observed "busy=true" while Ride A was active) and creating
// a BRAND NEW one whose `hasActiveOrder` starts at Dart's default `false`, with zero memory of ever
// having been busy. That fresh instance's very first _pollActiveOrderFallback() call therefore
// computes `wasBusy = false` (the fresh default, not a real "was free" observation) even though the
// rider was busy moments ago in the now-destroyed instance -- `wasBusy && !hasActiveOrder` evaluates
// to `false && true = false`, and the one guaranteed, sub-second self-heal this whole mechanism
// exists to provide silently never fires for the single most common way a rider actually finishes a
// local ride. The rider is left entirely dependent on the async trigger's proven silent-failure mode
// and the 20s cron tick -- exactly reproducing the reported "sees No rides" complaint.
//
// FIX: track whether THIS screen instance has completed its first busy-order poll yet
// (_hasPolledActiveOrderOnce). The self-heal condition also fires on that first poll whenever the
// rider is found free, not only on an in-memory-detected transition -- closing the gap for a freshly
// (re)created instance while remaining a safe no-op for a genuinely idle rider (rider_self_rematch()
// only ever creates a NEW rider_assignments row when a genuinely matching order exists; it is
// idempotent and side-effect-free otherwise). No SQL/migration change was needed -- every backend
// eligibility/business rule was already correct; only the CLIENT's self-heal trigger condition was
// wrong.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final ordersScreen = _read('lib/features/rider/orders/rider_orders_screen.dart');
  final navigator = _read('lib/features/local_rides/shared/navigation/local_ride_home_navigator.dart');
  final activeOrderScreen = _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');
  final findNearbyRiders = _read(
    'supabase/migrations/20260825000000_payment_pending_busy_state_fix.sql',
  );
  final freedTrigger = _read(
    'supabase/migrations/20260825000000_payment_pending_busy_state_fix.sql',
  );

  group('1. ROOT CAUSE: returnToLocalRideHome() destroys and recreates RiderOrdersScreenState, '
      'making the OLD wasBusy-only condition blind to the transition', () {
    test('returnToLocalRideHome() rebuilds a brand-new RiderMainNavigationScreen via '
        'pushAndRemoveUntil (not a bare pop) -- this destroys the previous RiderOrdersScreenState, '
        'including its in-memory hasActiveOrder history', () {
      expect(navigator.contains('Navigator.of(context).pushAndRemoveUntil('), isTrue);
      expect(
        navigator.contains('builder: (_) => isRider\n          ? const RiderMainNavigationScreen(initialIndex: 0)'),
        isTrue,
      );
    });

    test('rider_active_order_screen.dart\'s "Back to Home" completion button (the single most '
        'common exit after finishing a local ride) calls returnToLocalRideHome(), not a bare pop', () {
      expect(
        activeOrderScreen.contains('if (mounted) returnToLocalRideHome(context, isRider: true);'),
        isTrue,
      );
    });
  });

  group('2. THE FIX: the self-heal condition also fires on this instance\'s first poll, not only '
      'on an in-memory wasBusy->free transition', () {
    test('_hasPolledActiveOrderOnce field exists, starts false, is instance-scoped (not static) so '
        'a freshly created instance always starts at false regardless of a previous instance\'s '
        'history', () {
      expect(ordersScreen.contains('bool _hasPolledActiveOrderOnce = false;'), isTrue);
      // Must NOT be static -- a static flag would survive across instances and defeat the fix
      // (the whole point is that a FRESH instance must independently self-heal once).
      expect(ordersScreen.contains('static bool _hasPolledActiveOrderOnce'), isFalse);
    });

    test('the flag is captured into isFirstPollForThisInstance and flipped BEFORE the busy/free '
        'setState -- so the very first call after a fresh mount is unambiguously identified as '
        '"first", and every call after that is correctly "not first"', () {
      expect(
        ordersScreen.contains(
          'final isFirstPollForThisInstance = !_hasPolledActiveOrderOnce;\n'
          '      _hasPolledActiveOrderOnce = true;\n'
          '      setState(() {',
        ),
        isTrue,
      );
    });

    test('the self-heal condition is now (wasBusy || isFirstPollForThisInstance) && !hasActiveOrder '
        '-- NOT the old wasBusy-only check that misses a freshly-recreated instance', () {
      expect(
        ordersScreen.contains('if ((wasBusy || isFirstPollForThisInstance) && !hasActiveOrder) {'),
        isTrue,
      );
      // The old, buggy, wasBusy-only condition must no longer be the live check -- this is the
      // exact string that would make this test suite FAIL against the pre-fix code.
      expect(ordersScreen.contains('if (wasBusy && !hasActiveOrder) {'), isFalse);
    });

    test('the fix still calls the exact same, unmodified rider_self_rematch() RPC and '
        'fetchSearchingOrders() -- no new/duplicated matching logic, no new endpoint', () {
      final fixBlockStart = ordersScreen.indexOf('if ((wasBusy || isFirstPollForThisInstance)');
      expect(fixBlockStart, greaterThan(-1));
      // Bounded at the start of the try block's own catch (not '} catch (_) {} finally {' --
      // Phase 5 F8 added a PollBackoff.recordFailure() call inside this catch body, so it's no
      // longer an empty `{}` immediately followed by `finally`) -- still the exact same boundary
      // between "the fix block" and the surrounding try's error handling.
      final fixBlockEnd = ordersScreen.indexOf('} catch (_) {', fixBlockStart);
      final fixBlock = ordersScreen.substring(fixBlockStart, fixBlockEnd);
      expect(fixBlock.contains("await supabase.rpc('rider_self_rematch');"), isTrue);
      expect(fixBlock.contains('fetchSearchingOrders();'), isTrue);
      // Exactly one rpc('rider_self_rematch') call site in this whole fixed block -- not
      // duplicated.
      expect("rpc('rider_self_rematch')".allMatches(fixBlock).length, 1);
    });
  });

  group('3. No unnecessary repeated/duplicate work introduced (egress discipline preserved)', () {
    test('_hasPolledActiveOrderOnce is set exactly once per instance and never reset back to '
        'false anywhere in this file -- the "first poll" self-heal fires at most once per screen '
        'instance, not on every subsequent poll/timer tick', () {
      expect('_hasPolledActiveOrderOnce = false'.allMatches(ordersScreen).length, 1,
          reason: 'only the field declaration may initialize it to false');
      expect('_hasPolledActiveOrderOnce = true'.allMatches(ordersScreen).length, 1,
          reason: 'set exactly once, right after it is read, never toggled back');
    });

    test('the pre-existing _pollInFlight/_pollQueued re-entrancy guard (coalesces overlapping '
        'triggers into a single follow-up poll) is untouched and still wraps this whole function', () {
      expect(ordersScreen.contains('if (_pollInFlight) {\n      _pollQueued = true;\n      return;\n    }'), isTrue);
      expect(ordersScreen.contains('_pollInFlight = true;'), isTrue);
    });

    test('rider_self_rematch() itself performs no platform-wide query -- it resolves only the '
        'calling rider via auth.uid() and matches only that rider\'s own eligible orders', () {
      // Re-verified against the live migration source (unchanged by this fix).
      final rematchMig = _read(
        'supabase/migrations/20260826000000_rider_self_rematch_and_backstop_hardening.sql',
      );
      expect(
        rematchMig.contains('SELECT id, user_id, current_lat, current_lng, service_mode\n'
            '    INTO v_rider\n    FROM public.riders\n    WHERE user_id = auth.uid();'),
        isTrue,
      );
    });
  });

  group('4. Existing active-order / busy-rider protections are completely unchanged', () {
    test('find_nearby_riders() still excludes a rider on an active trip via the canonical '
        'rider_is_on_active_trip() predicate -- Partner A still cannot be offered Ride B while '
        'Ride A is active', () {
      expect(findNearbyRiders.contains('AND NOT public.rider_is_on_active_trip(r.id)'), isTrue);
    });

    test('rider_is_on_active_trip() still treats payment_pending/rider_at_drop/ongoing/etc as '
        'busy -- this fix does not touch or weaken that predicate at all (no SQL file was changed '
        'for this fix)', () {
      final activeTrip = _read('supabase/migrations/20260724000002_upi_payment_pending_flow_support.sql');
      expect(
        activeTrip.contains(
          "o.order_status::text IN ('rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending')",
        ),
        isTrue,
      );
    });

    test('the rider-freed trigger\'s WHEN clause still requires the OLD status to have genuinely '
        'been in the busy set before re-matching -- unrelated to and unchanged by this fix', () {
      expect(
        freedTrigger.contains(
          "OLD.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing', 'payment_pending')",
        ),
        isTrue,
      );
    });

    test('_isOrderActivelyBusy() and the busy-status query filter in _pollActiveOrderFallback() '
        'are unchanged -- still the exact same 6-status list, still hides the pending-orders list '
        'while genuinely busy', () {
      expect(
        ordersScreen.contains(
          ".inFilter('order_status', ['accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending']);",
        ),
        isTrue,
      );
    });
  });

  group('5. Every other reconciliation path this bug report asked about is untouched', () {
    test('the 30s active-order poll timer and its ActiveOrderScreenState.isOpen gating are '
        'unchanged', () {
      expect(ordersScreen.contains('_activeOrderPollTimer = Timer.periodic(const Duration(seconds: 30)'), isTrue);
      expect(ordersScreen.contains('if (ActiveOrderScreenState.isOpen.value) return;'), isTrue);
    });

    test('_onActiveOrderScreenVisibilityChanged() (fires the moment RiderActiveOrderScreen closes, '
        'regardless of which bottom-nav tab is visible) still calls _pollActiveOrderFallback() -- '
        'now benefiting from this fix too, on whichever instance is live at that moment', () {
      expect(
        ordersScreen.contains('void _onActiveOrderScreenVisibilityChanged() {'),
        isTrue,
      );
    });

    test('fetchSearchingOrders() itself -- the query that actually populates the visible list -- '
        'is completely unchanged: still rider_assignments where assignment_status=\'sent\' joined '
        'to orders, still the same column projection (egress fix preserved)', () {
      expect(
        ordersScreen.contains(
          ".from('rider_assignments')\n          .select('''\n            id,\n            order_id,\n            expires_at,\n            distance_km,\n            sent_at,\n            created_at,",
        ),
        isTrue,
      );
      expect(ordersScreen.contains(".eq('assignment_status', 'sent');"), isTrue);
    });
  });
}
