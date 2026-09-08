// Regression guard for PHASE 3, Issue 2: a "traveller available" match notification must open the
// canonical per-order Intercity Searching/matching screen (which already shows the live matched
// traveller via realtime subscriptions), never the generic date-picker/browse
// AvailablePartnersScreen -- and must never make the user "search again by date".
//
// ROOT CAUSE: notification_service.dart routed 'travel_partners_available'/'traveller_available'
// taps through _openAvailablePartnersFromPayload() -> AvailablePartnersScreen, a browse/search
// screen -- instead of IntercitySearchingScreen(orderId), the screen every other intercity
// notification type already routes to by order id, which already exists and already shows live
// matches for that exact order.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final source = _read('lib/modules/notifications/services/notification_service.dart');

  group('NotificationService -- match notification routes to IntercitySearchingScreen', () {
    test('IntercitySearchingScreen is imported', () {
      expect(
        source.contains(
          "import 'package:waydrop/features/intercity/shared/screens/intercity_searching_screen.dart';",
        ),
        isTrue,
      );
    });

    test('traveller_available and travel_partners_available both push '
        'IntercitySearchingScreen(orderId: orderId), not AvailablePartnersScreen', () {
      final branchStart = source.indexOf(
        "if (type == 'travel_partners_available' || type == 'traveller_available') {",
      );
      // WayDrop Intercity is strictly User-initiated: the aggregate rider-side
      // 'new_travelers_available' branch (and its only destination, AvailableTravelersScreen --
      // the Traveller-side browse/invite screen) was removed entirely -- see
      // reverse_traveller_invitation_removed_regression_test.dart. The next branch in the file is
      // now 'order_assignment'.
      final branchEnd = source.indexOf("if (type == 'order_assignment') {", branchStart);
      expect(branchStart, greaterThanOrEqualTo(0));
      expect(branchEnd, greaterThan(branchStart));
      final branchBody = source.substring(branchStart, branchEnd);

      expect(branchBody.contains('IntercitySearchingScreen(orderId: orderId)'), isTrue);
      // The branch's own explanatory comment legitimately mentions AvailablePartnersScreen by
      // name (contrasting it with the fix) -- what matters is it's never CONSTRUCTED here.
      expect(branchBody.contains('AvailablePartnersScreen('), isFalse);
    });

    test('the dead _openAvailablePartnersFromPayload helper (no longer called from anywhere) was '
        'removed rather than left as unreachable code', () {
      expect(source.contains('_openAvailablePartnersFromPayload'), isFalse);
    });

    test('the reverse-flow new_travelers_available branch (and AvailableTravelersScreen import) '
        'is gone -- removed together with the Traveller-initiated invitation flow', () {
      expect(source.contains("if (type == 'new_travelers_available') {"), isFalse);
      expect(source.contains('available_travelers_screen.dart'), isFalse);
    });
  });
}
