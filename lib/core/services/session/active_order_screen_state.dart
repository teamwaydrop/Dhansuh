import 'package:flutter/foundation.dart';

/// Perf fix (WayDrop Phase H): tracks whether RiderActiveOrderScreen is currently the open/visible
/// screen. RiderHomeTab lives inside the bottom-nav IndexedStack and never unmounts, so its own
/// realtime subscriptions and refresh work stay live the entire session, including while
/// RiderActiveOrderScreen is pushed on top and already handling the same order's realtime updates
/// itself -- this flag lets RiderHomeTab skip only that specific duplicated work while covered, and
/// reconcile once when the covering screen closes.
///
/// Mirrors the existing static-flag pattern already used by PipService (see pip_service.dart) --
/// RiderActiveOrderScreen sets this exactly like it already sets PipService.setPipEnabled, in the
/// same initState()/dispose() pair. A ValueNotifier (not a plain bool) so listeners can react to
/// the screen closing, not just poll it.
class ActiveOrderScreenState {
  static final ValueNotifier<bool> isOpen = ValueNotifier<bool>(false);
}
