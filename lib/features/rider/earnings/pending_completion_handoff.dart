import 'dart:convert';
import '../home/pending_assignment_read.dart';
import 'completion_notification_gate.dart';

class PendingCompletionScope {
  const PendingCompletionScope(this.accountId, this.riderId, this.ownerGeneration,
      this.queryContract, {this.cutoff});
  final String accountId;
  final String riderId;
  final int ownerGeneration;
  /// Must identify the complete projection/filter/order/limit contract.
  final String queryContract;
  /// Preserve the batch's exact captured instant; never round/recompute it.
  final DateTime? cutoff;
  String get key => jsonEncode([accountId, riderId, ownerGeneration, queryContract,
      cutoff?.toUtc().toIso8601String()]);
}

/// Unwired prototype. Publisher receives only current complete query evidence.
/// Integrating with a multi-query atomic publisher requires explicit batch ownership.
class PendingCompletionHandoff<T> {
  PendingCompletionHandoff(this.owner, this.publish);
  final CompletionNotificationGate owner;
  final void Function(PendingCompletionScope scope, T value) publish;
  final _reads = InFlightRead<_Evidence<T>>();
  final _pending = <String, _Consumer<T>>{};
  bool _disposed = false;
  bool _current(PendingCompletionScope scope) => !_disposed &&
      owner.owns(scope.accountId, scope.riderId, scope.ownerGeneration);
  void dispose() { _disposed = true; _reads.dispose(); }

  Future<T?> read(PendingCompletionScope scope, Future<T> Function() fetch) {
    if (!_current(scope)) return Future.error(StateError('Completion consumer retired'));
    final raw = _reads.read(scope.key, () async {
      if (!_current(scope)) throw StateError('Completion consumer retired');
      final revision = _reads.revisionFor(scope.key);
      final value = await fetch();
      return _Evidence(revision, value);
    });
    final existing = _pending[scope.key];
    if (existing != null && identical(existing.raw, raw)) return existing.consumed;
    late final Future<T?> consumed;
    consumed = raw.then<T?>((result) {
      if (!_current(scope) || result.revision != _reads.revisionFor(scope.key)) return null;
      publish(scope, result.value); // Synchronous identity/revision check immediately before handoff.
      return result.value;
    }).whenComplete(() {
      if (identical(_pending[scope.key]?.consumed, consumed)) _pending.remove(scope.key);
    });
    _pending[scope.key] = _Consumer(raw, consumed, fetch);
    return consumed;
  }

  /// Call once AFTER the owner gate accepts the completion. No read when idle.
  /// Returns the publication-bearing future; caller must observe any failure.
  Future<T?>? invalidatePending(PendingCompletionScope scope) {
    if (!_current(scope)) return null;
    _reads.invalidate(scope.key);
    final pending = _pending[scope.key];
    if (pending == null) return null;
    return read(scope, pending.fetch);
  }
}

class _Evidence<T> {
  _Evidence(this.revision, this.value);
  final int revision;
  final T value;
}
class _Consumer<T> {
  _Consumer(this.raw, this.consumed, this.fetch);
  final Future<_Evidence<T>> raw;
  final Future<T?> consumed;
  final Future<T> Function() fetch;
}
