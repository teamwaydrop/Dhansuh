// Regression guard for Phase 10E — Phase 2E.
//
// Phase 2E was primarily an audit of rider-GPS / Realtime / completion contention. The audit
// produced exactly ONE category-A (tiny, behaviour-preserving, evidenced) fix:
//
//   get-live-order-status/index.ts — the JWT-validation round trip (supabaseUserClient.auth
//   .getUser()) and the service-role order fetch were run SERIALLY. They are independent: the
//   order query never uses `user`, and the `order.user_id !== user.id` ownership check runs only
//   after BOTH resolve. Running them concurrently (Promise.all) removes one serial network round
//   trip from every ~5s live-order poll (~595 calls/24h, avg ~3.6s). This is the exact same
//   auth+fetch concurrency pattern update-order-status, accept-order and calculate-order-pricing
//   already use.
//
// Guard precedence is UNCHANGED: 401 (auth) → 400 (missing order_id) → 404 (order not found) →
// 403 (not the owner). The order query is skipped (Promise.resolve) when order_id is absent, so a
// missing-order_id request does no speculative DB work and still returns 400.
//
// Structural (source-as-text) guard — this repo's established convention.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final src = _read('supabase/functions/get-live-order-status/index.ts');

  group('Phase 2E — get-live-order-status: auth validation and order fetch run concurrently', () {
    test('auth.getUser() and the order fetch are inside a single Promise.all', () {
      expect(
        RegExp(
          r'await Promise\.all\(\[\s*'
          r'supabaseUserClient\.auth\.getUser\(\),\s*'
          r'orderId\s*\?\s*supabaseAdmin\s*\.from\("orders"\)',
        ).hasMatch(src),
        isTrue,
        reason: 'the JWT round trip and the order fetch must run concurrently',
      );
    });

    test('the order query is SKIPPED (Promise.resolve) when order_id is absent — no speculative '
        'DB work for a malformed request', () {
      expect(
        src.contains(': Promise.resolve({ data: null, error: null }),'),
        isTrue,
      );
    });

    test('guard PRECEDENCE is unchanged: 401 (auth) before 400 (order_id) before 404 before 403', () {
      // Position of each guard's executable `if (...)` (not the phrase, which also appears in the
      // explanatory comment) — asserted strictly increasing.
      int posOf(String needle) {
        final i = src.indexOf(needle);
        expect(i, isNonNegative, reason: 'guard "$needle" must exist');
        // Ensure it's the code, not a mention inside a `//` comment line.
        final lineStart = src.lastIndexOf('\n', i) + 1;
        expect(src.substring(lineStart, i).trimLeft().startsWith('//'), isFalse,
            reason: '"$needle" matched inside a comment, not the guard');
        return i;
      }

      final authIdx = posOf('if (authError || !user) {');
      final orderIdIdx = posOf('if (!orderId) {');
      final notFoundIdx = posOf('if (orderError || !order) {');
      final ownerIdx = posOf('if (order.user_id !== user.id) {');

      expect(authIdx, lessThan(orderIdIdx), reason: 'the 401 must still be evaluated before the 400');
      expect(orderIdIdx, lessThan(notFoundIdx), reason: 'the 400 must still be before the 404');
      expect(notFoundIdx, lessThan(ownerIdx), reason: 'the 404 must still be before the 403');
    });

    test('the exact response codes/messages for each guard are unchanged', () {
      expect(src.contains('error: "Unauthorized user",'), isTrue);
      expect(RegExp(r'error: "Unauthorized user",[\s\S]{0,120}status: 401').hasMatch(src), isTrue);
      expect(src.contains('error: "order_id is required",'), isTrue);
      expect(RegExp(r'error: "order_id is required",[\s\S]{0,120}status: 400').hasMatch(src), isTrue);
      expect(src.contains('error: "Order not found",'), isTrue);
      expect(src.contains('error: "Access denied",'), isTrue);
      expect(RegExp(r'error: "Access denied",[\s\S]{0,120}status: 403').hasMatch(src), isTrue);
    });

    test('the embedded orders+riders+rider_kyc+users select is byte-for-byte preserved', () {
      for (final fragment in [
        'rider_kyc!riders_kyc_id_fkey (',
        'users!riders_user_id_fkey (',
        'last_location_updated_at,',
        'current_heading,',
      ]) {
        expect(src.contains(fragment), isTrue, reason: 'select fragment "$fragment" must survive');
      }
      // exactly one embedded orders select in the file.
      expect('.from("orders")'.allMatches(src).length, 1);
    });

    test('the downstream enrichment (signed URL / ETA budget / intercity vehicle type) Promise.all '
        'and the eta_cache 20s TTL are untouched by this phase', () {
      expect(src.contains('getEtaWithBudget(orderId'), isTrue);
      expect(src.contains('getSignedRiderImageUrl(supabaseAdmin'), isTrue);
      expect(
        src.contains('const [resolvedRiderImage, etaResult, intercityPlanVehicleType] = await Promise.all(['),
        isTrue,
      );
    });

    test('no rider-GPS / Realtime / completion / dispatch code is touched by this phase', () {
      // This phase changes ONLY the auth+fetch ordering in this one edge function.
      for (final forbidden in [
        'ALTER PUBLICATION',
        'REPLICA IDENTITY',
        'complete_order_and_settle',
        'updateRiderLocation',
        'current_lat:', // no write to rider location columns
      ]) {
        expect(src.contains(forbidden), isFalse,
            reason: '"$forbidden" must not appear in get-live-order-status');
      }
    });
  });

  group('Phase 2E — sibling edge functions already use this same concurrency pattern (context)', () {
    test('update-order-status runs auth + order fetch concurrently', () {
      final uos = _read('supabase/functions/update-order-status/index.ts');
      expect(
        uos.contains('await Promise.all([\n        supabase.auth.getUser(token),'),
        isTrue,
      );
    });

    test('calculate-order-pricing runs auth + zone resolution concurrently', () {
      final cop = _read('supabase/functions/calculate-order-pricing/index.ts');
      expect(cop.contains('await Promise.all(['), isTrue);
      expect(cop.contains('supabase.auth.getUser(authToken)'), isTrue);
    });
  });
}
