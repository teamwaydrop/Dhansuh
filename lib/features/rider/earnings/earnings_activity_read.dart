import 'dart:convert';
import '../home/pending_assignment_read.dart';

/// Shares only the fixed daily-activity projection and identical query bounds.
/// Completed results are not cached. Existing UI triggers define freshness.
class EarningsActivityRead {
  final _reads = InFlightRead<EarningsActivityObservation>();
  final _keys = <String, Set<String>>{};
  int _sequence = 0;
  int _applied = 0;
  bool _disposed = false;
  void invalidate(String userId) {
    for (final key in _keys[userId] ?? <String>{}) { _reads.invalidate(key); }
  }
  void dispose() { _disposed = true; _reads.dispose(); }
  Future<EarningsActivityObservation> read(String userId, String riderId, String since,
      Future<List<Map<String, dynamic>>> Function() fetch) {
    final key = jsonEncode([userId, riderId, since]);
    (_keys[userId] ??= {}).add(key);
    return _reads.read(key, () async {
      final revision = _reads.revisionFor(key);
      final sequence = ++_sequence;
      final rows = await fetch();
      return EarningsActivityObservation(userId, key, revision, sequence, rows);
    });
  }
  bool accept(EarningsActivityObservation value, String? userId) {
    if (_disposed || value.userId != userId || value.revision != _reads.revisionFor(value.key) ||
        value.sequence < _applied) {
      return false;
    }
    _applied = value.sequence;
    return true;
  }
}

class EarningsActivityObservation {
  const EarningsActivityObservation(this.userId, this.key, this.revision, this.sequence, this.rows);
  final String userId;
  final String key;
  final int revision;
  final int sequence;
  final List<Map<String, dynamic>> rows;
}
