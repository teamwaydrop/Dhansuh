import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/home/today_earnings_refresh.dart';

void main() {
  test('completed snapshot cannot apply after identity retirement, rebinding or disposal', () async {
    final h = _Harness();
    final first = h.refresh.read(h.scope);
    h.requests[0].complete(42);
    final snapshot = (await first)!;
    h.refresh.retireIdentity();
    expect(h.refresh.markApplied(snapshot, h.scope), isFalse);
    h.refresh.bindIdentity('A', 'rider-A');
    expect(h.refresh.markApplied(snapshot, h.scope), isFalse);
    final fresh = h.refresh.read(h.scope);
    h.requests[1].complete(42);
    final current = (await fresh)!;
    h.refresh.dispose();
    expect(h.refresh.markApplied(current, h.scope), isFalse);
  });
  test('non-finite total fails rather than caching success and releases the guard', () async {
    final h = _Harness();
    final first = h.refresh.read(h.scope);
    final assertion = expectLater(first, throwsStateError);
    h.requests[0].complete(double.infinity);
    await assertion;
    final second = h.refresh.read(h.scope);
    expect(h.requests.length, 2);
    h.requests[1].complete(42);
    expect((await second)!.total, 42);
  });
  test('overlap shares one request and same-revision cache expires after 3 seconds', () async {
    final h = _Harness();
    final a = h.refresh.read(h.scope);
    final b = h.refresh.read(h.scope);
    expect(h.requests.length, 1);
    h.requests[0].complete(42);
    expect((await a)!.total, 42);
    expect((await b)!.total, 42);
    expect((await h.refresh.read(h.scope))!.total, 42);
    expect(h.requests.length, 1);
    h.now = h.now.add(const Duration(seconds: 3));
    final fresh = h.refresh.read(h.scope);
    h.requests[1].complete(63);
    expect((await fresh)!.total, 63);
  });
  test('new invalidations queue one latest attempt; stale results never apply', () async {
    final h = _Harness();
    final a = h.refresh.read(h.scope);
    h.refresh.invalidate();
    final b = h.refresh.read(h.scope);
    h.refresh.invalidate();
    final c = h.refresh.read(h.scope);
    expect(h.requests.length, 1);
    h.requests[0].complete(21);
    expect(await a, isNull);
    await Future<void>.value();
    expect(h.requests.length, 2);
    h.requests[1].complete(42);
    final result = (await b)!;
    expect((await c)!.total, 42);
    expect(h.refresh.markApplied(result, h.scope), isTrue);
  });
  test('invalidation alone never retries; a near-completion trigger is retained', () async {
    final h = _Harness();
    final a = h.refresh.read(h.scope);
    h.requests[0].complete(21);
    h.refresh.invalidate();
    final b = h.refresh.read(h.scope);
    expect(await a, isNull);
    await Future<void>.value();
    h.requests[1].complete(42);
    await b;
    h.refresh.invalidate();
    await Future<void>.value();
    expect(h.requests.length, 2);
  });
  test('older completed response cannot overwrite a newer applied value', () async {
    final h = _Harness();
    final first = h.refresh.read(h.scope);
    h.requests[0].complete(21);
    final old = (await first)!;
    h.now = h.now.add(const Duration(seconds: 4));
    final second = h.refresh.read(h.scope);
    h.requests[1].complete(42);
    final newer = (await second)!;
    expect(h.refresh.markApplied(newer, h.scope), isTrue);
    expect(h.refresh.markApplied(old, h.scope), isFalse);
  });
  test('identity change rejects A and returning to A cannot revive old evidence', () async {
    final h = _Harness();
    final a = h.refresh.read(h.scope);
    h.refresh.bindIdentity('B', 'rider-B');
    h.requests[0].complete(21);
    expect(await a, isNull);
    expect(await h.refresh.read(h.scope), isNull);
    h.refresh.bindIdentity('A', 'rider-A');
    final fresh = h.refresh.read(h.scope);
    h.requests[1].complete(42);
    expect((await fresh)!.total, 42);
  });
  test('local midnight changes the scope and rejects yesterday in flight', () async {
    final h = _Harness()..now = DateTime(2026, 10, 13, 23, 59, 59);
    final yesterdayScope = h.scope;
    final yesterday = h.refresh.read(yesterdayScope);
    h.now = DateTime(2026, 10, 14);
    final today = h.refresh.read(h.scope);
    expect(h.scopes[0].dayStart, DateTime(2026, 10, 13).toUtc());
    expect(h.scopes[1].dayStart, DateTime(2026, 10, 14).toUtc());
    h.requests[0].complete(21);
    expect(await yesterday, isNull);
    h.requests[1].complete(0);
    expect((await today)!.total, 0);
  });
  test('disposal prevents queued/future reads and stale application', () async {
    final h = _Harness();
    final a = h.refresh.read(h.scope);
    h.refresh.invalidate();
    final b = h.refresh.read(h.scope);
    h.refresh.dispose();
    h.requests[0].complete(21);
    expect(await a, isNull);
    expect(await b, isNull);
    expect(await h.refresh.read(h.scope), isNull);
    expect(h.requests.length, 1);
  });
  test('failure releases guard; explicitly queued demand still runs, without autonomous retry', () async {
    final h = _Harness();
    final a = h.refresh.read(h.scope);
    final failed = expectLater(a, throwsStateError);
    h.refresh.invalidate();
    final b = h.refresh.read(h.scope);
    h.requests[0].completeError(StateError('synthetic'));
    await failed;
    await Future<void>.value();
    h.requests[1].complete(21);
    expect((await b)!.total, 21);
    expect(h.requests.length, 2);
  });
  test('scope binding unchanged by service mode; earnings aggregate is not mode-filtered', () async {
    final h = _Harness();
    final a = h.refresh.read(h.scope);
    h.refresh.bindIdentity('A', 'rider-A'); // Same identity after a mode switch.
    final b = h.refresh.read(h.scope);
    h.requests[0].complete(21);
    expect((await a)!.total, 21);
    expect((await b)!.total, 21);
    expect(h.requests.length, 1);
  });
  test('row validator preserves legitimate nullable and numeric representations', () {
    expect(() => TodayEarningsRefresh.validateRows([
      {'final_fare': null, 'current_fare': null},
      {'final_fare': '21.50', 'current_fare': 21},
      {'final_fare': -1, 'current_fare': '2e1'},
    ]), returnsNormally);
    expect(() => TodayEarningsRefresh.validateRows([]), returnsNormally);
  });
  for (final invalid in [null, {}, [null], [{}], [{'final_fare': 'bad', 'current_fare': 21}],
    [{'final_fare': double.nan, 'current_fare': null}], [{'final_fare': true, 'current_fare': null}]]) {
    test('malformed/partial rows are not accepted as a zero total: $invalid', () {
      expect(() => TodayEarningsRefresh.validateRows(invalid), throwsStateError);
    });
  }
  test('terminal/fare changes invalidate earnings; GPS/unrelated ongoing changes do not', () {
    expect(TodayEarningsRefresh.orderEventAffectsEarnings({'order_status': 'completed'}, {'order_status': 'ongoing'}), isTrue);
    expect(TodayEarningsRefresh.orderEventAffectsEarnings({'order_status': 'completed', 'final_fare': 42}, {'order_status': 'completed', 'final_fare': 21}), isTrue);
    expect(TodayEarningsRefresh.orderEventAffectsEarnings({'order_status': 'ongoing', 'heading': 20}, {'order_status': 'ongoing', 'heading': 10}), isFalse);
    expect(TodayEarningsRefresh.orderEventAffectsEarnings({}, {'order_status': 'completed'}), isTrue);
  });
}

class _Harness {
  _Harness() {
    refresh = TodayEarningsRefresh(now: () => now, fetch: (scope) {
      scopes.add(scope);
      final response = Completer<double>();
      requests.add(response);
      return response.future;
    })..bindIdentity('A', 'rider-A');
  }
  DateTime now = DateTime(2026, 10, 13, 12);
  EarningsScope get scope => EarningsScope('A', 'rider-A', now);
  late final TodayEarningsRefresh refresh;
  final requests = <Completer<double>>[];
  final scopes = <EarningsScope>[];
}
