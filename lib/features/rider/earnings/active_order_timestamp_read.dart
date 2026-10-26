import 'dart:convert';
import '../home/pending_assignment_read.dart';

/// Earnings' fixed timestamp projection/status filter and maybeSingle only.
/// Null is a successful absent row; errors propagate. No resolved cache.
class ActiveOrderTimestampRead {
  final _reads = InFlightRead<ActiveOrderTimestampObservation>();
  final _keys = <String, Set<String>>{};
  int _sequence = 0;
  int _applied = 0;
  bool _disposed = false;
  void invalidate(String userId) {
    for (final key in _keys[userId] ?? <String>{}) { _reads.invalidate(key); }
  }
  void dispose() { _disposed = true; _reads.dispose(); }
  Future<ActiveOrderTimestampObservation> read(String userId, String riderId,
      Future<Map<String, dynamic>?> Function() fetch) {
    final key = jsonEncode([userId, riderId]);
    (_keys[userId] ??= {}).add(key);
    return _reads.read(key, () async {
      final revision = _reads.revisionFor(key);
      final sequence = ++_sequence;
      final row = await fetch();
      return ActiveOrderTimestampObservation(userId, key, revision, sequence, row);
    });
  }
  bool isCurrent(ActiveOrderTimestampObservation value, String? userId) =>
      !_disposed && value.userId == userId && value.revision == _reads.revisionFor(value.key) &&
      value.sequence >= _applied;
  bool accept(ActiveOrderTimestampObservation value, String? userId) {
    if (!isCurrent(value, userId)) return false;
    _applied = value.sequence;
    return true;
  }
}

class ActiveOrderTimestampObservation {
  const ActiveOrderTimestampObservation(this.userId, this.key, this.revision, this.sequence, this.row);
  final String userId;
  final String key;
  final int revision;
  final int sequence;
  final Map<String, dynamic>? row;
}
