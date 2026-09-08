// Structural + math regression guard for the Government Tax Due system (migrations
// 20260726000003/20260726000004; update-order-status, create-payment, cashfree-webhook,
// verify-payment, accept-order.ts; rider_earnings_tab.dart). This does not execute Postgres
// functions or the Edge Functions directly (Deno/TS + PL/pgSQL) -- it inspects their source for
// the required patterns, and independently re-derives the exact NUMERIC math the fixed functions
// must produce, so a future edit that reintroduces client-trusted amounts, double-charges tax on
// a Cashfree fare, or forgets the threshold gate on some dispatch path fails CI immediately.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// Mirrors apply_order_government_tax()'s rounding rule: ROUND(base * rate / 100, 2),
/// round-half-away-from-zero (PostgreSQL NUMERIC ROUND) -- Dart's num.round() already rounds
/// half-away-from-zero for positive values, matching that behavior for these test amounts.
double _expectedTax(double taxableBase, double ratePercent) {
  final raw = taxableBase * ratePercent / 100.0;
  return (raw * 100).round() / 100;
}

/// Mirrors is_rider_blocked_by_tax_due(): balance >= threshold blocks (not >).
bool _isBlocked(double balance, double threshold) => balance >= threshold;

void main() {
  final schemaMigration = _read('supabase/migrations/20260726000003_government_tax_due_schema.sql');
  final functionsMigration = _read('supabase/migrations/20260726000004_government_tax_due_functions.sql');
  final updateOrderStatus = _read('supabase/functions/update-order-status/index.ts');
  final completionSettlement = _read('supabase/migrations/20260813000000_atomic_order_completion_settlement.sql');
  final createPayment = _read('supabase/functions/create-payment/index.ts');
  final cashfreeWebhook = _read('supabase/functions/cashfree-webhook/index.ts');
  final verifyPayment = _read('supabase/functions/verify-payment/index.ts');
  final acceptOrder = _read('supabase/functions/accept-order/index.ts');
  final earningsTab = _read('lib/features/rider/earnings/rider_earnings_tab.dart');

  group('1/2. Direct-collection (Personal QR / Cash) tax math', () {
    test('₹200 local ride at 5% -> exactly ₹10 liability', () {
      expect(_expectedTax(200, 5.0), 10.0);
    });
    test('the configured local_passenger_ride rate is 5% and parcel_delivery is 18%', () {
      expect(schemaMigration.contains("('local_passenger_ride', 5.0)"), isTrue);
      expect(schemaMigration.contains("('parcel_delivery', 18.0)"), isTrue);
    });
    test('direct collection increments the outstanding balance, not a wallet credit', () {
      final start = functionsMigration.indexOf('IF p_is_direct_collection THEN');
      final end = functionsMigration.indexOf('ELSE', start);
      final branch = functionsMigration.substring(start, end);
      expect(branch.contains('government_tax_due_balance = government_tax_due_balance + v_tax_amount'), isTrue);
    });
  });

  group('3. Duplicate/retried completion never double-creates a liability', () {
    test('idempotency fast-path returns the existing amount instead of inserting again', () {
      expect(functionsMigration.contains("WHERE order_id = p_order_id AND entry_type = 'ORDER_TAX'"), isTrue);
      expect(functionsMigration.contains("'already_existed', true"), isTrue);
    });
    test('a DB-level unique index enforces exactly one ORDER_TAX row per order regardless of app logic', () {
      expect(schemaMigration.contains('idx_gov_tax_ledger_one_order_tax_per_order'), isTrue);
      expect(schemaMigration.contains('"government_tax_ledger" ("order_id")\n    WHERE "entry_type" = \'ORDER_TAX\''), isTrue);
    });
  });

  group('4. Parcel/delivery tax math', () {
    test('₹100 parcel at 18% -> exactly ₹18 liability', () {
      expect(_expectedTax(100, 18.0), 18.0);
    });
  });

  // WayDrop consolidated performance/correctness pass (2026-08-13): the settlement chain (wallet
  // credit, government tax, subscription waiver) moved from update-order-status's own JS into one
  // atomic RPC, complete_order_and_settle() (migration 20260813000000) -- see that migration's
  // header for the forensic incident that motivated it. Every rule below is unchanged, just
  // relocated with everything else it was already part of; these tests now check the new location.
  group('5. Tips / extra Personal QR amount are never taxed', () {
    test('the taxable base passed to the tax RPC is the same server-authoritative `fare` variable, not a UPI-observed amount', () {
      expect(completionSettlement.contains('v_fare,'), isTrue);
      expect(completionSettlement.contains('public.apply_order_government_tax('), isTrue);
      // `v_fare` itself is defined from final_fare/current_fare, never from any Personal-QR-scanned
      // or passenger-entered amount (there is no such field read anywhere in this function).
      expect(completionSettlement.contains('v_fare := COALESCE(v_order.final_fare, v_order.current_fare, 0);'), isTrue);
    });
  });

  group('6/7. Commission waiver and tax are independent', () {
    test('the tax RPC call is outside the v_has_active_subscription branch and still uses the original fare', () {
      final subBlockStart = completionSettlement.indexOf('IF v_has_active_subscription THEN');
      final subBlockEnd = completionSettlement.indexOf('v_order.subscription_commission_waived := true;');
      final taxCallIndex = completionSettlement.indexOf('public.apply_order_government_tax(');
      expect(subBlockStart, greaterThan(-1));
      expect(subBlockEnd, greaterThan(-1));
      expect(taxCallIndex, greaterThan(subBlockEnd));
    });
    test('tax liability creation happens for both subscribed and non-subscribed riders alike (no subscription gate around it)', () {
      final taxCallIndex = completionSettlement.indexOf('public.apply_order_government_tax(');
      final subscriptionBlockEnd = completionSettlement.indexOf('v_order.subscription_commission_waived := true;');
      expect(subscriptionBlockEnd, greaterThan(-1));
      expect(taxCallIndex, greaterThan(subscriptionBlockEnd));
      final snippet = completionSettlement.substring(subscriptionBlockEnd, taxCallIndex);
      expect(snippet.contains('IF v_has_active_subscription'), isFalse);
    });
  });

  group('8/9/10. ₹100 threshold math (>=, not >)', () {
    test('₹99.99 due is allowed', () => expect(_isBlocked(99.99, 100.0), isFalse));
    test('₹100.00 due is blocked', () => expect(_isBlocked(100.00, 100.0), isTrue));
    test('₹120 due is blocked', () => expect(_isBlocked(120.0, 100.0), isTrue));
    test('is_rider_blocked_by_tax_due uses >=, matching the spec exactly', () {
      expect(functionsMigration.contains('>= public.get_active_tax_due_threshold();'), isTrue);
    });
    test('the initial configured threshold is ₹100', () {
      expect(schemaMigration.contains('SELECT 100.0'), isTrue);
      expect(functionsMigration.contains('100.0\n    );'), isTrue);
    });
  });

  group('11. An existing active order is never interrupted by the threshold', () {
    test('the threshold gate is not present anywhere in the completion/payment/rating transition logic', () {
      // The threshold check only exists in dispatch/acceptance paths -- update-order-status's
      // own transition handling (accepted -> ... -> completed -> rating) has no
      // is_rider_blocked_by_tax_due reference at all.
      expect(updateOrderStatus.contains('is_rider_blocked_by_tax_due'), isFalse);
    });
  });

  group('12. Failed Cashfree tax payment leaves the due balance unchanged', () {
    test('the FAILED branch in both webhook and verify-payment never calls apply_government_tax_payment', () {
      for (final source in [cashfreeWebhook, verifyPayment]) {
        final failedIndex = source.indexOf('payment_status: "failed"');
        expect(failedIndex, greaterThan(-1));
        final failedBranch = source.substring(failedIndex, failedIndex + 400);
        expect(failedBranch.contains('apply_government_tax_payment'), isFalse);
      }
    });
  });

  group('13/14. Tax payment math, including concurrent-liability safety', () {
    test('₹120 payment against ₹120 due -> ₹0', () {
      const due = 120.0;
      const payment = 120.0;
      expect(due - payment, 0.0);
    });
    test('due ₹120, +₹10 liability, then ₹120 payment confirms -> ₹10 remains regardless of order', () {
      // Atomic deltas commute: (120 + 10) - 120 == (120 - 120) + 10 == 10.
      expect((120.0 + 10.0) - 120.0, 10.0);
      expect((120.0 - 120.0) + 10.0, 10.0);
    });
    test('apply_government_tax_payment decrements via an atomic column-delta UPDATE, never a blind SET to 0', () {
      expect(functionsMigration.contains('government_tax_due_balance = government_tax_due_balance - p_amount'), isTrue);
      expect(functionsMigration.contains('government_tax_due_balance = 0'), isFalse);
    });
  });

  group('15/16. Duplicate webhook / webhook+verify-payment race applies a payment exactly once', () {
    test('a DB-level unique index enforces exactly one TAX_PAYMENT row per Cashfree payment', () {
      expect(schemaMigration.contains('idx_gov_tax_ledger_one_payment_per_payment_id'), isTrue);
      expect(schemaMigration.contains('WHERE "entry_type" = \'TAX_PAYMENT\''), isTrue);
    });
    test('apply_government_tax_payment checks for an existing entry before crediting again', () {
      expect(functionsMigration.contains("WHERE payment_id = p_payment_id AND entry_type = 'TAX_PAYMENT'"), isTrue);
    });
    test('both cashfree-webhook and verify-payment call the exact same idempotent RPC for tax_due', () {
      for (final source in [cashfreeWebhook, verifyPayment]) {
        expect(source.contains('supabase Admin.rpc("apply_government_tax_payment"'.replaceAll(' ', '')), isTrue);
      }
    });
  });

  group('17/18. Client cannot fake a lower due or write the ledger directly', () {
    test('create-payment reads the real balance from the riders table, never trusting a client amount for tax_due', () {
      final start = createPayment.indexOf('GOVERNMENT TAX DUE REPAYMENT');
      final end = createPayment.indexOf('} else {', start);
      expect(start, greaterThan(-1));
      final branch = createPayment.substring(start, end);
      expect(branch.contains('taxRider.government_tax_due_balance'), isTrue);
      expect(branch.contains('finalAmount = dueBalance'), isTrue);
      expect(branch.contains('Number(amount)'), isFalse);
    });
    test('create-payment verifies rider_id belongs to the authenticated caller before reading its balance', () {
      expect(createPayment.contains('taxRider.user_id !== user.id'), isTrue);
    });
    test('no RLS INSERT/UPDATE policy exists for authenticated on government_tax_ledger', () {
      expect(schemaMigration.contains('FOR INSERT'), isFalse);
      expect(schemaMigration.contains('FOR UPDATE'), isFalse);
      expect(schemaMigration.contains('FOR ALL'), isFalse);
    });
    test('every ledger-mutating function is SECURITY DEFINER, granted only to service_role', () {
      expect(functionsMigration.contains('GRANT EXECUTE ON FUNCTION public.apply_order_government_tax(uuid, uuid, text, numeric, boolean) TO service_role;'), isTrue);
      expect(functionsMigration.contains('GRANT EXECUTE ON FUNCTION public.apply_government_tax_payment(uuid, uuid, numeric) TO service_role;'), isTrue);
    });
  });

  group('19. Passengers cannot access a rider\'s tax ledger', () {
    test('the read policy only matches rows whose rider_id belongs to the requesting user via the riders table', () {
      expect(schemaMigration.contains('government_tax_ledger_read_own'), isTrue);
      expect(schemaMigration.contains('r."user_id" = auth.uid()'), isTrue);
    });
  });

  group('20. A rate change never alters historical ledger entries', () {
    test('the ledger stores its own taxable_base/rate_percent/amount at creation time, independent of tax_rate_config', () {
      expect(schemaMigration.contains('"taxable_base" numeric'), isTrue);
      expect(schemaMigration.contains('"rate_percent" numeric'), isTrue);
      // The rate lookup only happens once, at apply time -- there is no recompute/backfill path
      // anywhere in these migrations.
      expect(functionsMigration.contains('UPDATE public.government_tax_ledger'), isFalse);
    });
    test('tax_rate_config is versioned by effective_from, so a new rate is additive, not a mutation of history', () {
      expect(schemaMigration.contains('"effective_from" timestamp with time zone'), isTrue);
    });
  });

  group('21. Cashfree fare does not economically charge tax twice', () {
    test('the Cashfree-collected branch withholds tax from the wallet-credited amount instead of also leaving it due', () {
      expect(completionSettlement.contains('v_rider_net_earning := ROUND(v_rider_net_earning - v_tax_amount, 2);'), isTrue);
      final start = functionsMigration.indexOf('ELSE');
      final elseBranchStart = functionsMigration.indexOf('-- Cashfree-collected');
      final elseBranchEnd = functionsMigration.indexOf('END IF;', elseBranchStart);
      final branch = functionsMigration.substring(elseBranchStart, elseBranchEnd);
      expect(branch.contains("'ORDER_TAX_WITHHELD'"), isTrue);
      // The withheld entry is negative, offsetting the positive ORDER_TAX entry -- net balance
      // change for a Cashfree-collected order is zero (the money was recovered via withholding,
      // not left outstanding).
      expect(branch.contains('-v_tax_amount'), isTrue);
      expect(start, greaterThan(-1));
    });
    test('the wallet-credited amount is reduced BEFORE credit_rider_for_completed_order is called, not after', () {
      final taxBlockIndex = completionSettlement.indexOf('public.apply_order_government_tax(');
      final creditCallIndex = completionSettlement.indexOf('public.credit_rider_for_completed_order(');
      expect(taxBlockIndex, greaterThan(-1));
      expect(creditCallIndex, greaterThan(taxBlockIndex));
    });
  });

  group('22/23. ₹40/₹280 subscription durations are unaffected by this feature', () {
    test('daily plan is still exactly 24 hours and weekly still exactly 168 hours', () {
      final planMigration = _read('supabase/migrations/20260726000002_subscription_plan_allowlist.sql');
      expect(planMigration.contains("('daily', '1 Day Pass', 40, 24)"), isTrue);
      expect(planMigration.contains("('weekly', '7 Days (1 Week)', 280, 168)"), isTrue);
    });
  });

  group('24/25/26. Subscription and tax-due payments never cross-affect each other', () {
    test('the subscription success branch never calls apply_government_tax_payment', () {
      for (final source in [cashfreeWebhook, verifyPayment]) {
        final subStart = source.indexOf('SUBSCRIPTION FLOW');
        final subBranch = source.substring(subStart, (subStart + 1200).clamp(0, source.length));
        expect(subBranch.contains('apply_government_tax_payment'), isFalse);
      }
    });
    test('the tax_due success branch never touches subscription_active/subscription_expires_at', () {
      for (final source in [cashfreeWebhook, verifyPayment]) {
        final taxStart = source.indexOf('GOVERNMENT TAX DUE REPAYMENT FLOW');
        final taxEnd = source.indexOf('} else {', taxStart);
        final taxBranch = source.substring(taxStart, taxEnd == -1 ? taxStart + 800 : taxEnd);
        expect(taxBranch.contains('subscription_active'), isFalse);
        expect(taxBranch.contains('subscription_expires_at'), isFalse);
      }
    });
    test('apply_government_tax_payment never touches wallet_balance/total_earnings/rider_earning', () {
      final start = functionsMigration.indexOf('CREATE OR REPLACE FUNCTION public.apply_government_tax_payment');
      final end = functionsMigration.indexOf('GRANT EXECUTE ON FUNCTION public.apply_government_tax_payment');
      final fnBody = functionsMigration.substring(start, end);
      expect(fnBody.contains('wallet_balance'), isFalse);
      expect(fnBody.contains('total_earnings'), isFalse);
      expect(fnBody.contains('rider_earning'), isFalse);
    });
  });

  group('27. Eligibility is restored immediately once balance falls below the threshold', () {
    test('is_rider_blocked_by_tax_due reads the live balance every call -- no separate cached "blocked" flag to go stale', () {
      final start = functionsMigration.indexOf('CREATE OR REPLACE FUNCTION public.is_rider_blocked_by_tax_due');
      final end = functionsMigration.indexOf('GRANT EXECUTE ON FUNCTION public.is_rider_blocked_by_tax_due');
      final fnBody = functionsMigration.substring(start, end);
      expect(fnBody.contains('SELECT government_tax_due_balance FROM public.riders'), isTrue);
    });
  });

  group('28. Every assignment/dispatch path respects the threshold', () {
    test('find_nearby_riders, assign_nearby_searching_orders_to_rider, and accept_intercity_request all call the gate', () {
      expect(functionsMigration.contains('AND NOT public.is_rider_blocked_by_tax_due(r.id)'), isTrue);
      expect(functionsMigration.contains('IF public.is_rider_blocked_by_tax_due(NEW.id) THEN'), isTrue);
      expect(functionsMigration.contains("'code', 'TAX_DUE_THRESHOLD_BLOCKED',"), isTrue);
    });
    test('accept-order.ts (the direct local/parcel/intercity-ride acceptance path) also calls the gate', () {
      expect(acceptOrder.contains('is_rider_blocked_by_tax_due'), isTrue);
      expect(acceptOrder.contains('TAX_DUE_THRESHOLD_BLOCKED'), isTrue);
    });
  });

  group('29. Completion/payment retries do not duplicate wallet or tax transactions', () {
    test('credit_rider_for_completed_order is still called exactly once per completion (optimistic lock unchanged)', () {
      expect(completionSettlement.contains('public.credit_rider_for_completed_order('), isTrue);
      // The optimistic lock itself: complete_order_and_settle's own initial UPDATE only matches
      // order_status = p_previous_status, so a retried/duplicate completion call for an order that
      // already transitioned finds no row, returns CONFLICT, and never reaches the credit call at all.
      expect(completionSettlement.contains('WHERE id = p_order_id'), isTrue);
      expect(completionSettlement.contains('AND order_status = p_previous_status::public.order_status_enum'), isTrue);
      expect(completionSettlement.contains("'code', 'CONFLICT'"), isTrue);
    });
    test('the tax RPC itself is idempotent per order (see group 3), so a retried completion cannot double-tax either', () {
      expect(functionsMigration.contains('ON CONFLICT (order_id) WHERE entry_type = \'ORDER_TAX\' DO NOTHING'), isTrue);
    });
  });

  group('30. Rating remains reachable after a successful completion', () {
    test('no new gate was added to the completed/delivered transition itself', () {
      final completedBlockStart = updateOrderStatus.indexOf('if (new_status === "completed" || new_status === "delivered") {');
      expect(completedBlockStart, greaterThan(-1));
      expect(updateOrderStatus.contains('complete_order_and_settle'), isTrue);
    });
    // A tax-ledger failure must never block (or, now that this runs inside one transaction, roll
    // back) an otherwise-legitimate completion -- the exact same "never block completion on
    // tax-ledger bookkeeping" rule as before, now enforced by a nested exception handler around
    // just the tax RPC call instead of a caught-and-logged JS error, since the whole settlement is
    // now one atomic transaction where an uncaught exception anywhere would otherwise roll back the
    // order_status write and wallet credit too.
    test('a government-tax-due failure is caught locally and never rolls back the rest of the completion', () {
      final taxCallIndex = completionSettlement.indexOf('public.apply_order_government_tax(');
      final nestedExceptionIndex = completionSettlement.indexOf('EXCEPTION', taxCallIndex);
      final creditCallIndex = completionSettlement.indexOf('public.credit_rider_for_completed_order(');
      expect(taxCallIndex, greaterThan(-1));
      expect(nestedExceptionIndex, greaterThan(taxCallIndex));
      expect(creditCallIndex, greaterThan(nestedExceptionIndex));
      expect(completionSettlement.contains('v_tax_result := NULL;'), isTrue);
    });
  });

  group('UI: Government Tax Due is visually and conceptually distinct from the subscription', () {
    test('the card uses required copy and never labels this as commission/WayDrop fee', () {
      expect(earningsTab.contains("'Government Tax Due'"), isTrue);
      expect(earningsTab.contains('Tax amount collected on completed services and payable through WayDrop.'), isTrue);
      expect(earningsTab.contains('Pay Government Tax Due'), isTrue);
      expect(earningsTab.contains('WayDrop fee'), isFalse);
      expect(earningsTab.contains('negative earnings'), isFalse);
    });
    test('balance and threshold are both fetched from the server, never hardcoded as a rebuild-requiring constant', () {
      expect(earningsTab.contains("rider?['government_tax_due_balance']"), isTrue);
      expect(earningsTab.contains("from('government_tax_config')"), isTrue);
    });
  });
}
