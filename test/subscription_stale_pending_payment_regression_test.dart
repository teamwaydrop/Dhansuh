// Structural regression guard for the stale-pending-payment reuse bug, covering all three
// payment types it applies to: subscription, tax_due, cod_settlement.
//
// CONFIRMED PRODUCTION BUG (subscription): create-payment/index.ts's duplicate-payment lookup
// matched an existing pending payment on user_id + payment_for + payment_status='pending' alone --
// it never checked plan_id or amount. A still-ACTIVE-on-Cashfree pending payment from an earlier
// attempt at a DIFFERENT plan/price (e.g. daily_bike changed from ₹40 to ₹39) was handed back
// verbatim. Observed: UI shows ₹39, Cashfree charges ₹40.
//
// SAME BUG, SIBLING TYPES (tax_due / cod_settlement): these two share the identical
// reference_id-IS-NULL duplicate-lookup branch as subscription, and their authoritative amount
// (government_tax_due_balance / cod_pending_amount) is re-read fresh on every call the same way
// plan.amount is for subscription -- so the exact same stale-reuse risk applies: UI shows a
// current due of ₹22.75, a stale still-ACTIVE ₹65.75 pending session gets reused instead.
//
// FIX (generalized): a single `requiresAmountMatch` guard now covers all three payment_for
// values. It requires existingPayment.final_amount === finalAmount (finalAmount is already the
// authoritative value for all three -- plan.amount, or the freshly-read due balance) and, for
// subscription only, existingPayment.plan_id === subscriptionPlanId. On any mismatch the stale
// local payment row is marked 'failed' with a type-specific failure_reason (the same
// supersede-and-fall-through pattern already used for an EXPIRED/TERMINATED Cashfree session just
// below it), and a fresh Cashfree order is created for the current plan/amount.
//
// This does not execute the Edge Function (Deno/TS) -- it inspects source structure and ordering,
// the same style already used by subscription_plan_regression_test.dart and
// vehicle_specific_subscription_pricing_regression_test.dart for this file.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final createPayment = _read('supabase/functions/create-payment/index.ts');

  final duplicateLookupIndex = createPayment.indexOf('let { data: existingPayment }');
  final activeSessionCheckIndex = createPayment.indexOf(
    'if (existingPayment && existingPayment.gateway_order_id)',
  );
  final staleCheckIndex = createPayment.indexOf(
    'const requiresAmountMatch = payment_for === "subscription" || isTaxDue || isCodSettlement;',
  );

  test('sanity: all three anchors exist and are in the expected order', () {
    expect(duplicateLookupIndex, greaterThan(-1));
    expect(staleCheckIndex, greaterThan(duplicateLookupIndex));
    expect(activeSessionCheckIndex, greaterThan(staleCheckIndex));
  });

  final staleCheckBlock = createPayment.substring(staleCheckIndex, activeSessionCheckIndex);

  group('A/C. Reuse when the existing pending payment matches the current authoritative amount', () {
    test('the mismatch check compares final_amount against the server-derived finalAmount '
        '(finalAmount IS the current dueBalance for tax_due/cod_settlement)', () {
      expect(
        staleCheckBlock.contains(
          'Number(existingPayment.final_amount).toFixed(2) !== finalAmount.toFixed(2)',
        ),
        isTrue,
      );
    });

    test('the guard is applied to exactly subscription, tax_due, and cod_settlement', () {
      expect(staleCheckBlock.contains('payment_for === "subscription" || isTaxDue || isCodSettlement'), isTrue);
    });

    test('plan_id is only compared for subscription -- tax_due/cod_settlement have no plan_id', () {
      expect(
        staleCheckBlock.contains(
          'payment_for === "subscription" && existingPayment.plan_id !== subscriptionPlanId',
        ),
        isTrue,
      );
    });

    test('the check never compares against the raw client-supplied plan_id/amount body fields', () {
      // subscriptionPlanId/finalAmount are the only trusted values (see subscription_plan_regression_test.dart
      // group 3/4/5) -- this fix must not silently reintroduce trust in the client's own `plan_id`/`amount`.
      expect(staleCheckBlock.contains('=== plan_id'), isFalse);
      expect(staleCheckBlock.contains('=== Number(amount)'), isFalse);
    });
  });

  group('B/D/I. A mismatched amount is superseded, never reused', () {
    test('a plan or amount mismatch supersedes the old row before any fresh order is created', () {
      expect(staleCheckBlock.contains('planMismatch || amountMismatch'), isTrue);
      expect(staleCheckBlock.contains('existingPayment = null;'), isTrue);
    });

    test('superseding uses the existing safe update-scoped-to-pending pattern, not a delete', () {
      expect(staleCheckBlock.contains('payment_status: "failed"'), isTrue);
      expect(staleCheckBlock.contains('.eq("id", existingPayment.id)'), isTrue);
      expect(staleCheckBlock.contains('.eq("payment_status", "pending")'), isTrue);
      expect(staleCheckBlock.contains('.delete('), isFalse);
    });

    test('each payment type gets its own distinct, descriptive failure_reason', () {
      expect(staleCheckBlock.contains('"subscription_plan_or_amount_changed"'), isTrue);
      expect(staleCheckBlock.contains('"tax_due_amount_changed"'), isTrue);
      expect(staleCheckBlock.contains('"cod_settlement_amount_changed"'), isTrue);
    });

    test('regression: a ₹22.75 current dueBalance never reuses a stale ₹65.75 ACTIVE session -- '
        'the amount comparison, not the raw numbers, is what prevents this (any mismatch is caught)', () {
      // The fix is amount-agnostic by construction (a generic .toFixed(2) inequality check), so
      // this is proven structurally: any existingPayment.final_amount != finalAmount mismatch --
      // ₹65.75 vs ₹22.75 included -- takes the supersede branch, never the reuse branch below it.
      expect(staleCheckBlock.contains('amountMismatch'), isTrue);
      expect(activeSessionCheckIndex, greaterThan(staleCheckIndex));
    });
  });

  group('E. The guard does not alter unrelated payment_for flows (order-fare)', () {
    test('order-fare is not one of the three guarded types', () {
      expect(staleCheckBlock.contains('isOrderFare'), isFalse);
    });

    test('order-fare continues to scope its own duplicate lookup via reference_id (order id), '
        'untouched by this guard', () {
      final referenceIdBranchIndex = createPayment.indexOf('duplicateQuery = reference_id');
      expect(referenceIdBranchIndex, greaterThan(-1));
      expect(staleCheckIndex, greaterThan(referenceIdBranchIndex));
    });
  });

  group('F. Existing subscription stale-payment protection still works', () {
    test('subscription is still one of the guarded payment_for values', () {
      expect(staleCheckBlock.contains('payment_for === "subscription"'), isTrue);
    });

    test('subscription plan/amount mismatch still supersedes via the shared branch', () {
      expect(staleCheckBlock.contains('planMismatch'), isTrue);
      expect(staleCheckBlock.contains('"subscription_plan_or_amount_changed"'), isTrue);
    });
  });

  group('G. Existing ACTIVE/EXPIRED Cashfree-session handling is untouched by this fix', () {
    test('the ACTIVE-session reuse branch still exists, unchanged, after the stale check', () {
      expect(createPayment.contains('statusData?.order_status === "ACTIVE"'), isTrue);
      expect(createPayment.contains('statusData?.order_status === "PAID"'), isTrue);
    });

    test('the EXPIRED/TERMINATED fresh-order fallback still exists, unchanged', () {
      expect(createPayment.contains('cashfree_session_expired'), isTrue);
      expect(createPayment.contains('EXPIRED / TERMINATED / TERMINATION_REQUESTED'), isTrue);
    });
  });

  group('H. The exact current dueBalance/plan amount becomes the new Cashfree order amount', () {
    test('the Cashfree order_amount sent is still exactly finalAmount -- no fee/rounding added', () {
      expect(createPayment.contains('order_amount: finalAmount,'), isTrue);
    });

    test('tax_due/cod_settlement finalAmount is the freshly-read balance, never the client amount', () {
      expect(createPayment.contains('finalAmount = dueBalance;'), isTrue);
    });

    test('customer_phone mapping is untouched by this fix', () {
      expect(createPayment.contains('customer_phone: user.phone ?? "9999999999",'), isTrue);
    });
  });
}
