import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/services/rider_status_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockClient client;
  late Completer<void> started;
  late Completer<void> gate;
  var heldTable = '';
  final requests = <String>[];
  final writtenUsers = <String>[];
  const channels = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    for (final name in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    client = MockClient((request) async {
      final table = request.url.path.split('/').last;
      requests.add(table);
      if (request.method == 'PATCH') {
        expect(jsonDecode(request.body), {'preferred_mode': 'rider', 'last_active_mode': 'rider'});
        writtenUsers.add(request.url.queryParameters['id']!);
      } else {
        expect(request.url.queryParameters['user_id'], 'eq.A');
        if (table == 'rider_payout_accounts') {
          expect(request.url.queryParameters['cashfree_beneficiary_status'], 'eq.active');
        }
      }
      if (table == heldTable) {
        started.complete();
        await gate.future;
      }
      final Object body = switch (table) {
        'rider_kyc' => {'kyc_status': 'approved', 'activation_status': 'active'},
        'riders' => {'service_mode': 'local'},
        'rider_payout_accounts' => {'id': 'synthetic-payout'},
        _ => [],
      };
      return http.Response(jsonEncode(body), 200, request: request,
          headers: {'content-type': 'application/json'});
    });
    await Supabase.initialize(url: 'http://127.0.0.1:1', anonKey: 'synthetic-local-key',
        httpClient: client, authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
  });
  setUp(() {
    started = Completer<void>();
    gate = Completer<void>();
    requests.clear();
    writtenUsers.clear();
  });
  tearDown(() { if (!gate.isCompleted) gate.complete(); });
  tearDownAll(() async {
    await Supabase.instance.dispose();
    client.close();
    for (final name in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });
  Future<void> identity(String id) async {
    final expires = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
    String encode(Map<String, Object> value) => base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token = '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': id, 'exp': expires, 'role': 'authenticated'})}.synthetic';
    // Local synthetic session; no auth endpoint and no printed credentials.
    await Supabase.instance.client.auth.recoverSession(jsonEncode({
      'access_token': token, 'refresh_token': 'synthetic', 'token_type': 'bearer', 'expires_in': 3600,
      'user': {'id': id, 'aud': 'authenticated', 'app_metadata': {}, 'user_metadata': {},
        'created_at': DateTime.now().toUtc().toIso8601String()},
    }));
  }
  for (final table in ['rider_kyc', 'riders', 'rider_payout_accounts', 'users']) {
    test('identity change during $table fences continuation and replacement writes', () async {
      heldTable = table;
      await identity('A');
      final operation = RiderStatusService.switchToRiderMode();
      final failed = expectLater(operation, throwsStateError);
      await started.future;
      await identity('B');
      gate.complete();
      await failed;
      expect(requests.last, table);
      expect(writtenUsers, table == 'users' ? ['eq.A'] : isEmpty);
    });
  }
  test('observed A-B-A cannot resume an obsolete operation', () async {
    heldTable = 'rider_kyc';
    await identity('A');
    final operation = RiderStatusService.switchToRiderMode();
    final failed = expectLater(operation, throwsStateError);
    await started.future;
    await identity('B');
    await identity('A');
    gate.complete();
    await failed;
    expect(writtenUsers, isEmpty);
  });
  test('same-account refresh preserves valid mode-switch payload and filters', () async {
    heldTable = 'rider_kyc';
    await identity('A');
    final operation = RiderStatusService.switchToRiderMode();
    await started.future;
    await identity('A');
    gate.complete();
    await operation;
    expect(requests, ['rider_kyc', 'riders', 'rider_payout_accounts', 'users']);
    expect(writtenUsers, ['eq.A']);
  });
}
