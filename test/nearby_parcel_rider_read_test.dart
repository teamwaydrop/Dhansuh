import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/local_parcels/booking/nearby_parcel_rider_read.dart';

void main() {
  test('six overlapping timer/page-ready triggers issue one real mocked GET; next tick reads again', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    var gets = 0;
    final queries = <Map<String, List<String>>>[];
    final client = SupabaseClient('http://127.0.0.1:1', 'synthetic', httpClient: MockClient((request) async {
      gets++; queries.add(Map.from(request.url.queryParametersAll));
      if (!started.isCompleted) { started.complete(); }
      await gate.future;
      return http.Response(jsonEncode([
        {'id': 'near', 'current_lat': 0, 'current_lng': 0, 'current_heading': 42, 'rider_kyc': {'vehicle_type': 'car'}},
        {'id': 'far', 'current_lat': 1, 'current_lng': 1, 'rider_kyc': {'vehicle_type': 'bike'}},
      ]), 200, request: request, headers: {'content-type': 'application/json'});
    }));
    final reader = NearbyParcelRiderRead(client);
    final applied = <List<Map<String, dynamic>>>[];
    Future<void> run() => reader.run(lat: 0, lng: 0, isCurrent: () => true,
        apply: (rows) async => applied.add(rows));
    final active = run();
    await Future.wait(List.generate(5, (_) => run()));
    await started.future;
    expect(gets, 1);
    gate.complete(); await active;
    expect(applied.single.single['id'], 'near');
    expect(applied.single.single['vehicle_type'], 'cab');
    expect(applied.single.single['current_heading'], 42);
    await run(); expect(gets, 2);
    for (final query in queries) {
      expect(query['select'], ['id,current_lat,current_lng,current_heading,rider_kyc!riders_kyc_id_fkey(vehicle_type)']);
      expect(query['account_status'], ['eq.online']);
      expect(query['current_lat'], contains('not.is.null'));
      expect(query['current_lng'], contains('not.is.null'));
      expect(query.containsKey('limit'), isFalse);
      expect(query.containsKey('order'), isFalse);
    }
    reader.dispose(); await client.dispose();
  });
  test('query failure releases guard; route replacement and disposal reject late data', () async {
    var gate = Completer<void>();
    var fail = true;
    var gets = 0;
    final client = SupabaseClient('http://127.0.0.1:1', 'synthetic', httpClient: MockClient((request) async {
      gets++; await gate.future;
      return http.Response(jsonEncode(fail ? {'message': 'synthetic', 'code': 'TEST'} : []), fail ? 400 : 200, request: request,
          headers: {'content-type': 'application/json'});
    }));
    final reader = NearbyParcelRiderRead(client);
    var current = true;
    var applications = 0;
    Future<void> run() => reader.run(lat: 0, lng: 0, isCurrent: () => current,
        apply: (_) async { applications++; });
    final failure = expectLater(run(), throwsA(isA<PostgrestException>()));
    gate.complete(); await failure;
    fail = false; await run(); expect(applications, 1);
    gate = Completer<void>();
    final obsolete = run(); current = false; gate.complete(); await obsolete;
    expect(applications, 1);
    current = true; gate = Completer<void>();
    final replay = run(); reader.invalidate(); reader.invalidate();
    gate.complete(); await replay; expect(applications, 1);
    current = true; gate = Completer<void>();
    final disposed = run(); reader.dispose(); gate.complete(); await disposed;
    final count = gets; await run();
    expect(gets, count); expect(applications, 1);
    await client.dispose();
  });
  test('A to B to A account changes fence old data without adding GETs', () async {
    final gate = Completer<void>();
    var gets = 0;
    final client = SupabaseClient('http://127.0.0.1:1', 'synthetic', httpClient: MockClient((request) async {
      gets++; await gate.future;
      return http.Response('[]', 200, request: request, headers: {'content-type': 'application/json'});
    }));
    Future<void> identity(String id) async {
      final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
      String encode(Map<String, Object> value) => base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      await client.auth.recoverSession(jsonEncode({
        'access_token': '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': id, 'exp': exp, 'role': 'authenticated'})}.synthetic',
        'refresh_token': 'synthetic', 'token_type': 'bearer', 'expires_in': 3600,
        'user': {'id': id, 'aud': 'authenticated', 'app_metadata': {}, 'user_metadata': {}, 'created_at': '2026-10-14T00:00:00Z'},
      }));
    }
    await identity('A');
    var accountClears = 0;
    final reader = NearbyParcelRiderRead(client, onAccountChanged: () { accountClears++; });
    var applications = 0;
    Future<void> run() => reader.run(lat: 0, lng: 0, isCurrent: () => true,
        apply: (_) async { applications++; });
    final old = run();
    await identity('B'); await identity('A');
    expect(accountClears, 2);
    gate.complete(); await old;
    expect(gets, 1); expect(applications, 0);
    await run(); expect(gets, 2); expect(applications, 1);
    reader.dispose(); await client.dispose();
  });
}
