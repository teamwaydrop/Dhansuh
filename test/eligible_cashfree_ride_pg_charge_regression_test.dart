// Structural + math regression guard for the eligible-Cashfree-ride rider earning on eligible
// RIDE orders. Base rule: migration 20260901000037_eligible_cashfree_ride_pg_charge.sql.
// SUPERSEDED (Phase 12, Part A) by migration 20260901000038_cashfree_pg_charge_wallet_gst_
// separation.sql — GST is still computed/recorded but no longer deducted from the wallet-credited
// rider_earning. Migration 37's own on-disk text is left untouched (forward-only migrations) and
// still correctly describes what 37 itself added (the pg_charge_amount column, the trigger
// extension, the two-phase-design cleanup, the payment-method guard) — only the CURRENT
// authoritative net-earning formula lives in 38 now, so the math/formula assertions below read
// from 38, not 37. Backend only.
//
// BUSINESS RULE (current, approved Phase 12) — applies ONLY when ALL FOUR are true at completion:
//   1. orders.order_type          = 'ride'
//   2. rider has active Free Trial OR active WayDrop MAX
//   3. orders.fare_payment_method = 'cashfree'
//   4. orders.payment_status      = 'paid'
//
//   Rider Net (wallet credit) = Customer Paid Fare − (2% of fare, as PG Charge) ONLY.
//   GST (5% of fare) is still computed and written to orders.gst_amount, but as a SEPARATE,
//   reporting-only figure — it is no longer subtracted from the wallet-credited amount.
//   Commission 0%. No additional Government Tax. FINAL and IMMEDIATE — no provisional, no T+1/T+2,
//   no Cashfree settlement reconciliation for rider earnings.
//
// This also guards that the earlier (cancelled) two-phase settlement design is GONE and cannot run
// in parallel: no cashfree_fee_ledger, no apply_cashfree_fee_adjustment, no reconciler edge fn, no
// cron job, no provisional credit.
//
// This does not execute Postgres / Deno — it inspects source for the required patterns and
// re-derives the exact NUMERIC math.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

double _round2(double v) => (v * 100).round() / 100;
double _gst5(double fare) => _round2(fare * 5 / 100);
double _pg2(double fare) => _round2(fare * 2 / 100);
double _net(double fare) => _round2(fare - _pg2(fare));

void main() {
  final migration =
      _read('supabase/migrations/20260901000037_eligible_cashfree_ride_pg_charge.sql');
  final migration38 = _read(
      'supabase/migrations/20260901000038_cashfree_pg_charge_wallet_gst_separation.sql');
  // Comment-stripped view of migration 38, for assertions about what the CODE does/doesn't
  // contain -- the migration's own header comments legitimately narrate the superseded OLD
  // formula and name cashfree-webhook/verify-payment/credit_rider_for_completed_order as
  // "explicitly unchanged", which would otherwise false-positive a substring match against the
  // full file text.
  final migration38Code = migration38
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('--'))
      .join('\n');
  final baseWaiverMigration = _read(
      'supabase/migrations/20260901000019_gate_free_trial_waiver_to_local_orders.sql');
  final guardBaseMigration =
      _read('supabase/migrations/20260730000002_protect_order_fare_columns.sql');

  group('1. Exact math — fare − 2% PG only; 5% GST recorded separately, not deducted', () {
    test('₹100 -> ₹5.00 GST (recorded only), ₹2.00 PG (deducted), ₹98.00 wallet net', () {
      expect(_gst5(100), 5.00);
      expect(_pg2(100), 2.00);
      expect(_net(100), 98.00);
    });
    test('₹21 -> ₹1.05 GST (recorded only), ₹0.42 PG (deducted), ₹20.58 wallet net', () {
      expect(_gst5(21), 1.05);
      expect(_pg2(21), 0.42);
      expect(_net(21), 20.58);
    });
    test('₹200 -> ₹10.00 GST (recorded only), ₹4.00 PG (deducted), ₹196.00 wallet net', () {
      expect(_gst5(200), 10.00);
      expect(_pg2(200), 4.00);
      expect(_net(200), 196.00);
    });
    test('NOT the superseded (migration-37) or otherwise-rejected figures', () {
      // 93.00 / 19.53 / 186.00 were the OLD (fare - gst - pg) figures migration 38 superseded.
      for (final wrong in [19.95, 18.95, 19.52, 19.47, 90.24, 95.24, 93.00, 19.53, 186.00]) {
        expect(_net(21) == wrong || _net(100) == wrong || _net(200) == wrong, isFalse);
      }
    });
  });

  group('2. Migration 38 — exact GST (recorded) + PG (deducted) + wallet-net formula', () {
    test('GST = ROUND(fare * 5.0 / 100.0, 2) — still computed/written, unchanged from migration 37', () {
      expect(migration38.contains('v_gst_amount := ROUND(v_fare * 5.0 / 100.0, 2)'), isTrue);
    });
    test('PG Charge = ROUND(fare * 2.0 / 100.0, 2) — auto-calculated, never a hardcoded amount', () {
      expect(migration38.contains('v_pg_charge := ROUND(v_fare * 2.0 / 100.0, 2)'), isTrue);
    });
    test('rider net (wallet) = ROUND(fare − pg, 2) — GST no longer part of this formula', () {
      expect(migration38Code.contains('v_rider_earning := ROUND(v_fare - v_pg_charge, 2)'), isTrue);
      // the old GST-inclusive deduction must be gone from the CODE (the header comment is allowed
      // to narrate it, for context, as the superseded formula)
      expect(migration38Code.contains('v_rider_earning := ROUND(v_fare - v_gst_amount - v_pg_charge, 2)'), isFalse);
    });
    test('orders.gst_amount is still written (separate bucket, not folded into rider_earning)', () {
      final s = migration38.indexOf('IF v_is_eligible_cashfree_ride THEN');
      final e = migration38.indexOf('ELSIF v_has_active_subscription', s);
      expect(migration38.substring(s, e).contains('gst_amount = v_gst_amount'), isTrue);
    });
    test('the eligible branch does NOT call calculate_fare_breakdown (no inclusive ₹4.76)', () {
      final s = migration38.indexOf('IF v_is_eligible_cashfree_ride THEN');
      final e = migration38.indexOf('ELSIF v_has_active_subscription', s);
      expect(migration38.substring(s, e).contains('calculate_fare_breakdown'), isFalse);
    });
    test('commission stays 0% in the eligible branch', () {
      final s = migration38.indexOf('IF v_is_eligible_cashfree_ride THEN');
      final e = migration38.indexOf('ELSIF v_has_active_subscription', s);
      expect(migration38.substring(s, e).contains('v_commission_amount := 0.0'), isTrue);
    });
  });

  group('2b. Migration 38 — additive, single-purpose supersession of migration 37', () {
    test('only CREATE OR REPLACEs complete_order_and_settle (+ its unchanged protect-columns dependency is not redefined here)', () {
      final defs = RegExp(r'CREATE OR REPLACE FUNCTION (public\.\w+)')
          .allMatches(migration38)
          .map((m) => m.group(1))
          .toSet();
      expect(defs, {'public.complete_order_and_settle'});
    });
    test('the payment-method guard (4 conditions) is byte-for-byte identical to migration 37', () {
      String extractGuard(String src) {
        final s = src.indexOf('v_is_eligible_cashfree_ride := (');
        final e = src.indexOf(');', s);
        return src.substring(s, e);
      }
      expect(extractGuard(migration38), extractGuard(migration));
    });
    test('the personal-QR/cash waiver ELSIF branch is byte-for-byte identical to migration 37', () {
      String extractWaiver(String src) {
        final s = src.indexOf("ELSIF v_has_active_subscription AND v_order.order_type::text IN ('ride', 'local_parcel') THEN");
        final e = src.indexOf('-- =====================================================\n    -- 4.', s);
        return src.substring(s, e);
      }
      expect(extractWaiver(migration38), extractWaiver(migration));
    });
    test('v_skip_government_tax := true still set (no government tax on eligible Cashfree rides)', () {
      final s = migration38.indexOf('IF v_is_eligible_cashfree_ride THEN');
      final e = migration38.indexOf('ELSIF v_has_active_subscription', s);
      expect(migration38.substring(s, e).contains('v_skip_government_tax := true'), isTrue);
    });
    test('cashfree-webhook / verify-payment / credit_rider_for_completed_order are not redefined or referenced in CODE', () {
      // CODE-level check (header comments are allowed to name these as "explicitly unchanged" --
      // that is context, not a reference/redefinition).
      expect(migration38Code.contains('CREATE OR REPLACE FUNCTION public.credit_rider_for_completed_order'), isFalse);
      expect(migration38Code.contains('CREATE OR REPLACE FUNCTION public.apply_order_government_tax'), isFalse);
      expect(migration38Code.contains('cashfree-webhook'), isFalse);
      expect(migration38Code.contains('verify-payment'), isFalse);
    });
    test('migration 38 CODE still has no provisional / ledger / reconciliation logic', () {
      final fnStart38 = migration38.indexOf('CREATE OR REPLACE FUNCTION public.complete_order_and_settle(');
      final fnCode38 = migration38
          .substring(fnStart38)
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('--'))
          .join('\n');
      for (final banned in [
        'cashfree_fee_ledger',
        'apply_cashfree_fee_adjustment',
        'RIDE_FARE_PROVISIONAL',
        'provisional',
        'reconcil',
        'service_charge',
        'settlement_utr',
      ]) {
        expect(fnCode38.toLowerCase().contains(banned.toLowerCase()), isFalse,
            reason: 'complete_order_and_settle (migration 38) CODE must not contain "$banned"');
      }
    });
  });

  group('3. Payment-method guard — RIDE + CASHFREE + PAID + active sub only', () {
    test('4-condition predicate', () {
      final s = migration.indexOf('v_is_eligible_cashfree_ride := (');
      final e = migration.indexOf(');', s);
      final p = migration.substring(s, e);
      expect(p.contains("v_order.order_type::text = 'ride'"), isTrue);
      expect(p.contains('v_has_active_subscription'), isTrue);
      expect(p.contains("v_order.fare_payment_method::text = 'cashfree'"), isTrue);
      expect(p.contains("v_order.payment_status::text = 'paid'"), isTrue);
    });
    test('new branch evaluated BEFORE the existing ride/local_parcel waiver ELSIF', () {
      final newBranch = migration.indexOf('IF v_is_eligible_cashfree_ride THEN');
      final elsif = migration.indexOf(
          "ELSIF v_has_active_subscription AND v_order.order_type::text IN ('ride', 'local_parcel') THEN");
      expect(newBranch, greaterThan(0));
      expect(elsif, greaterThan(newBranch));
    });
    test('existing ride/local_parcel commission-waiver branch preserved (still calls calculate_fare_breakdown)', () {
      expect(
          baseWaiverMigration.contains(
              "IF v_has_active_subscription AND v_order.order_type::text IN ('ride', 'local_parcel') THEN"),
          isTrue);
      expect(
          migration.contains(
              "ELSIF v_has_active_subscription AND v_order.order_type::text IN ('ride', 'local_parcel') THEN"),
          isTrue);
      expect(migration.contains('public.calculate_fare_breakdown('), isTrue);
    });
  });

  group('4. No additional Government Tax on the eligible ride (no double-charge)', () {
    test('eligible branch sets v_skip_government_tax := true', () {
      final s = migration.indexOf('IF v_is_eligible_cashfree_ride THEN');
      final e = migration.indexOf('ELSIF v_has_active_subscription', s);
      expect(migration.substring(s, e).contains('v_skip_government_tax := true'), isTrue);
    });
    test('apply_order_government_tax gated behind IF NOT v_skip_government_tax', () {
      final gate = migration.indexOf('IF NOT v_skip_government_tax THEN');
      final call = migration.indexOf('v_tax_result := public.apply_order_government_tax(');
      expect(gate, greaterThan(0));
      expect(call, greaterThan(gate));
    });
    test('migration does NOT redefine apply_order_government_tax / calculate_fare_breakdown / credit_rider_for_completed_order', () {
      expect(migration.contains('CREATE OR REPLACE FUNCTION public.apply_order_government_tax'), isFalse);
      expect(migration.contains('CREATE OR REPLACE FUNCTION public.calculate_fare_breakdown'), isFalse);
      expect(migration.contains('CREATE OR REPLACE FUNCTION public.credit_rider_for_completed_order'), isFalse);
    });
  });

  group('5. FINAL + IMMEDIATE — no provisional, no phase 2, no reconciliation', () {
    // The complete_order_and_settle body (the CREATE OR REPLACE region) is where wallet math lives.
    final fnStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.complete_order_and_settle(');
    final fnBody = migration.substring(fnStart);
    // Same, with SQL line comments stripped — so a comment that mentions "no provisional" for
    // clarity does not trip the "no provisional CODE" check below.
    final fnCode = fnBody
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('--'))
        .join('\n');

    test('credit_rider_for_completed_order still called in-transaction (immediate)', () {
      expect(fnCode.contains('PERFORM public.credit_rider_for_completed_order('), isTrue);
    });
    test('the settlement function CODE has NO provisional / ledger / reconciliation logic', () {
      for (final banned in [
        'cashfree_fee_ledger',
        'apply_cashfree_fee_adjustment',
        'RIDE_FARE_PROVISIONAL',
        'provisional',
        'reconcil',
        'service_charge',
        'settlement_utr',
      ]) {
        expect(fnCode.toLowerCase().contains(banned.toLowerCase()), isFalse,
            reason: 'complete_order_and_settle CODE must not contain "$banned"');
      }
    });
    test('the only INSERT in the settlement function is order_status_history', () {
      final inserts = RegExp(r'INSERT INTO public\.(\w+)').allMatches(fnBody).map((m) => m.group(1)).toSet();
      expect(inserts, {'order_status_history'});
    });
    test('the two-phase object names appear ONLY in the section-0 defensive cleanup / comments', () {
      final section0End = migration.indexOf('-- 1. orders.pg_charge_amount');
      expect(section0End, greaterThan(0));
      for (final entry in migration.split('\n').asMap().entries) {
        final line = entry.value;
        final offset = migration.indexOf(line);
        final l = line.trimLeft();
        final mentionsTwoPhase = l.contains('cashfree_fee_ledger') ||
            l.contains('apply_cashfree_fee_adjustment') ||
            l.contains('get_stale_pending_cashfree_fee_provisionals') ||
            l.contains('trigger_reconcile_cashfree_settlements') ||
            l.contains('reconcile-cashfree-settlements');
        if (!mentionsTwoPhase) continue;
        // allowed: in a leading comment, OR inside the section-0 DEFENSIVE CLEANUP block
        final ok = l.startsWith('--') || offset < section0End;
        expect(ok, isTrue, reason: 'two-phase name outside the cleanup section / comments: $line');
      }
    });
  });

  group('6. Defensive removal of the cancelled two-phase objects', () {
    test('migration drops the table + 3 functions + unschedules the cron job', () {
      expect(migration.contains('DROP TABLE IF EXISTS public.cashfree_fee_ledger CASCADE'), isTrue);
      expect(migration.contains('DROP FUNCTION IF EXISTS public.apply_cashfree_fee_adjustment(uuid, uuid, numeric, jsonb)'), isTrue);
      expect(migration.contains('DROP FUNCTION IF EXISTS public.get_stale_pending_cashfree_fee_provisionals(integer)'), isTrue);
      expect(migration.contains('DROP FUNCTION IF EXISTS public.trigger_reconcile_cashfree_settlements()'), isTrue);
      expect(migration.contains("cron.unschedule('reconcile-cashfree-settlements')"), isTrue);
    });
    test('the two-phase migration 20260901000038 and the reconciler edge fn no longer exist', () {
      expect(File('supabase/migrations/20260901000038_schedule_cashfree_settlement_reconciliation.sql').existsSync(), isFalse);
      expect(File('supabase/functions/reconcile-cashfree-settlements/index.ts').existsSync(), isFalse);
      expect(File('supabase/migrations/20260901000037_eligible_cashfree_ride_two_phase_settlement.sql').existsSync(), isFalse);
      expect(File('test/eligible_cashfree_ride_two_phase_settlement_regression_test.dart').existsSync(), isFalse);
    });
    test('no OTHER file in the repo still references the two-phase objects (only mig 37 cleans them up)', () {
      for (final dir in ['supabase/migrations', 'supabase/functions', 'lib', 'test']) {
        final d = Directory(dir);
        if (!d.existsSync()) continue;
        for (final f in d.listSync(recursive: true).whereType<File>()) {
          if (!(f.path.endsWith('.sql') || f.path.endsWith('.ts') || f.path.endsWith('.dart'))) continue;
          final base = f.uri.pathSegments.last;
          // mig 37 legitimately DROPs the objects; this test file legitimately names them.
          if (base == '20260901000037_eligible_cashfree_ride_pg_charge.sql') continue;
          if (base == 'eligible_cashfree_ride_pg_charge_regression_test.dart') continue;
          final c = f.readAsStringSync();
          expect(c.contains('cashfree_fee_ledger'), isFalse, reason: '${f.path} references cashfree_fee_ledger');
          expect(c.contains('apply_cashfree_fee_adjustment'), isFalse, reason: '${f.path} references apply_cashfree_fee_adjustment');
          expect(c.contains('reconcile-cashfree-settlements'), isFalse, reason: '${f.path} references reconcile-cashfree-settlements');
        }
      }
    });
  });

  group('7. orders.pg_charge_amount column + guard', () {
    test('additive column', () {
      expect(migration.contains('ALTER TABLE public.orders'), isTrue);
      expect(migration.contains('ADD COLUMN IF NOT EXISTS pg_charge_amount numeric NOT NULL DEFAULT 0'), isTrue);
    });
    test('written only in the eligible branch of complete_order_and_settle', () {
      // exactly one UPDATE ... SET ... pg_charge_amount in the migration
      final matches = RegExp(r'pg_charge_amount = v_pg_charge').allMatches(migration).length;
      expect(matches, 1);
    });
    test('protect_order_financial_columns extended by pg_charge_amount, escape hatch preserved', () {
      final s = migration.indexOf('CREATE OR REPLACE FUNCTION public.protect_order_financial_columns()');
      final e = migration.indexOf('DROP TRIGGER IF EXISTS protect_order_financial_columns_trigger', s);
      final body = migration.substring(s, e);
      expect(body.contains('OR NEW.pg_charge_amount IS DISTINCT FROM OLD.pg_charge_amount'), isTrue);
      // the two escape hatches this function must never lose (see 20260730000002 header)
      expect(body.contains("auth.role() <> 'service_role'"), isTrue);
      expect(body.contains("current_setting('app.bypass_financial_guard', true) IS DISTINCT FROM 'true'"), isTrue);
      // every column the live guard already protected is still present
      for (final col in [
        'commission_amount', 'gst_amount', 'rider_earning', 'commission_percentage',
        'gst_percentage', 'actual_fare', 'boost_rider_earning', 'boost_company_earning',
        'payment_status', 'fare_payment_method', 'current_fare', 'final_fare',
        'boost_amount', 'boost_percentage',
      ]) {
        expect(body.contains('NEW.$col IS DISTINCT FROM OLD.$col'), isTrue, reason: 'guard dropped $col');
        expect(guardBaseMigration.contains('NEW.$col IS DISTINCT FROM OLD.$col'), isTrue);
      }
    });
    test('the column-scoped trigger is recreated with pg_charge_amount in the UPDATE OF list', () {
      final s = migration.indexOf('CREATE TRIGGER protect_order_financial_columns_trigger');
      final e = migration.indexOf('EXECUTE FUNCTION public.protect_order_financial_columns()', s);
      expect(migration.substring(s, e).contains('pg_charge_amount'), isTrue);
    });
  });

  group('8. Rider UI reflects the deployed PG-charge rule (see eligible_pg_ride_ui_regression_test.dart for the full UI guard)', () {
    // The backend credits the FINAL net immediately; the rider-facing "YOUR TRIP EARNINGS"
    // surfaces must display that final net directly for an eligible ride (not the old
    // rider_earning + GST − Government Tax formula). FareBreakdown carries the authoritative
    // orders.pg_charge_amount; the four screens special-case breakdown.isPgChargeRide.
    test('FareBreakdown exposes pgChargeAmount + isPgChargeRide (5-condition)', () {
      final helper = _read('lib/shared/helpers/fare_presentation_helper.dart');
      expect(helper.contains('final double pgChargeAmount;'), isTrue);
      expect(helper.contains("order['pg_charge_amount']"), isTrue);
      expect(helper.contains('bool get isPgChargeRide =>'), isTrue);
      expect(helper.contains('pgChargeAmount > 0'), isTrue);
      expect(helper.contains("orderType == 'ride'"), isTrue);
      expect(helper.contains("farePaymentMethod == 'cashfree'"), isTrue);
      expect(helper.contains("paymentStatus == 'paid'"), isTrue);
      expect(helper.contains('subscriptionCommissionWaived'), isTrue);
    });
    for (final path in const [
      'lib/features/rider/orders/screens/rider_active_order_screen.dart',
      'lib/features/rider/orders/screens/rider_order_history_screen.dart',
      'lib/features/rider/activity/rider_activity_tab.dart',
      'lib/features/rider/earnings/rider_earnings_tab.dart',
    ]) {
      test('$path special-cases isPgChargeRide and shows the authoritative PG column', () {
        final src = _read(path);
        expect(src.contains('breakdown.isPgChargeRide'), isTrue);
        expect(src.contains("'PG Charge (2%)'"), isTrue);
        expect(src.contains(r'breakdown.pgChargeAmount.toStringAsFixed(2)'), isTrue);
        // eligible ride never re-runs the government-tax lookup formula in its branch
        expect(src.contains("'Government Tax'"), isTrue); // still present for the non-eligible path
      });
    }
  });

  group('9. No hardcoded PG / Cashfree fee amount', () {
    test('never the ₹0.48 Cashfree-QR figure anywhere', () {
      expect(migration.contains('0.48'), isFalse);
      expect(migration38.contains('0.48'), isFalse);
    });
    test('PG charge is computed as a percentage (fare * 2.0 / 100.0), never assigned a literal amount', () {
      expect(migration38.contains('v_pg_charge := ROUND(v_fare * 2.0 / 100.0, 2)'), isTrue);
      // no `v_pg_charge := <number>` and no `pg_charge_amount = <number-literal>`
      expect(RegExp(r'v_pg_charge\s*:=\s*[0-9]').hasMatch(migration38), isFalse);
      expect(RegExp(r'pg_charge_amount\s*=\s*[0-9]').hasMatch(migration38), isFalse);
    });
    test('GST is a direct 5% of the fare, not a literal and not the inclusive back-calc', () {
      expect(migration38.contains('v_gst_amount := ROUND(v_fare * 5.0 / 100.0, 2)'), isTrue);
      expect(migration38.contains('v_fare / (1'), isFalse);
      expect(migration38.contains('v_fare / 1.05'), isFalse);
    });
  });

  group('10. Non-eligible flows untouched (structural cross-check)', () {
    test('migration only CREATE OR REPLACEs the two intended functions', () {
      final defs = RegExp(r'CREATE OR REPLACE FUNCTION (public\.\w+)')
          .allMatches(migration)
          .map((m) => m.group(1))
          .toSet();
      expect(defs, {'public.protect_order_financial_columns', 'public.complete_order_and_settle'});
    });
    test('migration does not reference any intercity completion function', () {
      expect(migration.contains('confirm_intercity_parcel_payment_received'), isFalse);
      expect(migration.contains('complete_intercity_parcel_delivery'), isFalse);
    });
    test('direct-collection determination + company_cod_share still computed for non-eligible orders', () {
      expect(migration.contains('v_is_direct_collection := CASE'), isTrue);
      expect(migration.contains('v_company_cod_share := ROUND(v_commission_amount + v_gst_amount, 2)'), isTrue);
    });
  });
}
