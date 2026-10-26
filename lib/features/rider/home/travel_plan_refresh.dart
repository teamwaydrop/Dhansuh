import 'active_order_refresh_coordinator.dart';

class TravelPlanSnapshot {
  TravelPlanSnapshot(this.plans, this.acceptedCounts, this.pendingCounts);
  final List<Map<String, dynamic>> plans;
  final Map<String, int> acceptedCounts;
  final Map<String, int> pendingCounts;
}

/// Plans and counts form one UI snapshot, not one database transaction.
/// Ordinary demand queues at most one trailing batch. Authoritative plan events
/// and completed local mutations invalidate older batches. Never publish just
/// the first query; retain the previous UI on either query's failure.
class TravelPlanRefresh {
  TravelPlanRefresh({
    required this.currentRiderId,
    required this.fetchPlans,
    required this.fetchRequests,
    required void Function(TravelPlanSnapshot) apply,
    required this.onFailure,
  }) {
    _coordinator = ActiveOrderRefreshCoordinator<TravelPlanSnapshot>(
      currentRiderId: currentRiderId, fetch: _fetch, apply: apply);
  }
  final String? Function() currentRiderId;
  final Future<List<Map<String, dynamic>>> Function(String) fetchPlans;
  final Future<List<Map<String, dynamic>>> Function(List<String>) fetchRequests;
  final void Function() onFailure;
  late final ActiveOrderRefreshCoordinator<TravelPlanSnapshot> _coordinator;
  bool _disposed = false;

  Future<void> request(String riderId) => _coordinator.request(riderId);
  void invalidate() => _coordinator.invalidate();
  void dispose() { _disposed = true; _coordinator.dispose(); }

  Future<TravelPlanSnapshot> _fetch(String riderId) async {
    final revision = _coordinator.invalidationRevision;
    bool current() => !_disposed && currentRiderId() == riderId &&
        revision == _coordinator.invalidationRevision;
    try {
      final plans = await fetchPlans(riderId);
      if (!current()) throw StateError('Travel plan refresh retired');
      final ids = plans.map((p) => p['id'].toString()).toList();
      final accepted = <String, int>{};
      final pending = <String, int>{};
      if (ids.isNotEmpty) {
        final rows = await fetchRequests(ids);
        if (!current()) throw StateError('Travel plan refresh retired');
        for (final row in rows) {
          final routeId = row['route_id']?.toString();
          if (routeId == null) continue;
          final status = row['status']?.toString();
          if (['confirmed', 'paid', 'in_progress'].contains(status)) {
            accepted[routeId] = (accepted[routeId] ?? 0) + 1;
          } else if (['request_sent', 'discussion_started', 'fare_agreed'].contains(status)) {
            pending[routeId] = (pending[routeId] ?? 0) + 1;
          }
        }
      }
      return TravelPlanSnapshot(plans, accepted, pending);
    } catch (_) {
      if (current()) onFailure();
      rethrow; // The existing coordinator retains best-effort caller semantics.
    }
  }
}
