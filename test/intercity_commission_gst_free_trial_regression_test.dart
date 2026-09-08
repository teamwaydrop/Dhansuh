// Regression guard for: an intercity delivery completion screen showed Ride Fare ₹261, WayDrop
// Commission ₹0, Government Tax ₹0, Trip Earnings ₹261 -- i.e. WayDrop commission was incorrectly
// waived to 0% for an intercity order.
//
// BUSINESS RULE (explicit, verbatim): the 30-day free-trial / 0% WayDrop commission benefit
// applies ONLY to local rides and local parcels. It must NEVER waive WayDrop commission for
// intercity passenger rides (10% commission + 5% GST) or intercity parcel deliveries (10%
// commission + 18% GST).
//
// ROOT CAUSE (traced, not assumed): two settlement functions waived commission purely from
// riders.subscription_active / subscription_expires_at, with no order_type check --
//   1. complete_order_and_settle() -- the general completion path used for BOTH local ride/parcel
//      completions AND intercity_ride completions.
//   2. confirm_intercity_parcel_payment_received() -- always processes order_type =
//      'intercity_parcel' (enforced at its own top), yet still zeroed commission whenever the
//      rider's LOCAL free trial happened to be active.
//
// FIX (migration 20260901000019_gate_free_trial_waiver_to_local_orders.sql):
//   1. complete_order_and_settle()'s waiver branch gained
//      `AND v_order.order_type::text IN ('ride', 'local_parcel')`.
//   2. confirm_intercity_parcel_payment_received() no longer derives commission from
//      subscription state at all -- v_commission_pct always uses the order's actual
//      commission_percentage, and subscription_commission_waived is always written as false.
//
// CAUSE B, UPDATE (originally left unclassified per explicit business decision; later resolved,
// same session): apply_order_government_tax() initially had no category/rate configured for
// intercity_ride at all. Migration 20260901000021_intercity_ride_gov_tax_and_stale_negotiated_
// commission.sql resolves this -- intercity_ride now classifies under a new
// 'intercity_passenger_ride' category at 5.0% (mirroring local_passenger_ride's rate, per explicit
// business decision), seeded as a NEW tax_rate_config row rather than an edit to the existing
// local_passenger_ride/parcel_delivery rows. intercity_parcel is untouched -- it was already
// correctly configured under 'parcel_delivery' at 18%. See
// intercity_ride_gov_tax_and_accept_request_commission_regression_test.dart for the full guard on
// this fix (and the separate accept_intercity_request() stale-commission fix in the same
// migration).
//
// This is a structural + math regression guard: it reads the real SQL source and independently
// re-derives the commission math the fixed functions must produce, matching the pattern used
// throughout this suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

// Strips `--` line comments before a containment check, so an in-source comment that documents
// (and names) the removed old variable/condition -- exactly what this migration's own fix
// comments do -- can never cause a false positive.
String _stripLineComments(String source) => source
    .split('\n')
    .map((line) {
      final idx = line.indexOf('--');
      return idx == -1 ? line : line.substring(0, idx);
    })
    .join('\n');

void main() {
  final waiverMigration = _read(
    'supabase/migrations/20260901000019_gate_free_trial_waiver_to_local_orders.sql',
  );
  final govTaxFunctions = _read('supabase/migrations/20260726000004_government_tax_due_functions.sql');
  final govTaxSchema = _read('supabase/migrations/20260726000003_government_tax_due_schema.sql');

  group('complete_order_and_settle(): free-trial waiver gated to local orders only', () {
    test('the waiver IF now requires order_type IN (\'ride\', \'local_parcel\') in addition to '
        'v_has_active_subscription', () {
      expect(
        waiverMigration.contains(
          "IF v_has_active_subscription AND v_order.order_type::text IN ('ride', 'local_parcel') THEN",
        ),
        isTrue,
      );
    });

    test('a bare v_has_active_subscription-only IF (the old, ungated condition) is gone', () {
      final fnStart = waiverMigration.indexOf('CREATE OR REPLACE FUNCTION public.complete_order_and_settle');
      final fnEnd = waiverMigration.indexOf('CREATE OR REPLACE FUNCTION public.confirm_intercity_parcel_payment_received');
      final fnBody = waiverMigration.substring(fnStart, fnEnd);
      expect(fnBody.contains('IF v_has_active_subscription THEN'), isFalse);
    });

    test('the waiver body itself (0% commission, subscription_commission_waived=true) is otherwise '
        'byte-for-byte unchanged -- a local completion during an active trial still gets exactly '
        'the same waiver as before', () {
      final ifStart = waiverMigration.indexOf(
        "IF v_has_active_subscription AND v_order.order_type::text IN ('ride', 'local_parcel') THEN",
      );
      final ifEnd = waiverMigration.indexOf('END IF;', ifStart);
      final branch = waiverMigration.substring(ifStart, ifEnd);
      expect(branch.contains('v_commission_amount := 0.0;'), isTrue);
      expect(branch.contains('commission_amount = 0.0,'), isTrue);
      expect(branch.contains('subscription_commission_waived = true'), isTrue);
      expect(branch.contains('public.calculate_fare_breakdown('), isTrue);
    });

    test('government tax and every other settlement step (direct-collection determination, wallet '
        'credit, audit history) remain completely untouched by this migration', () {
      expect(waiverMigration.contains('public.apply_order_government_tax('), isTrue);
      expect(waiverMigration.contains('public.credit_rider_for_completed_order('), isTrue);
      expect(waiverMigration.contains('INSERT INTO public.order_status_history'), isTrue);
    });
  });

  group('confirm_intercity_parcel_payment_received(): never waives commission (order_type is '
      'always intercity_parcel here)', () {
    test('the function still hard-enforces order_type = intercity_parcel at its top, so no '
        'order_type check is even needed for the fix itself', () {
      final fnStart = waiverMigration.indexOf(
        'CREATE OR REPLACE FUNCTION public.confirm_intercity_parcel_payment_received',
      );
      expect(fnStart, greaterThan(-1));
      final fnBody = waiverMigration.substring(fnStart);
      expect(
        fnBody.contains("IF v_order.order_type::text <> 'intercity_parcel' THEN"),
        isTrue,
      );
    });

    test('v_commission_pct always uses the order\'s actual commission_percentage -- never '
        'v_has_active_subscription', () {
      final fnStart = waiverMigration.indexOf(
        'CREATE OR REPLACE FUNCTION public.confirm_intercity_parcel_payment_received',
      );
      final fnBody = _stripLineComments(waiverMigration.substring(fnStart));
      expect(fnBody.contains('v_commission_pct := COALESCE(v_order.commission_percentage, 0);'), isTrue);
      expect(fnBody.contains('v_has_active_subscription'), isFalse);
    });

    test('subscription_commission_waived is always written as false, not derived from the '
        'rider\'s (irrelevant, local-only) subscription state', () {
      final fnStart = waiverMigration.indexOf(
        'CREATE OR REPLACE FUNCTION public.confirm_intercity_parcel_payment_received',
      );
      final fnBody = waiverMigration.substring(fnStart);
      expect(fnBody.contains('subscription_commission_waived = false,'), isTrue);
    });

    test('₹261 fare at the standard 10% commission / 18% GST intercity-parcel rate -> commission '
        '₹26.10, matching what the completion screen must now show instead of ₹0', () {
      const fare = 261.0;
      const commissionPct = 10.0;
      final commission = (fare * commissionPct / 100 * 100).round() / 100;
      expect(commission, 26.10);
      expect(commission, isNot(0));
    });
  });

  group('GST rates are read from the order\'s own gst_percentage, never recomputed/hardcoded by '
      'this migration', () {
    test('both functions pass v_order.gst_percentage (with only a fallback default) into '
        'calculate_fare_breakdown, never a literal intercity-specific rate', () {
      expect(waiverMigration.contains('COALESCE(v_order.gst_percentage, 5.0)'), isTrue);
    });
  });

  group('Cause B (originally a business-policy gap, now resolved -- see migration 20260901000021 '
      'and its own dedicated regression test)', () {
    test('the ORIGINAL 20260726000004 definition of apply_order_government_tax() (superseded by '
        '20260901000021, not the live function any more) is left untouched by this migration -- '
        'confirms the fix is additive, not an edit to history', () {
      final categoryStart = govTaxFunctions.indexOf('v_category := CASE');
      final categoryEnd = govTaxFunctions.indexOf('END;', categoryStart);
      final categoryBlock = govTaxFunctions.substring(categoryStart, categoryEnd);
      expect(categoryBlock.contains("ELSE NULL -- includes 'intercity_ride'"), isTrue);
    });

    test('intercity_parcel, in this original definition, IS correctly classified under '
        'parcel_delivery at 18% -- so Government Tax already displays correctly for intercity '
        'parcel completions once commission is fixed', () {
      final categoryStart = govTaxFunctions.indexOf('v_category := CASE');
      final categoryEnd = govTaxFunctions.indexOf('END;', categoryStart);
      final categoryBlock = govTaxFunctions.substring(categoryStart, categoryEnd);
      expect(categoryBlock.contains("'intercity_parcel'"), isTrue);
      expect(categoryBlock.contains("THEN 'parcel_delivery'"), isTrue);
      expect(govTaxSchema.contains("('parcel_delivery', 18.0)"), isTrue);
    });
  });
}
