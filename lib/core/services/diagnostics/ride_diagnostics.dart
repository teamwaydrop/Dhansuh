import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

enum RideEvent {
  action,
  requestStart,
  response,
  confirmed,
  timeoutUnknown,
  exceptionUnknown,
  rejected,
  realtimeReceipt,
  applied,
  rendered,
  linked,
  observationSkipped,
  evidenceMismatch,
}

enum RideEndpoint {
  booking,
  acceptance,
  intercityAcceptance,
  status,
  intercityArrival,
  intercityCompletion,
  intercitySettlement,
  planStart,
  fallback,
  orderRead,
  liveStatus,
  verificationRead,
  assignmentFeed,
}

enum RideStatus {
  created,
  searching,
  accepted,
  riderArrived,
  ongoing,
  pickedUp,
  riderAtDrop,
  paymentPending,
  completed,
  delivered,
  cancelled,
  expired,
}

enum RideSurface {
  booking,
  riderHome,
  riderOrders,
  riderActive,
  intercityBookings,
  travelPlan,
  passengerSearching,
  passengerTracking,
  orderController,
  incomingCard,
}

enum RideCounter {
  gpsCallbacks,
  gpsIgnoredCallbacks,
  heartbeatCallbacks,
  locationWriteStarts,
  locationWriteResponses,
  locationWriteUnknown,
  realtimeReconnects,
  subscriptionCreates,
  subscriptionDisposes,
  channelErrors,
  requestStarts,
  requestResponses,
  requestTimeouts,
  requestExceptions,
}

RideStatus? diagnosticStatus(Object? value) => switch (value) {
  'created' => RideStatus.created,
  'searching' => RideStatus.searching,
  'accepted' => RideStatus.accepted,
  'rider_arrived' => RideStatus.riderArrived,
  'ongoing' => RideStatus.ongoing,
  'picked_up' => RideStatus.pickedUp,
  'rider_at_drop' => RideStatus.riderAtDrop,
  'payment_pending' => RideStatus.paymentPending,
  'completed' => RideStatus.completed,
  'delivered' => RideStatus.delivered,
  'cancelled' => RideStatus.cancelled,
  'expired' => RideStatus.expired,
  _ => null,
};

/// Only whitelisted, generated fields enter this buffer. No I/O or raw payload logging.
class RideDiagnostics {
  RideDiagnostics({
    this.enabled = false,
    this.capacity = 2048,
    int Function()? monotonicMicros,
    List<int>? pseudonymKey,
  }) : _clock = monotonicMicros {
    if (capacity < 1 || capacity > 8192) {
      throw ArgumentError('Invalid capacity');
    }
    if (pseudonymKey != null) {
      if (pseudonymKey.length != 32 ||
          pseudonymKey.any((v) => v < 0 || v > 255)) {
        throw ArgumentError('Invalid pseudonym key');
      }
      _key = List<int>.unmodifiable(pseudonymKey);
    }
  }
  static final instance = _fromBuild();
  static RideDiagnostics _fromBuild() {
    if (!const bool.fromEnvironment('WAYDROP_LOCAL_RIDE_DIAGNOSTICS')) {
      return RideDiagnostics();
    }
    try {
      const encodedKey = String.fromEnvironment('WAYDROP_DIAGNOSTIC_RUN_KEY');
      if (encodedKey.length != 44) return RideDiagnostics();
      final key = base64Decode(encodedKey);
      return RideDiagnostics(enabled: true, pseudonymKey: key);
    } catch (_) {
      return RideDiagnostics();
    } // Misconfigured diagnostics fail disabled.
  }

  final bool enabled;
  final int capacity;
  final int Function()? _clock;
  final Stopwatch _watch = Stopwatch();
  DateTime? _wallAnchor;
  int? _monotonicAnchor;
  void _startClock() {
    if (_watch.isRunning) return;
    _wallAnchor = DateTime.now().toUtc();
    _watch.start();
    _monotonicAnchor = _clock?.call() ?? _watch.elapsedMicroseconds;
  }

  List<int>? _key;
  final Queue<Map<String, Object>> _events = Queue();
  int _nextOperation = 0;
  int _nextAttempt = 0;
  int _nextEvent = 0;
  int _dropped = 0;
  int _observedWaits = 0;
  final Map<RideCounter, int> _counters = {};
  final Map<RideEndpoint, int> _requestCounts = {};
  void count(RideCounter counter) {
    if (enabled) {
      _startClock();
      _counters[counter] = (_counters[counter] ?? 0) + 1;
    }
  }

  String? pseudonym(Object? raw, {bool plan = false}) {
    if (!enabled || raw is! String || raw.isEmpty || raw.length > 512) {
      return null;
    }
    try {
      if (_key == null) {
        final random = Random.secure();
        _key = List.generate(32, (_) => random.nextInt(256));
      }
      return '${plan ? 'p' : 'r'}_${Hmac(sha256, _key!).convert(utf8.encode(raw)).toString().substring(0, 24)}';
    } catch (_) {
      return null;
    }
  }

  RideAttempt begin({
    required bool Function() isCurrent,
    String? rawRide,
    String? rawCorrelation,
    bool plan = false,
    RideEndpoint? endpoint,
    RideStatus? status,
    RideSurface? surface,
    bool action = true,
  }) {
    final attempt = RideAttempt._(
      this,
      isCurrent,
      enabled ? ++_nextOperation : 0,
      pseudonym(rawRide, plan: plan),
      pseudonym(rawCorrelation),
      endpoint,
      status,
      surface,
    );
    if (action) attempt.event(RideEvent.action);
    return attempt;
  }

  void _add(
    RideAttempt attempt,
    RideEvent event, {
    String? version,
    String? ride,
    int? httpStatus,
    RideStatus? observedStatus,
  }) {
    try {
      _addSafe(
        attempt,
        event,
        version: version,
        ride: ride,
        httpStatus: httpStatus,
        observedStatus: observedStatus,
      );
    } catch (_) {
      /* Diagnostics must not change application behavior. */
    }
  }

  void _addSafe(
    RideAttempt attempt,
    RideEvent event, {
    String? version,
    String? ride,
    int? httpStatus,
    RideStatus? observedStatus,
  }) {
    if (!enabled || !attempt.isCurrent()) return;
    switch (event) {
      case RideEvent.requestStart:
        count(RideCounter.requestStarts);
        if (attempt.endpoint != null) {
          _requestCounts[attempt.endpoint!] =
              (_requestCounts[attempt.endpoint!] ?? 0) + 1;
        }
      case RideEvent.response:
        count(RideCounter.requestResponses);
      case RideEvent.timeoutUnknown:
        count(RideCounter.requestTimeouts);
      case RideEvent.exceptionUnknown:
        count(RideCounter.requestExceptions);
      default:
        break;
    }
    _startClock();
    final row = <String, Object>{
      'event': event.name,
      'sequence': ++_nextEvent,
      'mono_us': _clock?.call() ?? _watch.elapsedMicroseconds,
      'operation': attempt.operation,
    };
    if (attempt.attempt != null) row['attempt'] = attempt.attempt!;
    if (httpStatus != null && httpStatus >= 100 && httpStatus <= 599) {
      row['http_status'] = httpStatus;
    }
    final label = ride ?? attempt.ride;
    if (label != null) row['ride'] = label;
    if (attempt.correlation != null) row['correlation'] = attempt.correlation!;
    if (attempt.endpoint != null) row['endpoint'] = attempt.endpoint!.name;
    if (attempt.status != null) {
      row[attempt.endpoint == null ? 'status' : 'requested_status'] =
          attempt.status!.name;
    }
    if (observedStatus != null) row['observed_status'] = observedStatus.name;
    if (attempt.surface != null) row['surface'] = attempt.surface!.name;
    if (_counters.isNotEmpty) {
      row['counter_snapshot'] = Map<String, int>.unmodifiable({
        for (final e in _counters.entries) e.key.name: e.value,
      });
    }
    // Server version is ordering evidence only, never a commit-time measurement.
    if (version != null &&
        version.length <= 64 &&
        RegExp(
          r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d:\d\d)$',
        ).hasMatch(version)) {
      final parsed = _validVersion(version);
      if (parsed != null) {
        row['server_version_candidate'] = parsed.toUtc().toIso8601String();
      }
    }
    if (_events.length == capacity) {
      _events.removeFirst();
      _dropped++;
    }
    _events.add(Map.unmodifiable(row));
  }

  /// Sanitized text only: caller must review before storing/sharing. No filesystem/export UI.
  String exportJson() => jsonEncode({
    'schema': 1,
    'capture_namespace': pseudonym('waydrop-capture-namespace-v1'),
    'clock': 'session_monotonic',
    'wall_anchor_utc': _wallAnchor?.toIso8601String(),
    'wall_anchor_mono_us': _monotonicAnchor,
    'clock_alignment': 'unverified',
    'dropped': _dropped,
    'client_observed_waits': _observedWaits,
    'request_counts': {
      for (final e in _requestCounts.entries) e.key.name: e.value,
    },
    'counters': {for (final e in _counters.entries) e.key.name: e.value},
    'events': _events.toList(),
  });

  /// Missing/duplicate endpoints are not interpolated, including evicted buffer entries.
  int? durationMicros(
    int operation,
    RideEvent start,
    RideEvent end, {
    int? attempt,
  }) {
    final rows = _events.where(
      (e) =>
          e['operation'] == operation &&
          (attempt == null || e['attempt'] == attempt),
    );
    final starts = rows.where((e) => e['event'] == start.name).toList();
    final ends = rows.where((e) => e['event'] == end.name).toList();
    if (starts.length != 1 || ends.length != 1) return null;
    final duration =
        (ends.single['mono_us'] as int) - (starts.single['mono_us'] as int);
    return duration < 0 ? null : duration;
  }

  static DateTime? _validVersion(String value) {
    final m = RegExp(
      r'^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d{1,6})?(Z|[+-](\d\d):(\d\d))$',
    ).firstMatch(value);
    if (m == null) return null;
    final parts = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
    final calendar = DateTime.utc(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
    );
    if (calendar.year != parts[0] ||
        calendar.month != parts[1] ||
        calendar.day != parts[2] ||
        calendar.hour != parts[3] ||
        calendar.minute != parts[4] ||
        calendar.second != parts[5] ||
        (m[8] != null && int.parse(m[8]!) > 23) ||
        (m[9] != null && int.parse(m[9]!) > 59)) {
      return null;
    }
    return DateTime.tryParse(value);
  }
}

class RideAttempt {
  RideAttempt._(
    this._recorder,
    this.isCurrent,
    this.operation,
    this.ride,
    this.correlation,
    this.endpoint,
    this.status,
    this.surface,
  );
  final RideDiagnostics _recorder;
  final bool Function() isCurrent;
  final int operation;
  final String? ride;
  final String? correlation;
  final RideEndpoint? endpoint;
  final RideStatus? status;
  final RideSurface? surface;
  int? attempt;
  RideAttempt forEndpoint(RideEndpoint value) => RideAttempt._(
    _recorder,
    isCurrent,
    operation,
    ride,
    correlation,
    value,
    status,
    surface,
  );
  void event(
    RideEvent event, {
    String? version,
    int? httpStatus,
    RideStatus? observedStatus,
  }) => _recorder._add(
    this,
    event,
    version: version,
    httpStatus: httpStatus,
    observedStatus: observedStatus,
  );
  void link(Object? rawRide) {
    final label = _recorder.pseudonym(rawRide);
    if (label != null) _recorder._add(this, RideEvent.linked, ride: label);
  }

  Future<T> observe<T>(
    Future<T> Function() invoke, {
    Map? Function(T)? evidence,
    int? Function(T)? httpStatus,
    int? Function(Object)? errorStatus,
  }) {
    if (!_recorder.enabled) return invoke();
    final invocation = RideAttempt._(
      _recorder,
      isCurrent,
      operation,
      ride,
      correlation,
      endpoint,
      status,
      surface,
    );
    if (_recorder._observedWaits >= 64) {
      invocation.attempt = ++_recorder._nextAttempt;
      invocation.event(RideEvent.requestStart);
      invocation.event(RideEvent.observationSkipped);
      return invoke(); // Same SDK operation; no additional retained completion observer.
    }
    _recorder._observedWaits++;
    return invocation._observe(
      invoke,
      evidence: evidence,
      httpStatus: httpStatus,
      errorStatus: errorStatus,
    );
  }

  Future<T> _observe<T>(
    Future<T> Function() invoke, {
    Map? Function(T)? evidence,
    int? Function(T)? httpStatus,
    int? Function(Object)? errorStatus,
  }) async {
    attempt = _recorder.enabled ? ++_recorder._nextAttempt : null;
    event(RideEvent.requestStart);
    try {
      final result = await invoke();
      int? code;
      try {
        code = httpStatus?.call(result);
      } catch (_) {}
      event(RideEvent.response, httpStatus: code);
      // Inspection must never change the result or exception of the observed operation.
      try {
        final data = evidence?.call(result);
        if (data?['success'] == true &&
            endpoint != RideEndpoint.orderRead &&
            endpoint != RideEndpoint.liveStatus &&
            endpoint != RideEndpoint.verificationRead &&
            endpoint != RideEndpoint.fallback) {
          final order = data?['order'];
          final returnedIdentity = order is Map
              ? order['id']
              : data?['order_id'];
          final returnedLabel = _recorder.pseudonym(returnedIdentity);
          if (ride != null && returnedLabel != null && returnedLabel != ride) {
            event(RideEvent.evidenceMismatch);
            return result; // Do not attach another ride's version/status; application unchanged.
          }
          if (endpoint == RideEndpoint.booking &&
              (order is! Map ||
                  order['id'] is! String ||
                  (order['id'] as String).isEmpty)) {
            return result; // No booking confirmation can be established without an identity.
          }
          event(
            RideEvent.confirmed,
            observedStatus: diagnosticStatus(
              order is Map
                  ? order['order_status']
                  : (data?['order_status'] ?? data?['status']),
            ),
            version:
                (order is Map ? order['updated_at'] : data?['updated_at'])
                    is String
                ? (order is Map ? order['updated_at'] : data?['updated_at'])
                      as String
                : null,
          );
          if (order is Map) link(order['id']);
        } else if (data?['success'] == false) {
          event(RideEvent.rejected);
        }
      } catch (_) {
        /* Diagnostic evidence is optional. */
      }
      return result;
    } on TimeoutException {
      event(RideEvent.timeoutUnknown);
      rethrow;
    } catch (error) {
      int? code;
      try {
        code = errorStatus?.call(error);
      } catch (_) {}
      event(RideEvent.exceptionUnknown, httpStatus: code);
      rethrow;
    } finally {
      _recorder._observedWaits--;
    }
  }
}
