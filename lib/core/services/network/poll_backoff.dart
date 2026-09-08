/// Tracks consecutive failures for a `Timer.periodic`-driven poll and tells the
/// caller when to skip a tick instead of firing again on the fixed interval.
///
/// PROBLEM THIS SOLVES (WayDrop Egress Audit, 2026-08-16): every `Timer.periodic` poll
/// in this app fires unconditionally on its fixed interval, even when every recent
/// attempt has errored. When Supabase starts throttling/rejecting requests (e.g. a
/// free-tier egress cap being hit), that means the app keeps hammering the same
/// endpoint on the same cadence -- looking like a hang to the user (stale data,
/// spinners that never resolve, silent `catch` blocks) while actively prolonging the
/// very throttling that caused it, since the retry volume never drops. Backing off
/// here both stops compounding an active throttle and gives Supabase room to recover.
///
/// One instance per polling loop -- deliberately NOT a singleton/static. Each screen's
/// poller tracks its own independent failure history; a failing chat-sync timer
/// should not throttle back an unrelated active-order poll.
///
/// Usage:
/// ```dart
/// final _backoff = PollBackoff();
/// _timer = Timer.periodic(const Duration(seconds: 30), (_) async {
///   if (!_backoff.shouldAttempt()) return;
///   try {
///     await doWork();
///     _backoff.recordSuccess();
///   } catch (e) {
///     _backoff.recordFailure();
///   }
/// });
/// ```
/// For call sites where the polled function already swallows its own errors
/// internally (this codebase's dominant pattern -- a `try/catch` that
/// `debugPrint`s and never rethrows, so the caller can't detect failure by
/// wrapping the call), call `recordSuccess()`/`recordFailure()` directly from
/// inside that function's own success path / catch block instead.
class PollBackoff {
  PollBackoff({this.maxConsecutiveSkips = 8});

  /// Caps how many ticks in a row can be skipped, so a poll that's been failing for a
  /// long time still checks in roughly every (maxConsecutiveSkips + 1) base intervals
  /// instead of backing off forever. E.g. with a 30s base interval, at most
  /// 30s * 9 = 4.5 minutes between attempts once fully backed off -- long enough to
  /// stop compounding a throttle, short enough that recovery is still noticed
  /// reasonably quickly once Supabase clears it.
  final int maxConsecutiveSkips;

  int _consecutiveFailures = 0;
  int _skipsRemaining = 0;

  /// Call at the top of every timer tick (after any existing due-to-fire check, so
  /// skips are counted against the poll's own cadence, not the base timer tick).
  /// Returns false -- and consumes one skip -- if this tick should be skipped due to
  /// recent failures; true if the caller should proceed with its normal request.
  bool shouldAttempt() {
    if (_skipsRemaining > 0) {
      _skipsRemaining--;
      return false;
    }
    return true;
  }

  /// Call after a successful request. Resets backoff back to normal cadence.
  void recordSuccess() {
    _consecutiveFailures = 0;
    _skipsRemaining = 0;
  }

  /// Call after a failed request. Doubles how many subsequent ticks are skipped
  /// before the next attempt (1, 2, 4, 8...), capped at [maxConsecutiveSkips].
  void recordFailure() {
    _consecutiveFailures++;
    final skips = 1 << (_consecutiveFailures - 1).clamp(0, 30);
    _skipsRemaining = skips.clamp(0, maxConsecutiveSkips);
  }

  bool get isBackedOff => _skipsRemaining > 0;
}
