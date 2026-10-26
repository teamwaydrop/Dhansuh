import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/home/pending_assignment_read.dart';

void main() {
  test('2000 overlapping local callers share one same-revision read', () async {
    final reader = PendingAssignmentRead();
    final response = Completer<List<Map<String, dynamic>>>();
    var requests = 0;
    final callers = List.generate(2000, (_) => reader.read('A', () {
      requests++;
      return response.future;
    }));
    expect(requests, 1);
    response.complete([]);
    final results = await Future.wait(callers);
    expect(results.length, 2000);
    expect(results.every((rows) => rows.isEmpty), isTrue);
  });
  test('explicit invalidation demand survives failure without an autonomous retry', () async {
    final reader = PendingAssignmentRead();
    final failed = Completer<List<Map<String, dynamic>>>();
    var requests = 0;
    Future<List<Map<String, dynamic>>> fetch() {
      requests++;
      return requests == 1 ? failed.future : Future.value([]);
    }
    final first = reader.read('A', fetch);
    final check = expectLater(first, throwsStateError);
    reader.invalidate('A');
    final demanded = reader.read('A', fetch);
    failed.completeError(StateError('synthetic'));
    await check;
    expect(await demanded, isEmpty);
    expect(requests, 2);
    await Future<void>.value();
    expect(requests, 2);
  });
  test('Realtime invalidation queues one fresh read without overlapping the stale query', () async {
    final reader = PendingAssignmentRead();
    final firstResult = Completer<List<Map<String, dynamic>>>();
    final nextResult = Completer<List<Map<String, dynamic>>>();
    final nextStarted = Completer<void>();
    var requests = 0;
    Future<List<Map<String, dynamic>>> fetch() {
      requests++;
      if (requests == 1) return firstResult.future;
      nextStarted.complete();
      return nextResult.future;
    }
    final revision = reader.revisionFor('A');
    final first = reader.read('A', fetch);
    reader.invalidate('A');
    final second = reader.read('A', fetch);
    reader.invalidate('A');
    final third = reader.read('A', fetch);
    expect(requests, 1);
    firstResult.complete([]);
    await first;
    await nextStarted.future;
    expect(reader.revisionFor('A'), isNot(revision));
    expect(requests, 2);
    nextResult.complete([{'order_id': 'new'}]);
    expect((await second).single['order_id'], 'new');
    expect((await third).single['order_id'], 'new');
  });
  test('disposal suppresses queued/future reads', () async {
    final reader = PendingAssignmentRead();
    final response = Completer<List<Map<String, dynamic>>>();
    final first = reader.read('A', () => response.future);
    reader.invalidate('A');
    final trailing = reader.read('A', () async => fail('Disposed query'));
    final check = expectLater(trailing, throwsStateError);
    reader.dispose();
    response.complete([]);
    await first;
    await check;
    await expectLater(reader.read('A', () async => fail('Disposed query')), throwsStateError);
  });
  test('badge and announcement callers share an in-flight read; next trigger reads afresh', () async {
    final reader = PendingAssignmentRead();
    final response = Completer<List<Map<String, dynamic>>>();
    var requests = 0;
    Future<List<Map<String, dynamic>>> fetch() { requests++; return response.future; }
    final announcement = reader.read('A', fetch);
    final badge = reader.read('A', fetch);
    final third = reader.read('A', fetch);
    expect(requests, 1);
    response.complete([{'order_id': 'synthetic', 'orders': {'order_status': 'searching', 'order_type': 'ride'}}]);
    final rows = await Future.wait([announcement, badge, third]);
    expect(rows.every((r) => r.single['orders']['order_status'] == 'searching'), isTrue);
    expect(rows.first.single['orders']['order_type'], 'ride');
    await reader.read('A', fetch);
    expect(requests, 2);
  });
  test('different riders never share a result', () async {
    final reader = PendingAssignmentRead();
    final a = Completer<List<Map<String, dynamic>>>();
    final b = Completer<List<Map<String, dynamic>>>();
    final first = reader.read('A', () => a.future);
    final second = reader.read('B', () => b.future);
    b.complete([{'order_id': 'B'}]);
    expect((await second).single['order_id'], 'B');
    a.complete([{'order_id': 'A'}]);
    expect((await first).single['order_id'], 'A');
  });
  test('async failure reaches all callers and releases the read', () async {
    final reader = PendingAssignmentRead();
    final failed = Completer<List<Map<String, dynamic>>>();
    final first = reader.read('A', () => failed.future);
    final second = reader.read('A', () => fail('Duplicate read'));
    final checks = [expectLater(first, throwsStateError), expectLater(second, throwsStateError)];
    failed.completeError(StateError('synthetic'));
    await Future.wait(checks);
    expect(await reader.read('A', () async => []), isEmpty);
  });
  test('synchronous failure releases the read without swallowing the error', () async {
    final reader = PendingAssignmentRead();
    await expectLater(reader.read('A', () => throw StateError('synthetic')), throwsStateError);
    expect(await reader.read('A', () async => []), isEmpty);
  });
}
