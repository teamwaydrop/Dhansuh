/// Polling belongs to one reconciliation attempt. Winning Realtime, the existing
/// deadline, disposal or a replacement attempt retires it; issued reads cannot be cancelled.
Future<bool> pollCompletionStatus({required String targetStatus,
  required Future<String?> Function() fetch,
  required bool Function() ownsAttempt,
  required void Function(Object error) onError,
  Future<void> Function(Duration delay)? wait}) async {
  const delays = [Duration.zero, Duration(seconds: 3), Duration(seconds: 6),
    Duration(seconds: 10), Duration(seconds: 15), Duration(seconds: 20), Duration(seconds: 20)];
  for (final delay in delays) {
    if (!ownsAttempt()) return false;
    if (delay > Duration.zero) {
      await (wait ?? Future<void>.delayed)(delay);
      if (!ownsAttempt()) return false;
    }
    try {
      final status = await fetch();
      if (!ownsAttempt()) return false;
      if (status == targetStatus) return true;
    } catch (error) {
      if (!ownsAttempt()) return false;
      onError(error);
    }
  }
  return false;
}
