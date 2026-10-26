/// Cosmetic map refreshes may skip overlap: the existing timer supplies the next
/// refresh. Invalidating a route rejects its result without treating absence as
/// authoritative. No request cancellation, retry, or extra timer is introduced.
class NearbyRiderRefresh {
  bool _running = false;
  bool _disposed = false;
  int _revision = 0;

  void invalidate() { _revision++; }
  void dispose() { _disposed = true; invalidate(); }

  Future<void> run<T>({
    required Future<T> Function() fetch,
    required bool Function() isCurrent,
    required Future<void> Function(T) apply,
  }) async {
    if (_running || _disposed || !isCurrent()) return;
    _running = true;
    final revision = _revision;
    try {
      final result = await fetch();
      if (!_disposed && revision == _revision && isCurrent()) {
        await apply(result);
      }
    } finally {
      _running = false;
    }
  }
}
