import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/earnings/earnings_threshold_read.dart';

void main() {
  test('six compatible callers issue one read; a later trigger reads anew', () async {
    final reader = EarningsThresholdRead();
    final gate = Completer<Map<String, dynamic>?>();
    var calls = 0;
    final futures = List.generate(6, (_) => reader.read('A', () { calls++; return gate.future; }));
    expect(calls, 1);
    gate.complete({'threshold_amount': '700.25'});
    for (final result in await Future.wait(futures)) {
      expect(result.value, 700.25);
      expect(reader.accept(result, 'A'), isTrue);
    }
    await reader.read('A', () async { calls++; return null; });
    expect(calls, 2);
  });
  test('invalidation requires one trailing read and rejects pre-write result', () async {
    final reader = EarningsThresholdRead();
    final first = Completer<Map<String, dynamic>?>();
    final second = Completer<Map<String, dynamic>?>();
    var calls = 0;
    Future<Map<String, dynamic>?> fetch() => ++calls == 1 ? first.future : second.future;
    final old = reader.read('A', fetch);
    reader.invalidate('A');
    final fresh = List.generate(5, (_) => reader.read('A', fetch));
    first.complete({'threshold_amount': 700});
    expect(reader.accept(await old, 'A'), isFalse);
    expect(calls, 2);
    second.complete({'threshold_amount': 800});
    for (final value in await Future.wait(fresh)) {
      expect(reader.accept(value, 'A'), isTrue);
      expect(value.value, 800);
    }
  });
  test('different accounts are isolated; older results cannot overwrite newer applied result', () async {
    final reader = EarningsThresholdRead();
    final a = await reader.read('A', () async => {'threshold_amount': 700});
    final b = await reader.read('B', () async => {'threshold_amount': 800});
    expect(reader.accept(a, 'B'), isFalse);
    expect(reader.accept(b, 'B'), isTrue);
    expect(reader.accept(a, 'A'), isFalse);
  });
  test('partial failure preserves existing config fallback, never an earnings zero', () async {
    final reader = EarningsThresholdRead();
    final failed = await reader.read('A', () async => throw StateError('synthetic'));
    expect(failed.failed, isTrue);
    expect(failed.value, 100);
    expect(reader.accept(failed, 'A'), isTrue);
    final invalid = await reader.read('A', () async => {'threshold_amount': 'malformed'});
    expect(invalid.value, 100);
    expect(invalid.failed, isFalse); // Existing tryParse fallback is unchanged.
    final empty = await reader.read('A', () async => null);
    expect(empty.value, 100);
  });
  test('disposal retires pending observation and prevents trailing/future work', () async {
    final reader = EarningsThresholdRead();
    final gate = Completer<Map<String, dynamic>?>();
    final old = reader.read('A', () => gate.future);
    reader.invalidate('A');
    var extra = 0;
    final trailing = reader.read('A', () async { extra++; return null; });
    final failure = expectLater(trailing, throwsStateError);
    reader.dispose();
    gate.complete({'threshold_amount': 700});
    expect(reader.accept(await old, 'A'), isFalse);
    await failure;
    await expectLater(reader.read('A', () async { extra++; return null; }), throwsStateError);
    expect(extra, 0);
  });
}
