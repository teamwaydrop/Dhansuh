// Structural + math regression guard for the temporary "Platform GST = 0" business decision
// (migration 20260905000000_temporarily_disable_platform_gst.sql).
//
// CONTEXT: orders.gst_amount ("Platform GST") used to be a GST-inclusive decomposition of the
// customer-paid fare (base_fare = fare/(1+gst%/100), gst_amount = fare - base_fare), feeding two
// places: (1) complete_order_and_settle()'s company_cod_share (-> cod_pending_amount, "Cash to be
// Paid" for direct-collection rides) and (2) the completion-screen display formula. Business
// decided (pending CA/GST confirmation) to charge 0 for it, WITHOUT removing the column, the
// function, or the Government Tax / commission calculations.
//
// This does not execute the SQL function itself -- it inspects the migration's source for the
// exact two-line change and independently re-derives the resulting math for a ₹21 example, the
// same style already used by rider_fare_whole_rupee_rounding_regression_test.dart and
// subscription_plan_regression_test.dart for this codebase.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// Mirrors calculate_fare_breakdown() AFTER 20260905000000: commission is still computed off the
/// GST-decomposed base_fare (unchanged), but gst_amount is pinned to 0 and rider_earning is the
/// full fare minus commission only (no GST withheld).
Map<String, double> _breakdown({
  required double totalFare,
  required double gstPercentage,
  required double commissionPercentage,
}) {
  final baseFare = double.parse((totalFare / (1 + gstPercentage / 100.0)).toStringAsFixed(2));
  const gstAmount = 0.0; // disabled
  final commissionAmount = double.parse((baseFare * commissionPercentage / 100.0).toStringAsFixed(2));
  final riderEarning = double.parse((totalFare - commissionAmount).toStringAsFixed(2));
  return {
    'base_fare': baseFare,
    'gst_amount': gstAmount,
    'commission_amount': commissionAmount,
    'rider_earning': riderEarning,
  };
}

void main() {
  final migration = _read('supabase/migrations/20260905000000_temporarily_disable_platform_gst.sql');
  // Scoped to the actual function body (excludes the descriptive header comment block above it,
  // which legitimately mentions company_cod_share/complete_order_and_settle/pg_charge/the old
  // formula for documentation purposes) -- this is what the negative "never touches X" assertions
  // below actually need to prove.
  final functionBody = migration.substring(
    migration.indexOf('CREATE OR REPLACE FUNCTION public.calculate_fare_breakdown'),
  );
  final settlementMigration = _read('supabase/migrations/20260901000038_cashfree_pg_charge_wallet_gst_separation.sql');
  final govTaxFunctions = _read('supabase/migrations/20260726000004_government_tax_due_functions.sql');
  final creditFunction = _read('supabase/migrations/20260820000000_fix_intercity_parcel_delivery_rider_credit_guard.sql');
  final baselineSchema = _read('supabase/migrations/20260529000000_baseline_foundational_schema.sql');

  group('1/3/6. ₹21 ride math: Platform GST = 0, commission unchanged at ₹2.00, rider net ₹17.95', () {
    test('the worked example matches the approved target exactly', () {
      final b = _breakdown(totalFare: 21, gstPercentage: 5.0, commissionPercentage: 10.0);
      expect(b['gst_amount'], 0.0);
      expect(b['commission_amount'], 2.00);
      expect(b['rider_earning'], 19.00); // fare(21) - commission(2.00), GST no longer withheld
      // Government Tax (unchanged, separate calculation, off the gross fare) subtracted only for
      // non-direct-collection (Cashfree) settlement -- see complete_order_and_settle step 5.
      const governmentTax = 1.05;
      final rideCompletionNet = double.parse((b['rider_earning']! - governmentTax).toStringAsFixed(2));
      expect(rideCompletionNet, 17.95);
    });
  });

  group('2/5. Government Tax is completely untouched by this migration', () {
    test('apply_order_government_tax formula/branches are byte-for-byte unaffected', () {
      expect(govTaxFunctions.contains('v_tax_amount := ROUND(p_taxable_base * v_rate / 100.0, 2);'), isTrue);
      expect(govTaxFunctions.contains('government_tax_due_balance = government_tax_due_balance + v_tax_amount'), isTrue);
    });

    test('the function body never touches apply_order_government_tax or tax_rate_config', () {
      expect(functionBody.contains('apply_order_government_tax'), isFalse);
      expect(functionBody.contains('tax_rate_config'), isFalse);
      expect(functionBody.contains('government_tax_due_balance'), isFalse);
    });
  });

  group('4. Direct-collection Cash to be Paid becomes commission-only (₹2.00, not ₹3.00)', () {
    test('company_cod_share (commission_amount + gst_amount) is an unchanged formula -- it now '
        'evaluates to commission-only because gst_amount is 0, not because the formula changed', () {
      expect(
        settlementMigration.contains('v_company_cod_share := ROUND(v_commission_amount + v_gst_amount, 2);'),
        isTrue,
      );
      expect(functionBody.contains('v_company_cod_share'), isFalse); // this function never touches it
    });

    test('credit_rider_for_completed_order cod_pending_amount formula is unchanged', () {
      expect(
        creditFunction.contains(
          'cod_pending_amount = COALESCE(cod_pending_amount, 0)\n            + (CASE WHEN p_is_direct_collection THEN p_company_cod_share ELSE 0 END),',
        ),
        isTrue,
      );
    });
  });

  group('7. Cashfree settlement (non-subscription) reflects the same ₹17.95 net', () {
    test('complete_order_and_settle step 5 (government-tax withholding for non-direct-collection) '
        'is unchanged -- it operates on whatever rider_earning it is given', () {
      expect(
        settlementMigration.contains(
          'v_rider_net_earning := ROUND(v_rider_net_earning - v_tax_amount, 2);',
        ),
        isTrue,
      );
    });

    test('the eligible-Cashfree-ride PG-charge branch (subscription-gated) is not reimplemented '
        'inside calculate_fare_breakdown -- it stays exclusively in complete_order_and_settle, per '
        '"Do NOT change subscription logic" (a pre-existing comment referencing that function by '
        'name is fine; no PG-charge-specific ASSIGNMENT exists here)', () {
      expect(functionBody.contains('v_is_eligible_cashfree_ride :='), isFalse);
      expect(functionBody.contains('pg_charge_amount ='), isFalse);
      expect(functionBody.contains('v_skip_government_tax'), isFalse);
    });
  });

  group('8. orders.gst_amount column/schema still exists for future re-enable', () {
    test('the column is not dropped anywhere, and this migration documents the exact revert', () {
      expect(baselineSchema.contains('gst_amount'), isTrue);
      expect(migration.contains('DROP COLUMN'), isFalse);
      expect(migration.contains('gst_amount'), isTrue); // still returned in the jsonb, just as 0
      expect(migration.contains('Re-enable'), isTrue);
    });

    test('calculate_fare_breakdown still returns a gst_amount key in its jsonb result', () {
      expect(migration.contains("'gst_amount', v_gst_amount,"), isTrue);
    });
  });

  group('9. No subscription/payment/reward regression -- scoped to one function only', () {
    test('this migration touches exactly one function: calculate_fare_breakdown', () {
      final createOrReplaceCount = 'CREATE OR REPLACE FUNCTION'.allMatches(migration).length;
      expect(createOrReplaceCount, 1);
      expect(migration.contains('CREATE OR REPLACE FUNCTION public.calculate_fare_breakdown'), isTrue);
    });

    test('no subscription, payment, or reward table/function is referenced', () {
      for (final term in [
        'subscription_plans',
        'rider_subscription_history',
        'payments',
        'rewards',
        'reward_activation',
        'activate_rider_free_trial',
      ]) {
        expect(migration.contains(term), isFalse);
      }
    });

    test('the commission formula and its base are byte-for-byte identical to the pre-existing '
        'whole-rupee-rounding definition -- only gst_amount and rider_earning source change', () {
      expect(
        migration.contains(
          'v_base_fare := ROUND(v_new_total_fare / (1 + (COALESCE(p_gst_percentage, 5.0) / 100.0)), 2);',
        ),
        isTrue,
      );
      expect(
        migration.contains(
          'v_commission_amount := ROUND(v_base_fare * (COALESCE(p_commission_percentage, 0) / 100.0), 2);',
        ),
        isTrue,
      );
      expect(migration.contains('v_gst_amount := 0;'), isTrue);
      expect(
        migration.contains('v_rider_earning := ROUND(v_new_total_fare - v_commission_amount, 2);'),
        isTrue,
      );
      // Not asserting the old formula's absence as code text -- a "Re-enable by restoring: ..."
      // comment documenting it verbatim, right above the new line, is intentional and expected
      // (both here and inside 20260901000018's own unedited history). CREATE OR REPLACE means
      // only ONE of the two can ever be the live executable statement regardless.
    });

    test('GRANT is preserved for both authenticated and service_role callers, unchanged', () {
      expect(
        migration.contains(
          'GRANT EXECUTE ON FUNCTION public.calculate_fare_breakdown(numeric, numeric, numeric, numeric, numeric) TO authenticated, service_role;',
        ),
        isTrue,
      );
    });
  });
}
