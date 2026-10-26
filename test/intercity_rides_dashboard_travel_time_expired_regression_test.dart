// Regression guard for Issue 3: an intercity order whose scheduled travel_date/time has already
// passed kept showing "SEARCHING..." on the Intercity Rides Dashboard card, because
// expire_stale_searching_orders() explicitly excludes intercity_ride/intercity_parcel from its
// auto-expiry sweep (order_type NOT IN (...)), so order_status can remain 'searching' indefinitely
// past the scheduled departure time, and the dashboard card's status derivation was a pure
// order_status string check with no travel_date/DateTime.now() comparison at all.
//
// FIX (Flutter-only, lib/features/intercity/rides/dashboard/intercity_rides_screen.dart): a new
// `isTravelTimeExpired` flag compares the order's full travel_date instant against
// DateTime.now() (DateTime.tryParse on the stored `timestamp with time zone` ISO 8601 string
// already yields the correct absolute instant -- no manual timezone conversion), and only applies
// when the order is still in a searching-ish state (`searching`/`created`). When true, the card's
// status label becomes 'Travel Time Expired' instead of the normal searching label, and the
// `isSearching` flag (which also gates the live IntercityMatchBadge) becomes false. No backend
// expiry mechanism, order_status value, match-intercity-riders logic, or accept_intercity_request()
// behavior was touched.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Line endings are not Dart semantics; keep every assertion otherwise exact.
String _read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  final screen = _read('lib/features/intercity/rides/dashboard/intercity_rides_screen.dart');

  group('1. THE FIX: a travel-time-expired, still-searching order gets its own status', () {
    test('isTravelTimeExpired compares the full travel_date instant against DateTime.now(), not '
        'just the calendar date', () {
      expect(screen.contains('travelDateTime.isBefore(DateTime.now())'), isTrue);
    });

    test('travel_date is parsed with DateTime.tryParse (no manual timezone offset arithmetic '
        'introduced) -- the stored ISO 8601 timestamptz string already carries its own offset', () {
      final anchor = screen.indexOf('final DateTime? travelDateTime = order[\'travel_date\'] != null');
      expect(anchor, greaterThan(-1));
      final block = screen.substring(anchor, anchor + 200);
      expect(block.contains("DateTime.tryParse(order['travel_date'].toString())"), isTrue);
      // Must not introduce any hardcoded UTC/IST offset math for this comparison.
      expect(block.contains('Duration(hours:'), isFalse);
    });

    test('the override is gated on the order still being in a searching-ish state -- cancelled/'
        'completed/already-backend-expired orders are unaffected regardless of travel_date', () {
      expect(
        screen.contains(
          'final bool isTravelTimeExpired = isSearchingStatus &&\n'
          '                            travelDateTime != null &&\n'
          '                            travelDateTime.isBefore(DateTime.now());',
        ),
        isTrue,
      );
    });

    test('the status label becomes "Travel Time Expired" for the expired-but-searching case, '
        'otherwise falls through to the existing intercityLifecycleLabel unchanged', () {
      expect(
        screen.contains(
          "final statusLabel = isTravelTimeExpired\n"
          "                            ? 'Travel Time Expired'\n"
          "                            : TransportOrder.fromJson(order).intercityLifecycleLabel;",
        ),
        isTrue,
      );
    });

    test('isSearching (which also gates the live IntercityMatchBadge) becomes false once '
        'travel-time-expired -- the card stops implying an active, ongoing search', () {
      expect(
        screen.contains('final bool isSearching = isSearchingStatus && !isTravelTimeExpired;'),
        isTrue,
      );
    });
  });

  group('2. Future travel plans and non-searching statuses are unaffected', () {
    test('the underlying order_status searching/created check is preserved verbatim as its own '
        'variable -- a future-dated searching order still satisfies it and is not expired', () {
      expect(
        screen.contains("final bool isSearchingStatus = status == 'searching' || status == 'created';"),
        isTrue,
      );
    });

    test('no backend expiry mechanism, order_status write, or database mutation was introduced -- '
        'this file has no .update(...)/.rpc(...) call added near the new logic', () {
      final anchor = screen.indexOf('final bool isTravelTimeExpired');
      final nearby = screen.substring(anchor, (anchor + 600).clamp(0, screen.length));
      expect(nearby.contains('.update('), isFalse);
      expect(nearby.contains('.rpc('), isFalse);
    });
  });
}
