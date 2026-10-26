import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/earnings/recent_completed_read.dart';

void main() {
  test('six overlapping reads share one GET; invalidation retains one fresh trailing read', () async {
    final reader = RecentCompletedRead();
    final first = Completer<List<Map<String, dynamic>>>();
    final next = Completer<List<Map<String, dynamic>>>();
    var calls = 0;
    Future<List<Map<String, dynamic>>> fetch() => ++calls == 1 ? first.future : next.future;
    final old = List.generate(6, (_) => reader.read('A', 'R', fetch));
    expect(calls, 1);
    reader.invalidate('A');
    final fresh = List.generate(6, (_) => reader.read('A', 'R', fetch));
    first.complete([{'id': 'old'}]);
    for (final result in await Future.wait(old)) { expect(reader.accept(result, 'A'), isFalse); }
    expect(calls, 2);
    next.complete([{'id': 'newest'}, {'id': 'middle'}, {'id': 'oldest'}]);
    for (final result in await Future.wait(fresh)) {
      expect(reader.accept(result, 'A'), isTrue);
      expect(result.rows.map((row) => row['id']), ['newest', 'middle', 'oldest']);
    }
  });
  test('accounts and riders stay separate; late older result cannot overwrite newer application', () async {
    final reader = RecentCompletedRead();
    final gate = Completer<List<Map<String, dynamic>>>();
    var calls = 0;
    Future<List<Map<String, dynamic>>> fetch() { calls++; return gate.future; }
    final futures = [reader.read('A', 'R', fetch), reader.read('B', 'RB', fetch), reader.read('A', 'R2', fetch)];
    expect(calls, 3);
    gate.complete([]);
    final results = await Future.wait(futures);
    expect(reader.accept(results.first, 'B'), isFalse);
    expect(reader.accept(results.last, 'A'), isTrue);
    expect(reader.accept(results.first, 'A'), isFalse);
    reader.invalidate('A');
    expect(reader.accept(results.last, 'A'), isFalse);
  });
  test('failure propagates, next caller can recover; disposal prevents queued work and application', () async {
    final reader = RecentCompletedRead();
    await expectLater(reader.read('A', 'R', () async => throw StateError('synthetic')), throwsStateError);
    expect(reader.accept(await reader.read('A', 'R', () async => []), 'A'), isTrue);
    final gate = Completer<List<Map<String, dynamic>>>();
    final old = reader.read('A', 'R', () => gate.future);
    reader.invalidate('A');
    var calls = 0;
    final queued = reader.read('A', 'R', () async { calls++; return []; });
    final failure = expectLater(queued, throwsStateError);
    reader.dispose(); gate.complete([]);
    expect(reader.accept(await old, 'A'), isFalse);
    await failure; expect(calls, 0);
    await expectLater(reader.read('A', 'R', () async => []), throwsStateError);
  });
}
