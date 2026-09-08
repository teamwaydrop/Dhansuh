// Structural regression guard for driver navigation: external Google Maps must never launch
// automatically on ride acceptance (or any other status/lifecycle transition) -- only the
// driver's own explicit tap on the "Directions on Maps" / "NAVIGATE TO DESTINATION" button may
// open it. This does not run the app -- it inspects the driver active-order screen source itself
// so a future edit that reintroduces an auto-launch fails CI immediately.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('Accept Ride never auto-launches external Google Maps', () {
    final driverScreen = _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');

    test('the old auto-launch-on-accept helper is gone, not just unused', () {
      expect(driverScreen.contains('_autoLaunchNavigationForLocalRide'), isFalse);
      expect(driverScreen.contains('_autoNavigationLaunched'), isFalse);
    });

    test('loadOrder() no longer triggers a maps launch as a side effect', () {
      final start = driverScreen.indexOf('Future<void> loadOrder()');
      final end = driverScreen.indexOf('\n  Future<void>', start + 1);
      expect(start, greaterThan(-1));
      final loadOrderBody = driverScreen.substring(start, end == -1 ? driverScreen.length : end);
      expect(loadOrderBody.contains('_openExternalGoogleMaps'), isFalse,
          reason: 'loadOrder() must not call _openExternalGoogleMaps automatically');
    });

    test('_openExternalGoogleMaps is only wired to the manual navigation button', () {
      // Exactly two occurrences expected: the function's own declaration, and the button's
      // onPressed wiring below -- nothing else may reference it.
      final occurrences = RegExp(r'_openExternalGoogleMaps').allMatches(driverScreen).length;
      expect(occurrences, 2, reason: 'expected exactly one definition + one manual button wiring');
      expect(driverScreen.contains('onPressed: _openExternalGoogleMaps'), isTrue);
    });
  });

  group('Passenger tracking screens carry no dead/duplicate external-maps launch code', () {
    final files = [
      'lib/features/local_rides/tracking/screens/ride_tracking_screen.dart',
      'lib/features/intercity/shared/screens/intercity_tracking_screen.dart',
      'lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart',
      'lib/shared/screens/completed_order_details_screen.dart',
    ];

    for (final path in files) {
      test('$path has no orphaned _openExternalGoogleMaps definition', () {
        expect(_read(path).contains('_openExternalGoogleMaps'), isFalse);
      });
    }
  });
}
