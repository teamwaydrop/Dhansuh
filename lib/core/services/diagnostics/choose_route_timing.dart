import 'package:flutter/foundation.dart';
import 'package:waydrop/core/services/diagnostics/performance_trace.dart';

enum ChooseRouteStage {
  navigationStart,
  firstFrame,
  coordinatesReady,
  routeStart,
  routeEnd,
  mapStart,
  mapEnd,
  serviceabilityStart,
  serviceabilityEnd,
  pricingStart,
  pricingEnd,
  optionRendered,
  bookingReady,
  routeFailure,
}

/// Debug/profile only. Never records coordinates, addresses, IDs or fares.
class ChooseRouteTiming {
  final int generation;
  final Stopwatch _watch = Stopwatch()..start();
  final _once = <ChooseRouteStage>{};
  ChooseRouteTiming(this.generation);
  void mark(ChooseRouteStage stage, {bool once = false}) {
    if (kReleaseMode || (once && !_once.add(stage))) return;
    PerformanceTrace.record({
      'kind': 'route_stage',
      'screen': 'choose_route',
      'stage': stage.name,
      'at_ms': DateTime.now().millisecondsSinceEpoch,
      'offset_ms': _watch.elapsedMilliseconds,
      'generation': generation,
    });
  }
}
