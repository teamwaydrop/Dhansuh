import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/earnings/completion_notification_gate.dart';
import 'package:waydrop/features/rider/earnings/pending_completion_handoff.dart';

CompletionContext event(CompletionNotificationGate owner, {String account = 'A',
    String rider = 'R', int? generation, int version = 2,
    CompletionEvidence evidence = CompletionEvidence.confirmed,
    CompletionSource source = CompletionSource.rpc}) => CompletionContext(
  accountId: account, riderId: rider, orderId: 'O', status: CompletionTerminalStatus.completed,
  serverVersion: DateTime.utc(2026, 10, 14, 0, 0, version),
  ownerGeneration: generation ?? owner.generation, evidence: evidence, source: source);

void main() {
  test('owner validates evidence, identity, generation and deduplicates RPC/Realtime', () {
    final owner = CompletionNotificationGate('A', 'R');
    expect(owner.accept(event(owner, evidence: CompletionEvidence.failed)), isFalse);
    expect(owner.accept(event(owner, evidence: CompletionEvidence.uncertain)), isFalse);
    expect(owner.accept(event(owner, account: 'B')), isFalse);
    expect(owner.accept(event(owner, rider: 'RB')), isFalse);
    expect(owner.accept(event(owner, generation: owner.generation + 1)), isFalse);
    expect(owner.accept(event(owner)), isTrue);
    expect(owner.accept(event(owner, source: CompletionSource.realtime)), isFalse);
    expect(owner.accept(event(owner, version: 1)), isFalse);
    final old = event(owner, version: 3);
    owner.retireAndBind('B', 'RB');
    expect(owner.accept(old), isFalse);
    owner.retireAndBind('A', 'R');
    expect(owner.accept(old), isFalse); // A -> B -> A is not the old owner.
    owner.dispose();
    expect(owner.accept(event(owner, version: 4)), isFalse);
  });
  test('idle notification makes zero GETs; six active callers and duplicate event make one trailing GET', () async {
    final owner = CompletionNotificationGate('A', 'R');
    final scope = PendingCompletionScope('A', 'R', owner.generation, 'orders-30d',
        cutoff: DateTime.utc(2026, 9, 14, 12));
    final published = <int>[];
    final handoff = PendingCompletionHandoff<int>(owner, (scope, value) => published.add(value));
    var calls = 0;
    expect(handoff.invalidatePending(scope), isNull);
    expect(calls, 0);
    final first = Completer<int>();
    final second = Completer<int>();
    final secondStarted = Completer<void>();
    Future<int> fetch() {
      if (++calls == 1) return first.future;
      secondStarted.complete();
      return second.future;
    }
    final old = List.generate(6, (_) => handoff.read(scope, fetch));
    expect(calls, 1);
    expect(owner.accept(event(owner)), isTrue);
    final fresh = handoff.invalidatePending(scope)!;
    expect(owner.accept(event(owner, source: CompletionSource.realtime)), isFalse);
    first.complete(1);
    expect(await Future.wait(old), everyElement(isNull));
    expect(published, isEmpty);
    await secondStarted.future;
    expect(calls, 2);
    second.complete(2);
    expect(await fresh, 2);
    expect(published, [2]); // Trailing result is consumed, not silently discarded.
    expect(scope.cutoff, DateTime.utc(2026, 9, 14, 12));
  });
  test('active failure still hands fresh complete evidence to an atomic consumer', () async {
    final owner = CompletionNotificationGate('A', 'R');
    final scope = PendingCompletionScope('A', 'R', owner.generation, 'orders-30d');
    ({int total, List<int> history}) visible = (total: 0, history: []);
    final handoff = PendingCompletionHandoff<({int total, List<int> history})>(owner,
        (_, value) => visible = value);
    final first = Completer<({int total, List<int> history})>();
    final second = Completer<({int total, List<int> history})>();
    final secondStarted = Completer<void>();
    var calls = 0;
    final old = handoff.read(scope, () {
      if (++calls == 1) return first.future;
      secondStarted.complete();
      return second.future;
    });
    final error = expectLater(old, throwsStateError);
    final fresh = handoff.invalidatePending(scope)!;
    first.completeError(StateError('synthetic'));
    await error;
    await secondStarted.future;
    expect(calls, 2);
    expect(visible.total, 0);
    expect(visible.history, isEmpty);
    second.complete((total: 21, history: [21]));
    await fresh;
    expect(visible.total, 21);
    expect(visible.history, [21]);
  });
  test('near-completion event is not lost; incompatible scopes stay independent', () async {
    final owner = CompletionNotificationGate('A', 'R');
    final scope = PendingCompletionScope('A', 'R', owner.generation, 'orders-30d', cutoff: DateTime.utc(2026, 9, 14));
    final other = PendingCompletionScope('A', 'R', owner.generation, 'orders-30d', cutoff: DateTime.utc(2026, 9, 15));
    final published = <int>[];
    final handoff = PendingCompletionHandoff<int>(owner, (_, value) => published.add(value));
    final first = Completer<int>();
    var calls = 0;
    final old = handoff.read(scope, () => ++calls == 1 ? first.future : Future.value(2));
    first.complete(1);
    final fresh = handoff.invalidatePending(scope)!; // Before completion continuations run.
    expect(await old, isNull);
    expect(await fresh, 2);
    expect(calls, 2);
    expect(published, [2]);
    expect(handoff.invalidatePending(other), isNull);
    expect(calls, 2);
  });
  test('account retirement and disposal fence old publication and queued fetches', () async {
    for (final dispose in [false, true]) {
      final owner = CompletionNotificationGate('A', 'R');
      final scope = PendingCompletionScope('A', 'R', owner.generation, 'orders-30d');
      final published = <int>[];
      final handoff = PendingCompletionHandoff<int>(owner, (_, value) => published.add(value));
      final first = Completer<int>();
      var calls = 0;
      final old = handoff.read(scope, () { calls++; return first.future; });
      final fresh = handoff.invalidatePending(scope)!;
      final error = expectLater(fresh, throwsStateError);
      if (dispose) { handoff.dispose(); owner.dispose(); }
      else { owner.retireAndBind('B', 'RB'); }
      first.complete(1);
      expect(await old, isNull);
      await error;
      expect(calls, 1);
      expect(published, isEmpty);
      expect(handoff.invalidatePending(scope), isNull);
    }
  });
  test('handoff preserves the captured cutoff through invalidation and atomic draft publication', () async {
    final owner = CompletionNotificationGate('A', 'R');
    final cutoff = DateTime.parse('2026-09-14T17:30:00+05:30');
    final scope = PendingCompletionScope('A', 'R', owner.generation, 'orders-30d', cutoff: cutoff);
    final requestedCutoffs = <DateTime>[];
    final visible = <({int total, List<int> history})>[];
    final handoff = PendingCompletionHandoff<({int total, List<int> history})>(owner,
        (_, value) => visible.add(value));
    final first = Completer<({int total, List<int> history})>();
    final second = Completer<({int total, List<int> history})>();
    final started = Completer<void>();
    Future<({int total, List<int> history})> fetch() {
      requestedCutoffs.add(scope.cutoff!);
      if (requestedCutoffs.length == 1) return first.future;
      started.complete();
      return second.future;
    }
    final old = handoff.read(scope, fetch);
    expect(owner.accept(event(owner)), isTrue);
    final fresh = handoff.invalidatePending(scope)!;
    first.complete((total: 10, history: [10]));
    expect(await old, isNull);
    await started.future;
    expect(visible, isEmpty);
    second.complete((total: 21, history: [21]));
    await fresh;
    expect(requestedCutoffs, [cutoff, cutoff]);
    expect(visible, hasLength(1));
    expect(visible.single.total, 21);
    expect(visible.single.history, [21]);
  });
  test('single-query handoff cannot certify revision coherence of a multi-query batch', () async {
    final owner = CompletionNotificationGate('A', 'R');
    final scope = PendingCompletionScope('A', 'R', owner.generation, 'orders-30d');
    final drafts = <({int ordersRevision, int profileRevision})>[];
    final handoff = PendingCompletionHandoff<({int ordersRevision, int profileRevision})>(owner,
        (_, value) => drafts.add(value));
    final oldRows = Completer<({int ordersRevision, int profileRevision})>();
    var calls = 0;
    final old = handoff.read(scope, () async {
      if (++calls == 1) return oldRows.future;
      // Profile was already consumed before completion; rerunning ONLY orders
      // cannot make that completed profile read belong to the new revision.
      return (ordersRevision: 2, profileRevision: 1);
    });
    final fresh = handoff.invalidatePending(scope)!;
    oldRows.complete((ordersRevision: 1, profileRevision: 1));
    expect(await old, isNull);
    await fresh;
    expect(calls, 2);
    expect(drafts, hasLength(1));
    expect(drafts.single.ordersRevision, 2);
    expect(drafts.single.profileRevision, 1);
    // This is evidence of the integration boundary, NOT an approved UI result.
    // The existing widget's batch-revision guards must remain in place.
  });
}
