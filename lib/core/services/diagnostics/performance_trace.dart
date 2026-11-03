import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Local numeric diagnostics only. No identifiers, payloads, tokens or URLs.
class PerformanceTrace {
  static const _screenKey = #waydropPerformanceScreen;
  static final samples = Queue<Map<String, Object>>();
  static final frameSamples = Queue<Map<String, Object>>();
  static bool _framesStarted = false;
  static const _exportEnabled = bool.fromEnvironment('WAYDROP_PERF_EXPORT');

  /// An allowlisted, bounded batch suitable for a device log capture. Unknown
  /// labels and extra keys cannot disclose IDs, message text, URLs or tokens.
  @visibleForTesting
  static Map<String, Object> safeDiagnosticBatch() {
    const screens = {
      'startup',
      'tracking',
      'passenger_home',
      'rider_home',
      'rider_orders',
      'notifications',
      'chat',
      'background',
      'choose_route',
    };
    const kinds = {
      'screen_work',
      'api_headers',
      'api_failure',
      'api_complete',
      'retry_wait',
      'frame',
      'route_stage',
    };
    const routeStages = {
      'navigationStart',
      'firstFrame',
      'coordinatesReady',
      'routeStart',
      'routeEnd',
      'mapStart',
      'mapEnd',
      'serviceabilityStart',
      'serviceabilityEnd',
      'pricingStart',
      'pricingEnd',
      'optionRendered',
      'bookingReady',
      'routeFailure',
    };
    final operation = RegExp(
      r'^(rest|auth|functions|storage) (GET|POST|PATCH|HEAD|PUT|DELETE) (orders|riders|rider_kyc|notifications|order_chat_messages|users|production_config|user_device_tokens|pricing_config|pricing_zones|dispatch_config|calculate-order-pricing|create-order|accept-order|start-dispatch|reject-order|user|token|request|rpc/(find_nearby_riders|rider_self_rematch|get_dispatch_round_status))$',
    );
    List<Map<String, Object>> clean(Iterable<Map<String, Object>> rows) => rows
        .map(
          (row) => <String, Object>{
            'kind': kinds.contains(row['kind']) ? row['kind']! : 'other',
            if (row.containsKey('screen'))
              'screen': screens.contains(row['screen'])
                  ? row['screen']!
                  : 'other',
            if (row.containsKey('operation'))
              'operation':
                  row['operation'] is String &&
                      operation.hasMatch(row['operation'] as String)
                  ? row['operation']!
                  : 'other',
            if (row.containsKey('stage'))
              'stage': routeStages.contains(row['stage'])
                  ? row['stage']!
                  : 'other',
            for (final key in [
              'status',
              'ms',
              'build_us',
              'raster_us',
              'at_ms',
              'offset_ms',
              'generation',
            ])
              if (row[key] is num && (row[key] as num).isFinite) key: row[key]!,
          },
        )
        .toList();
    return {'samples': clean(samples), 'frames': clean(frameSamples)};
  }

  @visibleForTesting
  static Iterable<Map<String, Object>> safeDiagnosticChunks() sync* {
    final batch = safeDiagnosticBatch();
    final rows = batch['samples'] as List<Map<String, Object>>;
    final frames = batch['frames'] as List<Map<String, Object>>;
    final length = rows.length > frames.length ? rows.length : frames.length;
    for (var offset = 0; offset < length; offset += 8) {
      yield {
        'samples': rows.skip(offset).take(8).toList(),
        'frames': frames.skip(offset).take(8).toList(),
      };
    }
  }

  static String get screen =>
      Zone.current[_screenKey] as String? ?? 'background';

  static void record(Map<String, Object> sample) {
    if (kReleaseMode) return;
    if (samples.length >= 256) samples.removeFirst();
    samples.add(sample);
  }

  static Future<T> measure<T>(String name, Future<T> Function() action) {
    if (kReleaseMode) return action();
    return runZoned(() async {
      final watch = Stopwatch()..start();
      try {
        return await action();
      } finally {
        record({
          'kind': 'screen_work',
          'screen': name,
          'ms': watch.elapsedMilliseconds,
        });
      }
    }, zoneValues: {_screenKey: name});
  }

  static void startFrames() {
    if (kReleaseMode || _framesStarted) return;
    _framesStarted = true;
    // Opt in on a test device. Release builds never start this exporter.
    // Drain each batch so offline analysis does not count ring snapshots twice.
    if (_exportEnabled) {
      Timer.periodic(const Duration(seconds: 1), (_) {
        // Keep each JSON line below Android's log-entry size limit.
        for (final batch in safeDiagnosticChunks()) {
          debugPrint('WAYDROP_PERF ${jsonEncode(batch)}');
        }
        samples.clear();
        frameSamples.clear();
      });
    }
    SchedulerBinding.instance.addTimingsCallback((frames) {
      for (final frame in frames) {
        if (frameSamples.length >= 256) frameSamples.removeFirst();
        frameSamples.add({
          'kind': 'frame',
          'build_us': frame.buildDuration.inMicroseconds,
          'raster_us': frame.rasterDuration.inMicroseconds,
        });
      }
    });
  }
}
