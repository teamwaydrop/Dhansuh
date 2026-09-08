// Regression guard for the canonical financial-presentation helper (lib/shared/helpers/
// fare_presentation_helper.dart), which every Local + Intercity completion/history screen now
// shares (Drop Partner + passenger). Root cause fixed: several screens previously either
// mislabeled the pre-GST base fare as a competing "total" ("Total Ride Fare" / "User Paid"), or
// (rider_order_history_screen.dart / rider_activity_tab.dart) actively recomputed a GST/commission
// split client-side from the customer total whenever the legacy `base_fare` column was
// unset/stale -- inventing financial truth instead of reading the authoritative server columns
// that were already present (gst_amount, commission_amount, rider_earning). This file is pure
// Dart (no Flutter/Supabase dependency), so it is unit-tested directly rather than via source-
// string assertions.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/shared/helpers/fare_presentation_helper.dart';

void main() {
  group('FareBreakdown.fromOrder -- reconciliation (tests 9-13, 19)', () {
    test('local ride: fare before GST + GST reconciles exactly with Customer Paid', () {
      // Matches the local-ride example from the bug report: Customer Paid ₹21.00, Total Ride Fare
      // ₹20.00, GST (5%) ₹1.00, Commission (10%) -₹2.00, Earnings ₹18.00.
      final order = {
        'final_fare': null,
        'current_fare': '21.00',
        'gst_amount': '1.00',
        'gst_percentage': '5',
        'commission_amount': '2.00',
        'commission_percentage': '10',
        'rider_earning': '18.00',
        'subscription_commission_waived': false,
      };
      final b = FareBreakdown.fromOrder(order);
      expect(b.customerPaid, 21.00);
      expect(b.fareBeforeGst, closeTo(20.00, 0.001));
      expect(b.gstAmount, 1.00);
      // Customer Paid = Fare before GST + GST, exactly -- never two independently-invented numbers.
      expect(b.fareBeforeGst + b.gstAmount, closeTo(b.customerPaid, 0.001));
      expect(b.commissionAmount, 2.00);
      expect(b.partnerEarning, 18.00);
      // Fare-before-GST must never equal Customer Paid when GST > 0 (the exact mislabeling bug).
      expect(b.fareBeforeGst, isNot(equals(b.customerPaid)));
    });

    test('intercity ride: fare before GST + GST reconciles exactly with Customer Paid', () {
      // Matches the intercity example from the bug report: Customer Paid ₹984.27, Total Ride Fare
      // ₹937.40, GST (5%) ₹46.87, Commission (10%) -₹93.74, Earnings ₹843.66.
      final order = {
        'final_fare': '984.27',
        'current_fare': '984.27',
        'gst_amount': '46.87',
        'gst_percentage': '5',
        'commission_amount': '93.74',
        'commission_percentage': '10',
        'rider_earning': '843.66',
        'subscription_commission_waived': false,
      };
      final b = FareBreakdown.fromOrder(order);
      expect(b.customerPaid, 984.27);
      expect(b.fareBeforeGst, closeTo(937.40, 0.01));
      expect(b.fareBeforeGst + b.gstAmount, closeTo(b.customerPaid, 0.01));
      expect(b.commissionAmount, 93.74);
      expect(b.gstPercentage, 5);
      expect(b.commissionPercentage, 10);
      expect(b.partnerEarning, 843.66);
    });

    test('no double tax deduction: fareBeforeGst - commissionAmount reconciles with partnerEarning', () {
      final order = {
        'current_fare': '984.27',
        'gst_amount': '46.87',
        'commission_amount': '93.74',
        'rider_earning': '843.66',
      };
      final b = FareBreakdown.fromOrder(order);
      // Earnings = fare-before-GST minus commission, exactly once -- GST is never subtracted a
      // second time here (GST was already excluded when deriving fareBeforeGst from customerPaid).
      expect(b.fareBeforeGst - b.commissionAmount, closeTo(b.partnerEarning, 0.01));
    });

    test('subscription commission waiver displays ₹0 commission (test 15)', () {
      final order = {
        'current_fare': '100.00',
        'gst_amount': '5.00',
        'commission_amount': '0.00',
        'commission_percentage': '0',
        'rider_earning': '95.00',
        'subscription_commission_waived': true,
      };
      final b = FareBreakdown.fromOrder(order);
      expect(b.subscriptionCommissionWaived, isTrue);
      expect(b.commissionAmount, 0.00);
      expect(b.partnerEarning, 95.00);
    });

    test('never invents a value when authoritative columns are present -- no percentage recomputation', () {
      // A stale/mismatched pair of values proves the helper reads gst_amount/commission_amount
      // directly rather than recomputing them from customerPaid * percentage (the exact bug it
      // replaces) -- if it recomputed, fareBeforeGst would come out different from this.
      final order = {
        'current_fare': '200.00',
        'gst_amount': '3.33', // deliberately NOT 5% of any clean base, to prove no recomputation
        'gst_percentage': '5',
        'commission_amount': '19.63',
        'commission_percentage': '10',
        'rider_earning': '176.71',
      };
      final b = FareBreakdown.fromOrder(order);
      expect(b.gstAmount, 3.33);
      expect(b.fareBeforeGst, closeTo(196.67, 0.01)); // 200.00 - 3.33, not a 1/(1+5%) recompute
    });
  });

  group('Ride Fare must be the ORIGINAL total fare, never fareBeforeGst -- Your Trip Earnings = '
      'customerPaid - commission - governmentTax (2026-08-20 real-device report: ₹51.49 fare '
      'wrongly became ₹49.04 on the completed-ride screen)', () {
    test('worked example matching the reported bug exactly: ₹51.49 fare, ₹2.57 government tax, '
        '0% commission (free trial) -> Ride Fare stays ₹51.49, Your Trip Earnings is ₹48.92, '
        'never the buggy ₹49.04 (fareBeforeGst, which silently nets out Platform GST)', () {
      // calculate_fare_breakdown() (20260724000005_canonical_fare_breakdown_and_intercity_fix.sql)
      // derives base_fare = total_fare / (1 + gst%/100), then commission off base_fare -- so
      // orders.gst_amount ("Platform GST") is GST embedded INSIDE the total fare, not an
      // additional deduction on top of rider_earning. rider_earning (backend, authoritative) is
      // base_fare - commission, i.e. ALREADY net of Platform GST. Government Tax is a completely
      // separate, later deduction (government_tax_ledger), read live for this exact order --
      // never confused with Platform GST, never backend-recalculated here.
      final order = {
        'final_fare': '51.49',
        'current_fare': '51.49',
        'gst_amount': '2.45', // orders.gst_amount ("Platform GST"), embedded in the 51.49 total
        'gst_percentage': '5',
        'commission_amount': '0.00',
        'commission_percentage': '0',
        'rider_earning': '49.04', // base_fare (51.49-2.45=49.04) - 0% commission = 49.04
        'subscription_commission_waived': true,
      };
      final breakdown = FareBreakdown.fromOrder(order);
      const governmentTaxAmount = 2.57; // government_tax_ledger amount for this exact order

      // Ride Fare shown to the partner MUST be the original total, never fareBeforeGst.
      expect(breakdown.customerPaid, closeTo(51.49, 0.001));
      expect(breakdown.customerPaid, isNot(closeTo(49.04, 0.001)));
      // Government Tax remains its own, separately-sourced value (never derived from Platform GST
      // or from a hardcoded percentage) -- shown as a distinct DEDUCTIONS row.
      expect(governmentTaxAmount, isNot(equals(breakdown.gstAmount)));

      // Your Trip Earnings = customerPaid - commission - governmentTax. Derived here without
      // reconstructing commission logic in Flutter: riderEarning (already correctly net of
      // commission, including any subscription waiver) plus the Platform GST it had netted out,
      // minus governmentTax. Algebraically identical to customerPaid - commissionAmount -
      // governmentTax -- every term is an existing authoritative backend value.
      final yourTripEarnings = breakdown.partnerEarning + breakdown.gstAmount - governmentTaxAmount;
      expect(yourTripEarnings, closeTo(48.92, 0.001));
      expect(
        yourTripEarnings,
        closeTo(breakdown.customerPaid - breakdown.commissionAmount - governmentTaxAmount, 0.001),
      );
      // Must never equal the reported buggy figure.
      expect(yourTripEarnings, isNot(closeTo(49.04, 0.001)));
    });

    test('same formula holds for a NON-zero-commission ride, proving commission is still '
        'correctly subtracted (not silently dropped by reusing riderEarning)', () {
      final order = {
        'current_fare': '100.00',
        'gst_amount': '4.76', // ~5% GST embedded in 100.00 (base_fare ~95.24)
        'gst_percentage': '5',
        'commission_amount': '19.05', // 20% of base_fare (95.24)
        'commission_percentage': '20',
        'rider_earning': '76.19', // 95.24 - 19.05
        'subscription_commission_waived': false,
      };
      final breakdown = FareBreakdown.fromOrder(order);
      const governmentTaxAmount = 5.00;
      final yourTripEarnings = breakdown.partnerEarning + breakdown.gstAmount - governmentTaxAmount;
      expect(
        yourTripEarnings,
        closeTo(breakdown.customerPaid - breakdown.commissionAmount - governmentTaxAmount, 0.01),
      );
    });
  });

  group('PaymentMethodPresentation -- canonical labels (tests 16-18)', () {
    test('Personal QR / UPI', () {
      expect(PaymentMethodPresentation.labelFor(fareMethod: 'personal_upi'), 'Personal QR / UPI');
    });
    test('Cash', () {
      expect(PaymentMethodPresentation.labelFor(fareMethod: 'cash'), 'Cash');
    });
    test('Cashfree -- never mislabeled as direct UPI', () {
      final label = PaymentMethodPresentation.labelFor(fareMethod: 'cashfree');
      expect(label, 'Cashfree');
      expect(label.contains('UPI'), isFalse);
      expect(label.contains('Direct'), isFalse);
    });
    test('legacy payment_mode fallback still maps correctly when fare_payment_method is unset', () {
      expect(PaymentMethodPresentation.labelFor(paymentMode: 'cash'), 'Cash');
      expect(PaymentMethodPresentation.labelFor(paymentMode: 'upi'), 'Personal QR / UPI');
    });
  });

  group('No client-authoritative financial mutation (test 20)', () {
    final helperSrc = File('lib/shared/helpers/fare_presentation_helper.dart').readAsStringSync();
    test('the helper never writes to Supabase -- it is a pure presentation/derivation library', () {
      expect(helperSrc.contains('supabase'), isFalse);
      expect(helperSrc.contains('.update('), isFalse);
      expect(helperSrc.contains('.insert('), isFalse);
      expect(helperSrc.contains('.rpc('), isFalse);
    });
  });
}
