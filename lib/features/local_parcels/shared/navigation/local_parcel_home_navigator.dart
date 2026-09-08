import 'package:flutter/material.dart';

import 'package:waydrop/features/rider/navigation/rider_main_navigation_screen.dart';
import 'package:waydrop/main_navigation_screen.dart';
import 'package:waydrop/core/navigation/nav_trace.dart';

/// After a local parcel's tracking session ends, every exit path must land on a fresh instance of
/// the correct home shell with a clean stack -- not on whatever
/// `Navigator.popUntil(context, (route) => route.isFirst)` used to overshoot to (the bare app
/// root, sitting one level below the actual home screen). Mirrors
/// `local_ride_home_navigator.dart`'s `returnToLocalRideHome` exactly.
///
/// [isRider] selects which side's home shell to land on: the Partner's
/// [RiderMainNavigationScreen], or the User's [MainNavigationScreen].
void returnToLocalParcelHome(BuildContext context, {required bool isRider}) {
  debugPrint(
    '[TRACE_CANCEL] returnToLocalParcelHome CALLED isRider=$isRider '
    'epoch=${DateTime.now().millisecondsSinceEpoch}',
  );
  NavTrace.begin('returnToLocalParcelHome', 'pushAndRemoveUntil isFirst isRider=$isRider');
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(
      builder: (_) => isRider
          ? const RiderMainNavigationScreen(initialIndex: 0)
          : const MainNavigationScreen(),
    ),
    (route) => route.isFirst,
  );
  NavTrace.end('returnToLocalParcelHome', 'pushAndRemoveUntil isFirst isRider=$isRider');
}
