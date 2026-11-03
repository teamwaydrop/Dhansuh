import 'package:http/http.dart' as http;
import 'performance_trace.dart';

/// Development/profile instrumentation. Never records tokens, query values or bodies.
/// Counts actual HTTP sends, including failed sends; excludes realtime socket frames.
class ApiMetricsClient extends http.BaseClient {
  final http.Client inner;
  final DateTime Function() now;
  final List<({DateTime at, String operation})> _requests = [];
  final Map<String, int> totals = {};
  ApiMetricsClient(this.inner, {DateTime Function()? now})
    : now = now ?? DateTime.now;

  Map<String, int> get requestsLastMinute {
    final cutoff = now().subtract(const Duration(minutes: 1));
    _requests.removeWhere((entry) => !entry.at.isAfter(cutoff));
    final counts = <String, int>{};
    for (final request in _requests) {
      counts.update(request.operation, (count) => count + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final watch = Stopwatch()..start();
    final screen = PerformanceTrace.screen;
    // Only known API collection/function names, never row ids or query strings.
    final parts = request.url.pathSegments;
    final category = parts.isEmpty ? 'http' : parts.first;
    final name = parts.length >= 3 && parts[1] == 'v1'
        ? (parts[2] == 'rpc' && parts.length >= 4
              ? 'rpc/${parts[3]}'
              : parts[2])
        : 'request';
    final operation = '$category ${request.method} $name';
    totals.update(operation, (count) => count + 1, ifAbsent: () => 1);
    _requests.add((at: now(), operation: operation));
    // Prune on writes as well so a long session cannot accumulate an unbounded log.
    requestsLastMinute;
    try {
      final response = await inner.send(request);
      PerformanceTrace.record({
        'kind': 'api_headers',
        'screen': screen,
        'operation': operation,
        'status': response.statusCode,
        'ms': watch.elapsedMilliseconds,
      });
      return http.StreamedResponse(
        _measureBody(response.stream, watch, screen, operation),
        response.statusCode,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (_) {
      PerformanceTrace.record({
        'kind': 'api_failure',
        'screen': screen,
        'operation': operation,
        'ms': watch.elapsedMilliseconds,
      });
      rethrow;
    }
  }

  Stream<List<int>> _measureBody(
    Stream<List<int>> source,
    Stopwatch watch,
    String screen,
    String operation,
  ) async* {
    try {
      yield* source;
    } finally {
      PerformanceTrace.record({
        'kind': 'api_complete',
        'screen': screen,
        'operation': operation,
        'ms': watch.elapsedMilliseconds,
      });
    }
  }

  @override
  void close() => inner.close();
}
