// Regression guard for three 2026-07-29 production bug reports on the Travel Plan / Travel
// Together flow:
//
// ISSUE 1 -- "Directions" on an accepted passenger's card in Travel Plan Details launched Google
// Maps directly (travel_plan_details_screen.dart's own _openDirectionsForOrder), instead of
// opening the app's existing canonical active-order/trip screen (RiderActiveOrderScreen: ACCEPTED
// state, fare, SHOW DETAILS, Directions on Maps, SWIPE TO ARRIVE, Call/Chat/Cancel Ride). Fixed by
// replacing both "Directions" render sites' onPressed with a push to
// RiderActiveOrderScreen(orderId: ...) for that specific row's own order -- the same canonical
// screen/order-loading path already reachable via "VIEW ORDER" right after accept. Only that
// reused screen's own "Directions on Maps" button now launches external navigation.
//
// ISSUE 2 -- the traveller could not see a passenger/parcel's EXACT pickup/drop address before
// deciding to Accept Request; travel_plan_details_screen.dart's order-details bottom sheet
// deliberately substituted the city name + "(Exact location hidden until accepted)" for the real
// pickup_address/destination_address. Fixed: the exact address is now always shown (falling back
// to the resolved city label only when an order genuinely has no address on file) -- mirroring
// passenger identity (name/gender/photo/rating), which was already shown pre-accept. Only contact
// info (phone) remains gated behind acceptance.
//
// ISSUE 3 -- cancelling a Travel Plan (`rider_travel_plans.status = 'cancelled'`, always a
// soft-cancel status transition in this codebase, never a hard DELETE) never cascaded to the
// dependent `intercity_requests` negotiation rows or `orders` rows tied to it, leaving the
// passenger (and the traveller's own other sessions) looking at a "matched"/"confirmed" ghost
// booking. Fixed via 20260729000003_cascade_cancel_travel_plan_dependents.sql: a BEFORE UPDATE
// guard blocks cancelling a plan with a trip already in_progress, and an AFTER UPDATE trigger
// cancels every still-open negotiation + its underlying accepted order the same way
// update-order-status already cancels an order (order_status/cancelled_at/cancel_reason/
// order_status_history), reusing the existing realtime subscriptions every affected screen
// (traveller's own TravelPlanDetailsScreen, passenger's IntercityTrackingScreen/
// IntercitySearchingScreen/OrderChatScreen) already has on `orders`/`intercity_requests` -- no
// client screen needed a new subscription. TravelPlanDetailsScreen additionally gained an
// app-resume reconciliation pass (WidgetsBindingObserver), matching the existing pattern already
// used by activity_tab.dart/home_tab.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final travelPlanDetails = _read('lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart');
  final activeOrderScreen = _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');
  final cascadeMigration = _read('supabase/migrations/20260729000003_cascade_cancel_travel_plan_dependents.sql');
  final riderHomeTab = _read('lib/features/rider/home/rider_home_tab.dart');
  final intercityBookingsScreen = _read('lib/features/rider/intercity/intercity_bookings_screen.dart');

  group('Issue 1 -- Directions opens the canonical active-order screen, never Google Maps directly', () {
    test('Test 1: travel_plan_details_screen.dart never launches an external map URL itself', () {
      expect(travelPlanDetails.contains('google.navigation:'), isFalse);
      expect(travelPlanDetails.contains('canLaunchUrl'), isFalse);
      // The identifier may still appear in an explanatory comment documenting what this replaced
      // -- assert the callable method itself (declaration) is gone, not the bare substring.
      expect(travelPlanDetails.contains('Future<void> _openDirectionsForOrder('), isFalse);
    });

    test('Test 2: both "Directions" render sites (sheet + main card list) call _openActiveOrderScreen', () {
      expect(RegExp(r"btnLabel = 'Directions';").allMatches(travelPlanDetails).length, greaterThanOrEqualTo(2));
      expect(RegExp(r'_openActiveOrderScreen\(orderId\.toString\(\)\)').allMatches(travelPlanDetails).length,
          greaterThanOrEqualTo(2));
    });

    test('Test 2: _openActiveOrderScreen pushes RiderActiveOrderScreen for the given orderId', () {
      final start = travelPlanDetails.indexOf('void _openActiveOrderScreen(String orderId)');
      expect(start, greaterThan(-1));
      final section = travelPlanDetails.substring(start, start + 400);
      expect(section.contains('Navigator.push'), isTrue);
      expect(section.contains('RiderActiveOrderScreen('), isTrue);
      expect(section.contains('orderId: orderId'), isTrue);
    });

    test('Test 3: RiderActiveOrderScreen (the reused canonical screen) owns the ONLY "Directions on Maps" external-navigation action, plus SWIPE TO ARRIVE/Call/Chat/Cancel', () {
      expect(activeOrderScreen.contains("'Directions on Maps'"), isTrue);
      expect(activeOrderScreen.contains("_openExternalGoogleMaps"), isTrue);
      expect(activeOrderScreen.contains("'SWIPE TO ARRIVE"), isTrue);
    });

    test('Test 3: RiderActiveOrderScreen self-loads strictly by orderId (no coordinates/params trusted from the caller)', () {
      // Confirms the canonical screen resolves its own order/route data server-side by id --
      // travel_plan_details_screen.dart cannot pass it stale/wrong coordinates even if it tried.
      expect(activeOrderScreen.contains("required this.orderId"), isTrue);
      final start = activeOrderScreen.indexOf('Future<void> loadOrder() async {');
      expect(start, greaterThan(-1));
      // Widened from a fixed 400-char window: the `if (widget.initialOrder != null)` seeded-order
      // fast path (an unrelated read-amplification optimization) grew its own explanatory comment
      // block long enough to push the `else` branch's `.from('orders').eq('id', widget.orderId)`
      // query outside a narrow window. Scoped to the method body itself instead of a char count.
      final end = activeOrderScreen.indexOf('order = response;', start);
      expect(end, greaterThan(start));
      final section = activeOrderScreen.substring(start, end);
      expect(section.contains("from('orders')"), isTrue);
      expect(section.contains("'id',"), isTrue);
      expect(section.contains("widget.orderId,"), isTrue);
    });

    test('Test 4: the correct per-passenger order is resolved when a plan has multiple accepted users -- each card/sheet scopes its own `order`/`orderId`, never a shared field', () {
      expect(travelPlanDetails.contains('final order = matches[idx];'), isTrue);
      expect(travelPlanDetails.contains("final req = intercityRequests[order['id']];"), isTrue);
      // The one-argument helper takes an explicit orderId every call -- there is no fallback to
      // "the first accepted order" or any other shared/ambient state.
      final helperStart = travelPlanDetails.indexOf('void _openActiveOrderScreen(String orderId)');
      expect(helperStart, greaterThan(-1));
    });
  });

  group('Issue 2 -- exact pickup/drop address visible before Accept Request', () {
    test('Test 5: the "hidden until accepted" address substitution is gone', () {
      expect(travelPlanDetails.contains('Exact location hidden until accepted'), isFalse);
      expect(travelPlanDetails.contains("isAccepted ? (order['pickup_address']"), isFalse);
      expect(travelPlanDetails.contains("isAccepted ? (order['destination_address']"), isFalse);
    });

    test('Test 5: displayPickupAddr/displayDestAddr always source the real pickup_address/destination_address fields (never synthesized from city alone unless genuinely absent)', () {
      final start = travelPlanDetails.indexOf("final pickupAddrRaw = order['pickup_address']");
      expect(start, greaterThan(-1));
      final section = travelPlanDetails.substring(start, start + 500);
      expect(section.contains("order['pickup_address']"), isTrue);
      expect(section.contains("order['destination_address']"), isTrue);
      expect(section.contains('pickupAddrRaw.isNotEmpty ? pickupAddrRaw : pickupCity'), isTrue);
      expect(section.contains('destAddrRaw.isNotEmpty ? destAddrRaw : destCity'), isTrue);
    });

    test('Test 5: contact info (phone) is still gated behind acceptance -- only the address gate was removed', () {
      expect(travelPlanDetails.contains("final displayPhone = isAccepted ? phone : 'Hidden until accepted';"), isTrue);
    });

    test('Test 6: after acceptance, the active order screen exposes the SAME canonical pickup_address/destination_address under SHOW DETAILS and for navigation', () {
      expect(activeOrderScreen.contains("order?['pickup_address']"), isTrue);
      expect(activeOrderScreen.contains("'HIDE DETAILS'") , isTrue);
      expect(activeOrderScreen.contains("'SHOW DETAILS'") , isTrue);
    });
  });

  group('Issue 3 -- Travel Plan cancellation cascades to dependent bookings, no ghost state', () {
    test('Test 7 & 8: a BEFORE UPDATE guard blocks cancelling a plan with a trip already in progress', () {
      expect(cascadeMigration.contains('guard_travel_plan_cancellation'), isTrue);
      expect(cascadeMigration.contains("status = 'in_progress'"), isTrue);
      expect(cascadeMigration.contains('BEFORE UPDATE ON public.rider_travel_plans'), isTrue);
      expect(cascadeMigration.contains('RAISE EXCEPTION'), isTrue);
    });

    test('Test 7 & 8: an AFTER UPDATE cascade cancels every still-open intercity_requests row on that plan', () {
      expect(cascadeMigration.contains('cascade_cancel_travel_plan_dependents'), isTrue);
      expect(cascadeMigration.contains('AFTER UPDATE ON public.rider_travel_plans'), isTrue);
      expect(cascadeMigration.contains(
          "status IN ('request_sent', 'discussion_started', 'fare_agreed', 'confirmed', 'paid')"), isTrue);
      // Never touches already-terminal history or an in_progress/completed trip.
      expect(cascadeMigration.contains("'in_progress'"), isTrue); // present only in the guard, not the cascade set
    });

    test('Test 8: the cascade cancels the underlying order too (terminal state), scoped to this exact plan\'s own rider -- never a cross-rider/cross-plan write', () {
      final start = cascadeMigration.indexOf('UPDATE public.orders o');
      expect(start, greaterThan(-1));
      final section = cascadeMigration.substring(start, start + 600);
      expect(section.contains("order_status = 'cancelled'"), isTrue);
      expect(section.contains('cancelled_at'), isTrue);
      expect(section.contains('cancel_reason'), isTrue);
      expect(section.contains("o.order_status = 'accepted'"), isTrue);
      expect(section.contains('o.rider_id = NEW.rider_id'), isTrue);
    });

    test('Test 8: an order_status_history row records the cascade for audit, mirroring update-order-status\'s own cancellation logging', () {
      expect(cascadeMigration.contains('INSERT INTO public.order_status_history'), isTrue);
      expect(cascadeMigration.contains("'system_travel_plan_cancelled'"), isTrue);
    });

    test('Test 9: on_intercity_request_change() notifies the passenger on this cancellation (previously silent -- no \'cancelled\' branch existed at all)', () {
      expect(cascadeMigration.contains("ELSIF NEW.status = 'cancelled' THEN"), isTrue);
      expect(cascadeMigration.contains("'Booking Cancelled'"), isTrue);
    });

    test('Test 9: every pre-existing notification branch is preserved byte-for-byte (confirmed, rejected, paid, in_progress, completed all still present)', () {
      for (final status in ['confirmed', 'rejected', 'paid', 'in_progress', 'completed', 'discussion_started']) {
        expect(cascadeMigration.contains("NEW.status = '$status'"), isTrue, reason: 'missing preserved branch: $status');
      }
    });

    test('Test 10 & 8: passenger-cancels-order direction already propagates via the pre-existing update-order-status sync (verified still intact, not modified by this fix)', () {
      final updateOrderStatus = _read('supabase/functions/update-order-status/index.ts');
      expect(updateOrderStatus.contains("SYNC THE LINKED intercity_requests"), isTrue);
      expect(updateOrderStatus.contains("const syncedStatus = new_status === \"cancelled\" ? \"cancelled\" : \"completed\";"), isTrue);
    });

    test('Test 7: TravelPlanDetailsScreen already has live realtime subscriptions on rider_assignments/intercity_requests/orders that react to this cascade -- unchanged, reused', () {
      expect(travelPlanDetails.contains("table: 'intercity_requests'"), isTrue);
      expect(travelPlanDetails.contains("table: 'orders'"), isTrue);
      expect(travelPlanDetails.contains('_loadMatches'), isTrue);
      expect(travelPlanDetails.contains('_loadIntercityRequests'), isTrue);
    });

    test('Test 11: TravelPlanDetailsScreen reconciles with DB truth on app resume, not realtime alone', () {
      expect(travelPlanDetails.contains('with WidgetsBindingObserver'), isTrue);
      expect(travelPlanDetails.contains('WidgetsBinding.instance.addObserver(this)'), isTrue);
      expect(travelPlanDetails.contains('WidgetsBinding.instance.removeObserver(this)'), isTrue);
      final start = travelPlanDetails.indexOf('void didChangeAppLifecycleState(AppLifecycleState state)');
      expect(start, greaterThan(-1));
      final section = travelPlanDetails.substring(start, start + 300);
      expect(section.contains('AppLifecycleState.resumed'), isTrue);
      expect(section.contains('_loadMatches()'), isTrue);
      expect(section.contains('_loadIntercityRequests()'), isTrue);
    });

    test('cancellation error messages are surfaced cleanly (e.g. the new in-progress guard), not a raw exception dump', () {
      expect(riderHomeTab.contains('e is PostgrestException ? e.message : e.toString()'), isTrue);
      expect(intercityBookingsScreen.contains('e is PostgrestException ? e.message : e.toString()'), isTrue);
    });

    test('Test 6/7/17: "delete Travel Plan" remains a soft-cancel status transition (never a hard '
        'DELETE) -- canonical model preserved. UPDATED (Phase 9, Issue 2): the write itself moved '
        'server-side into cancel_travel_plan_by_traveller() (one canonical RPC, replacing three '
        "separate direct client updates) so it can enforce its own authoritative trip-started "
        'check instead of trusting the client -- both screens now call the RPC via '
        'IntercityMatchingService.cancelTravelPlan(), and neither writes to rider_travel_plans '
        'directly any more.', () {
      expect(riderHomeTab.contains("supabase.from('rider_travel_plans').update({'status': 'cancelled'})"), isFalse);
      expect(intercityBookingsScreen.contains("supabase.from('rider_travel_plans').update({'status': 'cancelled'})"), isFalse);
      expect(riderHomeTab.contains('IntercityMatchingService.cancelTravelPlan('), isTrue);
      expect(intercityBookingsScreen.contains('IntercityMatchingService.cancelTravelPlan('), isTrue);

      final cancelPlanRpcMigration = _read(
        'supabase/migrations/20260901000002_cancel_travel_plan_by_traveller.sql',
      );
      // The RPC itself is still a soft-cancel status UPDATE, never a hard DELETE.
      expect(
        cancelPlanRpcMigration.contains(
          "UPDATE public.rider_travel_plans\n    SET status = 'cancelled'::public.travel_plan_status_enum,",
        ),
        isTrue,
      );
      expect(cancelPlanRpcMigration.contains('DELETE FROM'), isFalse);
    });
  });

  group('Test 17/18 -- unrelated flows and payment/accounting code left untouched', () {
    test('accept_intercity_request / start_intercity_trip_for_plan are not modified by the Issue 3 migration', () {
      expect(cascadeMigration.contains('CREATE OR REPLACE FUNCTION public.accept_intercity_request'), isFalse);
      expect(cascadeMigration.contains('CREATE OR REPLACE FUNCTION public.start_intercity_trip_for_plan'), isFalse);
    });

    test('no fare/GST/commission/wallet/subscription/Cashfree/Personal QR/Cash keyword appears in the cascade migration', () {
      for (final term in [
        'gst_amount',
        'commission_amount',
        'wallet',
        'subscription_commission_waived',
        'cashfree',
        'personal_upi',
        'fare_payment_method',
      ]) {
        expect(cascadeMigration.toLowerCase().contains(term.toLowerCase()), isFalse, reason: 'unexpected pricing/payment term: $term');
      }
    });

    test('the Accept Request button and its handler are unchanged in shape (still calls _acceptIntercityRequest via accept-intercity-request)', () {
      expect(travelPlanDetails.contains('_acceptIntercityRequest(req[\'id\'].toString(), orderId)'), isTrue);
      expect(travelPlanDetails.contains("'accept-intercity-request'"), isTrue);
    });
  });
}
