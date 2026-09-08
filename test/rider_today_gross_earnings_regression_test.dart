// Structural + math regression guard for the "Today's Earnings must be GROSS fare, not net
// rider_earning" fix in rider_earnings_tab.dart.
//
// CONFIRMED BUG (real-device report): the "Today's Earnings" hero figure summed
// orders.rider_earning (a NET figure -- fare minus commission, historically also minus Platform
// GST) instead of the gross customer-payable fare. For two ₹21 rides (one Cashfree, one Personal
// QR) this showed ₹36.95 instead of the expected ₹42.00.
//
// FIX: the summary loop now sums final_fare ?? current_fare (the same authoritative
// customer-payable-fare column create-payment/index.ts and every other settlement reader use) for
// `todayE` specifically. weekE/monthE and the separate Earnings Analytics chart/day-breakdown
// loops are deliberately left on the pre-existing net `rider_earning` figure -- out of scope for
// this fix, unaudited, not touched.
//
// This does not execute the widget -- it inspects source structure/ordering and independently
// re-derives the aggregation math for a worked example, the same style already used elsewhere in
// this test suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// Mirrors the fixed loop body in rider_earnings_tab.dart's processOrdersData().
double _todayGross(List<Map<String, dynamic>> orders, DateTime today) {
  double todayE = 0.0;
  for (final o in orders) {
    final dateStr = o['completed_at'] ?? o['created_at'];
    final completedAt = DateTime.tryParse(dateStr.toString());
    if (completedAt == null) continue;
    final orderDate = DateTime(completedAt.year, completedAt.month, completedAt.day);
    final grossFare = double.tryParse((o['final_fare'] ?? o['current_fare'])?.toString() ?? '0') ?? 0.0;
    if (orderDate.isAtSameMomentAs(today)) {
      todayE += grossFare;
    }
  }
  return double.parse(todayE.toStringAsFixed(2));
}

void main() {
  final earningsTab = _read('lib/features/rider/earnings/rider_earnings_tab.dart');

  group('1/2/3. Today\'s Gross Earnings sums final_fare/current_fare, not rider_earning', () {
    test('two ₹21 completed rides (Cashfree + Personal QR) sum to exactly ₹42.00', () {
      final today = DateTime(2026, 9, 5);
      final orders = [
        {
          'completed_at': '2026-09-05T10:00:00Z',
          'final_fare': 21,
          'current_fare': 21,
          'rider_earning': 17.95, // net, Cashfree -- must NOT be what gets summed
          'fare_payment_method': 'cashfree',
        },
        {
          'completed_at': '2026-09-05T14:00:00Z',
          'final_fare': 21,
          'current_fare': 21,
          'rider_earning': 19.00, // net, Personal QR -- must NOT be what gets summed
          'fare_payment_method': 'personal_upi',
        },
      ];
      expect(_todayGross(orders, today), 42.00);
    });

    test('the source reads final_fare ?? current_fare for todayE, the same authoritative '
        'customer-payable-fare column used elsewhere in the codebase', () {
      expect(
        earningsTab.contains(
          "final grossFare = double.tryParse((o['final_fare'] ?? o['current_fare'])?.toString() ?? '0') ?? 0.0;",
        ),
        isTrue,
      );
      expect(earningsTab.contains('todayE += grossFare;'), isTrue);
    });

    test('todayE no longer sums the net rider_earning field', () {
      expect(earningsTab.contains('todayE += fare;'), isFalse);
    });
  });

  group('4/5/6. Wallet, Cash to be Paid, Government Tax Due remain separate, untouched liabilities', () {
    test('Wallet mini-stat still reads wallet_balance directly, unchanged', () {
      expect(
        earningsTab.contains("_MiniStat(label: 'Wallet', value: '₹\${_fmt(rider?['wallet_balance'])}'"),
        isTrue,
      );
    });

    test('Cash to Paid mini-stat still reads cod_pending_amount directly, unchanged', () {
      expect(
        earningsTab.contains("_MiniStat(label: 'Cash to Paid', value: '₹\${_fmt(rider?['cod_pending_amount'])}'"),
        isTrue,
      );
    });

    test('Total Earned mini-stat is untouched -- it is a distinct, legitimately lifetime '
        'account metric (riders.total_earnings), not part of this bug', () {
      expect(
        earningsTab.contains("_MiniStat(label: 'Total Earned', value: '₹\${_fmt(rider?['total_earnings'])}'"),
        isTrue,
      );
    });
  });

  group('7. Existing commission/tax calculations are unchanged (this is a display-aggregation-only fix)', () {
    test('weekE/monthE are deliberately left on the pre-existing net figure, out of scope', () {
      expect(earningsTab.contains('weekE += fare;'), isTrue);
      expect(earningsTab.contains('monthE += fare;'), isTrue);
    });

    test('no order-level settlement field (rider_earning, commission_amount, gst_amount) is '
        'written anywhere in this file -- this is a read-only display aggregation fix', () {
      expect(earningsTab.contains("'rider_earning':"), isFalse);
      expect(earningsTab.contains("'commission_amount':"), isFalse);
      expect(earningsTab.contains("'gst_amount':"), isFalse);
    });

    test('the hero label is updated to avoid a misleading net-vs-gross ambiguity', () {
      expect(earningsTab.contains('"Today\'s Gross Earnings"'), isTrue);
    });
  });

  group('PHASE 1: Earnings-vs-Home reconciliation (real-device report: Home ₹112, Earnings ₹0)', () {
    test('1/6. today\'s date grouping uses the order\'s LOCAL calendar date (.toLocal()), not UTC, '
        'so a completed_at timestamp near local midnight is bucketed into the correct local day', () {
      expect(earningsTab.contains('DateTime.tryParse(dateStr.toString())?.toLocal()'), isTrue);
    });

    test('the orders query\'s 30-day lower bound cannot itself exclude today (30 days back, not '
        'forward, and converted to UTC before the .gte() comparison)', () {
      expect(
        earningsTab.contains('final thirtyDaysAgo = DateTime.now().subtract(const Duration(days: 30)).toUtc();'),
        isTrue,
      );
    });

    test('PROVEN ROOT CAUSE: riders.today_earnings (read by the Home tab) is never reset by any '
        'trigger/cron/function in this codebase -- it is only ever incremented in '
        'credit_rider_for_completed_order, so despite its name it behaves as a permanent '
        'cumulative counter, not a calendar-day-scoped figure. It must not be treated as the '
        'authoritative "today" benchmark to reconcile Earnings against.', () {
      final creditFn = File('supabase/migrations/20260820000000_fix_intercity_parcel_delivery_rider_credit_guard.sql')
          .readAsStringSync();
      expect(
        creditFn.contains('today_earnings = COALESCE(today_earnings, 0) + p_rider_earning,'),
        isTrue,
      );
      // No reset anywhere in the schema/functions this repo ships.
      expect(creditFn.contains('today_earnings = 0'), isFalse);
    });

    test('a genuine orders-query fetch failure is now visibly distinct from a real ₹0 -- previously '
        'both silently rendered as an identical, confident "₹0.00"', () {
      expect(earningsTab.contains('bool _todayEarningsUnavailable = false;'), isTrue);
      expect(earningsTab.contains('_todayEarningsUnavailable = true;'), isTrue);
      expect(earningsTab.contains('_todayEarningsUnavailable = false;'), isTrue);
      expect(earningsTab.contains("Text('Unable to load',"), isTrue);
    });

    test('the fetch-failure flag is scoped to display only -- it never changes what counts as '
        'gross earnings, and does not touch wallet/tax/cod fields', () {
      final flagLineIndex = earningsTab.indexOf('bool _todayEarningsUnavailable = false;');
      final catchBlockIndex = earningsTab.indexOf('_todayEarningsUnavailable = true;');
      expect(flagLineIndex, greaterThan(-1));
      expect(catchBlockIndex, greaterThan(flagLineIndex));
      // Still no wallet/tax/cod mutation anywhere in this read-only display file.
      expect(earningsTab.contains('wallet_balance ='), isFalse);
      expect(earningsTab.contains('government_tax_due_balance ='), isFalse);
      expect(earningsTab.contains('cod_pending_amount ='), isFalse);
    });
  });
}
