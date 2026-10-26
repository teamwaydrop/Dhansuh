enum OfflineTrackingRollback { restored, unavailable, retired }

/// Tracking readiness is not backend status evidence. Only an existing profile
/// read begun after uncertainty was recorded may resolve an unknown write outcome.
/// The caller fences reads/updates to its current rider and authenticated identity.
class OfflineStatusEvidence {
  int _revision = 0;
  bool _writing = false;
  bool _unknown = false;
  bool get unknown => _unknown;
  int get readRevision => _revision;
  void beginWrite() { _revision++; _writing = true; }
  void finishWrite() { _revision++; _writing = false; }
  void markUnknown() { _revision++; _unknown = true; }
  void resetIdentity() { _revision++; _unknown = false; _writing = false; }
  bool acceptsRead(int revision) => !_writing && revision == _revision;
  void confirmRead(int revision, Object? status) {
    if (acceptsRead(revision) && (status == 'online' || status == 'offline')) {
      _unknown = false;
    }
  }
  bool permitsOnline(bool trackingReady) => !unknown && trackingReady;
  bool permitsOnlineOperation(int revision, {
    required bool mounted,
    required String? userId,
    required String? riderId,
    required String? currentUserId,
    required String? currentRiderId,
  }) => mounted && userId != null && riderId != null &&
      userId == currentUserId && riderId == currentRiderId &&
      acceptsRead(revision) && !unknown;
}

/// Restore resources before publishing online state. Callers own UI mutation;
/// an operation that loses its identity may neither restore nor clean up theirs.
Future<OfflineTrackingRollback> restoreOfflineTracking({
  required bool Function() isCurrentIdentity,
  required bool Function() isTrackingActive,
  required Future<void> Function() restartTracking,
  required Future<void> Function() stopIncompleteTracking,
}) async {
  if (!isCurrentIdentity()) return OfflineTrackingRollback.retired;
  try {
    if (!isTrackingActive()) await restartTracking();
    if (!isCurrentIdentity()) return OfflineTrackingRollback.retired;
    if (isTrackingActive()) return OfflineTrackingRollback.restored;
  } catch (_) {
    if (!isCurrentIdentity()) return OfflineTrackingRollback.retired;
  }
  // Startup can resolve quietly without a stream, or leave only a heartbeat.
  // Retire only this owner's incomplete resources; no automatic retry/write.
  if (isCurrentIdentity()) {
    try {
      await stopIncompleteTracking();
    } catch (_) {
      // The caller still reports unavailable rather than advertising success.
    }
  }
  return isCurrentIdentity()
      ? OfflineTrackingRollback.unavailable : OfflineTrackingRollback.retired;
}
