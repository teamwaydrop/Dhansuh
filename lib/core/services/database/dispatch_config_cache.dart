/// In-memory TTL cache for the single active `dispatch_config` row.
///
/// dispatch_config only changes when an admin edits pricing/dispatch settings, but
/// [RiderOrdersScreen.fetchSearchingOrders] (lib/features/rider/orders/rider_orders_screen.dart)
/// re-read it fresh on every call -- every 10s timer tick, plus every rider_assignments/orders
/// realtime event -- with no cache. This class makes that read cheap without changing what value
/// is used: callers still get the same row shape, just not a fresh network round trip every time.
///
/// Deliberately a plain static in-memory cache, not [CacheService] (lib/core/services/cache) --
/// that cache is a disk-backed, encrypted Hive store meant for persistent/sensitive data and would
/// add async disk I/O to a value re-read multiple times a minute. This value is neither sensitive
/// nor worth persisting across app restarts.
class DispatchConfigCache {
  DispatchConfigCache._();

  /// How long a cached row is trusted before the next call triggers a real fetch. 30s bounds the
  /// worst case an admin's config edit takes to reach a rider's in-progress order list -- well
  /// within the tolerance already accepted elsewhere in this codebase for the same kind of
  /// dispatch-adjacent staleness (e.g. RealtimeOrderController's own 15s realtime-health gate).
  static const Duration ttl = Duration(seconds: 30);

  static Map<String, dynamic>? _data;
  static DateTime? _fetchedAt;
  static Future<Map<String, dynamic>?>? _inFlight;

  /// Returns the cached active dispatch_config row, calling [fetch] to refresh it only if the
  /// cache is empty or older than [ttl]. Concurrent callers that land during a refresh share the
  /// same in-flight request instead of each firing their own duplicate query.
  static Future<Map<String, dynamic>?> get(
    Future<Map<String, dynamic>?> Function() fetch,
  ) async {
    final fetchedAt = _fetchedAt;
    if (_data != null && fetchedAt != null && DateTime.now().difference(fetchedAt) < ttl) {
      return _data;
    }
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final future = fetch();
    _inFlight = future;
    try {
      final result = await future;
      _data = result;
      _fetchedAt = DateTime.now();
      return result;
    } finally {
      _inFlight = null;
    }
  }
}
