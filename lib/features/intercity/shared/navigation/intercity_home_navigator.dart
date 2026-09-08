import 'package:flutter/material.dart';

import 'package:waydrop/features/intercity/rides/dashboard/intercity_rides_screen.dart';
import 'package:waydrop/features/rider/intercity/intercity_bookings_screen.dart';
import 'package:waydrop/core/navigation/nav_trace.dart';

/// Task 4: after an intercity trip completes (or its tracking session ends), every exit path must
/// land back on the correct Intercity Home dashboard with a clean stack — not on whatever the
/// blind `Navigator.popUntil(context, (route) => route.isFirst)` pattern used to overshoot to
/// (the bare app root, sitting one level below the actual "Intercity Home" screen).
///
/// [isTraveller] selects which side's dashboard to land on: the rider/traveller's
/// [IntercityBookingsScreen], or the passenger's [IntercityRidesScreen].
///
/// Always rebuilds a fresh instance of the dashboard rather than merely revealing whatever
/// dormant instance might already sit in the stack — this guarantees the dashboard's initState
/// re-fetches, satisfying the "refresh the Intercity dashboard automatically" requirement without
/// depending on background realtime subscriptions having survived correctly, and it clears every
/// intermediate route (booking/tracking/rating) in one deterministic step. `route.isFirst` keeps
/// only the app's true root route (AppStartScreen), which manages top-level auth/session state.
void returnToIntercityHome(BuildContext context, {required bool isTraveller}) {
  debugPrint(
    '[TRACE_CANCEL] returnToIntercityHome CALLED isTraveller=$isTraveller '
    'epoch=${DateTime.now().millisecondsSinceEpoch}',
  );
  NavTrace.begin('returnToIntercityHome', 'pushAndRemoveUntil isFirst isTraveller=$isTraveller');
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(
      builder: (_) => isTraveller ? const IntercityBookingsScreen() : const IntercityRidesScreen(),
    ),
    (route) => route.isFirst,
  );
  NavTrace.end('returnToIntercityHome', 'pushAndRemoveUntil isFirst isTraveller=$isTraveller');
}
