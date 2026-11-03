/// Shares unfinished display refresh work. No cache, retry or timeout: a new
/// refresh is admitted only after the actual previous operation has settled.
class SingleFlightRefresh {
  Future<void>? _inFlight;

  Future<void> run(Future<void> Function() action) {
    final existing = _inFlight;
    if (existing != null) return existing;
    final operation = Future<void>.sync(action).whenComplete(() {
      _inFlight = null;
    });
    _inFlight = operation;
    return operation;
  }
}
