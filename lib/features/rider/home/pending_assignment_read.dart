/// Share only an in-flight, rider-scoped read. Never cache resolved rows: each
/// caller keeps its existing reconciliation and the next trigger reads afresh.
class InFlightRead<T> {
  final _pending = <String, _ReadAttempt<T>>{};
  final _revisions = <String, int>{};
  bool _disposed = false;
  int revisionFor(String riderId) => _revisions[riderId] ?? 0;
  void invalidate(String riderId) { _revisions[riderId] = revisionFor(riderId) + 1; }
  void dispose() { _disposed = true; }

  Future<T> read(String riderId, Future<T> Function() fetch) {
    if (_disposed) return Future.error(StateError('Assignment reader disposed'));
    final revision = revisionFor(riderId);
    final pending = _pending[riderId];
    if (pending != null) {
      if (pending.revision == revision) return pending.future;
      // A committed Realtime change requires a fresh trailing read, not reuse of
      // a query started before the change. Still keep only one active query.
      return pending.trailing ??= pending.future.then(
        (_) => read(riderId, fetch),
        onError: (Object error, StackTrace stack) => read(riderId, fetch),
      );
    }
    late final Future<T> future;
    future = Future<T>.sync(fetch).whenComplete(() {
      if (identical(_pending[riderId]?.future, future)) _pending.remove(riderId);
    });
    _pending[riderId] = _ReadAttempt<T>(revision, future);
    return future;
  }
}

class PendingAssignmentRead extends InFlightRead<List<Map<String, dynamic>>> {}

class _ReadAttempt<T> {
  _ReadAttempt(this.revision, this.future);
  final int revision;
  final Future<T> future;
  Future<T>? trailing;
}
