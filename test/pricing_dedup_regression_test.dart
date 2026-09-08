// Functional regression test for P3's in-flight pricing request deduplication in
// PricingController (lib/modules/payments/controllers/pricing_controller.dart). Like
// intercity_parcel_pricing_regression_test.dart, this drives the actual PricingController against
// the live, deployed calculate-order-pricing edge function over a real network round trip, and
// counts real network *attempts* via debugPrint interception, rather than asserting on source
// text.
//
// Every request below intentionally omits pickup_lat/pickup_lng. calculate-order-pricing requires
// them and deterministically returns HTTP 400 without them (verified directly against the
// function's own validation branch), so every attempt fails in a real, guaranteed, reproducible
// way -- this makes "FALLBACK ERROR [vehicle]" a reliable, environment-independent signal for "a
// real network attempt was made for this vehicle", which is exactly what these tests need to
// count. Deduplication itself does not care whether the underlying call ultimately succeeds or
// fails: an in-flight entry is inserted the same way and cleared in the same `finally` block
// regardless of outcome, so this failure path fully exercises the same dedup code the success path
// would. Fare-value correctness for these inputs is already covered separately by
// intercity_parcel_pricing_regression_test.dart, which is out of scope for this file.
//
// Requires a local `.env` (the same file `flutter run`/`flutter build` already need via
// --dart-define-from-file=.env) with SUPABASE_URL and SUPABASE_ANON_KEY. If that file isn't
// present, the test is skipped rather than failed. Read-only, safe to run repeatedly.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/modules/payments/controllers/pricing_controller.dart';

Map<String, String> _readDotEnv() {
  final file = File('.env');
  if (!file.existsSync()) return {};
  final values = <String, String>{};
  for (final rawLine in file.readAsLinesSync()) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eqIndex = line.indexOf('=');
    if (eqIndex <= 0) continue;
    final key = line.substring(0, eqIndex).trim();
    var value = line.substring(eqIndex + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    values[key] = value;
  }
  return values;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final env = _readDotEnv();
  final baseUrl = env['SUPABASE_URL'] ?? '';
  final anonKey = env['SUPABASE_ANON_KEY'] ?? '';
  final hasEnv = baseUrl.isNotEmpty && anonKey.isNotEmpty;

  final List<String> capturedLogs = [];
  final originalDebugPrint = debugPrint;

  const pickupAddress = 'Warangal';

  int attemptCount(String vehicle) =>
      capturedLogs.where((l) => l.contains('FALLBACK ERROR [$vehicle]')).length;

  setUpAll(() async {
    if (!hasEnv) return;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: baseUrl, anonKey: anonKey);
  });

  setUp(() {
    capturedLogs.clear();
    debugPrint = (String? message, {int? wrapWidth}) {
      capturedLogs.add(message ?? '');
    };
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
  });

  group('PricingController in-flight request deduplication (P3, live)', () {
    test('1. simultaneous IDENTICAL requests => exactly one real network attempt', () async {
      if (!hasEnv) {
        markTestSkipped('.env with SUPABASE_URL/SUPABASE_ANON_KEY not present in this environment');
        return;
      }
      final controller = PricingController();
      final f1 = controller.fetchMultiplePricing(
        orderType: 'intercity_parcel',
        distanceKm: 55.0,
        pickupAddress: pickupAddress,
        maxBoostAmount: 0.0,
        weightCategory: '2',
      );
      final f2 = controller.fetchMultiplePricing(
        orderType: 'intercity_parcel',
        distanceKm: 55.0,
        pickupAddress: pickupAddress,
        maxBoostAmount: 0.0,
        weightCategory: '2',
      );
      await Future.wait([f1, f2]);

      expect(
        attemptCount('bike'),
        1,
        reason: 'B arrived with the same key while A was still in flight; it should have awaited '
            "A's Future instead of firing its own request",
      );
    });

    test('2. simultaneous requests with a DIFFERENT distance => two real network attempts',
        () async {
      if (!hasEnv) {
        markTestSkipped('.env with SUPABASE_URL/SUPABASE_ANON_KEY not present in this environment');
        return;
      }
      final controller = PricingController();
      final f1 = controller.fetchMultiplePricing(
        orderType: 'intercity_parcel',
        distanceKm: 55.0,
        pickupAddress: pickupAddress,
        maxBoostAmount: 0.0,
        weightCategory: '2',
      );
      final f2 = controller.fetchMultiplePricing(
        orderType: 'intercity_parcel',
        distanceKm: 61.0,
        pickupAddress: pickupAddress,
        maxBoostAmount: 0.0,
        weightCategory: '2',
      );
      await Future.wait([f1, f2]);

      expect(
        attemptCount('bike'),
        2,
        reason: 'distance_km differs, so these are two genuinely different fares and must never '
            'be deduplicated together',
      );
    });

    test('3. a failed request clears its in-flight entry so a later retry is a fresh attempt, '
        'not blocked', () async {
      if (!hasEnv) {
        markTestSkipped('.env with SUPABASE_URL/SUPABASE_ANON_KEY not present in this environment');
        return;
      }
      final controller = PricingController();
      Future<void> attempt() => controller.fetchMultiplePricing(
            orderType: 'intercity_parcel',
            distanceKm: 55.0,
            pickupAddress: pickupAddress,
            maxBoostAmount: 0.0,
            weightCategory: '2',
          );

      await attempt();
      expect(attemptCount('bike'), 1, reason: 'first attempt should fail exactly once');
      expect(controller.error, isNotEmpty);

      capturedLogs.clear();
      await attempt();
      expect(
        attemptCount('bike'),
        1,
        reason: 'the failed in-flight entry must have been cleared, so this retry made its own '
            'fresh network attempt (and failed again the same deterministic way) instead of being '
            'silently blocked or reusing a stale failed Future',
      );
    });

    test('4. simultaneous requests with a DIFFERENT max boost amount => two real network attempts',
        () async {
      if (!hasEnv) {
        markTestSkipped('.env with SUPABASE_URL/SUPABASE_ANON_KEY not present in this environment');
        return;
      }
      final controller = PricingController();
      final f1 = controller.fetchMultiplePricing(
        orderType: 'intercity_parcel',
        distanceKm: 55.0,
        pickupAddress: pickupAddress,
        maxBoostAmount: 0.0,
        weightCategory: '2',
      );
      final f2 = controller.fetchMultiplePricing(
        orderType: 'intercity_parcel',
        distanceKm: 55.0,
        pickupAddress: pickupAddress,
        maxBoostAmount: 25.0,
        weightCategory: '2',
      );
      await Future.wait([f1, f2]);

      expect(
        attemptCount('bike'),
        2,
        reason: 'max_boost_amount differs, so these must never be deduplicated together',
      );
    });

    test('5. two different PricingController instances never share an in-flight request',
        () async {
      if (!hasEnv) {
        markTestSkipped('.env with SUPABASE_URL/SUPABASE_ANON_KEY not present in this environment');
        return;
      }
      final controllerA = PricingController();
      final controllerB = PricingController();
      final fa = controllerA.fetchMultiplePricing(
        orderType: 'intercity_parcel',
        distanceKm: 55.0,
        pickupAddress: pickupAddress,
        maxBoostAmount: 0.0,
        weightCategory: '2',
      );
      final fb = controllerB.fetchMultiplePricing(
        orderType: 'intercity_parcel',
        distanceKm: 55.0,
        pickupAddress: pickupAddress,
        maxBoostAmount: 0.0,
        weightCategory: '2',
      );
      await Future.wait([fa, fb]);

      expect(
        attemptCount('bike'),
        2,
        reason: 'each screen owns its own PricingController; in-flight requests must never be '
            'shared across instances',
      );
    });

    test('6. a normal, single, non-concurrent request behaves exactly as before (one attempt, '
        'loading/error state set normally)', () async {
      if (!hasEnv) {
        markTestSkipped('.env with SUPABASE_URL/SUPABASE_ANON_KEY not present in this environment');
        return;
      }
      final controller = PricingController();
      await controller.fetchMultiplePricing(
        orderType: 'intercity_parcel',
        distanceKm: 55.0,
        pickupAddress: pickupAddress,
        maxBoostAmount: 0.0,
        weightCategory: '2',
      );

      expect(attemptCount('bike'), 1);
      expect(controller.loading, isFalse);
      expect(controller.error, isNotEmpty);
    });
  });
}
