// Structural regression guards for the local order search/expiry window change
// (900s/15min -> 420s/7min), scoped to local_ride + local_parcel only.
//
// migration: 20260913000000_local_search_duration_420sec.sql (data-only UPDATE
//   to the single active dispatch_config row)
// companion Edge Function change: supabase/functions/create-order/index.ts
//   (searchExpiryMinutes local_ride default + local_parcel branch, 15/20 -> 7)
//
// Source-text guards, same style as the rest of test/. They do not execute
// Postgres or Deno. Behavioural verification (dispatch_config value, function
// counts/policies/triggers unchanged, deployed Edge Function content) was done
// against production at apply time.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  final migration =
      _read('supabase/migrations/20260913000000_local_search_duration_420sec.sql');
  final createOrder = _read('supabase/functions/create-order/index.ts');

  // executable SQL only, with -- comment lines stripped -- the migration's header
  // comment legitimately *discusses* intercity/expire_stale_searching_orders/etc.
  // to justify why this change is scoped correctly; only the real SQL statements
  // matter for "does this migration touch X".
  final migrationSql = migration
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('--'))
      .join('\n')
      .trim();

  group('local_search_duration_420sec migration', () {
    test('is a scoped, idempotent UPDATE to the single active DEFAULT_V1 row', () {
      expect(migrationSql.startsWith('UPDATE public.dispatch_config'), isTrue);
      expect(migrationSql.contains('SET max_search_duration_sec = 420'), isTrue);
      expect(migrationSql.contains("WHERE config_code = 'DEFAULT_V1'"), isTrue);
      expect(migrationSql.contains('AND is_active = true'), isTrue);
      // idempotent guard -- re-running is a no-op once already 420
      expect(migrationSql.contains('max_search_duration_sec IS DISTINCT FROM 420'), isTrue);
    });

    test('the ENTIRE executable SQL is exactly this one UPDATE -- nothing else', () {
      // exactly one statement (one semicolon, at the very end)
      expect(';'.allMatches(migrationSql).length, equals(1));
      expect(migrationSql.endsWith(';'), isTrue);
      // touches no other dispatch_config column
      for (final forbidden in const [
        'round_1_radius', 'round_1_batch', 'round_2_radius', 'round_2_batch',
        'round_3_radius', 'round_3_batch', 'rider_response_timeout_sec',
        'reject_cooldown_sec', 'timeout_cooldown_sec', 'rider_location_stale_sec',
        'max_active_orders_per_rider', 'allow_round_3', 'allow_boosted_priority',
        'round_2_trigger_if_no_riders_sec', 'round_2_trigger_after_sec', 'round_3_trigger_after_sec',
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

    test('header comments correctly document the intercity exclusion (for reviewer context)', () {
      expect(migration.contains("order_type NOT IN ('intercity_ride','intercity_parcel')"), isTrue);
      expect(migration.contains('expire_stale_intercity_requests()'), isTrue);
      expect(migration.contains('NOT TOUCHED: expire_stale_intercity_requests()'), isTrue);
    });
  });

  group('create-order Edge Function -- local search expiry aligned to 420s/7min', () {
    test('local_ride default searchExpiryMinutes = 7 (was 15)', () {
      expect(createOrder.contains(RegExp(r'let searchExpiryMinutes =\s+7;')), isTrue);
      expect(createOrder.contains(RegExp(r'let searchExpiryMinutes =\s+15;')), isFalse);
    });

    test('local_parcel branch searchExpiryMinutes = 7 (was 20)', () {
      final start = createOrder.indexOf('order_type === "local_parcel"');
      final end = createOrder.indexOf('order_type ===\n      "intercity_parcel"');
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final localParcelBlock = createOrder.substring(start, end);
      expect(localParcelBlock.contains(RegExp(r'searchExpiryMinutes =\s+7;')), isTrue);
      expect(localParcelBlock.contains(RegExp(r'searchExpiryMinutes =\s+20;')), isFalse);
    });

    test('intercity_parcel (60) and intercity_ride (30) branches are UNCHANGED', () {
      final intercityParcelStart = createOrder.indexOf('order_type ===\n      "intercity_parcel"');
      final intercityRideStart = createOrder.indexOf('order_type ===\n      "intercity_ride"');
      expect(intercityParcelStart, greaterThan(-1));
      expect(intercityRideStart, greaterThan(intercityParcelStart));
      final intercityParcelBlock = createOrder.substring(intercityParcelStart, intercityRideStart);
      expect(intercityParcelBlock.contains(RegExp(r'searchExpiryMinutes =\s+60;')), isTrue);

      final intercityRideEnd = createOrder.indexOf('const dbVehicleType');
      final intercityRideBlock = createOrder.substring(intercityRideStart, intercityRideEnd);
      expect(intercityRideBlock.contains(RegExp(r'searchExpiryMinutes =\s+30;')), isTrue);
    });

    test('travel_date still overrides searchExpiresAt for intercity orders, unchanged', () {
      expect(createOrder.contains(
          'const isIntercityOrder = order_type === "intercity_ride" || order_type === "intercity_parcel";'),
          isTrue);
      expect(createOrder.contains('searchExpiresAt = new Date(travel_date).toISOString();'), isTrue);
    });
  });
}
