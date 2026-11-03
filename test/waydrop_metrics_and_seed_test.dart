import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:waydrop/core/providers/initial_data_provider.dart';
import 'package:waydrop/core/services/diagnostics/api_metrics_client.dart';

void main() {
  test(
    'rider snapshot is scoped to the account and expires before a delayed tab visit',
    () {
      final fetched = DateTime.utc(2026, 10, 31);
      final data = InitialRiderData(
        rider: {'user_id': 'rider-user'},
        todayEarnings: null,
        fetchedAt: fetched,
      );
      expect(data.isUsableFor('rider-user', now: fetched), isTrue);
      expect(data.isUsableFor('other-user', now: fetched), isFalse);
      expect(data.isUsableFor(null, now: fetched), isFalse);
      expect(
        data.isUsableFor(
          'rider-user',
          now: fetched.add(const Duration(seconds: 5)),
        ),
        isFalse,
      );
    },
  );
  test(
    'request metrics count actual sends in a rolling minute and exclude secrets',
    () async {
      var now = DateTime.utc(2026, 10, 31);
      final client = ApiMetricsClient(
        MockClient((request) async => http.Response('', 200)),
        now: () => now,
      );
      await client.get(
        Uri.parse(
          'https://example.test/rest/v1/orders?user_id=private&apikey=secret',
        ),
        headers: {'Authorization': 'Bearer secret'},
      );
      expect(client.requestsLastMinute, {'rest GET orders': 1});
      expect(client.totals.toString(), isNot(contains('secret')));
      expect(client.totals.toString(), isNot(contains('private')));
      now = now.add(const Duration(minutes: 1));
      expect(client.requestsLastMinute, isEmpty);
      expect(client.totals, {'rest GET orders': 1});
      client.close();
    },
  );
}
