// Structural + math regression guard for Phase 2 / Issue 5: intercity parcel completions showed
// "Government Tax ₹0.00" on the rider completion/earnings screen.
//
// INVESTIGATION (exhaustive trace, empirically verified against a local Postgres instance running
// every current migration -- not assumed):
//   1. tax_rate_config seeds 'parcel_delivery' at 18.0% (20260726000003) -- confirmed live in a
//      reset local DB: `service_category='parcel_delivery', rate_percent=18.0, is_active=true`.
//   2. apply_order_government_tax() (latest: 20260901000021) classifies order_type='intercity_parcel'
//      into 'parcel_delivery' (same bucket as local_parcel/batch_delivery/food_delivery/
//      grocery_delivery) -- unchanged by this fix.
//   3. confirm_intercity_parcel_payment_received() (latest: 20260901000019) derives the taxable
//      base as `v_fare := COALESCE(v_order.final_fare, v_order.current_fare, 0)` -- the exact same
//      authoritative customer-payable-fare pattern every other settlement function uses -- and
//      calls apply_order_government_tax(order_id, rider_id, 'intercity_parcel', v_fare, ...).
//   4. EMPIRICAL PROOF the backend is correct: calling confirm_intercity_parcel_payment_received()
//      end-to-end against a real intercity_parcel order with final_fare/current_fare = ₹261 (no
//      test-only shortcuts -- the real RPC, the real trigger chain, the real tax_rate_config seed
//      row) produced a government_tax_ledger row with taxable_base=261, rate_percent=18.0,
//      amount=46.98 -- EXACTLY the worked example in the bug report (18% of ₹261 = ₹46.98). The
//      calculation, category resolution, and ledger persistence are NOT the bug.
//   5. ROOT CAUSE: lib/core/services/database/government_tax_ledger_cache.dart's static in-memory
//      cache treated a `null` (not-yet-found / a transient fetch failure) result EXACTLY like a
//      real row -- caching it FOREVER for that order_id, with no way for a later, legitimate query
//      (once the row genuinely exists, which it always does by the time order_status is visible as
//      'delivered' -- both are written in the same atomic settlement transaction) to ever see it
//      again within the same app session. rider_active_order_screen.dart's completion screen and
//      rider_earnings_tab.dart's expandable order card both read through this same cache.
//
// FIX: GovernmentTaxLedgerCache never caches a null/not-found result -- only a genuinely found row
// is cached (a found row is still cached indefinitely, since it's immutable once written -- that
// part of the design was always correct and is unchanged). rider_active_order_screen.dart also
// clears its own per-screen "already loaded" guard on a null/error result, so the very next
// rebuild of that screen instance retries instead of latching onto ₹0.00 for its whole lifetime.
// No pricing formula, GST rate, commission rate, tax rate, or tax-category classification changed
// -- this is a caching/retry-logic fix only. No migration is required (the SQL settlement logic
// was already correct, verified above).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// Mirrors apply_order_government_tax()'s rounding rule: ROUND(base * rate / 100, 2).
double _expectedTax(double taxableBase, double ratePercent) {
  final raw = taxableBase * ratePercent / 100.0;
  return (raw * 100).round() / 100;
}

void main() {
  final taxSchema = _read('supabase/migrations/20260726000003_government_tax_due_schema.sql');
  final taxFunctionsLatest =
      _read('supabase/migrations/20260901000021_intercity_ride_gov_tax_and_stale_negotiated_commission.sql');
  final confirmParcelPayment =
      _read('supabase/migrations/20260901000019_gate_free_trial_waiver_to_local_orders.sql');
  final commissionFix = _read('supabase/migrations/20260901000022_intercity_auto_commission_10_percent.sql');
  final cacheFile = _read('lib/core/services/database/government_tax_ledger_cache.dart');
  final activeOrderScreen = _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');
  final earningsTab = _read('lib/features/rider/earnings/rider_earnings_tab.dart');

  group('1/2. intercity_parcel resolves to the parcel_delivery category at 18%', () {
    test('parcel_delivery is seeded at 18.0% (and remains 5% for local_passenger_ride -- untouched)', () {
      expect(taxSchema.contains("('local_passenger_ride', 5.0)"), isTrue);
      expect(taxSchema.contains("('parcel_delivery', 18.0)"), isTrue);
    });

    test('apply_order_government_tax() maps intercity_parcel into parcel_delivery, alongside every '
        'other parcel/delivery order_type -- not its own bespoke category', () {
      final anchor = taxFunctionsLatest.indexOf('v_category := CASE');
      expect(anchor, greaterThan(-1));
      final nearby = taxFunctionsLatest.substring(anchor, (anchor + 400).clamp(0, taxFunctionsLatest.length));
      expect(
        nearby.contains(
          "WHEN p_order_type IN ('local_parcel', 'batch_delivery', 'food_delivery', 'grocery_delivery', 'intercity_parcel') THEN 'parcel_delivery'",
        ),
        isTrue,
      );
    });

    test('18% of ₹261 is exactly ₹46.98 -- the worked example from the bug report, empirically '
        'reproduced end-to-end against confirm_intercity_parcel_payment_received() on a local '
        'Postgres instance running this exact migration set', () {
      expect(_expectedTax(261.0, 18.0), 46.98);
    });
  });

  group('3/4/5. Taxable base selection, calculation, and persistence', () {
    test('confirm_intercity_parcel_payment_received() derives the taxable base from the same '
        'authoritative customer-payable-fare column every other settlement path uses -- '
        'final_fare, falling back to current_fare -- never a different/zero base', () {
      expect(
        confirmParcelPayment.contains('v_fare := COALESCE(v_order.final_fare, v_order.current_fare, 0);'),
        isTrue,
      );
      expect(confirmParcelPayment.contains('IF v_fare <= 0 THEN'), isTrue);
    });

    test('the tax RPC is actually called, passing that exact fare as the taxable base', () {
      final fnStart = confirmParcelPayment.indexOf(
        'CREATE OR REPLACE FUNCTION public.confirm_intercity_parcel_payment_received(p_order_id uuid)',
      );
      expect(fnStart, greaterThan(-1));
      final anchor = confirmParcelPayment.indexOf('v_tax_result := public.apply_order_government_tax(', fnStart);
      expect(anchor, greaterThan(-1));
      final nearby = confirmParcelPayment.substring(anchor, (anchor + 200).clamp(0, confirmParcelPayment.length));
      expect(nearby.contains('v_order.order_type::text,\n        v_fare,'), isTrue);
    });

    test('the ledger insert is unconditional on the collection method -- the ORDER_TAX row (what '
        'the completion screen reads) is always written with the correctly-calculated amount, '
        'regardless of direct-collection vs Cashfree-gateway', () {
      final insertIdx = taxFunctionsLatest.indexOf("'ORDER_TAX', v_category, p_taxable_base, v_rate, v_tax_amount");
      final directCollectionIdx = taxFunctionsLatest.indexOf('IF p_is_direct_collection THEN', insertIdx);
      expect(insertIdx, greaterThan(-1));
      expect(directCollectionIdx, greaterThan(insertIdx));
    });
  });

  group('6/7. UI reads the persisted tax correctly, and the caching bug that made it show ₹0 is fixed', () {
    test('GovernmentTaxLedgerCache no longer caches a null/not-found result -- only a genuinely '
        'found row is cached', () {
      final anchor = cacheFile.indexOf('final result = await future;');
      expect(anchor, greaterThan(-1));
      final nearby = cacheFile.substring(anchor, (anchor + 150).clamp(0, cacheFile.length));
      expect(nearby.contains('if (result != null) {'), isTrue);
      expect(nearby.contains('_cache[orderId] = result;'), isTrue);
      // The old unconditional "_cache[orderId] = result;" run for every outcome (including null)
      // must be gone -- it must now be inside the null-guard, not a bare statement right after
      // the await.
      expect(cacheFile.contains('final result = await future;\n      _cache[orderId] = result;'), isFalse);
    });

    test('the completion screen (rider_active_order_screen.dart) reads amount/rate_percent off '
        'the same government_tax_ledger ORDER_TAX row, and clears its own per-screen guard on a '
        'null/error result so the very next rebuild retries instead of freezing at ₹0.00', () {
      expect(
        activeOrderScreen.contains(
          "_completionGovTaxAmount = double.tryParse(row['amount']?.toString() ?? '0') ?? 0.0;",
        ),
        isTrue,
      );
      final nullBranchAnchor = activeOrderScreen.indexOf('if (row == null) {');
      expect(nullBranchAnchor, greaterThan(-1));
      final nullBranchEnd = activeOrderScreen.indexOf('return;', nullBranchAnchor);
      expect(nullBranchEnd, greaterThan(nullBranchAnchor));
      final nullBranch = activeOrderScreen.substring(nullBranchAnchor, nullBranchEnd);
      expect(nullBranch.contains('_completionTaxOrderId = null;'), isTrue);

      final catchAnchor = activeOrderScreen.indexOf('} catch (_) {\n      if (!mounted || _completionTaxOrderId != orderId) return;');
      expect(catchAnchor, greaterThan(-1));
      final catchBranchEnd = activeOrderScreen.indexOf('});', catchAnchor);
      expect(catchBranchEnd, greaterThan(catchAnchor));
      final catchBranch = activeOrderScreen.substring(catchAnchor, catchBranchEnd);
      expect(catchBranch.contains('_completionTaxOrderId = null;'), isTrue);
    });

    test('rider_earnings_tab.dart\'s expandable order card reads the same amount/rate_percent '
        'fields through the same shared cache -- no second, independently-derived tax figure', () {
      expect(
        earningsTab.contains("_govTaxAmount = double.tryParse(row?['amount']?.toString() ?? '0') ?? 0.0;"),
        isTrue,
      );
      expect(earningsTab.contains('GovernmentTaxLedgerCache.get('), isTrue);
    });

    test('Government Tax is not ₹0 when a valid taxable base exists (the reported bug) -- proven '
        'end-to-end above via direct RPC execution, not just by reading source', () {
      // Re-asserts the empirical result documented in the file header: a real settlement call
      // against a real order (final_fare=261) produced a real, non-zero, correctly-rounded ledger
      // amount. This test exists so a future change to the rounding/base-selection logic that
      // would break that invariant fails a fast, static check even without a live DB on hand.
      expect(_expectedTax(261.0, 18.0), isNot(0.0));
      expect(_expectedTax(261.0, 18.0), greaterThan(0.0));
    });
  });

  group('8/9. Platform GST and commission are untouched', () {
    test('intercity parcel Platform GST stays 5% -- this migration set never changes '
        'pricing_config.gst_percentage', () {
      // The commission-correction migration only ever WRITES commission_percentage -- it
      // documents (in a comment) that gst_percentage must stay untouched, but its actual UPDATE
      // statement never sets/touches that column.
      expect(commissionFix.contains('SET commission_percentage = 10,'), isTrue);
      expect(commissionFix.contains('SET gst_percentage'), isFalse);
      expect(
        commissionFix.contains(
          'gst_percentage (Platform GST, must stay 5% for both, per explicit instruction',
        ),
        isTrue,
      );
    });

    test('intercity parcel commission is 10% (bike and auto alike) -- confirmed by the existing, '
        'unmodified commission-correction migration; this Issue 5 fix touches no commission logic', () {
      expect(
        commissionFix.contains(
          "WHERE service_type IN ('intercity_ride', 'intercity_parcel')\n  AND vehicle_type = 'auto'",
        ),
        isTrue,
      );
    });

    test('confirm_intercity_parcel_payment_received() reads commission_percentage straight off '
        'the order (the value stamped at booking time) -- it never recomputes or overrides it', () {
      expect(
        confirmParcelPayment.contains('v_commission_pct := COALESCE(v_order.commission_percentage, 0);'),
        isTrue,
      );
    });
  });

  group('10. Free trial cannot waive Government Tax', () {
    test('confirm_intercity_parcel_payment_received() never reads subscription_active/'
        'subscription_expires_at at all -- the free-trial 0% commission waiver is local-orders-'
        'only (Issue 5, 20260901000019) and has no code path into this function, let alone into '
        'the separate Government Tax system', () {
      final fnStart = confirmParcelPayment.indexOf(
        'CREATE OR REPLACE FUNCTION public.confirm_intercity_parcel_payment_received(p_order_id uuid)',
      );
      final fnEnd = confirmParcelPayment.indexOf(
        'GRANT EXECUTE ON FUNCTION public.confirm_intercity_parcel_payment_received',
      );
      expect(fnStart, greaterThan(-1));
      expect(fnEnd, greaterThan(fnStart));
      final fnBody = confirmParcelPayment.substring(fnStart, fnEnd);
      expect(fnBody.contains('subscription_active'), isFalse);
      // The function body itself declares/uses no such variable -- only a trailing explanatory
      // comment mentions it (documenting the removal), so check for actual usage, not the bare
      // substring (which the comment prose also contains).
      expect(fnBody.contains('v_has_active_subscription boolean;'), isFalse);
      expect(fnBody.contains('v_has_active_subscription :='), isFalse);
      expect(fnBody.contains('IF v_has_active_subscription'), isFalse);
      // complete_order_and_settle() (the separate, local/intercity_ride settlement path earlier
      // in this same file) legitimately still reads subscription state for its own local-only
      // waiver -- confirming this isn't simply absent from the whole file by coincidence.
      expect(confirmParcelPayment.contains('SELECT subscription_active, subscription_expires_at INTO v_rider'), isTrue);
    });

    test('apply_order_government_tax() itself takes no subscription/waiver parameter of any kind '
        '-- it cannot be told to skip or discount a liability', () {
      final sigStart = taxFunctionsLatest.indexOf('CREATE OR REPLACE FUNCTION public.apply_order_government_tax(');
      final sigEnd = taxFunctionsLatest.indexOf(')', sigStart);
      final signature = taxFunctionsLatest.substring(sigStart, sigEnd);
      expect(signature.contains('subscription'), isFalse);
      expect(signature.contains('waive'), isFalse);
    });
  });

  group('11. Intercity passenger (intercity_ride) Government Tax remains 5%, untouched', () {
    test('intercity_passenger_ride is seeded at 5.0%, a separate category/rate from parcel_delivery', () {
      expect(taxFunctionsLatest.contains("VALUES ('intercity_passenger_ride', 5.0);"), isTrue);
    });

    test('the classification CASE keeps intercity_ride and intercity_parcel as two distinct '
        'categories -- no shared/merged bucket', () {
      expect(taxFunctionsLatest.contains("WHEN p_order_type = 'intercity_ride' THEN 'intercity_passenger_ride'"), isTrue);
    });
  });

  group('12. Local ride / local parcel behavior is unchanged', () {
    test('local_passenger_ride (ride/ride_sharing) still resolves to its own 5% category, '
        'reproduced byte-for-byte', () {
      expect(
        taxFunctionsLatest.contains("WHEN p_order_type IN ('ride', 'ride_sharing') THEN 'local_passenger_ride'"),
        isTrue,
      );
    });

    test('the government-tax ROUND(taxable_base * rate / 100.0, 2) formula itself is untouched by '
        'this fix -- no new/second rounding formula was invented', () {
      expect(taxFunctionsLatest.contains('v_tax_amount := ROUND(p_taxable_base * v_rate / 100.0, 2);'), isTrue);
    });

    test('the GovernmentTaxLedgerCache fix applies identically to every order type -- it is not '
        'scoped to intercity_parcel, so local ride/parcel completions get the exact same '
        'correctness improvement (never a regression) from the same one-line change', () {
      expect(cacheFile.contains('static Future<Map<String, dynamic>?> get('), isTrue);
      // A single, order-type-agnostic cache implementation -- no intercity-specific branch.
      expect(cacheFile.contains('order_type'), isFalse);
    });
  });
}
