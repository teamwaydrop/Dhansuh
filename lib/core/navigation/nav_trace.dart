import 'package:flutter/material.dart';

/// [NAV_TRACE] TEMPORARY instrumentation — delete after root-cause capture.
///
/// Evidence-gathering only, not a fix. Proves/disproves a hypothesized race between the app's
/// three independent navigation-mutating sources: AppStartScreen's auth-driven root content swap
/// (a setState, not a real Navigator mutation, so invisible to [NavTraceObserver] on its own),
/// ordinary in-screen Navigator.push/pop/etc calls (captured globally via [NavTraceObserver]
/// instead of touching every call site), and NotificationService's FCM-tap-driven
/// navigatorKey.currentState calls.
///
/// [begin]/[end] bracket the exact moment a source attempts a navigation mutation. `inFlightBefore
/// > 0` at a [begin] call is the direct "another source's navigation was already in flight right
/// now" signal — correlate its timestamp against [NavTraceObserver]'s own log lines (same
/// `[NAV_TRACE]` tag, same epoch clock) to see exactly which call landed last before a black
/// screen.
class NavTrace {
  NavTrace._();

  static int _inFlight = 0;
  static String? _lastSource;
  static String? _lastDetail;
  static DateTime? _lastStart;

  static bool begin(String source, String detail) {
    final now = DateTime.now();
    final overlapping = _inFlight > 0;
    debugPrint(
      '[NAV_TRACE] ${now.toIso8601String()} BEGIN source=$source detail="$detail" '
      'inFlightBefore=$_inFlight overlapping=$overlapping lastSource=$_lastSource '
      'lastDetail="$_lastDetail" lastStart=$_lastStart epoch=${now.millisecondsSinceEpoch}',
    );
    _inFlight++;
    _lastSource = source;
    _lastDetail = detail;
    _lastStart = now;
    return overlapping;
  }

  static void end(String source, String detail) {
    final now = DateTime.now();
    _inFlight = (_inFlight - 1).clamp(0, 1 << 30);
    debugPrint(
      '[NAV_TRACE] ${now.toIso8601String()} END source=$source detail="$detail" '
      'inFlightAfter=$_inFlight epoch=${now.millisecondsSinceEpoch}',
    );
  }

  /// One-shot log for events that aren't a bracketed begin/end pair (e.g. an auth event arriving,
  /// a notification payload received) but still need a timestamp on the same shared clock/tag to
  /// correlate against begin/end/observer lines.
  static void mark(String source, String detail) {
    final now = DateTime.now();
    debugPrint(
      '[NAV_TRACE] ${now.toIso8601String()} MARK source=$source detail="$detail" '
      'inFlight=$_inFlight epoch=${now.millisecondsSinceEpoch}',
    );
  }
}
