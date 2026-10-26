import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/core/models/today_earnings_seed.dart';
import 'package:waydrop/core/providers/initial_data_provider.dart';
import 'package:waydrop/features/rider/home/today_earnings_refresh.dart';

void main() {
  final day = DateTime(2026, 10, 13, 12);
  TodayEarningsSeed make(Object? rows, int? count, {DateTime? observed}) =>
      TodayEarningsSeed.fromRows(userId: 'A', riderId: 'R', queryLocalDay: day,
          observedAt: observed ?? day, rows: rows, exactCount: count);
  final rows = [
    {'final_fare': 21, 'current_fare': 21, 'rider_earning': '17.95'},
    {'final_fare': null, 'current_fare': '21.00', 'rider_earning': 19},
  ];
  test('same source observation seeds Home gross and active-order stored measure separately', () {
    final seed = make(rows, 2);
    final home = TodayEarningsRefresh(now: () => day, fetch: (_) async => fail('Unexpected fetch'))
      ..bindIdentity('A', 'R');
    final scope = EarningsScope('A', 'R', day);
    final gross = home.seedGross(seed, scope)!;
    expect(home.markApplied(gross, scope), isTrue);
    expect(gross.total, 42);
    final active = StoredPartnerEarningsState();
    expect(active.acceptHandoff(seed, 'A', 'R', day), isTrue);
    expect(active.valueFor('A', 'R', day), closeTo(36.95, 0.000001));
  });
  test('legacy scalar remains accepted by model but cannot authorize either metric', () {
    final legacy = InitialRiderData(userId: 'A', rider: {'id': 'R'}, todayEarnings: 42);
    expect(legacy.todayEarnings, 42);
    expect(legacy.earningsSeed, isNull);
    expect(StoredPartnerEarningsState().acceptHandoff(legacy.earningsSeed, 'A', 'R', day), isFalse);
  });
  test('profile-only consumers reject another account or missing owner proof', () {
    final data = InitialRiderData(userId: 'A', rider: {'id': 'R'}, earningsSeed: make(rows, 2));
    expect(data.belongsTo('A'), isTrue);
    expect(data.belongsTo('B'), isFalse);
    expect(data.belongsTo(null), isFalse);
    expect(InitialRiderData(rider: {'id': 'R'}).belongsTo('A'), isFalse);
  });
  test('gross and stored availability are independent; unknown never borrows the other amount', () {
    final grossOnly = make([{'final_fare': 21, 'current_fare': null, 'rider_earning': null}], 1);
    expect(grossOnly.grossFare, 21);
    expect(grossOnly.storedPartnerEarnings, isNull);
    final storedOnly = make([{'rider_earning': 17.95}], 1);
    expect(storedOnly.grossFare, isNull);
    expect(storedOnly.storedPartnerEarnings, 17.95);
    final unknown = make([{'final_fare': null, 'current_fare': null, 'rider_earning': null}], 1);
    expect(unknown.grossFare, isNull);
    expect(unknown.storedPartnerEarnings, isNull);
  });
  test('complete empty set is a real zero; missing/incomplete metadata is unavailable', () {
    expect(make([], 0).grossFare, 0);
    expect(make([], 0).storedPartnerEarnings, 0);
    for (final seed in [make(rows, null), make(rows, 3), make(rows, -1), make(null, 0)]) {
      expect(seed.grossFare, isNull);
      expect(seed.storedPartnerEarnings, isNull);
    }
  });
  test('malformed values invalidate their metric instead of becoming zero', () {
    final invalidStored = make([{'final_fare': 21, 'current_fare': null, 'rider_earning': 'bad'}], 1);
    expect(invalidStored.grossFare, 21);
    expect(invalidStored.storedPartnerEarnings, isNull);
    final invalidGross = make([{'final_fare': double.nan, 'current_fare': 21, 'rider_earning': 17.95}], 1);
    expect(invalidGross.grossFare, isNull);
    expect(invalidGross.storedPartnerEarnings, 17.95);
    expect(make([{}], 1).grossFare, isNull);
    expect(make([null], 1).storedPartnerEarnings, isNull);
  });
  test('expired, future, wrong-user/rider/day handoffs are rejected by both consumers', () {
    final seed = make(rows, 2);
    for (final context in [
      ('B', 'R', day), ('A', 'S', day), ('A', 'R', day.add(const Duration(days: 1))),
      ('A', 'R', day.add(const Duration(seconds: 3))), ('A', 'R', day.subtract(const Duration(seconds: 1))),
    ]) {
      expect(StoredPartnerEarningsState().acceptHandoff(seed, context.$1, context.$2, context.$3), isFalse);
      final home = TodayEarningsRefresh(now: () => context.$3, fetch: (_) async => 0)
        ..bindIdentity(context.$1, context.$2);
      expect(home.seedGross(seed, EarningsScope(context.$1, context.$2, context.$3)), isNull);
    }
  });
  test('Home seed-to-live refresh transition cannot be overwritten by a late seed', () async {
    var now = day;
    final seed = make(rows, 2);
    final home = TodayEarningsRefresh(now: () => now, fetch: (_) async => 63)..bindIdentity('A', 'R');
    final scope = EarningsScope('A', 'R', now);
    final first = home.seedGross(seed, scope)!;
    home.markApplied(first, scope);
    now = now.add(const Duration(seconds: 4));
    final fresh = (await home.read(EarningsScope('A', 'R', now)))!;
    expect(home.markApplied(fresh, EarningsScope('A', 'R', now)), isTrue);
    expect(fresh.total, 63);
    expect(home.seedGross(seed, scope), isNull);
    expect(home.markApplied(first, scope), isFalse);
  });
  test('active-order controlled late response cannot overwrite a newer refresh', () async {
    final state = StoredPartnerEarningsState();
    state.acceptHandoff(make(rows, 2), 'A', 'R', day);
    final oldRevision = state.beginRequest();
    final delayed = Completer<StoredEarningsObservation>();
    final applyOld = delayed.future.then((result) => state.apply(result, 'A', 'R', day));
    final newRevision = state.beginRequest();
    final newer = make([{'rider_earning': 55}], 1);
    expect(state.apply(state.observation(newer, newRevision), 'A', 'R', day), isTrue);
    delayed.complete(state.observation(make(rows, 2), oldRevision));
    expect(await applyOld, isFalse);
    expect(state.valueFor('A', 'R', day), 55);
    expect(state.acceptHandoff(make(rows, 2), 'A', 'R', day), isFalse);
  });
  test('active-order unknown, identity/day change and disposal do not fabricate zeros', () {
    final state = StoredPartnerEarningsState();
    final revision = state.beginRequest();
    final observation = state.observation(make(rows, 2), revision);
    expect(state.apply(observation, 'B', 'R', day), isFalse);
    expect(state.apply(observation, 'A', 'R', day.add(const Duration(days: 1))), isFalse);
    expect(state.valueFor('A', 'R', day), isNull);
    expect(state.apply(observation, 'A', 'R', day), isTrue);
    final unknown = make(rows, null);
    expect(state.apply(state.observation(unknown, state.beginRequest()), 'A', 'R', day), isTrue);
    expect(state.valueFor('A', 'R', day), isNull);
    state.dispose();
    expect(state.apply(observation, 'A', 'R', day), isFalse);
    expect(state.valueFor('A', 'R', day), isNull);
  });
}
