import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/earnings/active_order_timestamp_read.dart';

void main() {
  test('six reads share one GET; invalidation retains one trailing query and fences old result', () async {
    final reader = ActiveOrderTimestampRead();
    final first = Completer<Map<String, dynamic>?>();
    final next = Completer<Map<String, dynamic>?>();
    var calls = 0;
    Future<Map<String, dynamic>?> fetch() => ++calls == 1 ? first.future : next.future;
    final old = List.generate(6, (_) => reader.read('A', 'R', fetch));
    expect(calls, 1);
    reader.invalidate('A');
    final fresh = List.generate(6, (_) => reader.read('A', 'R', fetch));
    first.complete({'picked_up_at': null, 'accepted_at': '2026-10-14T00:00:00Z', 'created_at': null});
    for (final value in await Future.wait(old)) { expect(reader.accept(value, 'A'), isFalse); }
    expect(calls, 2);
    next.complete(null);
    for (final value in await Future.wait(fresh)) {
      expect(reader.accept(value, 'A'), isTrue);
      expect(value.row, isNull);
    }
  });
  test('accounts/riders never share; older result cannot overwrite newer application', () async {
    final reader = ActiveOrderTimestampRead();
    final gate = Completer<Map<String, dynamic>?>();
    var calls = 0;
    Future<Map<String, dynamic>?> fetch() { calls++; return gate.future; }
    final futures = [reader.read('A', 'R', fetch), reader.read('B', 'RB', fetch), reader.read('A', 'R2', fetch)];
    expect(calls, 3); gate.complete(null);
    final values = await Future.wait(futures);
    expect(reader.accept(values.first, 'B'), isFalse);
    expect(reader.accept(values.last, 'A'), isTrue);
    expect(reader.accept(values.first, 'A'), isFalse);
    reader.invalidate('A');
    expect(reader.accept(values.last, 'A'), isFalse);
  });
  test('query/cardinality errors propagate and recover; disposal prevents late/queued work', () async {
    final reader = ActiveOrderTimestampRead();
    await expectLater(reader.read('A', 'R', () async => throw StateError('synthetic cardinality')), throwsStateError);
    expect(reader.accept(await reader.read('A', 'R', () async => null), 'A'), isTrue);
    final gate = Completer<Map<String, dynamic>?>();
    final old = reader.read('A', 'R', () => gate.future);
    reader.invalidate('A');
    var calls = 0;
    final queued = reader.read('A', 'R', () async { calls++; return null; });
    final failure = expectLater(queued, throwsStateError);
    reader.dispose(); gate.complete(null);
    expect(reader.accept(await old, 'A'), isFalse);
    await failure; expect(calls, 0);
    await expectLater(reader.read('A', 'R', () async => null), throwsStateError);
  });
}
