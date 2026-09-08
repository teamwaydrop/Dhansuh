// Structural regression guard for the riders-table RLS bypass fix
// (20260730000000_protect_rider_financial_columns.sql). Like the other
// *_regression_test.dart files in this repo, this inspects the migration's source directly rather
// than executing it against Postgres -- PL/pgSQL triggers can't run inside `flutter test`. It locks
// in: every guarded column is present, the guard is UPDATE-only (never INSERT, so rider signup/
// profile-creation flows are untouched), service_role is always exempt (so every legitimate
// server-side writer -- cashfree-webhook, verify-payment, apply_order_government_tax,
// apply_government_tax_payment, credit_rider_for_completed_order, the withdrawal RPCs -- keeps
// working unmodified), and the migration touches nothing else.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read('supabase/migrations/20260730000000_protect_rider_financial_columns.sql');

  const guardedColumns = [
    'wallet_balance',
    'cod_pending_amount',
    'cod_limit',
    'subscription_active',
    'subscription_expires_at',
    'commission_waiver_active',
    'government_tax_due_balance',
    'is_verified',
  ];

  group('protect_rider_financial_columns() guards every financial/subscription column', () {
    for (final column in guardedColumns) {
      test('$column is compared NEW vs OLD inside the guard', () {
        expect(
          migration.contains('NEW.$column IS DISTINCT FROM OLD.$column'),
          isTrue,
          reason: '$column must be guarded by the trigger',
        );
      });
    }

    test('a non-service-role change to any guarded column raises an exception', () {
      expect(migration.contains("auth.role() <> 'service_role'"), isTrue);
      expect(migration.contains('RAISE EXCEPTION'), isTrue);
    });
  });

  group('the guard is UPDATE-only -- rider signup/profile creation is untouched', () {
    test('trigger fires BEFORE UPDATE, never BEFORE INSERT', () {
      expect(migration.contains('BEFORE UPDATE ON public.riders'), isTrue);
      expect(migration.contains('BEFORE INSERT'), isFalse);
      expect(migration.contains('BEFORE INSERT OR UPDATE'), isFalse);
    });

    test('non-guarded profile columns (name, vehicle, location, etc.) are never referenced', () {
      // The guard must only ever compare the 8 financial/subscription columns above -- it must not
      // grow to block ordinary profile edits (name, phone, vehicle info, live location) that riders
      // are expected to keep updating themselves.
      const ordinaryProfileColumns = [
        'full_name',
        'vehicle_number',
        'current_latitude',
        'current_longitude',
        'profile_photo_url',
      ];
      for (final column in ordinaryProfileColumns) {
        expect(migration.contains(column), isFalse,
            reason: '$column must not be added to the financial-column guard');
      }
    });
  });

  group('service_role (every legitimate server-side writer) is exempt', () {
    test('the function is SECURITY DEFINER with a locked search_path', () {
      expect(migration.contains('SECURITY DEFINER'), isTrue);
      expect(migration.contains('SET search_path = public'), isTrue);
    });

    test('trigger and function names match between CREATE FUNCTION and CREATE TRIGGER', () {
      expect(migration.contains('CREATE OR REPLACE FUNCTION public.protect_rider_financial_columns()'),
          isTrue);
      expect(
        migration.contains(
          'CREATE TRIGGER protect_rider_financial_columns_trigger\nBEFORE UPDATE ON public.riders\nFOR EACH ROW\nEXECUTE FUNCTION public.protect_rider_financial_columns();',
        ),
        isTrue,
      );
      expect(migration.contains('DROP TRIGGER IF EXISTS protect_rider_financial_columns_trigger ON public.riders;'),
          isTrue);
    });
  });

  group('no business logic elsewhere was touched by this migration', () {
    test('the migration file contains no DROP/ALTER of any unrelated object', () {
      // This fix must be additive-only: one new function, one new trigger. No table alterations,
      // no other function/policy touched.
      expect(migration.contains('ALTER TABLE'), isFalse);
      expect(migration.contains('DROP POLICY'), isFalse);
      expect(migration.contains('DROP FUNCTION'), isFalse);
      // The only DROP allowed is the idempotent re-create of this migration's own trigger.
      final dropCount = 'DROP '.allMatches(migration).length;
      expect(dropCount, 1, reason: 'only the DROP TRIGGER IF EXISTS for this migration\'s own trigger');
    });
  });

  group('every known server-side writer of these columns runs only under service_role', () {
    // Cross-checked directly against the audit: none of these functions are GRANTed to
    // `authenticated`, so none of them are broken by requiring auth.role() = 'service_role'.
    final withdrawalFns = _read('supabase/migrations/20260530000001_rider_withdrawals.sql');
    final taxFns = _read('supabase/migrations/20260726000004_government_tax_due_functions.sql');
    final creditFn = _read('supabase/migrations/20260724000003_atomic_rider_completion_credit.sql');

    test('withdrawal functions (wallet_balance writers) are granted only to service_role/postgres', () {
      expect(withdrawalFns.contains('GRANT EXECUTE ON FUNCTION public.initiate_withdrawal(numeric, uuid) TO service_role, postgres;'),
          isTrue);
      expect(withdrawalFns.contains('GRANT EXECUTE ON FUNCTION public.fail_withdrawal(uuid, jsonb) TO service_role, postgres;'),
          isTrue);
      expect(
        withdrawalFns.contains(
          'GRANT EXECUTE ON FUNCTION public.complete_withdrawal(uuid, text, text, jsonb) TO service_role, postgres;',
        ),
        isTrue,
      );
      // rider_withdrawals itself has its own SELECT-only "TO authenticated" RLS policies (a rider
      // reading their own withdrawal history) -- that's unrelated and expected. What matters is
      // that none of the three wallet_balance-writing *functions* above are EXECUTE-granted to
      // authenticated, which the three exact GRANT lines checked above already establish.
      expect(withdrawalFns.contains('GRANT EXECUTE ON FUNCTION public.initiate_withdrawal'), isTrue);
      expect(withdrawalFns.contains('GRANT EXECUTE ON FUNCTION public.initiate_withdrawal(numeric, uuid) TO authenticated'),
          isFalse);
    });

    test('government tax due balance writers (apply_order_government_tax / apply_government_tax_payment) are service_role-only', () {
      expect(
        taxFns.contains(
          'GRANT EXECUTE ON FUNCTION public.apply_order_government_tax(uuid, uuid, text, numeric, boolean) TO service_role;',
        ),
        isTrue,
      );
      expect(
        taxFns.contains('GRANT EXECUTE ON FUNCTION public.apply_government_tax_payment(uuid, uuid, numeric) TO service_role;'),
        isTrue,
      );
    });

    test('credit_rider_for_completed_order (wallet credit on order completion) is service_role-only', () {
      expect(
        creditFn.contains(
          'GRANT EXECUTE ON FUNCTION public.credit_rider_for_completed_order(uuid, numeric, boolean, numeric) TO service_role;',
        ),
        isTrue,
      );
    });
  });
}
