import 'package:waydrop/core/models/today_earnings_seed.dart';

class EarningsScope {
  EarningsScope(this.userId, this.riderId, this.localNow)
      : dayStart = DateTime(localNow.year, localNow.month, localNow.day).toUtc();
  final String userId;
  final String riderId;
  final DateTime localNow;
  final DateTime dayStart;
  String get key => '$userId/$riderId/${dayStart.toIso8601String()}';
}

class EarningsSnapshot {
  EarningsSnapshot._(this.scope, this.total, this.revision, this.serial);
  final EarningsScope scope;
  final double total;
  final int revision;
  final int serial;
}

/// Independent read coordinator: cache only valid same-scope/revision results.
/// Invalidations never retry by themselves; explicit demand retains one trailing
/// attempt. Callers must validate again immediately before publishing the value.
class TodayEarningsRefresh {
  TodayEarningsRefresh({required this.fetch, DateTime Function()? now})
      : _now = now ?? DateTime.now;
  static const dedupeWindow = Duration(seconds: 3);
  final Future<double> Function(EarningsScope) fetch;
  final DateTime Function() _now;
  final _pending = <String, _EarningsAttempt>{};
  String? _userId;
  String? _riderId;
  int _revision = 0;
  int _serial = 0;
  int _appliedSerial = 0;
  bool _disposed = false;
  EarningsSnapshot? _cached;
  DateTime? _cachedAt;

  void bindIdentity(String userId, String riderId) {
    if (_disposed || (_userId == userId && _riderId == riderId)) return;
    invalidate();
    _userId = userId;
    _riderId = riderId;
  }
  void retireIdentity() { invalidate(); _userId = null; _riderId = null; }
  void invalidate() { _revision++; _cached = null; _cachedAt = null; }
  void dispose() { _disposed = true; retireIdentity(); }
  bool _owns(EarningsScope scope) => !_disposed && scope.userId == _userId &&
      scope.riderId == _riderId && scope.dayStart ==
          EarningsScope(scope.userId, scope.riderId, _now()).dayStart;

  EarningsSnapshot? seedGross(TodayEarningsSeed seed, EarningsScope scope) {
    if (_serial != 0 || _pending.isNotEmpty || !_owns(scope) || seed.grossFare == null ||
        !seed.usableForHandoff(scope.userId, scope.riderId, _now())) {
      return null;
    }
    final snapshot = EarningsSnapshot._(scope, seed.grossFare!, _revision, ++_serial);
    _cached = snapshot;
    _cachedAt = seed.observedAt;
    return snapshot;
  }

  Future<EarningsSnapshot?> read(EarningsScope scope) {
    if (!_owns(scope)) return Future.value();
    final cached = _cached;
    final cachedAt = _cachedAt;
    if (cached != null && cached.scope.key == scope.key && cached.revision == _revision &&
        cachedAt != null && !_now().isBefore(cachedAt) &&
        _now().difference(cachedAt) < dedupeWindow) {
      return Future.value(cached);
    }
    final pending = _pending[scope.key];
    if (pending != null) {
      if (pending.revision == _revision) return pending.future;
      return pending.trailing ??= pending.future.then((_) => read(scope),
          onError: (Object error, StackTrace stack) => read(scope));
    }
    final revision = _revision;
    final serial = ++_serial;
    late final Future<EarningsSnapshot?> future;
    future = Future<double>.sync(() => fetch(scope)).then((total) {
      if (!_owns(scope) || revision != _revision) return null;
      if (!total.isFinite) throw StateError('Invalid earnings total');
      final result = EarningsSnapshot._(scope, total, revision, serial);
      _cached = result;
      _cachedAt = _now();
      return result;
    }).whenComplete(() {
      if (identical(_pending[scope.key]?.future, future)) _pending.remove(scope.key);
    });
    _pending[scope.key] = _EarningsAttempt(revision, future);
    return future;
  }

  bool markApplied(EarningsSnapshot snapshot, EarningsScope? currentScope) {
    if (currentScope == null || !_owns(snapshot.scope) ||
        snapshot.scope.key != currentScope.key || snapshot.revision != _revision ||
        snapshot.serial < _appliedSerial) {
      return false;
    }
    _appliedSerial = snapshot.serial;
    return true;
  }

  static void validateRows(Object? rows) {
    if (rows is! List) throw StateError('Invalid earnings response');
    for (final row in rows) {
      if (row is! Map || !row.containsKey('final_fare') || !row.containsKey('current_fare')) {
        throw StateError('Incomplete earnings row');
      }
      for (final key in ['final_fare', 'current_fare']) {
        final value = row[key];
        if (value == null) continue;
        if ((value is! num && value is! String) ||
            double.tryParse(value.toString())?.isFinite != true) {
          throw StateError('Invalid earnings value');
        }
      }
    }
  }

  /// Cardinality evidence must come from count=exact on this same unpaginated
  /// GET, not a second query, estimate or hard-coded server limit. Valid duplicate
  /// fare values are distinct orders; the two-column projection cannot dedupe IDs.
  static void validateCompleteRows(Object? rows, int? exactCount) {
    if (rows is! List || exactCount == null || exactCount < 0 || rows.length != exactCount) {
      throw StateError('Incomplete earnings response');
    }
    validateRows(rows);
    for (final row in rows) {
      if (row['final_fare'] == null && row['current_fare'] == null) {
        throw StateError('Gross earnings amount unavailable');
      }
    }
  }

  static bool orderEventAffectsEarnings(Map<String, dynamic> row, Map<String, dynamic> old) {
    if (row['order_status'] == null || old['order_status'] == null) return true;
    const terminal = ['completed', 'delivered'];
    if (!terminal.contains(row['order_status']) && !terminal.contains(old['order_status'])) return false;
    return ['order_status', 'final_fare', 'current_fare', 'completed_at', 'rider_id']
        .any((key) => row[key] != old[key]);
  }
}

class _EarningsAttempt {
  _EarningsAttempt(this.revision, this.future);
  final int revision;
  final Future<EarningsSnapshot?> future;
  Future<EarningsSnapshot?>? trailing;
}
