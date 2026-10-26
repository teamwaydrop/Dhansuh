// Structural + math regression guard for Phase 2: reconciling the Rider Home "Today earning"
// card with the Earnings tab's "Today's Gross Earnings".
//
// PHASE 1 FINDING (reused, not re-derived): riders.today_earnings is a never-reset cumulative
// counter (only ever incremented in credit_rider_for_completed_order) and cannot be treated as a
// reliable current-day figure -- see rider_today_gross_earnings_regression_test.dart.
//
// PHASE 2 FINDING: Home's displayed "Today earning" figure does NOT actually read
// riders.today_earnings at all -- it already ran its own separate, correctly local-day-filtered
// live query (_fetchTodayEarnings), but summed orders.rider_earning (NET), the exact same
// net-vs-gross mismatch rider_earnings_tab.dart had before its Phase 1 fix. Home and Earnings
// therefore disagreed not because one used a stale counter, but because they used two DIFFERENT,
// independently-implemented aggregation formulas over the same underlying orders.
//
// FIX: _fetchTodayEarnings now sums final_fare ?? current_fare -- the identical authoritative
// gross-fare definition rider_earnings_tab.dart's todayE uses -- so both screens reconcile.
//
// This does not execute the widgets -- it inspects source structure/ordering and independently
// re-derives the aggregation math for a worked example, the same style already used by
// rider_today_gross_earnings_regression_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// Mirrors the fixed _fetchTodayEarnings() in rider_home_tab.dart.
double _homeTodayGross(List<Map<String, dynamic>> orders) {
  double total = 0.0;
  for (final o in orders) {
    total += double.tryParse((o['final_fare'] ?? o['current_fare'])?.toString() ?? '0') ?? 0.0;
  }
  return double.parse(total.toStringAsFixed(2));
}

void main() {
  final homeTab = _read('lib/features/rider/home/rider_home_tab.dart');
  final earningsTab = _read('lib/features/rider/earnings/rider_earnings_tab.dart');

  final fetchFnStart = homeTab.indexOf('Future<double> _fetchTodayEarnings(String riderId, DateTime nowLocal) async {');
  final fetchFnEnd = homeTab.indexOf('\n  }', fetchFnStart);

  test('sanity: _fetchTodayEarnings anchor exists', () {
    expect(fetchFnStart, greaterThan(-1));
    expect(fetchFnEnd, greaterThan(fetchFnStart));
  });

  final fetchFnBody = homeTab.substring(fetchFnStart, fetchFnEnd);

  group('1/3. Two ₹21 completed rides today (Cashfree + Personal QR) → Home = ₹42.00', () {
    test('the worked example matches the target regardless of payment method', () {
      final orders = [
        {'final_fare': 21, 'current_fare': 21, 'rider_earning': 17.95, 'fare_payment_method': 'cashfree'},
        {'final_fare': 21, 'current_fare': 21, 'rider_earning': 19.00, 'fare_payment_method': 'personal_upi'},
      ];
      expect(_homeTodayGross(orders), 42.00);
    });

    test('the query selects final_fare/current_fare, not rider_earning', () {
      expect(fetchFnBody.contains("select('final_fare, current_fare')"), isTrue);
      expect(fetchFnBody.contains("select('rider_earning')"), isFalse);
    });

    test('the summation reads final_fare ?? current_fare, never rider_earning', () {
      expect(
        fetchFnBody.contains("total += double.tryParse((o['final_fare'] ?? o['current_fare'])?.toString() ?? '0') ?? 0.0;"),
        isTrue,
      );
      expect(fetchFnBody.contains("o['rider_earning']"), isFalse);
    });

    test('no payment-method filter is applied -- every completed order contributes its gross fare', () {
      expect(fetchFnBody.contains('fare_payment_method'), isFalse);
      expect(fetchFnBody.contains('payment_mode'), isFalse);
    });
  });

  group('2. Home and Earnings use the identical authoritative gross-fare definition', () {
    test('both files use the exact same final_fare ?? current_fare fallback expression', () {
      const expression = "(o['final_fare'] ?? o['current_fare'])?.toString() ?? '0'";
      expect(homeTab.contains(expression), isTrue);
      expect(earningsTab.contains(expression), isTrue);
    });

    test('both filter on the same completed/delivered order_status set', () {
      const filter = ".inFilter('order_status', ['completed', 'delivered'])";
      expect(homeTab.contains(filter), isTrue);
      expect(earningsTab.contains(filter), isTrue);
    });
  });

  group('4. riders.today_earnings is not used for the Home display', () {
    test('_fetchTodayEarnings never reads the today_earnings column', () {
      expect(fetchFnBody.contains('today_earnings'), isFalse);
    });

    test('the rendered Home card text uses the `today` local variable (fed by _fetchTodayEarnings '
        'via the todayEarnings state field), not rider?[\'today_earnings\']', () {
      final cardStart = homeTab.indexOf('Widget _buildTodayEarningsCard()');
      final cardEnd = homeTab.indexOf("'₹\${_fmt(today)}'", cardStart);
      expect(cardStart, greaterThan(-1));
      expect(cardEnd, greaterThan(cardStart));
      final cardHeader = homeTab.substring(cardStart, cardEnd);
      expect(cardHeader.contains("rider?['today_earnings']"), isFalse);
      expect(cardHeader.contains('final today = todayEarnings;'), isTrue);
    });

    test('the label is updated to "Today\'s Gross Earnings", consistent with the Earnings tab', () {
      expect(homeTab.contains("\"Today's Gross Earnings\""), isTrue);
      expect(homeTab.contains("'Today earning'"), isFalse);
    });
  });

  group('5. Wallet/tax/COD accounting is unchanged', () {
    test('_fetchTodayEarnings never writes to wallet_balance, government_tax_due_balance, or '
        'cod_pending_amount -- read-only display aggregation', () {
      expect(fetchFnBody.contains('wallet_balance'), isFalse);
      expect(fetchFnBody.contains('government_tax_due_balance'), isFalse);
      expect(fetchFnBody.contains('cod_pending_amount'), isFalse);
    });

    test('the wallet figure shown alongside the earnings card is unchanged (still wallet_balance)', () {
      expect(homeTab.contains("final wallet = rider?['wallet_balance'] ?? 0;"), isTrue);
    });
  });

  group('6. Current local-day filtering is consistent between Home and Earnings', () {
    test('Home computes startOfToday from local year/month/day, converted to UTC for the query', () {
      expect(
        fetchFnBody.contains('final startOfToday = DateTime(nowLocal.year, nowLocal.month, nowLocal.day).toUtc();'),
        isTrue,
      );
    });

    test('Earnings groups by the order\'s local calendar date the same way (.toLocal() on completed_at)', () {
      expect(earningsTab.contains('DateTime.tryParse(dateStr.toString())?.toLocal()'), isTrue);
    });
  });
}
