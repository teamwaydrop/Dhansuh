/// In-memory session cache for the rider's OWN `rider_payout_accounts` display/edit row, keyed by
/// user id.
///
/// Egress fix (Fix #6 completion): rider_earnings_tab.dart, rider_payout_details_screen.dart,
/// rider_active_order_screen.dart, and rider_payment_settings_screen.dart each independently
/// queried this same row with overlapping-but-not-identical field lists, on every screen
/// open/reopen within a session. This cache fetches the UNION of fields all four actually read
/// once, and each caller reads its own subset back out of the shared map.
///
/// Deliberately scoped to display/edit reads only -- see the reasoning in the egress audit
/// implementation report for why the OTHER `rider_payout_accounts` call-sites are excluded:
/// - `rider_status_service.dart.hasActivePayoutAccount()` and `rider_entry_handler.dart` both
///   check `cashfree_beneficiary_status='active'` to GATE entering/using Drop Partner mode --
///   a security/payment-eligibility decision. A stale cached "active" answer could let a rider
///   proceed on a payout account that was just deactivated. Those two call-sites (and
///   `profile_tab.dart`'s identical existence+active-filter check) intentionally stay direct,
///   uncached, always-fresh queries -- never routed through this cache.
/// - `rider_home_tab.dart`'s quick-VPA-edit sheet filters by `rider_id`, not `user_id` -- a
///   structurally different query shape, left separately queried rather than forced into this
///   cache's key scheme.
///
/// Invalidation: explicit only, called after every write to this rider's own payout account row
/// (bank/UPI details save, QR upload, default-payment-method change) and from
/// `CacheCleanupHelper.clearAllCaches()` on logout/account-switch so a cached row can never survive
/// into a different account's session. No blind TTL -- payout/beneficiary details do not change
/// outside an explicit edit action, so "stale after an edit we didn't invalidate for" is the only
/// staleness risk, not "stale because time passed".
class RiderPayoutAccountCache {
  RiderPayoutAccountCache._();

  static String? _userId;
  static Map<String, dynamic>? _data;
  static Future<Map<String, dynamic>?>? _inFlight;

  static Future<Map<String, dynamic>?> get(
    String userId,
    Future<Map<String, dynamic>?> Function() fetch,
  ) async {
    if (_userId != userId) {
      // Different (or newly-signed-in) account -- never serve another user's cached row.
      _data = null;
      _inFlight = null;
      _userId = userId;
    } else if (_data != null) {
      return _data;
    }

    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final future = fetch();
    _inFlight = future;
    try {
      final result = await future;
      _data = result;
      return result;
    } finally {
      _inFlight = null;
    }
  }

  /// Call after any write to the current user's rider_payout_accounts row.
  static void invalidate() {
    _data = null;
    _inFlight = null;
  }

  /// Call on logout/account-switch.
  static void clear() {
    _userId = null;
    _data = null;
    _inFlight = null;
  }
}
