import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/home/rider_profile_read.dart';

void main() {
  test('same-user/scope callers share a raw read but enrich independent maps', () async {
    final reader = RiderProfileRead();
    reader.prepare('A', 0);
    final response = Completer<Map<String, dynamic>?>();
    var reads = 0;
    Future<Map<String, dynamic>?> fetch() { reads++; return response.future; }
    final first = reader.read('A', fetch);
    final second = reader.read('A', fetch);
    expect(reads, 1);
    response.complete({'id': 'rider-A', 'account_status': 'online', 'wallet_balance': 12.5});
    final a = (await first)!;
    final b = (await second)!;
    a['full_name'] = 'synthetic display';
    expect(b.containsKey('full_name'), isFalse);
    expect(b['wallet_balance'], 12.5);
    await reader.read('A', fetch);
    expect(reads, 2); // No completed-result cache.
  });
  test('meaningful Realtime event invalidates stale data and queues one fresh read', () async {
    final reader = RiderProfileRead();
    final oldRevision = reader.prepare('A', 0);
    final oldResponse = Completer<Map<String, dynamic>?>();
    final first = reader.read('A', () => oldResponse.future);
    final freshRevision = reader.invalidate('A');
    var reads = 0;
    Future<Map<String, dynamic>?> fresh() async { reads++; return {'account_status': 'offline'}; }
    final second = reader.read('A', fresh);
    final third = reader.read('A', fresh);
    oldResponse.complete({'account_status': 'online'});
    await first;
    expect(reader.isCurrent('A', oldRevision), isFalse);
    expect((await second)!['account_status'], 'offline');
    await third;
    expect(reader.isCurrent('A', freshRevision), isTrue);
    expect(reads, 1);
  });
  test('offline-write scope changes prevent reuse of an earlier query', () async {
    final reader = RiderProfileRead();
    final oldRevision = reader.prepare('A', 0);
    final response = Completer<Map<String, dynamic>?>();
    final first = reader.read('A', () => response.future);
    reader.prepare('A', 2);
    final next = reader.read('A', () async => {'account_status': 'offline'});
    response.complete({'account_status': 'online'});
    await first;
    expect(reader.isCurrent('A', oldRevision), isFalse);
    expect((await next)!['account_status'], 'offline');
  });
  test('fresh HTTP application retires an older suspended Realtime callback', () {
    final reader = RiderProfileRead();
    final revision = reader.invalidate('A');
    final callbackApplication = reader.applicationRevision;
    reader.applied(); // The newer identity-matched HTTP profile was applied.
    expect(reader.isCurrent('A', revision), isTrue);
    expect(reader.applicationRevision == callbackApplication, isFalse);
  });
  test('different users do not share profile results', () async {
    final reader = RiderProfileRead();
    reader.prepare('A', 0);
    reader.prepare('B', 0);
    final a = reader.read('A', () async => {'id': 'rider-A'});
    final b = reader.read('B', () async => {'id': 'rider-B'});
    expect((await a)!['id'], 'rider-A');
    expect((await b)!['id'], 'rider-B');
  });
  test('null profile is distinct from failure; failures permit later reads', () async {
    final reader = RiderProfileRead();
    expect(await reader.read('A', () async => null), isNull);
    await expectLater(reader.read('A', () async => throw StateError('synthetic')), throwsStateError);
    expect((await reader.read('A', () async => {'id': 'rider-A'}))!['id'], 'rider-A');
  });
  test('disposed reader rejects queued and future queries', () async {
    final reader = RiderProfileRead();
    reader.prepare('A', 0);
    final response = Completer<Map<String, dynamic>?>();
    final first = reader.read('A', () => response.future);
    reader.invalidate('A');
    final queued = reader.read('A', () async => fail('Disposed fetch'));
    final assertion = expectLater(queued, throwsStateError);
    reader.dispose();
    response.complete(null);
    await first;
    await assertion;
    await expectLater(reader.read('A', () async => fail('Disposed fetch')), throwsStateError);
  });
}
