import 'pending_assignment_read.dart';

/// Coordinate only the raw profile query. Earnings, order verification, travel
/// plans and assignments retain their independent contracts and caller logic.
class RiderProfileRead {
  final _reads = PendingAssignmentRead();
  final _statusScopes = <String, int>{};
  int _applicationRevision = 0;
  int get applicationRevision => _applicationRevision;

  int prepare(String userId, int statusScope) {
    if (_statusScopes[userId] != statusScope) {
      _statusScopes[userId] = statusScope;
      _reads.invalidate(userId);
    }
    return _reads.revisionFor(userId);
  }
  int invalidate(String userId) {
    _reads.invalidate(userId);
    return _reads.revisionFor(userId);
  }
  bool isCurrent(String userId, int revision) => _reads.revisionFor(userId) == revision;
  void applied() { _applicationRevision++; }
  void dispose() => _reads.dispose();

  Future<Map<String, dynamic>?> read(String userId,
      Future<Map<String, dynamic>?> Function() fetch) async {
    final rows = await _reads.read(userId, () async {
      final row = await fetch();
      return row == null ? [] : [row];
    });
    // Callers enrich KYC display fields; don't share a mutable top-level map.
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.single);
  }
}
