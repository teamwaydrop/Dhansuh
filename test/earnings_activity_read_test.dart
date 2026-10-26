import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/earnings/earnings_activity_read.dart';

void main() {
  test('six identical scopes share one GET; invalidation retains one trailing read', () async {
    final reader = EarningsActivityRead();
    final first = Completer<List<Map<String, dynamic>>>();
    final second = Completer<List<Map<String, dynamic>>>();
    var calls = 0;
    Future<List<Map<String, dynamic>>> fetch() => ++calls == 1 ? first.future : second.future;
    final old = List.generate(6, (_) => reader.read('A', 'R', '2026-09-14', fetch));
    expect(calls, 1);
    reader.invalidate('A');
    final fresh = List.generate(6, (_) => reader.read('A', 'R', '2026-09-14', fetch));
    first.complete([{'date': '2026-10-14', 'online_seconds': 12, 'last_online_toggle_at': null}]);
    for (final result in await Future.wait(old)) { expect(reader.accept(result, 'A'), isFalse); }
    expect(calls, 2);
    second.complete([{'date': '2026-10-14', 'online_seconds': 24, 'last_online_toggle_at': null}]);
    for (final result in await Future.wait(fresh)) {
      expect(reader.accept(result, 'A'), isTrue);
      expect(result.rows.single['online_seconds'], 24);
    }
  });
  test('identity, rider and date bounds cannot share; older applied result is fenced', () async {
    final reader = EarningsActivityRead();
    var calls = 0;
    final gate = Completer<List<Map<String, dynamic>>>();
    Future<List<Map<String, dynamic>>> fetch() { calls++; return gate.future; }
    final futures = [reader.read('A', 'R', '2026-09-14', fetch),
      reader.read('B', 'RB', '2026-09-14', fetch), reader.read('A', 'R2', '2026-09-14', fetch),
      reader.read('A', 'R', '2026-09-15', fetch)];
    expect(calls, 4);
    gate.complete([]);
    final rows = await Future.wait(futures);
    expect(reader.accept(rows[0], 'B'), isFalse);
    expect(reader.accept(rows.last, 'A'), isTrue);
    expect(reader.accept(rows.first, 'A'), isFalse);
    reader.invalidate('A');
    expect(reader.accept(rows.last, 'A'), isFalse);
  });
  test('errors propagate, retry is caller driven; disposal suppresses trailing and application', () async {
    final reader = EarningsActivityRead();
    await expectLater(reader.read('A', 'R', 'day', () async => throw StateError('synthetic')), throwsStateError);
    expect(reader.accept(await reader.read('A', 'R', 'day', () async => []), 'A'), isTrue);
    final gate = Completer<List<Map<String, dynamic>>>();
    final old = reader.read('A', 'R', 'day', () => gate.future);
    reader.invalidate('A');
    var calls = 0;
    final trailing = reader.read('A', 'R', 'day', () async { calls++; return []; });
    final failure = expectLater(trailing, throwsStateError);
    reader.dispose(); gate.complete([]);
    expect(reader.accept(await old, 'A'), isFalse);
    await failure; expect(calls, 0);
  });
}
