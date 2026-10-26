import 'dart:async';

/// Serializes snapshots. Each caller waits for its own batch, not drain idleness.
/// Calls during a fetch share one trailing batch that starts after those calls.
/// Completion means that batch finished (possibly failed or was invalidated).
class ActiveOrderRefreshCoordinator<T> {
  ActiveOrderRefreshCoordinator({
    required this.fetch,
    required this.apply,
    required this.currentRiderId,
  });

  final Future<T> Function(String riderId) fetch;
  final void Function(T result) apply;
  final String? Function() currentRiderId;
  Completer<void>? _completion;
  String? _pendingRiderId;
  Completer<void>? _pendingCompletion;
  int _revision = 0;
  bool _disposed = false;

  /// An authoritative event invalidates any snapshot already in flight.
  void invalidate() => _revision++;
  int get invalidationRevision => _revision;

  Future<void> request(String riderId) {
    if (_disposed || currentRiderId() != riderId) return Future.value();
    final running = _completion;
    if (running != null) {
      _pendingRiderId = riderId;
      return (_pendingCompletion ??= Completer<void>()).future;
    }
    final completion = Completer<void>();
    _completion = completion;
    unawaited(_drain(riderId, completion));
    return completion.future;
  }

  Future<void> _drain(String riderId, Completer<void> completion) async {
    try {
      while (!_disposed) {
        final revision = _revision;
        try {
          if (currentRiderId() != riderId) break;
          final result = await fetch(riderId);
          if (!_disposed && currentRiderId() == riderId && revision == _revision) {
            apply(result);
          }
        } catch (_) {
          // Preserve Rider Home's existing best-effort refresh error handling.
        }
        completion.complete();
        if (_disposed || _pendingRiderId == null) break;
        riderId = _pendingRiderId!;
        completion = _pendingCompletion!;
        _pendingRiderId = null;
        _pendingCompletion = null;
        _completion = completion;
      }
    } finally {
      _completion = null;
      if (!completion.isCompleted) completion.complete();
      _pendingCompletion?.complete();
      _pendingCompletion = null;
      _pendingRiderId = null;
    }
  }

  void dispose() {
    _disposed = true;
    _pendingRiderId = null;
    _pendingCompletion?.complete();
    _pendingCompletion = null;
    invalidate();
  }
}

/// Uses the snapshot contract's explicit-timezone timestamp format.
DateTime? _orderEventVersion(dynamic value) {
  if (value is! String) return null;
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (match == null) return null;
  final date = DateTime.utc(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
  if (date.year != int.parse(match[1]!) || date.month != int.parse(match[2]!) ||
      date.day != int.parse(match[3]!) || int.parse(match[4]!) > 23 ||
      int.parse(match[5]!) > 59 || int.parse(match[6]!) > 59) {
    return null;
  }
  final zone = match[7]!;
  if (zone != 'Z' && (int.parse(zone.substring(1, 3)) > 23 ||
      int.parse(zone.substring(4, 6)) > 59)) {
    return null;
  }
  return DateTime.tryParse(value);
}

/// Stores event evidence without allowing malformed events to lower its floor.
class ActiveOrderEventMetadata {
  final Map<String, Map<String, dynamic>?> _events = {};
  final Map<String, DateTime> _floors = {};
  final Set<String> _ambiguousVersions = {};
  final Set<String> _unversionedDeletes = {};
  bool _requireScopedEvidence = false;

  void record(Map<String, dynamic> record, Map<String, dynamic> oldRecord,
      {required bool deleted}) {
    // Only DELETE legitimately identifies its row through oldRecord.
    final id = deleted ? oldRecord['id'] : record['id'];
    if (id is! String || id.trim().isEmpty || id.trim() != id) {
      // The target is unknown: retain all known floors and mark their evidence
      // ambiguous. Other orders can recover through versioned snapshots; the
      // caller invalidates pre-event requests before recording this evidence.
      // Returned rows require explicit versions until identity reset.
      _requireScopedEvidence = true;
      _ambiguousVersions.addAll(_floors.keys.where((id) => _events[id] != null));
      // oldRecord is only a quarantine hint here, never an accepted new state.
      final oldId = oldRecord['id'];
      if (oldId is String && oldId.trim().isNotEmpty && oldId.trim() == oldId) {
        _ambiguousVersions.add(oldId);
        final oldVersion = _orderEventVersion(oldRecord['updated_at']);
        final floor = _floors[oldId];
        if (oldVersion != null && (floor == null || oldVersion.isAfter(floor))) {
          _floors[oldId] = oldVersion;
        }
      }
      return;
    }
    if (deleted) {
      final deletionVersion = _orderEventVersion(oldRecord['updated_at']);
      final floor = _floors[id];
      if (floor != null && deletionVersion != null && deletionVersion.isBefore(floor)) return;
      if (deletionVersion != null) _floors[id] = deletionVersion;
      if (deletionVersion == null) {
        _unversionedDeletes.add(id);
      }
      _events[id] = null;
      _ambiguousVersions.remove(id);
      return;
    }
    final incoming = _orderEventVersion(record['updated_at']);
    if (incoming == null || record['order_status'] is! String ||
        !record.containsKey('rider_id') ||
        (record['rider_id'] != null && record['rider_id'] is! String)) {
      _ambiguousVersions.add(id);
      return;
    }
    final floor = _floors[id];
    if (floor != null && incoming.isBefore(floor)) return;
    final previous = _events[id];
    // DELETE wins ties. Unversioned deletion uncertainty is latched until the
    // owning identity/lifecycle resets; later events cannot prove its age.
    if (_events.containsKey(id) && previous == null &&
        (_unversionedDeletes.contains(id) || floor == null || !incoming.isAfter(floor))) {
      return;
    }
    if (floor != null && incoming.isAtSameMomentAs(floor) && previous != null &&
        (previous['order_status'] != record['order_status'] ||
         previous['rider_id'] != record['rider_id'] ||
         previous['trip_started_at'] != record['trip_started_at'])) {
      _ambiguousVersions.add(id);
      return;
    }
    _floors[id] = incoming;
    _events[id] = {
      'order_status': record['order_status'], 'rider_id': record['rider_id'],
      'trip_started_at': record['trip_started_at'], 'updated_at': record['updated_at'],
    };
    _ambiguousVersions.remove(id);
  }

  bool matches(List<Map<String, dynamic>> rows) {
    final ids = <String>{};
    for (final row in rows) {
      final id = row['id'];
      if (id is! String || id.trim().isEmpty || id.trim() != id || !ids.add(id) ||
          _ambiguousVersions.contains(id) ||
          (_requireScopedEvidence && _orderEventVersion(row['updated_at']) == null)) {
        return false;
      }
    }
    // Absence in the authoritative filtered query is still allowed: it cannot
    // resurrect an ambiguous/deleted row, and may reflect missed completion.
    return activeOrderSnapshotMatchesEvents(rows, _events);
  }

  /// Every returned row needs a non-null, valid timezone-aware updated_at
  /// before it can establish complete evidence, even if busy filtering hides it.
  /// Complete evidence retains filtered-query replacement/removal semantics.
  /// Partial evidence may add/update validated rows, but absence removes none.
  /// Explicit, unambiguous terminal events/versioned DELETEs may remove their
  /// own row. Invalid identities reject the batch without changing membership.
  ActiveOrderReconciliation reconcile(
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> previous,
    bool Function(Map<String, dynamic>) isBusy,
  ) {
    final ids = <String>{};
    for (final row in rows) {
      final id = row['id'];
      if (id is! String || id.trim().isEmpty || id.trim() != id || !ids.add(id)) {
        return ActiveOrderReconciliation(previous, ActiveOrderEvidence.rejected);
      }
    }
    final retained = {for (final row in previous) row['id']?.toString(): row};
    bool respectsPreviousVersion(Map<String, dynamic> row) {
      final floor = _orderEventVersion(retained[row['id']]?['updated_at']);
      final incoming = _orderEventVersion(row['updated_at']);
      return floor == null || (incoming != null && !incoming.isBefore(floor));
    }
    if (_ambiguousVersions.isEmpty &&
        rows.every((row) => _orderEventVersion(row['updated_at']) != null) &&
        matches(rows) && rows.every(respectsPreviousVersion)) {
      return ActiveOrderReconciliation(rows.where(isBusy).toList(), ActiveOrderEvidence.complete);
    }
    // An ambiguous row must never make unrelated validated rows wait for it.
    for (final row in rows) {
      if (_orderEventVersion(row['updated_at']) != null &&
          matches([row]) && respectsPreviousVersion(row)) {
        retained[row['id'] as String] = row;
      }
    }
    retained.removeWhere((id, _) {
      if (_ambiguousVersions.contains(id) || _unversionedDeletes.contains(id)) return false;
      if (!_events.containsKey(id)) return false;
      final event = _events[id];
      final retainedVersion = _orderEventVersion(retained[id]?['updated_at']);
      final eventVersion = _floors[id];
      if (retainedVersion != null &&
          (eventVersion == null || retainedVersion.isAfter(eventVersion))) {
        return false;
      }
      return event == null || ['completed', 'delivered', 'cancelled', 'expired']
          .contains(event['order_status']);
    });
    return ActiveOrderReconciliation(
      retained.values.where(isBusy).toList(), ActiveOrderEvidence.partial);
  }

  void clear() {
    _events.clear();
    _floors.clear();
    _ambiguousVersions.clear();
    _unversionedDeletes.clear();
    _requireScopedEvidence = false;
  }
}

enum ActiveOrderEvidence { complete, partial, rejected }

class ActiveOrderReconciliation {
  ActiveOrderReconciliation(this.orders, this.evidence);
  final List<Map<String, dynamic>> orders;
  final ActiveOrderEvidence evidence;
  bool get unresolved => evidence != ActiveOrderEvidence.complete;
  bool get blocksBusyActions => unresolved || orders.isNotEmpty;
}

/// A new rider is unknown, not free. Only their reconciled result may release
/// verification; busy rows remain an independent restriction in Rider Home.
class RiderActiveOrderVerification {
  String? _riderId;
  bool _unresolved = true;
  bool _disposed = false;
  int _identityGeneration = 0;
  int _safetyGeneration = 0;
  int? _verifiedOrderRevision;

  void beginIdentity(String? riderId) {
    if (_disposed || _riderId == riderId) return;
    _riderId = riderId;
    _identityGeneration++;
    _unresolved = true;
    _verifiedOrderRevision = null;
  }

  bool unresolvedFor(String? riderId, {int? orderRevision}) =>
      _disposed || riderId == null || riderId != _riderId || _unresolved ||
      (orderRevision != null && _verifiedOrderRevision != orderRevision);

  bool apply(String? riderId, ActiveOrderReconciliation result, {int orderRevision = 0}) {
    if (_disposed || riderId == null || riderId != _riderId) return false;
    _unresolved = result.unresolved;
    _verifiedOrderRevision = result.unresolved ? null : orderRevision;
    if (result.blocksBusyActions) _safetyGeneration++;
    return true;
  }

  RiderOfflineContext? captureOfflineContext({
    required String? riderId,
    required String? userId,
    required bool hasActiveOrders,
    required int orderRevision,
  }) {
    if (unresolvedFor(riderId) || _verifiedOrderRevision != orderRevision ||
        hasActiveOrders || userId == null || userId.isEmpty) {
      return null;
    }
    return RiderOfflineContext._(riderId!, userId, _identityGeneration,
        _safetyGeneration, orderRevision);
  }

  bool sameOfflineIdentity(RiderOfflineContext operation, String? riderId, String? userId) =>
      !_disposed && operation.riderId == riderId && operation.userId == userId &&
      _identityGeneration == operation._identityGeneration;

  bool permitsOffline(RiderOfflineContext operation, {
    required String? riderId,
    required String? userId,
    required bool hasActiveOrders,
    required int orderRevision,
  }) => sameOfflineIdentity(operation, riderId, userId) && !unresolvedFor(riderId) &&
      !hasActiveOrders && _safetyGeneration == operation._safetyGeneration &&
      orderRevision == operation._orderRevision && _verifiedOrderRevision == orderRevision;

  void dispose() {
    _disposed = true;
  }
}

class RiderOfflineContext {
  RiderOfflineContext._(this.riderId, this.userId, this._identityGeneration,
      this._safetyGeneration, this._orderRevision);
  final String riderId;
  final String userId;
  final int _identityGeneration;
  final int _safetyGeneration;
  final int _orderRevision;
}

/// The existing Rider Home predicate, shared so tests use the production rule.
bool isRiderOrderActivelyBusy(Map<String, dynamic> order) {
  final status = order['order_status']?.toString();
  if (status != 'accepted') return true;
  final type = order['order_type']?.toString() ?? '';
  final distanceMeters = double.tryParse(order['distance_meters']?.toString() ?? '0') ?? 0.0;
  final isIntercity = type.startsWith('intercity') || (type == 'ride' && distanceMeters > 20000);
  if (!isIntercity) return true;
  return order['trip_started_at'] != null;
}

bool activeOrderSnapshotMatchesEvents(
  List<Map<String, dynamic>> rows,
  Map<String, Map<String, dynamic>?> events,
) {
  final byId = {for (final row in rows) row['id']?.toString(): row};
  for (final entry in events.entries) {
    final row = byId[entry.key];
    final event = entry.value;
    if (event == null) {
      if (row != null) return false;
      continue;
    }
    if (row == null) {
      // This filtered query legitimately omits orders that became terminal or
      // changed rider, even if their later Realtime event was missed.
      continue;
    }
    final eventVersion = _orderEventVersion(event['updated_at']);
    final rowVersion = _orderEventVersion(row['updated_at']);
    if (eventVersion == null) return false;
    if (rowVersion == null) return false;
    if (rowVersion.isBefore(eventVersion)) return false;
    if (rowVersion.isAfter(eventVersion)) continue;
    if (row['order_status'] != event['order_status'] ||
        row['rider_id'] != event['rider_id'] ||
        row['trip_started_at'] != event['trip_started_at']) {
      return false;
    }
  }
  return true;
}
