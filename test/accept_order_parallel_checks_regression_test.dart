// Regression guard for the accept-order eligibility-check parallelization (performance pass).
//
// CONTEXT: accept-order previously ran three independent, read-only RPCs back-to-back --
// is_rider_blocked_by_tax_due, is_rider_blocked_by_cod_limit, rider_is_on_active_trip -- each
// awaited serially even though none of their inputs depend on another's result (all take only
// rider_id, already validated earlier in the function). They now run concurrently via Promise.all,
// but each result must still be evaluated in the exact same order as before so the *first*
// blocking reason reported to the client when more than one check would fail is unchanged, and
// every existing error/response path (including the non-fatal-log-and-continue behavior for the
// first two checks vs. the 500 on the third) is preserved byte-for-byte.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite for
// Deno edge functions that can't run against a live Supabase instance in a plain unit test.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('accept-order -- tax-due/COD-limit/active-trip checks run concurrently', () {
    final source = _read('supabase/functions/accept-order/index.ts');
    final checksStart = source.indexOf('const [\n      { data: isBlockedByTaxDue');
    final checksEnd = source.indexOf('if (hasActiveTrip)');
    final checksBlock = source.substring(checksStart, checksEnd);

    test('the three eligibility RPCs are destructured from a single Promise.all', () {
      expect(checksStart, greaterThanOrEqualTo(0),
          reason: 'expected a single Promise.all destructuring all three checks');
      expect(checksBlock.contains('await Promise.all(['), isTrue);
      expect(checksBlock.contains('supabase.rpc("is_rider_blocked_by_tax_due"'), isTrue);
      expect(checksBlock.contains('supabase.rpc("is_rider_blocked_by_cod_limit"'), isTrue);
      expect(checksBlock.contains('supabase.rpc("rider_is_on_active_trip"'), isTrue);
    });

    test('tax-due is still evaluated before COD limit, and COD limit before active-trip '
        '(preserves which blocking reason wins when more than one check fails)', () {
      final taxIdx = source.indexOf('code: "TAX_DUE_THRESHOLD_BLOCKED"');
      final codIdx = source.indexOf('code: "COD_LIMIT_EXCEEDED"');
      final activeIdx = source.indexOf('message: "Rider already has an active order"');
      expect(taxIdx, greaterThan(0));
      expect(codIdx, greaterThan(taxIdx));
      expect(activeIdx, greaterThan(codIdx));
    });

    test('tax-due and COD-limit RPC errors are still non-fatal (logged, not thrown)', () {
      final afterPromiseAll = checksBlock.substring(checksBlock.indexOf(']);'));
      expect(afterPromiseAll.contains('supabase.rpc('), isFalse,
          reason: 'no further RPC calls should exist between the Promise.all and the active-trip '
              'check -- only result evaluation');
      final afterChecks = source.substring(checksEnd - 2000, checksEnd);
      expect(afterChecks.contains('if (taxBlockError) {'), isTrue);
      expect(afterChecks.contains('if (codBlockError) {'), isTrue);
    });

    test('the active-trip check still returns a 500 on RPC error (unlike the other two)', () {
      final activeOrdersErrorBlock = source.substring(
        source.indexOf('if (activeOrdersError) {'),
        source.indexOf('if (hasActiveTrip)'),
      );
      expect(activeOrdersErrorBlock.contains('status: 500'), isTrue);
      expect(activeOrdersErrorBlock.contains('"Unable to validate active rides"'), isTrue);
    });

    test('no state-changing operation (rider_assignments/orders writes) was pulled into the '
        'parallel block', () {
      expect(checksBlock.contains('.insert('), isFalse);
      expect(checksBlock.contains('.update('), isFalse);
    });
  });
}
