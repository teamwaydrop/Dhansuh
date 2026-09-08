// Regression guard for three production behaviors that were found missing from a physically
// tested APK build vs. the current repository at the time of this fix (2026-08-02):
//
// ISSUE 1 -- IncomingOrderCard (lib/features/rider/orders/widgets/incoming_order_card.dart) had a
// circular "Reject" button that called the reject-order edge function directly, permanently marking
// the rider_assignments row 'rejected'. This is wrong: the secondary button must only MINIMIZE
// without touching the assignment at all, so the request keeps showing in the Orders tab
// (rider_orders_screen.dart already lists every 'sent' assignment) and can be reopened -- including
// once this rider's current active ride finishes and they're eligible for it again.
// Fixed: the button now calls minimizeOrder(), which only calls widget.onMinimized() -- no
// supabase.functions.invoke('reject-order') call anywhere in this widget.
// UPDATE (2026-08-08, "production-grade incoming ride experience"): rider_home_tab.dart's
// _showIncomingOrder no longer shows IncomingOrderCard as a blocking modal at all (see ISSUE 2
// below) -- the widget file itself is untouched and its own Accept+Minimize contract still holds,
// so those checks remain, but the "home tab wires the modal" checks below are replaced with checks
// for the new sound/haptic-only announcement design.
//
// ISSUE 2 (updated 2026-08-08) -- The original fix made sure a busy rider (one with an active
// order) never saw a new incoming-order MODAL POPUP. That popup has since been removed entirely:
// "Rider opens app -> goes online -> gets a takeover dialog that blocks map/navigation use" was
// itself a production complaint (Uber/Rapido/Blinkit Partner never interrupt the driver like this).
// _showIncomingOrder is now sound + haptic + Orders-tab badge only (rider_orders_screen.dart already
// lists every 'sent' assignment as its own card, with a live per-card countdown, and supports any
// number of simultaneous incoming rides since it's a list, not a single modal). The busy-rider guard
// is preserved unchanged -- a busy rider must still never be announced (sound/haptic) a new order --
// just checked against the new no-modal body instead of the old showModalBottomSheet call.
//
// ISSUE 3 -- Intercity Request Accepted flow (travel_plan_details_screen.dart's
// _acceptIntercityRequest) showed a SnackBar with a "VIEW ORDER" action that navigated the
// traveller off the Travel Plan Details page. Fixed: replaced with an AlertDialog titled "Request
// Accepted" with a single "OK" button that only calls Navigator.pop -- no navigation anywhere in
// this dialog, so the traveller always stays on the same Travel Plan Details page.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final card = _read('lib/features/rider/orders/widgets/incoming_order_card.dart');
  final homeTab = _read('lib/features/rider/home/rider_home_tab.dart');
  final travelPlanDetails = _read('lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart');

  group('Issue 1 -- Incoming Order popup: Accept + Minimize only, no Reject', () {
    test('the popup never invokes the reject-order edge function', () {
      expect(card.contains("'reject-order'"), isFalse);
      expect(card.contains('rejectOrder'), isFalse);
    });

    test('the callback contract is Accept + Minimize, not Accept + Reject', () {
      expect(card.contains('required this.onAccepted'), isTrue);
      expect(card.contains('required this.onMinimized'), isTrue);
      expect(card.contains('required this.onRejected'), isFalse);
    });

    test('minimizeOrder() only closes the popup -- no network/DB call', () {
      final start = card.indexOf('void minimizeOrder()');
      expect(start, greaterThan(-1));
      final end = card.indexOf('\n  }', start);
      final body = card.substring(start, end > start ? end : start + 200);
      expect(body.contains('supabase.functions.invoke'), isFalse);
      expect(body.contains('widget.onMinimized()'), isTrue);
    });

    test('rider_home_tab no longer shows IncomingOrderCard as a blocking modal', () {
      // Superseded by the 2026-08-08 "production-grade incoming ride experience" redesign: the
      // Orders tab (rider_orders_screen.dart) is now the sole review/accept surface, so Home no
      // longer constructs the widget anywhere in the file (showModalBottomSheet itself is still
      // used elsewhere in this file for unrelated sheets -- e.g. the Go Offline confirmation -- so
      // only the IncomingOrderCard construction itself, and its use inside _showIncomingOrder
      // specifically, are asserted here).
      expect(homeTab.contains('IncomingOrderCard('), isFalse);
      // Signature gained an optional `{String? orderType}` param (WayDrop bug-fix pass: gates the
      // local incoming-ride sound to local order types, see
      // intercity_match_no_local_sound_regression_test.dart) -- match on the stable prefix only.
      final start = homeTab.indexOf('void _showIncomingOrder(Map<String, dynamic> assignment');
      expect(start, greaterThan(-1));
      final end = homeTab.indexOf('\n  }\n', start);
      final body = homeTab.substring(start, end > start ? end : start + 800);
      expect(body.contains('showModalBottomSheet'), isFalse);
    });
  });

  group('Issue 2 -- busy riders are never announced (sound/haptic) a new incoming order', () {
    test('_showIncomingOrder bails out immediately when the rider already has an active order', () {
      // Signature gained an optional `{String? orderType}` param (WayDrop bug-fix pass: gates the
      // local incoming-ride sound to local order types, see
      // intercity_match_no_local_sound_regression_test.dart) -- match on the stable prefix only.
      final start = homeTab.indexOf('void _showIncomingOrder(Map<String, dynamic> assignment');
      expect(start, greaterThan(-1));
      final end = homeTab.indexOf('\n  }\n', start);
      final body = homeTab.substring(start, end > start ? end : start + 800);
      expect(body.contains('if (activeOrders.isNotEmpty) {'), isTrue);
      // The guard must come before the sound/haptic announcement, not after.
      final guardIndex = body.indexOf('if (activeOrders.isNotEmpty) {');
      final soundIndex = body.indexOf('_playOrderNearbySoundThrottled()');
      expect(guardIndex, greaterThan(-1));
      expect(soundIndex, greaterThan(guardIndex));
    });

    test('a new incoming order plays sound/haptic and is tracked in _announcedOrders, never a dialog/sheet', () {
      // Signature gained an optional `{String? orderType}` param (WayDrop bug-fix pass: gates the
      // local incoming-ride sound to local order types, see
      // intercity_match_no_local_sound_regression_test.dart) -- match on the stable prefix only.
      final start = homeTab.indexOf('void _showIncomingOrder(Map<String, dynamic> assignment');
      expect(start, greaterThan(-1));
      final end = homeTab.indexOf('\n  }\n', start);
      final body = homeTab.substring(start, end > start ? end : start + 800);
      expect(body.contains('HapticFeedback.heavyImpact()'), isTrue);
      expect(body.contains('_playOrderNearbySoundThrottled()'), isTrue);
      expect(body.contains('_announcedOrders.add(orderId)'), isTrue);
      expect(body.contains('showDialog'), isFalse);
      expect(body.contains('showModalBottomSheet'), isFalse);
      expect(body.contains('Navigator.push'), isFalse);
    });

    test('reconciliation no longer caps announcing to one assignment per pass', () {
      // The old modal design could only ever show one sheet at a time, so
      // _reconcilePendingAssignments used to `break` after the first unannounced assignment. With
      // no modal, every pending assignment can be announced in the same pass -- multiple
      // simultaneous incoming rides are expected (Orders tab already renders one card each).
      final start = homeTab.indexOf('Future<void> _reconcilePendingAssignments(String riderId) async {');
      expect(start, greaterThan(-1));
      final end = homeTab.indexOf('\n  }\n', start);
      final body = homeTab.substring(start, end > start ? end : start + 1500);
      expect(body.contains('_showIncomingOrder(row)'), isTrue);
      expect(body.contains('break;'), isFalse);
    });
  });

  group('Issue 4 -- Orders tab is a production-grade multi-ride list, not a single-item surface', () {
    final ordersScreen = _read('lib/features/rider/orders/rider_orders_screen.dart');

    test('assignments are collected into lists (rides/parcels), not a single latest item', () {
      expect(ordersScreen.contains('List<Map<String, dynamic>> rideOrders'), isTrue);
      expect(ordersScreen.contains('List<Map<String, dynamic>> parcelOrders'), isTrue);
    });

    test('a live per-card countdown timer exists, independent of the rest of the screen', () {
      expect(ordersScreen.contains('_expiryNotifier'), isTrue);
      expect(ordersScreen.contains('ValueListenableBuilder<int>'), isTrue);
    });

    test('the Orders-tab badge count reflects every pending assignment, not just one', () {
      expect(ordersScreen.contains('activeAssignmentsCountProvider'), isTrue);
      expect(ordersScreen.contains('rides.length + parcels.length'), isTrue);
    });
  });

  group('Issue 3 -- Intercity Request Accepted: OK-only dialog, stays on Travel Plan Details', () {
    test('accepting a request shows a dialog, not a SnackBar with a navigating action', () {
      final start = travelPlanDetails.indexOf('Future<void> _acceptIntercityRequest(');
      expect(start, greaterThan(-1));
      // CRLF-tolerant: this file is checked out with \r\n line endings, so a literal '\n  }\n'
      // never matches and previously fell through to the `start + 4000` fallback below.
      final endMatch = RegExp(r'\r?\n  \}\r?\n').firstMatch(travelPlanDetails.substring(start));
      final end = endMatch == null ? -1 : start + endMatch.start;
      final section = travelPlanDetails.substring(start, end > start ? end : start + 4000);
      expect(section.contains('showDialog'), isTrue);
      expect(section.contains("'Request Accepted'"), isTrue);
      expect(section.contains("'OK'"), isTrue);
      expect(section.contains('VIEW ORDER'), isFalse);
      expect(section.contains('SnackBarAction'), isFalse);
    });

    test('the OK button only pops the dialog -- no Navigator.push to another screen inside it', () {
      final dialogStart = travelPlanDetails.indexOf("'Request Accepted'");
      expect(dialogStart, greaterThan(-1));
      final dialogEnd = travelPlanDetails.indexOf(');', dialogStart);
      final dialogSection = travelPlanDetails.substring(dialogStart, dialogEnd > dialogStart ? dialogEnd + 2 : dialogStart + 1200);
      expect(dialogSection.contains('Navigator.push'), isFalse);
      expect(dialogSection.contains("Navigator.pop(ctx)"), isTrue);
    });
  });
}
