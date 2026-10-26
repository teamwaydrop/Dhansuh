import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/core/services/cache/identity_scoped_future.dart';

void main() {
  test('one cached future per identical account and purpose; old results fenced', () async {
    String? account = 'A';
    final cache = IdentityScopedFuture<int>(() => account);
    final old = Completer<int>();
    var calls = 0;
    Future<int?> fetch() { calls++; return old.future; }
    final a = cache.read('role', fetch);
    expect(identical(cache.read('role', fetch), a), isTrue);
    expect(calls, 1);
    account = 'B';
    final b = cache.read('role', () async => 2);
    expect(await b, 2);
    old.complete(1);
    expect(await a, isNull);
    expect(await cache.read('role', () async => 9), 2);
    expect(await cache.read('reward:rider', () async => 3), 3);
    expect(await cache.read('reward:user', () async => 4), 4);
  });
  test('logout, disposal and A-B-A do not resurrect pending values', () async {
    String? account = 'A';
    final cache = IdentityScopedFuture<int>(() => account);
    final gate = Completer<int>();
    final pending = cache.read('role', () => gate.future);
    account = null;
    expect(await cache.read('role', () async => 99), isNull);
    account = 'A';
    expect(await cache.read('role', () async => 2), 2);
    gate.complete(1);
    expect(await pending, isNull);
    cache.dispose();
    expect(await cache.read('role', () async => 99), isNull);
  });
  test('failure is an error, never authorization or a zero reward', () async {
    final cache = IdentityScopedFuture<int>(() => 'A');
    await expectLater(cache.read('role', () async => throw StateError('synthetic')), throwsStateError);
    // Existing widget-lifetime failure behavior: no new retry request.
    await expectLater(cache.read('role', () async => 99), throwsStateError);
  });
}
