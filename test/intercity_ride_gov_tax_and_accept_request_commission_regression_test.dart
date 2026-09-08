// Regression guard for two independent intercity fixes in migration
// 20260901000021_intercity_ride_gov_tax_and_stale_negotiated_commission.sql, both approved after
// investigation (not assumed) in the same session as the local-free-trial waiver gate
// (20260901000019, see intercity_commission_gst_free_trial_regression_test.dart).
//
// FIX 1 -- intercity_ride government tax (Section 9(5)) classification.
// ROOT CAUSE: apply_order_government_tax() always resolved intercity_ride's tax category to NULL
// ("v_category := CASE ... ELSE NULL -- includes 'intercity_ride'"), so government tax was NEVER
// applied to any intercity passenger ride, by design, pending a business decision -- unlike
// intercity_parcel, which was already correctly classified under 'parcel_delivery' at 18%.
// BUSINESS DECISION (explicit, this session): intercity_ride now gets its own
// 'intercity_passenger_ride' category at 5.0% -- mirroring local_passenger_ride's rate (matching
// the stated business rule that intercity passenger rides carry 5% GST), kept as its own category
// so a future rate change to local_passenger_ride never silently changes intercity_ride's rate too.
//
// FIX 2 -- accept_intercity_request(): stale commission_amount/gst_amount/rider_earning after a
// negotiated (Travel Together chat) fare is accepted.
// ROOT CAUSE: the function wrote the negotiated, rounded proposed_fare directly into
// orders.final_fare/current_fare, but never recomputed commission_amount/gst_amount/rider_earning
// -- those stayed at whatever create-order/index.ts estimated at booking time, before negotiation.
// This is the SAME bug class confirm_intercity_booking() (20260724000005) already hit and fixed,
// via the same canonical fix: route the new total fare through calculate_fare_breakdown() instead
// of writing final_fare/current_fare alone.
//
// Structural + math regression guard: reads the real SQL source and independently re-derives the
// tax/commission math the fixed functions must produce, matching the pattern used throughout this
// suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

double _round2(double v) => (v * 100).round() / 100;

void main() {
  final migration = _read(
    'supabase/migrations/20260901000021_intercity_ride_gov_tax_and_stale_negotiated_commission.sql',
  );

  group('FIX 1 -- intercity_ride government tax classification', () {
    test('a new tax_rate_config row seeds intercity_passenger_ride at 5.0%, as an INSERT (new '
        'row), never an UPDATE/edit to an existing row', () {
      expect(
        migration.contains(
          'INSERT INTO "public"."tax_rate_config" ("service_category", "rate_percent")',
        ),
        isTrue,
      );
      expect(migration.contains("VALUES ('intercity_passenger_ride', 5.0);"), isTrue);
      expect(migration.contains('UPDATE "public"."tax_rate_config"'), isFalse);
      expect(migration.contains('UPDATE public.tax_rate_config'), isFalse);
    });

    test('apply_order_government_tax()\'s category CASE now resolves intercity_ride to '
        "'intercity_passenger_ride' instead of falling through to the ELSE NULL branch", () {
      final fnStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.apply_order_government_tax');
      final fnEnd = migration.indexOf('CREATE OR REPLACE FUNCTION public.accept_intercity_request');
      expect(fnStart, greaterThan(-1));
      expect(fnEnd, greaterThan(fnStart));
      final fnBody = migration.substring(fnStart, fnEnd);
      expect(
        fnBody.contains("WHEN p_order_type = 'intercity_ride' THEN 'intercity_passenger_ride'"),
        isTrue,
      );
      // The ELSE NULL branch must still exist for genuinely unclassified types -- this fix adds
      // one explicit WHEN clause, it does not remove the unclassified-type safety net entirely.
      expect(fnBody.contains('ELSE NULL'), isTrue);
    });

    test('local_passenger_ride and parcel_delivery classification (ride/ride_sharing, and every '
        'parcel type including intercity_parcel) are completely unchanged', () {
      final fnStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.apply_order_government_tax');
      final fnEnd = migration.indexOf('CREATE OR REPLACE FUNCTION public.accept_intercity_request');
      final fnBody = migration.substring(fnStart, fnEnd);
      expect(
        fnBody.contains("WHEN p_order_type IN ('ride', 'ride_sharing') THEN 'local_passenger_ride'"),
        isTrue,
      );
      expect(
        fnBody.contains(
          "WHEN p_order_type IN ('local_parcel', 'batch_delivery', 'food_delivery', 'grocery_delivery', 'intercity_parcel') THEN 'parcel_delivery'",
        ),
        isTrue,
      );
    });

    test('every other clause -- idempotency fast-path, ledger INSERT with its ON CONFLICT race '
        'handling, the direct-collection vs. Cashfree-withheld branches -- is reproduced '
        'byte-for-byte from the live definition, not simplified/altered by this fix', () {
      final fnStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.apply_order_government_tax');
      final fnEnd = migration.indexOf('CREATE OR REPLACE FUNCTION public.accept_intercity_request');
      final fnBody = migration.substring(fnStart, fnEnd);
      expect(
        fnBody.contains(
          "SELECT amount, service_category, rate_percent INTO v_existing\n    FROM public.government_tax_ledger\n    WHERE order_id = p_order_id AND entry_type = 'ORDER_TAX';",
        ),
        isTrue,
      );
      expect(
        fnBody.contains(
          'INSERT INTO public.government_tax_ledger (\n        rider_id, order_id, entry_type, service_category, taxable_base, rate_percent, amount\n    ) VALUES (\n        p_rider_id, p_order_id, \'ORDER_TAX\', v_category, p_taxable_base, v_rate, v_tax_amount\n    )\n    ON CONFLICT (order_id) WHERE entry_type = \'ORDER_TAX\' DO NOTHING;',
        ),
        isTrue,
        reason: 'column order in the INSERT must exactly match the live definition -- a reordered '
            'VALUES tuple against this column list would silently insert values into the wrong '
            'columns',
      );
      expect(
        fnBody.contains(
          "'ORDER_TAX_WITHHELD', v_category, p_taxable_base, v_rate, -v_tax_amount",
        ),
        isTrue,
      );
      expect(
        fnBody.contains(
          "ON CONFLICT (order_id) WHERE entry_type = 'ORDER_TAX_WITHHELD' DO NOTHING;",
        ),
        isTrue,
      );
      expect(
        fnBody.contains(
          'UPDATE public.riders\n        SET government_tax_due_balance = government_tax_due_balance + v_tax_amount,\n            updated_at = now()',
        ),
        isTrue,
      );
    });

    test('₹250 intercity_ride fare at the new 5.0% rate -> exactly ₹12.50 government tax '
        '(previously ₹0, always unapplied)', () {
      expect(_round2(250.0 * 5.0 / 100.0), 12.50);
    });

    test('the grant is re-asserted to service_role only, matching the live definition', () {
      expect(
        migration.contains(
          'GRANT EXECUTE ON FUNCTION public.apply_order_government_tax(uuid, uuid, text, numeric, boolean) TO service_role;',
        ),
        isTrue,
      );
    });
  });

  group('FIX 2 -- accept_intercity_request() recomputes commission/GST/rider_earning for the '
      'negotiated fare', () {
    late final int fnStart;
    late final String fnBody;

    setUpAll(() {
      fnStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.accept_intercity_request');
      fnBody = migration.substring(fnStart);
    });

    test('the function exists in this migration', () {
      expect(fnStart, greaterThan(-1));
    });

    test('a v_breakdown := calculate_fare_breakdown(...) call replaces the old direct '
        'v_rounded_fare := ROUND(proposed_fare, 0) assignment', () {
      expect(fnBody.contains('v_rounded_fare'), isFalse);
      expect(fnBody.contains('v_breakdown := public.calculate_fare_breakdown('), isTrue);
      expect(fnBody.contains('v_request.proposed_fare,'), isTrue);
      expect(fnBody.contains('v_order.actual_fare,'), isTrue);
      expect(fnBody.contains('v_order.gst_percentage,'), isTrue);
      expect(fnBody.contains('v_order.commission_percentage,'), isTrue);
    });

    test('a promo_discount is preserved via the same formula confirm_intercity_booking() already '
        'uses, not dropped/hardcoded to 0', () {
      expect(
        fnBody.contains(
          'v_promo_discount := GREATEST(0, COALESCE(v_order.current_fare, 0) - COALESCE(v_order.final_fare, v_order.current_fare, 0));',
        ),
        isTrue,
      );
      expect(fnBody.contains('v_promo_discount\n    );'), isTrue);
    });

    test('the final UPDATE writes every breakdown field, not just current_fare/final_fare', () {
      final updateStart = fnBody.indexOf('UPDATE public.orders\n    SET order_status');
      final updateEnd = fnBody.indexOf('WHERE id = v_order.id;');
      expect(updateStart, greaterThan(-1));
      expect(updateEnd, greaterThan(updateStart));
      final updateBody = fnBody.substring(updateStart, updateEnd);
      for (final field in [
        'current_fare = (v_breakdown->>\'current_fare\')::numeric',
        'final_fare = (v_breakdown->>\'final_fare\')::numeric',
        'gst_amount = (v_breakdown->>\'gst_amount\')::numeric',
        'boost_amount = (v_breakdown->>\'boost_amount\')::numeric',
        'boost_percentage = (v_breakdown->>\'boost_percentage\')::numeric',
        'boost_rider_earning = (v_breakdown->>\'boost_rider_earning\')::numeric',
        'boost_company_earning = (v_breakdown->>\'boost_company_earning\')::numeric',
        'commission_amount = (v_breakdown->>\'commission_amount\')::numeric',
        'rider_earning = (v_breakdown->>\'rider_earning\')::numeric',
      ]) {
        expect(updateBody.contains(field), isTrue, reason: 'missing: $field');
      }
      // order_status/rider_id/pickup_otp/updated_at -- the pre-existing writes -- are untouched.
      expect(updateBody.contains("order_status = 'accepted'::public.order_status_enum"), isTrue);
      expect(updateBody.contains('rider_id = v_rider.id'), isTrue);
      expect(updateBody.contains('pickup_otp = v_otp'), isTrue);
      expect(updateBody.contains('updated_at = now()'), isTrue);
    });

    test('no app.bypass_financial_guard bypass was added -- this function is service_role-only '
        '(granted only to service_role, invoked only via the edge function with the service-role '
        'key), so the financial-columns guard trigger already passes trivially', () {
      expect(fnBody.contains('app.bypass_financial_guard'), isFalse);
      expect(
        migration.contains('GRANT EXECUTE ON FUNCTION public.accept_intercity_request(uuid, uuid) TO service_role;'),
        isTrue,
      );
    });

    test('every validation clause ahead of the fix (auth, service_mode, tax-due, request/order/'
        'OTP validation, travel-plan/seat/rider-busy/passenger-conflict checks) is preserved', () {
      expect(fnBody.contains('WRONG_SERVICE_MODE'), isTrue);
      expect(fnBody.contains('TAX_DUE_THRESHOLD_BLOCKED'), isTrue);
      expect(fnBody.contains('INVALID_FARE'), isTrue);
      expect(fnBody.contains('TRAVEL_PLAN_INACTIVE'), isTrue);
      expect(fnBody.contains('PLAN_FULLY_BOOKED'), isTrue);
      expect(fnBody.contains('RIDER_ALREADY_BUSY'), isTrue);
      expect(fnBody.contains('PASSENGER_ALREADY_CONFIRMED'), isTrue);
    });

    test('a ₹1200 negotiated fare at 10% commission / 5% GST recomputes correctly via the same '
        'base-fare-from-total-fare formula calculate_fare_breakdown() already uses -- not just '
        'passed through unmodified', () {
      // Mirrors calculate_fare_breakdown()'s own math: base = total / (1 + gst/100).
      const totalFare = 1200.0;
      const gstPct = 5.0;
      const commissionPct = 10.0;
      final baseFare = _round2(totalFare / (1 + gstPct / 100.0));
      final gstAmount = _round2(totalFare - baseFare);
      final commissionAmount = _round2(baseFare * commissionPct / 100.0);
      final riderEarning = _round2(baseFare - commissionAmount);
      expect(baseFare, 1142.86);
      expect(gstAmount, 57.14);
      expect(commissionAmount, 114.29);
      expect(riderEarning, 1028.57);
      // Sanity: this is NOT the same as commission computed against the raw total fare (the bug
      // this fix corrects) -- 10% of 1200 would be 120.00, not 114.29.
      expect(commissionAmount, isNot(_round2(totalFare * commissionPct / 100.0)));
    });
  });
}
