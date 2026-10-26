/// One widget-owned cached future for one account and query purpose. No global
/// cache, TTL or retries. Identity/purpose changes retire even pending results.
class IdentityScopedFuture<T> {
  IdentityScopedFuture(this.currentUserId);
  final String? Function() currentUserId;
  (String, String)? _scope;
  Future<T?>? _future;
  int _revision = 0;
  bool _disposed = false;

  Future<T?> read(String purpose, Future<T?> Function() fetch) {
    final userId = currentUserId();
    if (_disposed || userId == null) {
      _scope = null;
      _future = null;
      _revision++;
      return Future.value(null);
    }
    final scope = (userId, purpose);
    if (_scope == scope && _future != null) return _future!;
    _scope = scope;
    final revision = ++_revision;
    return _future = Future<T?>.sync(fetch).then((value) =>
        !_disposed && currentUserId() == userId && _scope == scope &&
            revision == _revision ? value : null);
  }

  void dispose() { _disposed = true; _revision++; _future = null; }
}
