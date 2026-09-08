// Structural regression guard for the whole-rupee fare rounding fix (2026-09-01).
//
// BUG REPORT: the app sometimes computed a fare with paise (e.g. ₹52.22). The customer saw this
// decimal amount during booking, but a DIFFERENT, inconsistently-rounded figure could end up
// authoritative by payment/completion time -- a mismatch between what the customer was shown,
// what they were charged, the partner's "Ride Fare", and government-tax/commission derived from
// it.
//
// ROOT CAUSE (traced end to end -- see the full trace in
// supabase/migrations/20260901000018_whole_rupee_fare_rounding.sql's header comment):
// calculate-order-pricing/pricing-calculations.ts's buildPricingResponse() computed
// finalFare = fareAfterDiscount + gstAmount as a decimal and never rounded it. create-order/
// index.ts copies that decimal straight into orders.current_fare (and, with a promo, into
// orders.final_fare) -- the SINGLE authoritative "customer payable fare" column every other
// system reads (create-payment's Cashfree amount, FareBreakdown.customerPaid on every rider
// screen, calculate_fare_breakdown()'s commission/Platform-GST/rider_earning re-derivation at
// accept-order/boost/completion, and apply_order_government_tax()'s taxable_base).
//
// FIX: round the customer-payable total to the nearest whole rupee at the two places a NEW
// authoritative total is ever produced -- pricing-calculations.ts (the initial booking-time
// estimate, Deno/TS) and calculate_fare_breakdown() + accept_intercity_request() (every post-
// booking fare change, Postgres SQL) -- so every downstream reader inherits an already-whole
// value without re-rounding anywhere else. GST rate, commission rate, government-tax formula, and
// free-trial 0% commission logic are all UNCHANGED -- see pricing-calculations.test.ts (Deno) for
// an executable proof of the TypeScript half of this fix.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final pricingCalc = _read('supabase/functions/calculate-order-pricing/pricing-calculations.ts');
  final createOrder = _read('supabase/functions/create-order/index.ts');
  final createPayment = _read('supabase/functions/create-payment/index.ts');
  final boostOrderFare = _read('supabase/functions/boost-order-fare/index.ts');
  final fareRoundingMigration =
      _read('supabase/migrations/20260901000018_whole_rupee_fare_rounding.sql');
  final govTaxFunctions = _read('supabase/migrations/20260726000004_government_tax_due_functions.sql');
  final fareBreakdownHelper = _read('lib/shared/helpers/fare_presentation_helper.dart');

  group('1-4. roundToWholeRupee() exists and buildPricingResponse() uses it for the customer-payable total', () {
    test('a dedicated, documented whole-rupee rounding helper exists in the pricing engine', () {
      expect(pricingCalc.contains('export function roundToWholeRupee(amount: number): number'), isTrue);
      expect(pricingCalc.contains('Math.round(amount)'), isTrue);
    });

    test('buildPricingResponse() rounds finalFare via roundToWholeRupee -- the customer-payable '
        'total is never a raw, unrounded fareAfterDiscount + gstAmount sum', () {
      final anchor = pricingCalc.indexOf('const finalFare = roundToWholeRupee(rawFinalFare);');
      expect(anchor, greaterThan(-1));
      // gstAmount absorbs the rounding remainder so base + gst reconciles exactly with the
      // rounded total -- commissionAmount/riderEarning are computed BEFORE this point, off the
      // true (unrounded) fareAfterDiscount, so rounding never touches them.
      final nearby = pricingCalc.substring(anchor, (anchor + 200).clamp(0, pricingCalc.length));
      expect(nearby.contains('const gstAmount = finalFare - fareAfterDiscount;'), isTrue);
      final commissionIdx = pricingCalc.indexOf('const commissionAmount = fareAfterDiscount * (commissionPercent / 100);');
      expect(commissionIdx, greaterThan(-1));
      expect(commissionIdx, lessThan(anchor));
    });

    test('the response field final_fare is built from the rounded finalFare, never the raw sum', () {
      expect(pricingCalc.contains('final_fare: format2(finalFare)'), isTrue);
      expect(pricingCalc.contains('final_fare: format2(rawFinalFare)'), isFalse);
      expect(pricingCalc.contains('final_fare: format2(fareAfterDiscount + gstAmount)'), isFalse);
    });
  });

  group('5. create-order.ts: customer displayed fare == order authoritative fare', () {
    test('current_fare is copied verbatim from pricing.final_fare (calculate-order-pricing\'s '
        'already-rounded output) -- never independently recomputed or re-rounded here', () {
      final anchor = createOrder.indexOf('const currentFare =');
      expect(anchor, greaterThan(-1));
      final nearby = createOrder.substring(anchor, (anchor + 60).clamp(0, createOrder.length));
      expect(nearby.contains("Number(\n        pricing.final_fare"), isTrue);
    });

    test('the promo-discount branch rounds the post-discount final_fare to a whole rupee '
        '(Math.round), never a 2-decimal .toFixed(2) that could reintroduce paise', () {
      final anchor = createOrder.indexOf('finalFare = Math.round(currentFare - appliedDiscount);');
      expect(anchor, greaterThan(-1));
      expect(createOrder.contains('finalFare = Number((currentFare - appliedDiscount).toFixed(2));'), isFalse);
    });
  });

  group('6. create-payment.ts: customer displayed fare == payment amount sent to Cashfree', () {
    test('the Cashfree order_amount is read directly from orders.final_fare/current_fare -- the '
        'exact same authoritative column the booking screen and completion screen read, never a '
        'separately-rounded or re-derived figure', () {
      final anchor = createPayment.indexOf('finalAmount = Number(orderRow.final_fare ?? orderRow.current_fare ?? 0);');
      expect(anchor, greaterThan(-1));
      expect(createPayment.contains('order_amount: finalAmount'), isTrue);
      // No independent rounding/truncation of the order fare inside create-payment -- fixing the
      // amount here-only (formatting it for display without changing the stored value) is exactly
      // what the bug report explicitly warned against.
      expect(createPayment.contains('Math.round(finalAmount)'), isFalse);
      expect(createPayment.contains('finalAmount.toFixed(0)'), isFalse);
    });
  });

  group('7. Postgres side: calculate_fare_breakdown() and accept_intercity_request() round the '
      'total to a whole rupee, with GST/commission formulas otherwise byte-for-byte unchanged', () {
    test('calculate_fare_breakdown() rounds p_new_total_fare to a whole rupee as its first step', () {
      final anchor = fareRoundingMigration.indexOf('v_new_total_fare := ROUND(COALESCE(p_new_total_fare, 0), 0);');
      expect(anchor, greaterThan(-1));
      // Must happen before base_fare/gst/commission/rider_earning are derived from it.
      final baseFareIdx = fareRoundingMigration.indexOf('v_base_fare := ROUND(v_new_total_fare /', anchor);
      expect(baseFareIdx, greaterThan(anchor));
    });

    test('the GST-inclusive base-fare derivation, commission calculation, and rider-earning '
        'calculation formulas are unchanged in shape -- only their input is now pre-rounded', () {
      expect(
        fareRoundingMigration.contains(
          'v_base_fare := ROUND(v_new_total_fare / (1 + (COALESCE(p_gst_percentage, 5.0) / 100.0)), 2);',
        ),
        isTrue,
      );
      expect(
        fareRoundingMigration.contains(
          'v_commission_amount := ROUND(v_base_fare * (COALESCE(p_commission_percentage, 0) / 100.0), 2);',
        ),
        isTrue,
      );
      expect(
        fareRoundingMigration.contains('v_rider_earning := ROUND(v_base_fare - v_commission_amount, 2);'),
        isTrue,
      );
    });

    test('v_final_fare (the promo-adjusted payable amount) is rounded to a whole rupee (0 decimal '
        'places), not 2 -- it too must never carry paise', () {
      expect(
        fareRoundingMigration.contains(
          "v_final_fare := GREATEST(0, ROUND(v_new_total_fare - COALESCE(p_promo_discount, 0), 0));",
        ),
        isTrue,
      );
    });

    test('current_fare in the returned breakdown is the ROUNDED total, not the raw input', () {
      final anchor = fareRoundingMigration.indexOf("'current_fare', v_new_total_fare,");
      expect(anchor, greaterThan(-1));
      expect(fareRoundingMigration.contains("'current_fare', p_new_total_fare,"), isFalse);
    });

    test('accept_intercity_request() rounds the negotiated proposed_fare to a whole rupee before '
        'it ever becomes orders.final_fare/current_fare -- the one remaining path that bypassed '
        'calculate_fare_breakdown() entirely', () {
      final anchor = fareRoundingMigration.indexOf('v_rounded_fare := ROUND(v_request.proposed_fare, 0);');
      expect(anchor, greaterThan(-1));
      final updateIdx = fareRoundingMigration.indexOf('final_fare = v_rounded_fare,', anchor);
      expect(updateIdx, greaterThan(anchor));
      expect(fareRoundingMigration.contains('current_fare = v_rounded_fare,'), isTrue);
      // The raw, unrounded proposed_fare must no longer be written directly.
      expect(fareRoundingMigration.contains('final_fare = v_request.proposed_fare,'), isFalse);
    });

    test('boost-order-fare.ts still delegates entirely to calculate_fare_breakdown via RPC -- it '
        'never rounds the fare itself, so it automatically inherits the whole-rupee guarantee', () {
      expect(boostOrderFare.contains('supabase.rpc("calculate_fare_breakdown"'), isTrue);
      expect(boostOrderFare.contains('Math.round('), isFalse);
    });
  });

  group('8. No paise/decimal fare on the primary customer booking-screen fare displays', () {
    test('local ride, local parcel, and intercity ride/parcel primary per-vehicle fare chips '
        'render with .toStringAsFixed(0), matching the now-whole-rupee underlying value', () {
      final rideBooking = _read('lib/features/local_rides/booking/screens/ride_location_screen.dart');
      final parcelBooking = _read('lib/features/local_parcels/booking/screens/parcel_booking_screen.dart');
      final intercityRideBooking =
          _read('lib/features/intercity/rides/booking/intercity_ride_booking_screen.dart');
      final intercityParcelBooking =
          _read('lib/features/intercity/parcels/booking/intercity_booking_screen.dart');

      expect(rideBooking.contains('displayFare.toStringAsFixed(0)'), isTrue);
      expect(parcelBooking.contains('finalFare.toStringAsFixed(0)'), isTrue);
      expect(intercityRideBooking.contains(r"'₹${estimatedFare.toStringAsFixed(0)}'"), isTrue);
      expect(intercityParcelBooking.contains('displayFare.toStringAsFixed(0)'), isTrue);
    });
  });

  group('9. Government tax remains correctly calculated from the authoritative fare -- formula untouched', () {
    test('apply_order_government_tax() still uses its original, documented ROUND(taxable_base * '
        'rate/100, 2) formula -- this migration never touched the government-tax business logic '
        '(rate lookup, service-category classification, direct-collection due-balance handling)', () {
      expect(
        govTaxFunctions.contains('v_tax_amount := ROUND(p_taxable_base * v_rate / 100.0, 2);'),
        isTrue,
      );
      expect(
        govTaxFunctions.contains(
          'tax_amount is always\n-- ROUND(taxable_base * rate_percent / 100.0, 2)',
        ),
        isTrue,
      );
    });

    test('the whole-rupee rounding migration file itself never redefines '
        'apply_order_government_tax -- it only touches calculate_fare_breakdown and '
        'accept_intercity_request', () {
      expect(fareRoundingMigration.contains('CREATE OR REPLACE FUNCTION public.apply_order_government_tax'), isFalse);
      expect(fareRoundingMigration.contains('CREATE OR REPLACE FUNCTION public.calculate_fare_breakdown'), isTrue);
      expect(fareRoundingMigration.contains('CREATE OR REPLACE FUNCTION public.accept_intercity_request'), isTrue);
    });
  });

  group('10 & 11. Free-trial 0% commission and paid partner commission are both unchanged', () {
    test('calculate_fare_breakdown() still takes p_commission_percentage as a plain caller-'
        'supplied rate -- it never decides free-trial eligibility itself, so the 0%-during-'
        'active-subscription rule (decided by callers like complete_order_and_settle reading '
        'subscription_active/subscription_expires_at) is untouched by this migration', () {
      expect(
        fareRoundingMigration.contains(
          'p_new_total_fare numeric,\n    p_actual_fare numeric,\n    p_gst_percentage numeric,\n    p_commission_percentage numeric,',
        ),
        isTrue,
      );
    });

    test('the commission-rate-to-amount arithmetic is the exact same single-line formula as '
        'before this migration (only its input, v_base_fare, is now derived from a pre-rounded '
        'total) -- commissionPercent itself is read, never computed here', () {
      expect(
        fareRoundingMigration.contains('COALESCE(p_commission_percentage, 0) / 100.0'),
        isTrue,
      );
    });

    test('the Flutter-side subscription-commission-waiver read is the same pre-existing field '
        'this feature has always used -- no new/duplicate waiver state introduced by this fix', () {
      expect(fareBreakdownHelper.contains("order['subscription_commission_waived'] == true"), isTrue);
    });
  });

  group('12. Cash and online payment use the same final rounded fare -- no separate cash-only fare path', () {
    test('the cash-collection sheet is invoked with the same `fare` local used everywhere else on '
        'the active-order screen -- there is no independently-computed cash amount', () {
      final activeOrderScreen =
          _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');
      expect(activeOrderScreen.contains('showCashCollectionSheet(fare, targetStatus: targetStatus)'), isTrue);
    });

    test('FareBreakdown.customerPaid (read by every completed-ride/order-history/earnings screen, '
        'regardless of collection method) is still exactly final_fare ?? current_fare -- the same '
        'single authoritative column this whole fix makes whole-rupee, never a payment-method-'
        'specific derivation', () {
      expect(
        fareBreakdownHelper.contains(
          "order['final_fare']?.toString() ?? order['current_fare']?.toString() ?? '0'",
        ),
        isTrue,
      );
    });
  });
}
