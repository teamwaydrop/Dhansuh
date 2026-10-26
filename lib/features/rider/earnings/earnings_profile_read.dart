import '../home/pending_assignment_read.dart';

/// Only Earnings' identical user_id-scoped projection. No completed cache.
/// Fresh triggers retire pre-event evidence and retain one trailing read.
class EarningsProfileRead {
  final _reads = InFlightRead<EarningsProfileObservation>();
  int _sequence = 0;
  int _appliedSequence = 0;
  bool _disposed = false;
  void invalidate(String userId) => _reads.invalidate(userId);
  void dispose() { _disposed = true; _reads.dispose(); }
  EarningsProfileObservation seed(String userId, Map<String, dynamic> row) =>
      EarningsProfileObservation(userId, _reads.revisionFor(userId), ++_sequence, row);
  Future<EarningsProfileObservation> read(String userId,
      Future<Map<String, dynamic>> Function() fetch) => _reads.read(userId, () async {
    final revision = _reads.revisionFor(userId);
    final sequence = ++_sequence;
    final row = await fetch(); // Preserve original query errors; never substitute a row.
    return EarningsProfileObservation(userId, revision, sequence, row);
  });
  bool isCurrent(EarningsProfileObservation row, String? currentUserId) =>
      !_disposed && row.userId == currentUserId &&
      row.revision == _reads.revisionFor(row.userId) && row.sequence >= _appliedSequence;
  bool accept(EarningsProfileObservation row, String? currentUserId) {
    if (!isCurrent(row, currentUserId)) return false;
    _appliedSequence = row.sequence;
    return true;
  }
}

class EarningsProfileObservation {
  const EarningsProfileObservation(this.userId, this.revision, this.sequence, this.row);
  final String userId;
  final int revision;
  final int sequence;
  final Map<String, dynamic> row;
}
