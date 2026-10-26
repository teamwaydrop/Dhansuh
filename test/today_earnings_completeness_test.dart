import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/home/today_earnings_refresh.dart';

void main() {
  const row = {'final_fare': 21, 'current_fare': 21};
  test('local config supplies row-cap evidence; production limit is not inferred', () {
    final config = File('supabase/config.toml').readAsStringSync();
    expect(config, contains('max_rows = 1000'));
  });
  test('1000 valid rows cannot certify a 1001-row result', () {
    final rows = List.generate(1000, (_) => row);
    expect(() => TodayEarningsRefresh.validateCompleteRows(rows, 1001), throwsStateError);
    expect(() => TodayEarningsRefresh.validateCompleteRows(rows, 1000), returnsNormally);
  });
  test('only exact cardinality permits empty zero or a nonempty total', () {
    expect(() => TodayEarningsRefresh.validateCompleteRows([], 0), returnsNormally);
    expect(() => TodayEarningsRefresh.validateCompleteRows([row], 1), returnsNormally);
    for (final count in [null, -1, 0, 2]) {
      expect(() => TodayEarningsRefresh.validateCompleteRows([row], count), throwsStateError);
    }
    expect(() => TodayEarningsRefresh.validateCompleteRows([], null), throwsStateError);
    expect(() => TodayEarningsRefresh.validateCompleteRows([], 1), throwsStateError);
  });
  test('equal fare rows are not duplicate order identities; missing columns still fail', () {
    expect(() => TodayEarningsRefresh.validateCompleteRows([row, row], 2), returnsNormally);
    expect(() => TodayEarningsRefresh.validateCompleteRows([row, {}], 2), throwsStateError);
    expect(() => TodayEarningsRefresh.validateCompleteRows(null, 0), throwsStateError);
  });
  for (final range in ['0-0/2', '0-0/1', '*/0', null, '0-0/*']) {
    test('installed SDK GET count contract: $range', () async {
      var requests = 0;
      final transport = MockClient((request) async {
        requests++;
        expect(request.method, 'GET');
        expect(request.headers['Prefer'], contains('count=exact'));
        expect(request.url.queryParameters['select'], 'final_fare,current_fare');
        expect(request.url.queryParameters['rider_id'], 'eq.synthetic-rider');
        expect(request.url.queryParameters['order_status'], 'in.("completed","delivered")');
        expect(request.url.queryParameters.containsKey('limit'), isFalse);
        expect(request.url.queryParameters.containsKey('offset'), isFalse);
        final headers = {'content-type': 'application/json'};
        if (range != null) headers['content-range'] = range;
        return http.Response(jsonEncode(range == '*/0' ? [] : [row]),
          range == '0-0/2' ? 206 : 200, request: request, headers: headers);
      });
      final client = SupabaseClient('http://127.0.0.1:1', 'synthetic-local-key', httpClient: transport);
      try {
        final query = client.from('orders').select('final_fare, current_fare')
            .eq('rider_id', 'synthetic-rider').inFilter('order_status', ['completed', 'delivered'])
            .gte('completed_at', DateTime(2026, 10, 13).toUtc().toIso8601String())
            .count(CountOption.exact);
        Future<void> validate() async {
          final result = await query;
          TodayEarningsRefresh.validateCompleteRows(result.data, result.count);
        }
        if (range == '0-0/1' || range == '*/0') {
          await validate();
        } else if (range == '0-0/2') {
          await expectLater(validate(), throwsStateError);
        } else {
          await expectLater(validate(), throwsA(isA<TypeError>()));
        }
        expect(requests, 1); // No HEAD, second count, retries or pagination.
      } finally {
        await client.dispose();
        transport.close();
      }
    });
  }
  test('incomplete read never caches a partial total; a subsequent explicit refresh succeeds', () async {
    final now = DateTime(2026, 10, 13, 12);
    final scope = EarningsScope('A', 'R', now);
    var calls = 0;
    final refresh = TodayEarningsRefresh(now: () => now, fetch: (_) async {
      calls++;
      TodayEarningsRefresh.validateCompleteRows([row], calls == 1 ? 2 : 1);
      return 21;
    })..bindIdentity('A', 'R');
    await expectLater(refresh.read(scope), throwsStateError);
    final complete = (await refresh.read(scope))!;
    expect(complete.total, 21);
    expect(refresh.markApplied(complete, scope), isTrue);
    expect(calls, 2);
  });
  test('complete cardinality does not bypass identity/day/disposal freshness', () async {
    var now = DateTime(2026, 10, 13, 23, 59, 59);
    final response = Completer<double>();
    final refresh = TodayEarningsRefresh(now: () => now, fetch: (_) => response.future)
      ..bindIdentity('A', 'R');
    final scope = EarningsScope('A', 'R', now);
    final read = refresh.read(scope);
    TodayEarningsRefresh.validateCompleteRows([row], 1);
    now = DateTime(2026, 10, 14);
    refresh.retireIdentity();
    refresh.dispose();
    response.complete(21);
    expect(await read, isNull);
  });
  test('Home validates exact count before its preserved gross-fare sum', () {
    final source = File('lib/features/rider/home/rider_home_tab.dart').readAsStringSync();
    final start = source.indexOf('Future<double> _fetchTodayEarnings(');
    final end = source.indexOf('\n  }', start);
    final body = source.substring(start, end);
    expect(body, contains('.count(CountOption.exact)'));
    final validation = body.indexOf('TodayEarningsRefresh.validateCompleteRows(ordersData, response.count)');
    final summation = body.indexOf('for (var o in ordersData)');
    expect(validation, greaterThan(0));
    expect(summation, greaterThan(validation));
    expect(body, isNot(contains('.range(')));
    expect(body, isNot(contains('.limit(')));
  });
  test('a scalar seed alone cannot certify response completeness', () {
    // No total can establish whether underlying rows were truncated, nor which
    // net/gross measure was used. Do not pin the existing startup defect in tests.
    expect(() => TodayEarningsRefresh.validateCompleteRows(42.0, null), throwsStateError);
    expect(() => TodayEarningsRefresh.validateCompleteRows(42.0, 2), throwsStateError);
  });
}
