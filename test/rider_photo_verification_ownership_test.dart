import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/orders/services/rider_photo_verification_service.dart';

void main() {
  const uid = '00000000-0000-4000-8000-000000000321';
  late SupabaseClient client;
  late RiderPhotoVerificationService service;
  late Completer<void> started;
  Completer<void>? gate;
  var calls = 0, status = 200, active = true;
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  setUp(() async {
    calls = 0;
    status = 200;
    active = true;
    gate = null;
    started = Completer<void>();
    client = SupabaseClient(
      'https://example.supabase.co',
      'synthetic-public',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          return http.Response(
            jsonEncode({
              'access_token':
                  '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': uid, 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000})}.synthetic',
              'refresh_token': 'synthetic',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': uid,
                'aud': 'authenticated',
                'created_at': '2026-01-01T00:00:00Z',
                'app_metadata': {},
                'user_metadata': {},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.contains('/functions/v1/')) {
          calls++;
          if (!started.isCompleted) started.complete();
          final body = jsonDecode(request.body);
          expect(body['order_id'], 'order-a');
          expect(body['rider_id'], 'rider-a');
          await gate?.future;
          return http.Response(
            jsonEncode({'success': status == 200}),
            status,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await client.auth.setSession('synthetic-refresh');
    service = RiderPhotoVerificationService(
      client,
      responseTimeout: const Duration(seconds: 5),
    );
  });
  tearDown(() async {
    gate?.isCompleted == false ? gate!.complete() : null;
    await client.dispose();
  });
  Future<FunctionResponse> verify({String type = 'pickup'}) => service.verify(
    owner: uid,
    orderId: 'order-a',
    riderId: 'rider-a',
    photoType: type,
    photoUrl:
        'https://example.supabase.co/storage/v1/object/public/parcel_images/synthetic',
    isActive: () => active,
  );

  test(
    'concurrent verification and completed replay share one actual SDK POST',
    () async {
      gate = Completer<void>();
      final work = [verify(), verify(), verify()];
      await started.future;
      gate!.complete();
      await Future.wait(work);
      await verify();
      expect(calls, 1);
    },
  );
  test('visible timeout does not release pending proof POST', () async {
    service = RiderPhotoVerificationService(
      client,
      responseTimeout: const Duration(milliseconds: 30),
    );
    gate = Completer<void>();
    final work = verify();
    final observed = expectLater(work, throwsA(isA<RiderProofUnconfirmed>()));
    await started.future;
    await observed;
    final retry = verify();
    gate!.complete();
    await retry;
    expect(calls, 1);
  });
  test('ambiguous 500 response cannot replay writes for same proof', () async {
    status = 500;
    await expectLater(verify(), throwsA(isA<RiderProofUnconfirmed>()));
    await expectLater(verify(), throwsA(isA<RiderProofUnconfirmed>()));
    expect(calls, 1);
  });
  test('disposed screen cannot start verification', () async {
    active = false;
    await expectLater(verify(), throwsA(isA<StateError>()));
    expect(calls, 0);
  });
  test(
    'sign-out while request waits cannot publish old account result',
    () async {
      gate = Completer<void>();
      final work = verify();
      final observed = expectLater(work, throwsA(isA<AuthException>()));
      await started.future;
      await client.auth.signOut(scope: SignOutScope.local);
      gate!.complete();
      await observed;
      expect(calls, 1);
    },
  );
  test('pickup and dropoff are separate verification intents', () async {
    await verify();
    await verify(type: 'dropoff');
    expect(calls, 2);
  });
}
