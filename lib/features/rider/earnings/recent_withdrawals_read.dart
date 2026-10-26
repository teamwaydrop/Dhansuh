import 'dart:convert';
import '../home/pending_assignment_read.dart';

/// Earnings' fixed six-column projection, created_at DESC, limit 10 only.
/// No resolved cache and no sharing with payout/balance or other screens.
class RecentWithdrawalsRead {
  final _reads = InFlightRead<RecentWithdrawalsObservation>();
  final _keys = <String, Set<String>>{};
  int _sequence = 0;
  int _applied = 0;
  bool _disposed = false;
  void invalidate(String userId) {
    for (final key in _keys[userId] ?? <String>{}) { _reads.invalidate(key); }
  }
  void dispose() { _disposed = true; _reads.dispose(); }
  Future<RecentWithdrawalsObservation> read(String userId, String riderId,
      Future<List<Map<String, dynamic>>> Function() fetch) {
    final key = jsonEncode([userId, riderId]);
    (_keys[userId] ??= {}).add(key);
    return _reads.read(key, () async {
      final revision = _reads.revisionFor(key);
      final sequence = ++_sequence;
      final rows = await fetch();
      return RecentWithdrawalsObservation(userId, key, revision, sequence, rows);
    });
  }
  bool isCurrent(RecentWithdrawalsObservation value, String? userId) =>
      !_disposed && value.userId == userId && value.revision == _reads.revisionFor(value.key) &&
      value.sequence >= _applied;
  bool accept(RecentWithdrawalsObservation value, String? userId) {
    if (!isCurrent(value, userId)) return false;
    _applied = value.sequence;
    return true;
  }
}

class RecentWithdrawalsObservation {
  const RecentWithdrawalsObservation(this.userId, this.key, this.revision, this.sequence, this.rows);
  final String userId;
  final String key;
  final int revision;
  final int sequence;
  final List<Map<String, dynamic>> rows;
}
