import '../home/pending_assignment_read.dart';

/// Coordinates only the active tax-config projection. Never caches completed
/// results or shares across accounts; config has no rider/day filter.
class EarningsThresholdRead {
  final _reads = InFlightRead<EarningsThresholdObservation>();
  int _sequence = 0;
  int _appliedSequence = 0;
  bool _disposed = false;
  void invalidate(String userId) => _reads.invalidate(userId);
  void dispose() { _disposed = true; _reads.dispose(); }
  Future<EarningsThresholdObservation> read(String userId,
      Future<Map<String, dynamic>?> Function() fetch) => _reads.read(userId, () async {
    final revision = _reads.revisionFor(userId);
    final sequence = ++_sequence;
    double value = 100.0; // Existing config lookup fallback, not an earnings amount.
    var failed = false;
    try {
      final row = await fetch();
      if (row != null) value = double.tryParse('${row['threshold_amount']}') ?? 100.0;
    } catch (_) { failed = true; }
    return EarningsThresholdObservation(userId, revision, sequence, value, failed);
  });
  bool accept(EarningsThresholdObservation value, String? currentUserId) {
    if (_disposed || value.userId != currentUserId ||
        _reads.revisionFor(value.userId) != value.revision || value.sequence < _appliedSequence) return false;
    _appliedSequence = value.sequence;
    return true;
  }
}

class EarningsThresholdObservation {
  const EarningsThresholdObservation(this.userId, this.revision, this.sequence, this.value, this.failed);
  final String userId;
  final int revision;
  final int sequence;
  final double value;
  final bool failed;
}
