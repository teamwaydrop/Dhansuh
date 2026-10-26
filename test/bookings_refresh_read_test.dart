import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/intercity/bookings_refresh_read.dart';

void main() {
  test('six overlapping three-query batches become one active and one fresh trailing batch', () async {
    final reader = BookingsRefreshRead();
    final first = Completer<List<dynamic>>();
    final next = Completer<List<dynamic>>();
    final started = Completer<void>();
    var gets = 0;
    Future<List<dynamic>> fetch() {
      gets += 3;
      if (gets == 3) return first.future;
      started.complete(); return next.future;
    }
    final old = reader.read('A', 'R', fetch);
    final trailing = List.generate(5, (_) => reader.read('A', 'R', fetch));
    expect(gets, 3);
    first.complete([[], [], []]);
    expect(reader.isCurrent(await old, 'A', 'R'), isFalse);
    await started.future;
    expect(gets, 6); // Old implementation: six independent batches = 18 GETs.
    next.complete([[], [], [{'status': 'in_progress'}]]);
    for (final value in await Future.wait(trailing)) {
      expect(reader.isCurrent(value, 'A', 'R'), isTrue);
      expect(value.results.last.single['status'], 'in_progress');
    }
  });
  test('failed active batch retains required trailing read; later requests recover', () async {
    final reader = BookingsRefreshRead();
    final first = Completer<List<dynamic>>();
    var calls = 0;
    Future<List<dynamic>> fetch() => ++calls == 1 ? first.future : Future.value([[], [], []]);
    final old = reader.read('A', 'R', fetch);
    final error = expectLater(old, throwsStateError);
    final fresh = reader.read('A', 'R', fetch);
    first.completeError(StateError('synthetic'));
    await error;
    expect(reader.isCurrent(await fresh, 'A', 'R'), isTrue);
    expect(reader.isCurrent(await reader.read('A', 'R', fetch), 'A', 'R'), isTrue);
    expect(calls, 3);
  });
  test('near-completion trigger is retained; identity and disposal fence results', () async {
    final reader = BookingsRefreshRead();
    final gate = Completer<List<dynamic>>();
    var calls = 0;
    Future<List<dynamic>> fetch() => ++calls == 1 ? gate.future : Future.value([[], [], []]);
    final old = reader.read('A', 'R', fetch);
    gate.complete([[], [], []]);
    final fresh = reader.read('A', 'R', fetch);
    expect(reader.isCurrent(await old, 'A', 'R'), isFalse);
    final result = await fresh;
    expect(reader.isCurrent(result, 'B', 'RB'), isFalse);
    reader.retire('A');
    expect(reader.isCurrent(result, 'A', 'R'), isFalse);
    reader.dispose();
    await expectLater(reader.read('A', 'R', fetch), throwsStateError);
    expect(calls, 2);
  });
  test('disposal during active read prevents queued batch from making requests', () async {
    final reader = BookingsRefreshRead();
    final gate = Completer<List<dynamic>>();
    var calls = 0;
    Future<List<dynamic>> fetch() { calls++; return gate.future; }
    final old = reader.read('A', 'R', fetch);
    final fresh = reader.read('A', 'R', fetch);
    final error = expectLater(fresh, throwsStateError);
    reader.dispose();
    gate.complete([[], [], []]);
    expect(reader.isCurrent(await old, 'A', 'R'), isFalse);
    await error;
    expect(calls, 1);
  });
}
