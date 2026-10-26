import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/home/pending_assignment_read.dart';
import 'package:waydrop/features/rider/home/rider_profile_read.dart';
import 'package:waydrop/core/models/today_earnings_seed.dart';

void main() {
  test('profile duplicate callers share only one compatible in-flight query', () async {
    final reader = RiderProfileRead();
    reader.prepare('A/R/active-profile', 0);
    final response = Completer<Map<String, dynamic>?>();
    var requests = 0;
    Future<Map<String, dynamic>?> fetch() { requests++; return response.future; }
    final a = reader.read('A/R/active-profile', fetch);
    final b = reader.read('A/R/active-profile', fetch);
    expect(requests, 1);
    response.complete({'id': 'R', 'wallet_balance': 42});
    expect((await a)!['wallet_balance'], 42);
    expect((await b)!['wallet_balance'], 42);
  });
  test('completion invalidates older profile and retains one latest trailing query', () async {
    final reader = RiderProfileRead();
    final oldVersion = reader.prepare('A/R', 0);
    final old = Completer<Map<String, dynamic>?>();
    final first = reader.read('A/R', () => old.future);
    reader.invalidate('A/R');
    final freshVersion = reader.prepare('A/R', 1);
    var requests = 0;
    Future<Map<String, dynamic>?> fetch() async { requests++; return {'id': 'R', 'wallet_balance': 63}; }
    final a = reader.read('A/R', fetch);
    final b = reader.read('A/R', fetch);
    old.complete({'id': 'R', 'wallet_balance': 21});
    await first;
    expect(reader.isCurrent('A/R', oldVersion), isFalse);
    expect((await a)!['wallet_balance'], 63);
    await b;
    expect(requests, 1);
    expect(reader.isCurrent('A/R', freshVersion), isTrue);
  });
  test('typed stored read shares a receipt, retains trailing demand and rejects obsolete application', () async {
    final reader = InFlightRead<StoredEarningsObservation?>();
    final state = StoredPartnerEarningsState();
    final now = DateTime(2026, 10, 13, 12);
    final firstResponse = Completer<void>();
    var requests = 0;
    Future<StoredEarningsObservation?> fetch() async {
      requests++;
      final version = state.beginRequest();
      if (requests == 1) await firstResponse.future;
      if (!state.isCurrent(version)) return null;
      final seed = TodayEarningsSeed.fromRows(userId: 'A', riderId: 'R', queryLocalDay: now,
          observedAt: now, rows: [{'rider_earning': 18}], exactCount: 1);
      return state.observation(seed, version);
    }
    final old = reader.read('A/R/day', fetch);
    state.invalidate();
    reader.invalidate('A/R/day');
    final a = reader.read('A/R/day', fetch);
    final b = reader.read('A/R/day', fetch);
    expect(requests, 1);
    firstResponse.complete();
    expect(await old, isNull);
    final result = (await a)!;
    expect((await b)!.revision, result.revision);
    expect(state.apply(result, 'A', 'R', now), isTrue);
    expect(state.valueFor('A', 'R', now), 18);
    expect(requests, 2);
  });
  test('different users/riders/days and profile purposes remain independent', () async {
    final reader = InFlightRead<int>();
    final hold = Completer<int>();
    final first = reader.read('A/R/day1/net', () => hold.future);
    for (final key in ['B/R/day1/net', 'A/S/day1/net', 'A/R/day2/net', 'A/R/day1/profile']) {
      expect(await reader.read(key, () async => 2), 2);
    }
    hold.complete(1);
    expect(await first, 1);
  });
  test('failed/incomplete aggregate leaves stored state unchanged; explicit later read succeeds', () async {
    final state = StoredPartnerEarningsState();
    final reader = InFlightRead<StoredEarningsObservation?>();
    final now = DateTime(2026, 10, 13, 12);
    final valid = TodayEarningsSeed.fromRows(userId: 'A', riderId: 'R', queryLocalDay: now,
        observedAt: now, rows: [{'rider_earning': 18}], exactCount: 1);
    state.acceptHandoff(valid, 'A', 'R', now);
    await expectLater(reader.read('A/R/day', () async {
      state.beginRequest();
      final partial = TodayEarningsSeed.fromRows(userId: 'A', riderId: 'R', queryLocalDay: now,
          observedAt: now, rows: [{'rider_earning': 19}], exactCount: 2);
      if (partial.storedPartnerEarnings == null) throw StateError('Stored earnings unavailable');
      return state.observation(partial, 1);
    }), throwsStateError);
    expect(state.valueFor('A', 'R', now), 18);
    final result = (await reader.read('A/R/day', () async => state.observation(valid, state.beginRequest())))!;
    expect(state.apply(result, 'B', 'R', now), isFalse);
    expect(state.apply(result, 'A', 'R', now.add(const Duration(days: 1))), isFalse);
    expect(state.apply(result, 'A', 'R', now), isTrue);
  });
  test('disposal rejects queued/future reads and prevents late state publication', () async {
    final reader = InFlightRead<int>();
    final response = Completer<int>();
    final old = reader.read('A/R/day', () => response.future);
    reader.invalidate('A/R/day');
    final queued = reader.read('A/R/day', () async => fail('Disposed query'));
    final assertion = expectLater(queued, throwsStateError);
    reader.dispose();
    response.complete(1);
    await old;
    await assertion;
    await expectLater(reader.read('A/R/day', () async => fail('Disposed query')), throwsStateError);
  });
}
