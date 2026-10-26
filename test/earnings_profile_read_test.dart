import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/earnings/earnings_profile_read.dart';

void main() {
  test('six callers share one GET; invalidation retains one fresh trailing GET', () async {
    final reader = EarningsProfileRead();
    final first = Completer<Map<String, dynamic>>();
    final second = Completer<Map<String, dynamic>>();
    var calls = 0;
    Future<Map<String, dynamic>> fetch() => ++calls == 1 ? first.future : second.future;
    final old = List.generate(6, (_) => reader.read('A', fetch));
    expect(calls, 1);
    reader.invalidate('A');
    final fresh = List.generate(6, (_) => reader.read('A', fetch));
    first.complete({'id': 'R', 'wallet_balance': 1});
    for (final row in await Future.wait(old)) { expect(reader.isCurrent(row, 'A'), isFalse); }
    expect(calls, 2);
    second.complete({'id': 'R', 'wallet_balance': 2});
    for (final row in await Future.wait(fresh)) { expect(reader.accept(row, 'A'), isTrue); }
  });
  test('older batch cannot apply after newer result; accounts never share', () async {
    final reader = EarningsProfileRead();
    final old = await reader.read('A', () async => {'id': 'R', 'wallet_balance': 1});
    final newer = await reader.read('A', () async => {'id': 'R', 'wallet_balance': 2});
    expect(reader.accept(newer, 'A'), isTrue);
    expect(reader.accept(old, 'A'), isFalse);
    expect(reader.accept(newer, 'B'), isFalse);
    final gate = Completer<Map<String, dynamic>>();
    final a = reader.read('A', () => gate.future);
    final b = await reader.read('B', () async => {'id': 'RB'});
    expect(reader.accept(b, 'B'), isTrue);
    reader.invalidate('A');
    gate.complete({'id': 'R'});
    expect(reader.accept(await a, 'A'), isFalse);
  });
  test('errors propagate and permit reuse; disposal rejects late and queued work', () async {
    final reader = EarningsProfileRead();
    await expectLater(reader.read('A', () async => throw StateError('synthetic')), throwsStateError);
    expect(reader.accept(await reader.read('A', () async => {'id': 'R'}), 'A'), isTrue);
    final gate = Completer<Map<String, dynamic>>();
    final old = reader.read('A', () => gate.future);
    reader.invalidate('A');
    var calls = 0;
    final queued = reader.read('A', () async { calls++; return {'id': 'R'}; });
    final failure = expectLater(queued, throwsStateError);
    reader.dispose(); gate.complete({'id': 'R'});
    expect(reader.accept(await old, 'A'), isFalse);
    await failure; expect(calls, 0);
  });
}
