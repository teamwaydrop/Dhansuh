import 'package:flutter/foundation.dart';

class RealtimeObservability {
  static final RealtimeObservability instance = RealtimeObservability._internal();
  RealtimeObservability._internal();

  int realtimeReconnectCount = 0;
  int activeChannelCount = 0;
  double apiErrorRate = 0.0;
  double cacheHitRate = 0.0;
  int subscriptionCreateCount = 0;
  int subscriptionDisposeCount = 0;
  int channelErrorCount = 0;
  int totalReconnectTimeMs = 0;
  int reconnectAttemptsCount = 0;
  int heartbeatFailures = 0;

  double get averageReconnectTimeMs =>
      reconnectAttemptsCount == 0 ? 0.0 : totalReconnectTimeMs / reconnectAttemptsCount;

  void recordReconnect(int durationMs) {
    realtimeReconnectCount++;
    reconnectAttemptsCount++;
    totalReconnectTimeMs += durationMs;
  }

  void recordHeartbeatFailure() {
    heartbeatFailures++;
  }

  void recordChannelError() {
    channelErrorCount++;
  }

  void recordSubscriptionCreate() {
    subscriptionCreateCount++;
  }

  void recordSubscriptionDispose() {
    subscriptionDisposeCount++;
  }

  void updateActiveChannelCount(int count) {
    activeChannelCount = count;
  }

  void updateApiErrorRate(double rate) {
    apiErrorRate = rate;
  }

  void updateCacheHitRate(double rate) {
    cacheHitRate = rate;
  }

  Map<String, dynamic> getMetricsSummary() {
    return {
      'realtime_reconnect_count': realtimeReconnectCount,
      'active_channel_count': activeChannelCount,
      'api_error_rate': apiErrorRate,
      'cache_hit_rate': cacheHitRate,
      'subscription_create_count': subscriptionCreateCount,
      'subscription_dispose_count': subscriptionDisposeCount,
      'channel_error_count': channelErrorCount,
      'average_reconnect_time_ms': averageReconnectTimeMs,
      'heartbeat_failures': heartbeatFailures,
    };
  }

  void printMetrics() {
    debugPrint('=== REALTIME METRICS ===');
    getMetricsSummary().forEach((key, value) {
      debugPrint('$key: $value');
    });
  }
}
