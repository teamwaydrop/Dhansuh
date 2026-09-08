/// In-memory cache for the `government_tax_ledger` ORDER_TAX row of a given order, keyed by
/// order_id.
///
/// Unlike [DispatchConfigCache] (a single admin-editable row that can change at any time), a
/// government_tax_ledger entry is written once by apply_order_government_tax() for a given order
/// and never updated afterwards -- it's an immutable historical ledger row, not live config. That
/// makes it safe to cache a FOUND row indefinitely per order_id with no TTL/staleness risk: once
/// fetched, an order's tax entry can never go stale.
///
/// Egress fix (Fix #6): rider_activity_tab.dart, rider_order_history_screen.dart,
/// rider_earnings_tab.dart, and rider_active_order_screen.dart each independently ran the exact
/// same `.select('amount, rate_percent').eq('order_id', orderId).eq('entry_type', 'ORDER_TAX')`
/// lookup, including re-running it every time the same order's detail sheet was reopened within a
/// session. This does not touch how the tax amount/rate is calculated or written -- only where a
/// screen that already fetched it once reads it from on a subsequent open.
///
/// Deliberately a plain static in-memory cache, not [CacheService] (disk-backed) -- this value is
/// only useful for the lifetime of the current session and isn't worth persisting across restarts.
///
/// PHASE 2 / ISSUE 5 FIX ("Government Tax shows ₹0.00" on the intercity parcel completion
/// screen): a `null` result (no row found -- e.g. the query genuinely ran before settlement, or a
/// transient network error left `fetch()` returning/throwing early) used to be cached exactly like
/// a real row, FOREVER, for that order_id -- there was no way for ANY later, legitimate query
/// (once the row really does exist) to ever see it again within the same app session. Verified
/// directly against a local Postgres instance running every current migration:
/// apply_order_government_tax()/confirm_intercity_parcel_payment_received() ALREADY compute and
/// persist the correct amount (a ₹261 taxable base at the seeded parcel_delivery 18% rate produces
/// exactly ₹46.98, written to the ledger the instant settlement commits) -- the backend was never
/// the problem. A `null` is now never cached: the next call for that order_id always re-queries,
/// so a genuinely-missing-so-far row can never permanently mask a real one that lands moments
/// later (or after a transient fetch failure clears up).
class GovernmentTaxLedgerCache {
  GovernmentTaxLedgerCache._();

  static final Map<String, Map<String, dynamic>?> _cache = {};
  static final Map<String, Future<Map<String, dynamic>?>> _inFlight = {};

  /// Returns the cached ORDER_TAX row for [orderId], calling [fetch] only while no successful
  /// result has been cached yet for that order. Concurrent callers for the same order share the
  /// same in-flight request. A `null` result is NEVER cached (see class doc) -- only a genuinely
  /// found row is; call [invalidate] to explicitly forget a cached row (rarely needed, since a
  /// found row can never go stale).
  static Future<Map<String, dynamic>?> get(
    String orderId,
    Future<Map<String, dynamic>?> Function() fetch,
  ) async {
    if (_cache.containsKey(orderId)) {
      return _cache[orderId];
    }
    final inFlight = _inFlight[orderId];
    if (inFlight != null) return inFlight;

    final future = fetch();
    _inFlight[orderId] = future;
    try {
      final result = await future;
      if (result != null) {
        _cache[orderId] = result;
      }
      return result;
    } finally {
      _inFlight.remove(orderId);
    }
  }

  static void invalidate(String orderId) => _cache.remove(orderId);

  /// Call on logout/account-switch (mirrors RiderPayoutAccountCache.clear() /
  /// QrSignedUrlCache.clear()). This cache is keyed by order_id, not user_id, so a stale entry
  /// can't itself leak one user's data into another's session unless a second account somehow
  /// queries the exact same order_id -- still cleared here for consistency with the other
  /// session-lifetime caches and to bound its memory to the current session.
  static void clearAll() {
    _cache.clear();
    _inFlight.clear();
  }
}
