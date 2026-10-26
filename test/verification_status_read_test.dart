import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/orders/verification_status_read.dart';

void main() {
  const scope = 'user/rider/order';
  const verified = [{'verification_type': 'pickup', 'verification_status': 'verified'}];
  test('compatible reads share; write invalidation queues one fresh observation', () async {
    final reads = VerificationStatusRead();
    final first = Completer<Object?>();
    final next = Completer<Object?>();
    var calls = 0;
    Future<Object?> fetch() => ++calls == 1 ? first.future : next.future;
    final a = reads.read(scope, fetch);
    final b = reads.read(scope, fetch);
    expect(identical(a, b), isTrue);
    reads.invalidate(scope);
    final c = reads.read(scope, fetch);
    final d = reads.read(scope, fetch);
    expect(identical(c, d), isTrue);
    first.complete([]);
    expect(reads.isCurrent(await a), isFalse);
    next.complete(verified);
    expect((await c).pickup, isTrue);
    expect(reads.isCurrent(await d), isTrue);
    expect(calls, 2);
  });
  test('account rider order and purpose scopes never share', () async {
    final reads = VerificationStatusRead();
    var calls = 0;
    final gate = Completer<Object?>();
    final futures = [scope, 'other/rider/order', 'user/other/order',
      'user/rider/other', 'photos/user/rider/order']
        .map((key) => reads.read(key, () { calls++; return gate.future; })).toList();
    expect(calls, 5);
    gate.complete([]);
    await Future.wait(futures);
  });
  for (final invalid in [null, {}, [null], [{}],
    [{'verification_type': 'pickup', 'verification_status': 'approved'}]]) {
    test('malformed evidence fails and reader remains reusable: $invalid', () async {
      final reads = VerificationStatusRead();
      await expectLater(reads.read(scope, () async => invalid), throwsStateError);
      expect((await reads.read(scope, () async => verified)).pickup, isTrue);
    });
  }
  test('pending and failed are incomplete; empty is valid; errors are not empty', () async {
    final reads = VerificationStatusRead();
    await expectLater(reads.read(scope, () async => throw StateError('failure')), throwsStateError);
    final result = await reads.read(scope, () async => [
      {'verification_type': 'pickup', 'verification_status': 'pending_sync'},
      {'verification_type': 'dropoff', 'verification_status': 'failed'},
      {'verification_type': 'signature', 'verification_status': 'verified'},
    ]);
    expect(result.pickup, isFalse);
    expect(result.dropoff, isFalse);
    expect(reads.isCurrent(await reads.read(scope, () async => [])), isTrue);
  });
  test('disposal fences active evidence and prevents queued work', () async {
    final reads = VerificationStatusRead();
    final gate = Completer<Object?>();
    final a = reads.read(scope, () => gate.future);
    reads.invalidate(scope);
    var trailingCalls = 0;
    final b = reads.read(scope, () async { trailingCalls++; return verified; });
    final rejected = expectLater(b, throwsStateError);
    reads.dispose();
    gate.complete(verified);
    expect(reads.isCurrent(await a), isFalse);
    await rejected;
    expect(trailingCalls, 0);
  });
}
