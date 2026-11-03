import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/core/services/diagnostics/performance_trace.dart';

void main() {
  test(
    'route timing export allowlists stages and excludes location details',
    () {
      PerformanceTrace.samples.add({
        'kind': 'route_stage',
        'screen': 'choose_route',
        'stage': 'pricingStart',
        'at_ms': 123,
        'offset_ms': 45,
        'generation': 2,
        'latitude': 17.2,
        'address': 'private-address',
      });
      PerformanceTrace.samples.add({
        'kind': 'route_stage',
        'stage': 'private-stage',
        'offset_ms': double.infinity,
      });
      final data = jsonEncode(PerformanceTrace.safeDiagnosticBatch());
      expect(data, contains('pricingStart'));
      expect(data, contains('45'));
      expect(data, isNot(contains('private')));
      expect(data, isNot(contains('latitude')));
      expect(data, isNot(contains('Infinity')));
    },
  );
  tearDown(() {
    PerformanceTrace.samples.clear();
    PerformanceTrace.frameSamples.clear();
  });
  test(
    'device export preserves numeric API and frame evidence without private fields',
    () {
      PerformanceTrace.samples.add({
        'kind': 'api_complete',
        'screen': 'chat',
        'operation': 'rest POST order_chat_messages',
        'ms': 35,
        'status': 201,
        'token': 'synthetic-private-token',
        'message': 'synthetic-private-text',
        'url': 'https://private.invalid',
      });
      PerformanceTrace.frameSamples.add({
        'kind': 'frame',
        'build_us': 1500,
        'raster_us': 1800,
        'user_id': 'synthetic-private-user',
      });
      final batch = PerformanceTrace.safeDiagnosticBatch();
      final text = jsonEncode(batch);
      expect(text, contains('rest POST order_chat_messages'));
      expect(text, contains('1500'));
      expect(text, contains('35'));
      expect(text, isNot(contains('private')));
      expect(text, isNot(contains('token')));
      expect(text, isNot(contains('user_id')));
    },
  );
  test('unexpected labels cannot smuggle private values into log capture', () {
    PerformanceTrace.samples.add({
      'kind': 'synthetic-private-kind',
      'screen': 'synthetic-private-screen',
      'operation': 'rest GET users?token=synthetic-private-token',
      'ms': double.infinity,
    });
    expect(
      jsonEncode(PerformanceTrace.safeDiagnosticBatch()),
      isNot(contains('private')),
    );
    expect(
      jsonEncode(PerformanceTrace.safeDiagnosticBatch()),
      isNot(contains('Infinity')),
    );
    // Reading the sanitized batch itself does not mutate diagnostics.
    expect(PerformanceTrace.samples.length, 1);
  });
  test(
    'device log chunks retain all bounded samples without oversized JSON lines',
    () {
      for (var i = 0; i < 256; i++) {
        PerformanceTrace.samples.add({
          'kind': 'api_complete',
          'screen': 'rider_home',
          'operation': 'rest POST rpc/get_dispatch_round_status',
          'ms': i,
        });
        PerformanceTrace.frameSamples.add({
          'kind': 'frame',
          'build_us': i,
          'raster_us': i,
        });
      }
      final chunks = PerformanceTrace.safeDiagnosticChunks().toList();
      expect(chunks.length, 32);
      expect(chunks.expand((c) => c['samples'] as List).length, 256);
      expect(chunks.expand((c) => c['frames'] as List).length, 256);
      for (final chunk in chunks) {
        expect(
          utf8.encode('WAYDROP_PERF ${jsonEncode(chunk)}').length,
          lessThan(4000),
        );
      }
    },
  );
}
