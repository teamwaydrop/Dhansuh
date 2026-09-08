// Regression guard for the rider-facing UI of the deployed PG-charge rule (migration
// 20260901000037, wallet formula updated by 20260901000038 -- Phase 12 Part A). The BACKEND
// already credits the final net; this test locks in that the four rider "YOUR TRIP EARNINGS"
// surfaces display that final net directly for an eligible ride and keep the old formula for
// every other order. GST is still shown (reporting-only), but as a SEPARATE line, never inside
// DEDUCTIONS and never subtracted from the credited amount.
//
// Eligible (all five): order_type='ride' + subscription_commission_waived=true (active Free
// Trial/WayDrop MAX at completion) + fare_payment_method='cashfree' + payment_status='paid' +
// pg_charge_amount > 0.
//
// Unlike the SQL guards, FareBreakdown is pure Dart -- so this test actually EXECUTES
// FareBreakdown.fromOrder for eligible / non-eligible order maps, plus structural checks on the
// four screens.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/shared/helpers/fare_presentation_helper.dart';

String _read(String p) => File(p).readAsStringSync();

Map<String, dynamic> _eligibleOrder(num fare) => {
      'order_type': 'ride',
      'current_fare': fare,
      'final_fare': fare,
      'gst_amount': (fare * 5 / 100 * 100).round() / 100,
      'gst_percentage': 5,
      'pg_charge_amount': (fare * 2 / 100 * 100).round() / 100,
      'commission_amount': 0,
      'commission_percentage': 0,
      // rider_earning = fare - PG charge ONLY (migration 20260901000038) -- GST is recorded
      // (gst_amount above) but no longer subtracted from the wallet-credited amount.
      'rider_earning': ((fare - (fare * 2 / 100 * 100).round() / 100) * 100).round() / 100,
      'subscription_commission_waived': true,
      'fare_payment_method': 'cashfree',
      'payment_status': 'paid',
    };

void main() {
  final helperSrc = _read('lib/shared/helpers/fare_presentation_helper.dart');
  final completionScreen = _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');
  final historyScreen = _read('lib/features/rider/orders/screens/rider_order_history_screen.dart');
  final activityTab = _read('lib/features/rider/activity/rider_activity_tab.dart');
  final earningsTab = _read('lib/features/rider/earnings/rider_earnings_tab.dart');
  final screens = {
    'rider_active_order_screen.dart': completionScreen,
    'rider_order_history_screen.dart': historyScreen,
    'rider_activity_tab.dart': activityTab,
    'rider_earnings_tab.dart': earningsTab,
  };

  group('1. FareBreakdown — exact math for an eligible PG ride (executed, not string-matched)', () {
    test('₹21 → GST ₹1.05 (recorded only), PG ₹0.42 (deducted), YOUR TRIP EARNINGS ₹20.58', () {
      final b = FareBreakdown.fromOrder(_eligibleOrder(21));
      expect(b.isPgChargeRide, isTrue);
      expect(b.gstAmount, 1.05);
      expect(b.pgChargeAmount, 0.42);
      expect(b.partnerEarning, 20.58); // = orders.rider_earning, the FINAL net (fare - PG only)
    });
    test('₹100 → GST ₹5.00 (recorded only), PG ₹2.00 (deducted), YOUR TRIP EARNINGS ₹98.00', () {
      final b = FareBreakdown.fromOrder(_eligibleOrder(100));
      expect(b.isPgChargeRide, isTrue);
      expect(b.gstAmount, 5.00);
      expect(b.pgChargeAmount, 2.00);
      expect(b.partnerEarning, 98.00);
    });
    test('₹200 → GST ₹10.00 (recorded only), PG ₹4.00 (deducted), YOUR TRIP EARNINGS ₹196.00', () {
      final b = FareBreakdown.fromOrder(_eligibleOrder(200));
      expect(b.isPgChargeRide, isTrue);
      expect(b.gstAmount, 10.00);
      expect(b.pgChargeAmount, 4.00);
      expect(b.partnerEarning, 196.00);
    });
  });

  group('2. isPgChargeRide requires ALL FIVE conditions (executed)', () {
    test('the reference eligible order is eligible', () {
      expect(FareBreakdown.fromOrder(_eligibleOrder(21)).isPgChargeRide, isTrue);
    });
    test('order_type != ride → not eligible', () {
      final o = _eligibleOrder(21)..['order_type'] = 'local_parcel';
      expect(FareBreakdown.fromOrder(o).isPgChargeRide, isFalse);
    });
    test('subscription_commission_waived false (no active Trial/MAX) → not eligible', () {
      final o = _eligibleOrder(21)..['subscription_commission_waived'] = false;
      expect(FareBreakdown.fromOrder(o).isPgChargeRide, isFalse);
    });
    test('fare_payment_method != cashfree (cash / direct) → not eligible', () {
      for (final m in ['cash', 'personal_upi', '']) {
        final o = _eligibleOrder(21)..['fare_payment_method'] = m;
        expect(FareBreakdown.fromOrder(o).isPgChargeRide, isFalse, reason: 'method=$m');
      }
    });
    test('payment_status != paid → not eligible', () {
      final o = _eligibleOrder(21)..['payment_status'] = 'pending';
      expect(FareBreakdown.fromOrder(o).isPgChargeRide, isFalse);
    });
    test('pg_charge_amount 0 / missing → not eligible', () {
      final o = _eligibleOrder(21)..['pg_charge_amount'] = 0;
      expect(FareBreakdown.fromOrder(o).isPgChargeRide, isFalse);
      final o2 = _eligibleOrder(21)..remove('pg_charge_amount');
      expect(FareBreakdown.fromOrder(o2).isPgChargeRide, isFalse);
    });
    test('a plain non-eligible order has isPgChargeRide=false and pgChargeAmount=0', () {
      final b = FareBreakdown.fromOrder({
        'current_fare': 100,
        'gst_amount': 4.76,
        'commission_amount': 15,
        'rider_earning': 80.24,
        'order_type': 'ride',
      });
      expect(b.isPgChargeRide, isFalse);
      expect(b.pgChargeAmount, 0);
    });
  });

  group('3. FareBreakdown exposes the authoritative PG column, never recomputed', () {
    test('helper reads orders.pg_charge_amount and exposes pgChargeAmount + isPgChargeRide', () {
      expect(helperSrc.contains('final double pgChargeAmount;'), isTrue);
      expect(helperSrc.contains("order['pg_charge_amount']"), isTrue);
      expect(helperSrc.contains('bool get isPgChargeRide =>'), isTrue);
      expect(helperSrc.contains("orderType == 'ride'"), isTrue);
      expect(helperSrc.contains("farePaymentMethod == 'cashfree'"), isTrue);
      expect(helperSrc.contains("paymentStatus == 'paid'"), isTrue);
      expect(helperSrc.contains('subscriptionCommissionWaived'), isTrue);
      expect(helperSrc.contains('pgChargeAmount > 0'), isTrue);
    });
  });

  group('4a. Eligible net = raw final earning (exact ternary per screen)', () {
    test('rider_active_order_screen.dart: completionNetEarnings = isPgChargeRide ? riderEarning : (old)', () {
      expect(
        completionScreen.contains(
          'final completionNetEarnings = breakdown.isPgChargeRide\n'
          '        ? riderEarning\n'
          '        : (_completionTaxLoading ? riderEarning : (riderEarning + breakdown.gstAmount - _completionGovTaxAmount));',
        ),
        isTrue,
      );
    });
    test('rider_earnings_tab.dart: netEarnings = isPgChargeRide ? riderEarning : (old)', () {
      expect(
        earningsTab.contains(
          'final netEarnings = breakdown.isPgChargeRide\n'
          '        ? riderEarning\n'
          '        : (_taxLoading ? riderEarning : (riderEarning + breakdown.gstAmount - govTaxAmount));',
        ),
        isTrue,
      );
    });
    for (final entry in {'rider_order_history_screen.dart': historyScreen, 'rider_activity_tab.dart': activityTab}.entries) {
      test('${entry.key}: netEarnings = isPgChargeRide ? partnerEarning : (old)', () {
        expect(
          entry.value.contains(
            'final netEarnings = breakdown.isPgChargeRide\n'
            '                            ? breakdown.partnerEarning\n'
            '                            : (taxLoading\n'
            '                                ? breakdown.partnerEarning\n'
            '                                : (breakdown.partnerEarning + breakdown.gstAmount - taxAmount));',
          ),
          isTrue,
        );
      });
    }
  });

  group('4. Each screen: DEDUCTIONS itemize PG only; GST shown separately, not deducted (Phase 12)', () {
    for (final entry in screens.entries) {
      final name = entry.key;
      final src = entry.value;
      test('$name: renders PG Charge (2%) from breakdown.pgChargeAmount', () {
        expect(src.contains("'PG Charge (2%)'"), isTrue, reason: '$name missing PG Charge (2%) row');
        expect(src.contains(r'breakdown.pgChargeAmount.toStringAsFixed(2)'), isTrue);
      });
      test('$name: PG charge is read from breakdown.pgChargeAmount, never recomputed as a local 2%', () {
        // the PG amount shown must be the authoritative column
        expect(src.contains(r"'PG Charge (2%)', '₹${breakdown.pgChargeAmount.toStringAsFixed(2)}'"), isTrue);
        // and there must be no local "× 0.02" / "× 2 / 100" PG recomputation
        expect(src.contains('* 0.02'), isFalse);
        expect(src.contains('* 2 / 100'), isFalse);
        expect(src.contains('* 2.0 / 100'), isFalse);
      });
      test('$name: renders GST (5%) as a separate, recorded-only line -- reads breakdown.gstAmount, never recomputed', () {
        expect(src.contains('GST (5%) -- recorded separately'), isTrue, reason: '$name missing the separate GST line');
        expect(src.contains(r'breakdown.gstAmount.toStringAsFixed(2)'), isTrue);
        expect(src.contains('* 5 / 100'), isFalse);
        expect(src.contains('* 5.0 / 100'), isFalse);
      });
      test('$name: the separate GST line appears AFTER "YOUR TRIP EARNINGS", never inside DEDUCTIONS', () {
        // Match the actual rendered row (quoted string literal), not any explanatory comment that
        // happens to mention the phrase "YOUR TRIP EARNINGS" earlier in the file.
        final deductionsIdx = src.indexOf('DEDUCTIONS');
        final earningsIdx = src.indexOf("'YOUR TRIP EARNINGS'");
        final gstLineIdx = src.indexOf('GST (5%) -- recorded separately');
        expect(deductionsIdx, greaterThan(-1));
        expect(earningsIdx, greaterThan(deductionsIdx));
        expect(gstLineIdx, greaterThan(earningsIdx),
            reason: '$name: GST line must come after YOUR TRIP EARNINGS, not inside DEDUCTIONS');
      });
      test('$name: government-tax row is still present for the NON-eligible path', () {
        expect(src.contains("'Government Tax'"), isTrue, reason: '$name lost the non-eligible Government Tax row');
        expect(src.contains("government_tax_ledger"), isTrue);
      });
      test('$name: non-eligible net formula (partnerEarning/riderEarning + gstAmount - tax) preserved', () {
        final hasHistoryForm = src.contains('breakdown.partnerEarning + breakdown.gstAmount - taxAmount');
        final hasCompletionForm = src.contains('riderEarning + breakdown.gstAmount - _completionGovTaxAmount');
        final hasEarningsForm = src.contains('riderEarning + breakdown.gstAmount - govTaxAmount');
        expect(hasHistoryForm || hasCompletionForm || hasEarningsForm, isTrue,
            reason: '$name lost the non-eligible YOUR TRIP EARNINGS formula');
      });
    }
  });

  group('5. No Platform-GST-netting regression / no gstPercentage label', () {
    for (final entry in screens.entries) {
      test('${entry.key}: no fareBeforeGst-minus-tax, no gstPercentage reference', () {
        expect(entry.value.contains('fareBeforeGst - '), isFalse);
        expect(entry.value.contains('gstPercentage'), isFalse);
      });
    }
  });

  group('6. The three list-based screens actually SELECT pg_charge_amount', () {
    // FareBreakdown.isPgChargeRide reads order['pg_charge_amount']; if a screen's orders query
    // does not request the column, the whole UI special-case is silently inert on that screen
    // (an eligible ride would still show the old rider_earning + GST − Government Tax figure).
    // rider_active_order_screen.dart is exempt: its 'order' comes from .select('*')/realtime full
    // row/the update-order-status RPC response (to_jsonb(v_order)), all of which carry the column.
    test('rider_order_history_screen.dart orders SELECT includes pg_charge_amount', () {
      expect(historyScreen.contains('pg_charge_amount'), isTrue);
      // in the same select string that already lists the other FareBreakdown inputs
      expect(historyScreen.contains('gst_amount, gst_percentage, pg_charge_amount,'), isTrue);
    });
    test('rider_activity_tab.dart orders SELECT includes pg_charge_amount', () {
      expect(activityTab.contains('pg_charge_amount'), isTrue);
      expect(activityTab.contains('gst_amount, gst_percentage, pg_charge_amount,'), isTrue);
    });
    test('rider_earnings_tab.dart BOTH orders SELECT queries include pg_charge_amount', () {
      final matches = RegExp(r'gst_amount, gst_percentage, pg_charge_amount,').allMatches(earningsTab).length;
      expect(matches, 2, reason: 'expected pg_charge_amount in both earnings-tab orders selects');
    });
  });
}
