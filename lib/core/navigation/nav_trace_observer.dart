import 'package:flutter/material.dart';

/// [NAV_TRACE] TEMPORARY instrumentation — delete after root-cause capture. See nav_trace.dart.
///
/// Observes every real push/pop/replace/remove on the app's single Navigator, globally, regardless
/// of which of the three sources triggered it — this is what gives visibility into ordinary
/// in-screen `Navigator.of(context)` calls without editing every call site in the app.
class NavTraceObserver extends NavigatorObserver {
  int _stackDepth = 0;

  String _label(Route<dynamic>? route) {
    if (route == null) return 'null';
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) return name;
    return route.runtimeType.toString();
  }

  void _log(String event, Route<dynamic>? route, Route<dynamic>? previousRoute) {
    final now = DateTime.now();
    debugPrint(
      '[NAV_TRACE] ${now.toIso8601String()} OBSERVER event=$event '
      'route=${_label(route)} previousRoute=${_label(previousRoute)} '
      'stackDepth=$_stackDepth epoch=${now.millisecondsSinceEpoch}',
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stackDepth++;
    _log('didPush', route, previousRoute);
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stackDepth = (_stackDepth - 1).clamp(0, 1 << 30);
    _log('didPop', route, previousRoute);
    super.didPop(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _log('didReplace', newRoute, oldRoute);
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stackDepth = (_stackDepth - 1).clamp(0, 1 << 30);
    _log('didRemove', route, previousRoute);
    super.didRemove(route, previousRoute);
  }

  @override
  void didStartUserGesture(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _log('didStartUserGesture', route, previousRoute);
    super.didStartUserGesture(route, previousRoute);
  }
}
