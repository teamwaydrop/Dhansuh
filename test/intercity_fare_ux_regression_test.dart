// Regression guard for the passenger-facing "Intercity Fare UX" requirement: the booking screen's
// PRIMARY number must be the final GST-inclusive estimated payable amount, with a clear positive
// "Inclusive of GST" indicator -- never a second, competing total, and GST must never read as a
// charge added later. The completed-trip screen must show a reconciled Fare-before-GST / GST /
// Total breakdown, using "Total Paid" only once payment is actually confirmed. All figures must
// come from the authoritative backend pricing response (calculate-order-pricing /
// FareBreakdown.fromOrder) -- never a client-side GST calculation.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final bookingScreen = _read('lib/features/intercity/rides/booking/intercity_ride_booking_screen.dart');
  final completedScreen = _read('lib/shared/screens/completed_order_details_screen.dart');
  final flowModules = _read('lib/core/navigation/flow_modules.dart');
  final activeOrderScreen = _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');
  final pricingController = _read('lib/modules/payments/controllers/pricing_controller.dart');

  group('Test 1 & 2: booking screen primary fare includes GST, with "Inclusive of GST" shown', () {
    test('the primary ESTIMATED FARE amount is pricingController.getFinalFare (GST-inclusive, server-computed)', () {
      // UPDATED (2026-09-01 whole-rupee fare rounding fix): calculate-order-pricing now rounds
      // final_fare to a whole rupee at the source, so this primary display was switched from
      // .toStringAsFixed(2) to .toStringAsFixed(0) -- no information loss (paise is always zero),
      // and no customer-visible "₹52.22 during booking" figure that a later payment/settlement
      // step could disagree with.
      expect(bookingScreen.contains("'₹\${estimatedFare.toStringAsFixed(0)}'"), isTrue);
      expect(bookingScreen.contains("double get estimatedFare => pricingController.getFinalFare('cab')"), isTrue);
    });

    test('"Inclusive of GST" is shown directly under the primary amount using the positive accent color', () {
      expect(bookingScreen.contains("'Inclusive of GST'"), isTrue);
      expect(bookingScreen.contains('Icons.check_circle_rounded'), isTrue);
      // The app's existing positive/green accent (0xFF10B981), not a warning/neutral color.
      expect(bookingScreen.contains("Color(0xFF10B981)"), isTrue);
    });
  });

  group('Test 3: booking screen never presents two conflicting totals on the primary view', () {
    test('the main ESTIMATED FARE row renders exactly one currency amount, not a second competing total', () {
      final start = bookingScreen.indexOf("'ESTIMATED FARE'");
      expect(start, greaterThan(-1));
      final section = bookingScreen.substring(start, start + 3200);
      // estimatedFare (the one primary total) appears; estimatedBaseFare/estimatedGstAmount (the
      // secondary breakdown numbers) must NOT appear on this primary view -- they only ever show
      // inside the secondary "Confirm Travel Request" fare breakdown sheet.
      expect(section.contains('estimatedFare'), isTrue);
      expect(section.contains('estimatedBaseFare'), isFalse);
    });
  });

  group('Secondary fare-details sheet uses consistent terminology and never hides GST as a later charge', () {
    test('the expandable breakdown labels the pre-tax amount "Fare before GST", not a bare "Total"', () {
      expect(bookingScreen.contains("'Fare before GST'"), isTrue);
    });

    test('the breakdown total is "Estimated Total" (still an estimate) with its own Inclusive-of-GST note', () {
      expect(bookingScreen.contains("'Estimated Total'"), isTrue);
    });

    test('GST rate/amount comes from the authoritative pricing_config response, never a hardcoded percentage', () {
      expect(pricingController.contains("pricing['gst_percentage']"), isTrue);
      expect(pricingController.contains("getVehiclePricing(vehicle)?['gst_amount']"), isTrue);
      // No Flutter-side GST rate constant/hardcode in the booking screen itself.
      expect(bookingScreen.contains('* 0.05'), isFalse);
      expect(bookingScreen.contains('* 1.05'), isFalse);
    });
  });

  group('Test 4 & 5: completed passenger screen reconciles fare + GST = total, and never says "Paid" early', () {
    test('completed_order_details_screen.dart shows a FARE DETAILS breakdown built from FareBreakdown.fromOrder', () {
      expect(completedScreen.contains("'FARE DETAILS'"), isTrue);
      expect(completedScreen.contains('FareBreakdown.fromOrder(order)'), isTrue);
      expect(completedScreen.contains("'Fare before GST'"), isTrue);
    });

    test('"Total Paid" is used only when payment_status is actually paid; otherwise "Total Fare"', () {
      expect(completedScreen.contains("isPaymentConfirmed = paymentStatus == 'paid'"), isTrue);
      expect(completedScreen.contains("isPaymentConfirmed ? 'Total Paid' : 'Total Fare'"), isTrue);
    });

    test('ParcelFlowModule (transient completion sheet) never labels an unsettled online payment as "Total Paid"', () {
      final start = flowModules.indexOf('class ParcelFlowModule');
      final end = flowModules.indexOf('class IntercityFlowModule');
      final parcelSrc = flowModules.substring(start, end);
      expect(parcelSrc.contains("isSettled ? 'Total Paid' : 'Amount Due'"), isTrue);
    });
  });

  group('Test 6: partner/traveller earnings remain conceptually separate from the customer total', () {
    // UPDATED (rider-facing commission/tax transparency fix): "CUSTOMER PAYMENT" was renamed to
    // "RIDE FARE" and the top-line label became isDirectSettlement-aware ("Ride Fare" for cash/
    // personal-UPI rides that have no real WayDrop-collected figure, "Customer Paid" only for a
    // genuine gateway settlement) -- see the comment at that row in rider_active_order_screen.dart.
    //
    // UPDATED AGAIN (2026-08-20 real-device report, ROUND 3): the VALUE shown was found to be
    // wrong too -- a ₹51.49 fare (correctly shown pre-completion) became ₹49.04 on the completed
    // screen, because the direct-settlement branch used `baseFare` (breakdown.fareBeforeGst,
    // which nets "Platform GST" out of the total) instead of the plain `fare` local
    // (breakdown.customerPaid). Both branches now read the same `fare` value -- only the LABEL
    // still depends on settlement type. "Your Trip Earnings" was ALSO wrong for the same reason
    // (and separately never subtracted commission at all): it is now completionNetEarnings =
    // riderEarning + breakdown.gstAmount - governmentTax, algebraically equal to
    // customerPaid - commission - governmentTax. See fare_presentation_regression_test.dart for
    // an executable worked-example proof against the exact reported numbers.
    test('the Drop Partner completion screen has a distinct RIDE FARE section and a distinct DEDUCTIONS section', () {
      expect(activeOrderScreen.contains("'RIDE FARE'"), isTrue);
      expect(activeOrderScreen.contains("'DEDUCTIONS'"), isTrue);
      expect(activeOrderScreen.contains("'YOUR TRIP EARNINGS'"), isTrue);
    });

    test('the top summary row is isDirectSettlement-aware in its LABEL only -- "Customer Paid" for '
        'a real gateway settlement, "Ride Fare" for cash/personal-UPI -- but both read the SAME '
        '`fare` (breakdown.customerPaid) value, never the Platform-GST-netted `baseFare`; and the '
        'hero "YOUR TRIP EARNINGS" figure is never the raw riderEarning identity that caused the '
        'original bug', () {
      expect(activeOrderScreen.contains("isDirectSettlement ? 'Ride Fare' : 'Customer Paid'"), isTrue);
      expect(activeOrderScreen.contains("'₹\${fare.toStringAsFixed(2)}'"), isTrue);
      // The old, buggy per-branch value expression and the `baseFare` variable itself must both
      // be gone -- not merely superseded alongside a correct replacement.
      expect(activeOrderScreen.contains('isDirectSettlement ? baseFare : fare'), isFalse);
      expect(activeOrderScreen.contains('baseFare'), isFalse);
      // riderEarning.toStringAsFixed no longer appears anywhere -- the hero figure reads the
      // tax-adjusted completionNetEarnings instead (see Test 8 below for the shared fetch itself).
      expect(activeOrderScreen.contains("'₹\${riderEarning.toStringAsFixed(2)}'"), isFalse);
      expect(activeOrderScreen.contains("'₹\${completionNetEarnings.toStringAsFixed(2)}'"), isTrue);
    });
  });

  group('Test 7: Local and Intercity terminology is consistent', () {
    // UPDATED: "Fare before GST" was replaced with the neutral "Ride Fare" label (never claims a
    // customer-facing pre-GST breakdown that doesn't exist for direct-collection rides), and a
    // Government Tax row (read from government_tax_ledger, distinct from WayDrop Commission) was
    // added to the DEDUCTIONS section.
    test('"Ride Fare" / "WayDrop Commission" / "Government Tax" / "Your Trip Earnings" are shared '
        'across the one completion screen both Local and Intercity orders render through', () {
      // rider_active_order_screen.dart's buildCompletionScreen is reached for order_type in
      // {ride, local_parcel, intercity_ride, intercity_parcel} alike (see _isIntercityOrder) --
      // one shared implementation, not two conflicting ones.
      expect(activeOrderScreen.contains("bool get _isIntercityOrder"), isTrue);
      expect(activeOrderScreen.contains("_buildStatRow('Ride Fare', '₹\${fare.toStringAsFixed(2)}')"), isTrue);
      expect(activeOrderScreen.contains("'WayDrop Commission'"), isTrue);
      expect(activeOrderScreen.contains("from('government_tax_ledger')"), isTrue);
    });

    test('the ambiguous "Total Ride Fare" label (which excluded GST but read like a grand total) is gone', () {
      expect(activeOrderScreen.contains('Total Ride Fare'), isFalse);
      expect(completedScreen.contains('Total Ride Fare'), isFalse);
    });
  });

  group('Test 8: Government Tax is never confused with WayDrop Commission on the rider completion screen', () {
    // UPDATED (Issues 1-4 fix round): the government_tax_ledger fetch moved from an inline
    // FutureBuilder (keyed on order!['id'].toString()) to a single State-level method,
    // _loadCompletionGovernmentTax(orderId), fetched once per order so the hero card and the
    // DEDUCTIONS row can never disagree -- see rider_earnings_and_dispatch_fixes_regression_test
    // .dart for the fuller test of this restructuring.
    test('Government Tax is read live from government_tax_ledger for this exact order, never a '
        'hard-coded amount/percentage', () {
      expect(activeOrderScreen.contains('Future<void> _loadCompletionGovernmentTax(String orderId) async'), isTrue);
      final anchor = activeOrderScreen.indexOf("from('government_tax_ledger')");
      expect(anchor, greaterThan(-1));
      final nearby = activeOrderScreen.substring(anchor, anchor + 500);
      expect(nearby.contains("eq('order_id', orderId)"), isTrue);
      expect(nearby.contains("eq('entry_type', 'ORDER_TAX')"), isTrue);
    });

    test('a disclosure states government tax applies regardless of subscription/free-trial status', () {
      expect(
        activeOrderScreen.contains(
          'Government tax is separate from company commission and applies ',
        ),
        isTrue,
      );
    });

    // UPDATED (Issue 3 -- remove Platform GST from partner-facing UI): "Platform GST" is no
    // longer shown as its own row at all on this screen, not even gated behind a > 0 check -- two
    // GST-looking numbers (Platform GST and Government Tax) for one order was the reported
    // confusion.
    //
    // UPDATED AGAIN (ROUND 3): breakdown.gstAmount is now legitimately READ (not displayed) as an
    // input to the YOUR TRIP EARNINGS formula (added back to riderEarning to recover the true
    // total-fare basis before subtracting government tax) -- gst_percentage, which only ever fed
    // the removed "Platform GST (X%)" label, is still never referenced at all.
    test('Platform GST (orders.gst_amount) is never shown as its own row on this screen, though '
        'gstAmount itself is now a legitimate input to the YOUR TRIP EARNINGS formula', () {
      expect(activeOrderScreen.contains('gstPercentage'), isFalse);
      expect(activeOrderScreen.contains("'Platform GST"), isFalse);
    });
  });
}
