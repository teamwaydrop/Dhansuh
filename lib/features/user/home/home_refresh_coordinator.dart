typedef HomeRefreshOperation = Future<void> Function(bool useInitialData);

/// Serializes passenger-home refreshes while retaining one trailing refresh.
class HomeRefreshCoordinator {
  HomeRefreshCoordinator(this._operation);

  final HomeRefreshOperation _operation;

  bool _inFlight = false;
  bool _queued = false;
  bool _queuedUseInitialData = true;
  bool _disposed = false;

  Future<void> request({bool useInitialData = false}) async {
    if (_disposed) return;
    if (_inFlight) {
      _queued = true;
      // A normal refresh wins over a seeded refresh so a later lifecycle or
      // Realtime trigger always observes current server state.
      _queuedUseInitialData = _queuedUseInitialData && useInitialData;
      return;
    }

    _inFlight = true;
    var nextUseInitialData = useInitialData;
    try {
      while (!_disposed) {
        await _operation(nextUseInitialData);
        if (_disposed || !_queued) break;

        nextUseInitialData = _queuedUseInitialData;
        _queued = false;
        _queuedUseInitialData = true;
      }
    } finally {
      _inFlight = false;
      _queued = false;
      _queuedUseInitialData = true;
    }
  }

  void dispose() {
    _disposed = true;
    _queued = false;
  }
}
