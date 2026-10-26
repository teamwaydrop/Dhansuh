import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/earnings/recent_withdrawals_read.dart';

void main() {
  test('six callers share one GET; committed withdrawal event retains one trailing read', () async {
    final reader = RecentWithdrawalsRead();
    final first = Completer<List<Map<String, dynamic>>>();
    final second = Completer<List<Map<String, dynamic>>>();
    var calls = 0;
    Future<List<Map<String, dynamic>>> fetch() => ++calls == 1 ? first.future : second.future;
    final old = List.generate(6, (_) => reader.read('A', 'R', fetch));
    expect(calls, 1);
    reader.invalidate('A');
    final fresh = List.generate(6, (_) => reader.read('A', 'R', fetch));
    first.complete([{'amount': 12, 'status': 'pending'}]);
    for (final result in await Future.wait(old)) { expect(reader.accept(result, 'A'), isFalse); }
    expect(calls, 2);
    second.complete([{'amount': 12, 'status': 'success'}]);
    for (final result in await Future.wait(fresh)) {
      expect(reader.accept(result, 'A'), isTrue);
      expect(result.rows.single, {'amount': 12, 'status': 'success'});
    }
  });
  test('accounts/riders never share; older result cannot overwrite newer applied result', () async {
    final reader = RecentWithdrawalsRead();
    final gate = Completer<List<Map<String, dynamic>>>();
    var calls = 0;
    Future<List<Map<String, dynamic>>> fetch() { calls++; return gate.future; }
    final futures = [reader.read('A', 'R', fetch), reader.read('B', 'RB', fetch), reader.read('A', 'R2', fetch)];
    expect(calls, 3); gate.complete([]);
    final values = await Future.wait(futures);
    expect(reader.accept(values.first, 'B'), isFalse);
    expect(reader.accept(values.last, 'A'), isTrue);
    expect(reader.accept(values.first, 'A'), isFalse);
    reader.invalidate('A');
    expect(reader.accept(values.last, 'A'), isFalse);
  });
  test('errors propagate and future reads recover; disposal prevents late and trailing work', () async {
    final reader = RecentWithdrawalsRead();
    await expectLater(reader.read('A', 'R', () async => throw StateError('synthetic')), throwsStateError);
    expect(reader.accept(await reader.read('A', 'R', () async => []), 'A'), isTrue);
    final gate = Completer<List<Map<String, dynamic>>>();
    final old = reader.read('A', 'R', () => gate.future);
    reader.invalidate('A');
    var calls = 0;
    final trailing = reader.read('A', 'R', () async { calls++; return []; });
    final failure = expectLater(trailing, throwsStateError);
    reader.dispose(); gate.complete([]);
    expect(reader.accept(await old, 'A'), isFalse);
    await failure; expect(calls, 0);
    await expectLater(reader.read('A', 'R', () async => []), throwsStateError);
  });
}
