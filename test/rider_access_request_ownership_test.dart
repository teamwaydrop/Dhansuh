import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/session/rider_access_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = '00000000-0000-4000-8000-000000000111';
  Completer<void>? kycGate;
  Completer<void>? payoutGate;
  var failKyc = false;
  var tokenRevision = 0;
  final counts = <String, int>{};
  String encode(Object v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    String token() =>
        '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': uid, 'role': 'authenticated', 'revision': ++tokenRevision, 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000})}.synthetic';
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'synthetic-public-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        final path = r.url.pathSegments.last;
        counts.update(path, (v) => v + 1, ifAbsent: () => 1);
        Object? body;
        var status = 200;
        if (path == 'token') {
          body = {
            'access_token': token(),
            'refresh_token': 'synthetic',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': uid,
              'aud': 'authenticated',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': {},
              'user_metadata': {},
            },
          };
        } else if (path == 'riders') {
          body = {
            'id': 'synthetic-rider',
            'user_id': uid,
            'account_status': 'offline',
            'service_mode': 'local',
          };
        } else if (path == 'rider_kyc') {
          await kycGate?.future;
          if (failKyc) {
            status = 503;
            body = {'message': 'synthetic unavailable'};
          } else {
            body = {'kyc_status': 'approved', 'activation_status': 'active'};
          }
        } else if (path == 'rider_payout_accounts') {
          await payoutGate?.future;
          body = {'id': 'synthetic-active-payout'};
        } else {
          body = {};
        }
        return http.Response(
          jsonEncode(body),
          status,
          request: r,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await Supabase.instance.client.auth.setSession('synthetic');
  });
  setUp(() {
    counts.clear();
    kycGate = null;
    payoutGate = null;
    failKyc = false;
  });
  tearDownAll(() async => Supabase.instance.dispose());
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
  }

  Future<void> release(WidgetTester tester) async {
    if (kycGate != null && !kycGate!.isCompleted) kycGate!.complete();
    if (payoutGate != null && !payoutGate!.isCompleted) payoutGate!.complete();
    await flush(tester);
    await tester.pump(const Duration(seconds: 9));
  }

  Future<void> observe(
    Future<RiderAccess> f,
    List<Object> errors,
    List<RiderAccess> values,
  ) => f.then<void>(
    values.add,
    onError: (Object e, StackTrace s) {
      errors.add(e);
    },
  );

  testWidgets(
    'profile timeout retry keeps one actual request until transport settles',
    (tester) async {
      final service = RiderAccessService();
      final errors = <Object>[];
      final values = <RiderAccess>[];
      kycGate = Completer<void>();
      try {
        final first = observe(service.resolve(), errors, values);
        await flush(tester);
        await tester.pump(const Duration(seconds: 8));
        await tester.pump();
        expect(errors.single, isA<TimeoutException>());
        final retry = observe(service.resolve(), errors, values);
        await tester.pump();
        expect(counts['rider_kyc'], 1);
        expect(counts['riders'], 1);
        await release(tester);
        await Future.wait([first, retry]);
        expect(
          values,
          isEmpty,
          reason: 'timed-out work must not later authorize entry',
        );
        expect(counts['rider_payout_accounts'] ?? 0, 0);
        final fresh = service.resolve();
        await flush(tester);
        expect((await fresh).state, RiderAccessState.ready);
        expect(counts['rider_kyc'], 2);
      } finally {
        await release(tester);
      }
    },
  );

  testWidgets(
    'payout timeout retains ownership and never caches a late ready result',
    (tester) async {
      final service = RiderAccessService();
      final errors = <Object>[];
      final values = <RiderAccess>[];
      payoutGate = Completer<void>();
      try {
        final first = observe(service.resolve(), errors, values);
        await flush(tester);
        await flush(tester);
        expect(counts['rider_payout_accounts'], 1);
        await tester.pump(const Duration(seconds: 8));
        await tester.pump();
        expect(errors.single, isA<TimeoutException>());
        final retry = observe(service.resolve(), errors, values);
        await tester.pump();
        expect(counts['riders'], 1);
        expect(counts['rider_payout_accounts'], 1);
        await release(tester);
        await Future.wait([first, retry]);
        expect(values, isEmpty);
        final fresh = service.resolve();
        await flush(tester);
        expect((await fresh).state, RiderAccessState.ready);
        expect(counts['rider_payout_accounts'], 2);
      } finally {
        await release(tester);
      }
    },
  );

  testWidgets(
    'concurrent checks share reads and a completed check is revalidated',
    (tester) async {
      final service = RiderAccessService();
      final work = List.generate(5, (_) => service.resolve());
      await flush(tester);
      await flush(tester);
      expect(
        (await Future.wait(
          work,
        )).every((v) => v.state == RiderAccessState.ready),
        isTrue,
      );
      expect(counts['riders'], 1);
      expect(counts['rider_payout_accounts'], 1);
      final fresh = service.resolve();
      await flush(tester);
      expect((await fresh).state, RiderAccessState.ready);
      expect(counts['riders'], 2);
    },
  );

  testWidgets(
    'completed server failure releases ownership for a genuine fresh retry',
    (tester) async {
      final service = RiderAccessService();
      final errors = <Object>[];
      failKyc = true;
      final first = observe(service.resolve(), errors, []);
      await flush(tester);
      await first;
      expect(errors.single, isA<PostgrestException>());
      failKyc = false;
      final retry = service.resolve();
      await flush(tester);
      expect((await retry).state, RiderAccessState.ready);
      expect(counts['riders'], 2);
    },
  );

  testWidgets(
    'renewed credentials replace a hung owner without stale cleanup',
    (tester) async {
      final service = RiderAccessService();
      final errors = <Object>[];
      final values = <RiderAccess>[];
      final oldGate = Completer<void>();
      final newGate = Completer<void>();
      kycGate = oldGate;
      try {
        final first = observe(service.resolve(), errors, values);
        await flush(tester);
        await tester.pump(const Duration(seconds: 8));
        await tester.pump();
        expect(errors.single, isA<TimeoutException>());
        await tester.runAsync(
          () => Supabase.instance.client.auth.setSession('synthetic-renewed'),
        );
        kycGate = newGate;
        final replacement = observe(service.resolve(), errors, values);
        await flush(tester);
        expect(counts['rider_kyc'], 2);
        oldGate.complete();
        await flush(tester);
        final joined = observe(service.resolve(), errors, values);
        await flush(tester);
        expect(counts['rider_kyc'], 2);
        expect(counts['riders'], 2);
        newGate.complete();
        await flush(tester);
        await Future.wait([first, replacement, joined]);
        expect(values.length, 2);
        expect(values.every((v) => v.state == RiderAccessState.ready), isTrue);
        expect(errors.length, 1);
        expect(counts['rider_payout_accounts'], 1);
      } finally {
        if (!oldGate.isCompleted) oldGate.complete();
        if (!newGate.isCompleted) newGate.complete();
        await release(tester);
      }
    },
  );

  testWidgets('sign-out while profile is pending stops the late payout read', (
    tester,
  ) async {
    final service = RiderAccessService();
    kycGate = Completer<void>();
    try {
      final work = service.resolve();
      await flush(tester);
      await tester.runAsync(
        () => Supabase.instance.client.auth.signOut(scope: SignOutScope.local),
      );
      await release(tester);
      expect((await work).state, RiderAccessState.unauthenticated);
      expect(counts['rider_payout_accounts'] ?? 0, 0);
    } finally {
      await release(tester);
    }
  });
}
