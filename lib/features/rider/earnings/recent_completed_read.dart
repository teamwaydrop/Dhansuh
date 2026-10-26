import 'dart:convert';
import '../home/pending_assignment_read.dart';

/// Only Earnings' fixed latest-three projection/status/order/limit contract.
/// No completed cache; existing fresh triggers invalidate pre-event evidence.
class RecentCompletedRead {
  final _reads = InFlightRead<RecentCompletedObservation>();
  final _keys = <String, Set<String>>{};
  int _sequence = 0;
  int _applied = 0;
  bool _disposed = false;
  void invalidate(String userId) {
    for (final key in _keys[userId] ?? <String>{}) { _reads.invalidate(key); }
  }
  void dispose() { _disposed = true; _reads.dispose(); }
  Future<RecentCompletedObservation> read(String userId, String riderId,
      Future<List<Map<String, dynamic>>> Function() fetch) {
    final key = jsonEncode([userId, riderId]);
    (_keys[userId] ??= {}).add(key);
    return _reads.read(key, () async {
      final revision = _reads.revisionFor(key);
      final sequence = ++_sequence;
      final rows = await fetch();
      return RecentCompletedObservation(userId, key, revision, sequence, rows);
    });
  }
  bool isCurrent(RecentCompletedObservation value, String? userId) =>
      !_disposed && value.userId == userId && value.revision == _reads.revisionFor(value.key) &&
      value.sequence >= _applied;
  bool accept(RecentCompletedObservation value, String? userId) {
    if (!isCurrent(value, userId)) return false;
    _applied = value.sequence;
    return true;
  }
}

class RecentCompletedObservation {
  const RecentCompletedObservation(this.userId, this.key, this.revision, this.sequence, this.rows);
  final String userId;
  final String key;
  final int revision;
  final int sequence;
  final List<Map<String, dynamic>> rows;
}
