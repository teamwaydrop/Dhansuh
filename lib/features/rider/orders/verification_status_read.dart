import '../home/pending_assignment_read.dart';

/// Order-scoped pickup/dropoff evidence, not account KYC or passenger photos.
/// No completed-result cache. Writers invalidate before work and request a
/// fresh read after confirmation; older observations cannot be applied.
class VerificationStatusRead {
  final _reads = InFlightRead<VerificationStatusObservation>();
  bool _disposed = false;
  void invalidate(String scope) => _reads.invalidate(scope);
  void dispose() { _disposed = true; _reads.dispose(); }
  bool isCurrent(VerificationStatusObservation value) =>
      !_disposed && _reads.revisionFor(value.scope) == value.revision;

  Future<VerificationStatusObservation> read(
      String scope, Future<Object?> Function() fetch) {
    return _reads.read(scope, () async {
      final revision = _reads.revisionFor(scope);
      final rows = await fetch();
      if (rows is! List) throw StateError('Invalid verification response');
      var pickup = false;
      var dropoff = false;
      for (final row in rows) {
        if (row is! Map ||
            !const ['pickup', 'dropoff', 'damage_report', 'signature']
                .contains(row['verification_type']) ||
            !const ['verified', 'bypassed', 'pending_sync', 'failed']
                .contains(row['verification_status'])) {
          throw StateError('Invalid verification response');
        }
        final completed = row['verification_status'] == 'verified' ||
            row['verification_status'] == 'bypassed';
        pickup |= row['verification_type'] == 'pickup' && completed;
        dropoff |= row['verification_type'] == 'dropoff' && completed;
      }
      return VerificationStatusObservation(scope, revision, pickup, dropoff);
    });
  }
}

class VerificationStatusObservation {
  const VerificationStatusObservation(
      this.scope, this.revision, this.pickup, this.dropoff);
  final String scope;
  final int revision;
  final bool pickup;
  final bool dropoff;
}
