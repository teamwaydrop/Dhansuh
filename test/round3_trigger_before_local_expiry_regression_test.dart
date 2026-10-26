// Structural regression guards for lowering Round 3's dispatch trigger from
// 600s to 360s, so it lands in the final ~60s before the 420s local search
// expiry (migration 20260913000001_round3_trigger_before_local_expiry.sql,
// follow-up to 20260913000000_local_search_duration_420sec.sql).
//
// Source-text guards, same style as the rest of test/. They do not execute
// Postgres or Deno. Behavioural verification (dispatch_config value, function/
// policy/trigger/index counts unchanged) was done against production at apply
// time.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  final migration = _read(
      'supabase/migrations/20260913000001_round3_trigger_before_local_expiry.sql');
  final expiryMigration = _read(
      'supabase/migrations/20260913000000_local_search_duration_420sec.sql');
  final startDispatch =
      _read('supabase/functions/start-dispatch/index.ts');

  final migrationSql = migration
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('--'))
      .join('\n')
      .trim();

  group('round3_trigger_before_local_expiry migration', () {
    test('is a scoped, idempotent UPDATE to round_3_trigger_after_sec = 360 only', () {
      expect(migrationSql.startsWith('UPDATE public.dispatch_config'), isTrue);
      expect(migrationSql.contains('SET round_3_trigger_after_sec = 360'), isTrue);
      expect(migrationSql.contains("WHERE config_code = 'DEFAULT_V1'"), isTrue);
      expect(migrationSql.contains('AND is_active = true'), isTrue);
      expect(migrationSql.contains('round_3_trigger_after_sec IS DISTINCT FROM 360'), isTrue);
    });

    test('the ENTIRE executable SQL is exactly this one UPDATE -- nothing else touched', () {
      expect(';'.allMatches(migrationSql).length, equals(1));
      expect(migrationSql.endsWith(';'), isTrue);
      // round_2 (explicitly must stay untouched) and every other dispatch_config
      // column must not appear in the executable SQL
      for (final forbidden in const [
        'round_2_trigger_after_sec', 'round_2_trigger_if_no_riders_sec',
        'max_search_duration_sec', 'round_1_radius', 'round_1_batch',
        'round_2_radius', 'round_2_batch', 'round_3_radius', 'round_3_batch',
        'rider_response_timeout_sec', 'reject_cooldown_sec', 'timeout_cooldown_sec',
        'rider_location_stale_sec', 'max_active_orders_per_rider',
        'allow_round_3', 'allow_boosted_priority',
      ]) {
        expect(migrationSql.contains(forbidden), isFalse, reason: 'SQL must not touch "$forbidden"');
      }
      // no DDL of any kind -- data-only change
      for (final forbidden in const [
        'CREATE', 'ALTER', 'DROP', 'GRANT', 'REVOKE', 'INSERT', 'DELETE',
      ]) {
        expect(migrationSql.contains(forbidden), isFalse, reason: 'SQL must not contain DDL keyword "$forbidden"');
      }
    });

    test('does not modify the 420s local-expiry migration or intercity logic', () {
      // the migration's header comment legitimately *documents* that
      // expire_stale_intercity_requests() is NOT touched -- only real DDL
      // against it (or any function) would be a violation, and the SQL-only
      // check above already proves there is none.
      expect(migration.contains('CREATE OR REPLACE FUNCTION'), isFalse);
      expect(migration.contains('DROP FUNCTION'), isFalse);
      expect(migration.contains('NOT TOUCHED: '), isTrue);
      // the 420s expiry migration itself is untouched (still sets 420, not edited)
      expect(expiryMigration.contains('SET max_search_duration_sec = 420'), isTrue);
    });
  });

  group('start-dispatch -- Round 3 timing verified safe against expiry', () {
    test('round_3_trigger_after_sec is read from config (not hardcoded)', () {
      expect(startDispatch.contains(
          'const round3TriggerAfterSec = Number(config.round_3_trigger_after_sec);'),
          isTrue);
      expect(startDispatch.contains(
          'if (config.allow_round_3 && searchAgeSeconds >= round3TriggerAfterSec) {'),
          isTrue);
    });

    test('the overall-expiry check runs BEFORE the Round 1/2/3 building block on every iteration', () {
      // so Round 3 (eligible from searchAgeSeconds >= 360) still gets built and
      // attempted for every iteration up to the 420s expiry check that follows it
      final expiryCheckIdx = startDispatch.indexOf(
          'if (searchAgeSeconds * 1000 > maxSearchDurationMs) {');
      final round1Idx = startDispatch.indexOf('// Round 1 always');
      final round3Idx = startDispatch.indexOf(
          'const round3TriggerAfterSec = Number(config.round_3_trigger_after_sec);');
      expect(expiryCheckIdx, greaterThan(-1));
      expect(round1Idx, greaterThan(expiryCheckIdx));
      expect(round3Idx, greaterThan(round1Idx));
    });

    test('search age is measured from order.created_at, not from this invocation\'s start time', () {
      // so search age keeps advancing correctly across the self-chained
      // invocations this loop uses once its own ~85s per-call cap is hit --
      // Round 3 (360s) and expiry (420s) are reachable regardless of how many
      // chained invocations it takes to get there.
      expect(startDispatch.contains(
          'const searchAgeSeconds = (Date.now() - new Date(currentOrder.created_at).getTime()) / 1000;'),
          isTrue);
      expect(startDispatch.contains('chainedTriggered = true;'), isTrue);
      expect(startDispatch.contains('re-triggering start-dispatch asynchronously'), isTrue);
    });

    test('order stays actively searchable (order_status untouched) until expiry fires', () {
      expect(startDispatch.contains('if (currentOrder.order_status !== "searching") {'), isTrue);
      expect(startDispatch.contains('Overall search timeout reached, order expired'), isTrue);
    });
  });
}
