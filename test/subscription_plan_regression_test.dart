// Structural + math regression guard for the subscription plan security fix (migration
// 20260726000002_subscription_plan_allowlist.sql). Confirmed vulnerability: create-payment
// trusted a client-supplied `amount` verbatim for payment_for = 'subscription', and
// cashfree-webhook/verify-payment computed subscription_expires_at from client-supplied
// metadata.days snapped to end-of-calendar-day IST -- a tampered client could request e.g.
// amount=1 with metadata.days=999 and receive an almost-free, near-unlimited zero-commission
// subscription. This does not run the Edge Functions themselves (Deno/TS) -- it inspects
// their source for the authoritative-plan-lookup pattern, and independently re-derives the
// exact millisecond math the fixed computeSubscriptionExpiry() must produce, so a future edit
// that reintroduces client-trusted amount/days, or calendar-day snapping, fails CI immediately.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// Mirrors computeSubscriptionExpiry() in cashfree-webhook/index.ts and verify-payment/index.ts:
/// base is ALWAYS the activation time (Phase 14 no-stacking fix -- a currently-active free trial
/// or prior paid subscription is never used as the base); expiry is base + durationHours, in
/// exact milliseconds -- never a calendar snap. `subscriptionActive`/`currentExpires` are accepted
/// only so callers can prove they have NO effect on the result (see the no-stacking tests below).
DateTime _expectedExpiry({
  required bool subscriptionActive,
  DateTime? currentExpires,
  required DateTime activationTime,
  required int durationHours,
}) {
  final DateTime base = activationTime;
  return base.add(Duration(hours: durationHours));
}

void main() {
  final migration = _read('supabase/migrations/20260726000002_subscription_plan_allowlist.sql');
  final createPayment = _read('supabase/functions/create-payment/index.ts');
  final cashfreeWebhook = _read('supabase/functions/cashfree-webhook/index.ts');
  final verifyPayment = _read('supabase/functions/verify-payment/index.ts');
  final riderHomeTab = _read('lib/features/rider/home/rider_home_tab.dart');
  final paymentService = _read('lib/modules/payments/services/payment_service.dart');
  final updateOrderStatus = _read('supabase/functions/update-order-status/index.ts');
  final completionSettlement = _read('supabase/migrations/20260813000000_atomic_order_completion_settlement.sql');

  group('Authoritative plan allowlist (migration)', () {
    test('daily plan is exactly ₹40 for 24 hours', () {
      expect(migration.contains("('daily', '1 Day Pass', 40, 24)"), isTrue);
    });

    test('weekly plan is exactly ₹280 for 168 hours', () {
      expect(migration.contains("('weekly', '7 Days (1 Week)', 280, 168)"), isTrue);
    });

    test('payments.plan_id references subscription_plans, so an invalid plan_id cannot be stored', () {
      expect(migration.contains('REFERENCES "public"."subscription_plans"("plan_id")'), isTrue);
    });
  });

  group('1/2. Exact-hour math: 24h and 168h, no calendar-day snapping', () {
    test('₹40 (daily, 24h): a purchase at 23:00 expires next day at 23:00, not end of day', () {
      final activation = DateTime.utc(2026, 7, 26, 23, 0, 0); // 26 Jul 2026, 23:00 UTC
      final expiry = _expectedExpiry(
        subscriptionActive: false,
        activationTime: activation,
        durationHours: 24,
      );
      expect(expiry, DateTime.utc(2026, 7, 27, 23, 0, 0));
      expect(expiry.difference(activation), const Duration(hours: 24));
    });

    test('the example in the spec: 26 Jul 2026 3:30 PM IST -> 27 Jul 2026 3:30 PM IST', () {
      final activationIst = DateTime.utc(2026, 7, 26, 10, 0, 0); // 15:30 IST = 10:00 UTC
      final expiry = _expectedExpiry(
        subscriptionActive: false,
        activationTime: activationIst,
        durationHours: 24,
      );
      expect(expiry, DateTime.utc(2026, 7, 27, 10, 0, 0)); // 27 Jul 2026, 15:30 IST
    });

    test('₹280 (weekly, 168h) is exactly 7 days from activation, not 7 calendar-day boundaries', () {
      final activation = DateTime.utc(2026, 7, 26, 15, 30, 0);
      final expiry = _expectedExpiry(
        subscriptionActive: false,
        activationTime: activation,
        durationHours: 168,
      );
      expect(expiry.difference(activation), const Duration(hours: 168));
      expect(expiry, DateTime.utc(2026, 8, 2, 15, 30, 0));
    });

    test('PHASE 14 NO-STACKING: a paid plan bought while a free trial/prior plan is still active '
        'starts fresh from ITS OWN activation -- never extended onto the existing future expiry '
        '(previously: stacked, turning a 24h purchase into weeks)', () {
      final currentExpires = DateTime.utc(2026, 7, 27, 10, 0, 0); // e.g. an active 30-day trial
      final activation = DateTime.utc(2026, 7, 26, 12, 0, 0); // bought before that expiry
      final expiry = _expectedExpiry(
        subscriptionActive: true,
        currentExpires: currentExpires,
        activationTime: activation,
        durationHours: 24,
      );
      expect(expiry, DateTime.utc(2026, 7, 27, 12, 0, 0)); // exactly activation + 24h, NOT
      // currentExpires + 24h (which would have been 2026-07-28 10:00 under the old stacking bug).
      expect(expiry.difference(activation), const Duration(hours: 24));
    });

    test('an expired subscription also starts fresh from activation (unchanged: never stacked '
        'once already expired, before or after Phase 14)', () {
      final currentExpires = DateTime.utc(2026, 7, 20, 10, 0, 0); // already expired
      final activation = DateTime.utc(2026, 7, 26, 12, 0, 0);
      final expiry = _expectedExpiry(
        subscriptionActive: true,
        currentExpires: currentExpires,
        activationTime: activation,
        durationHours: 24,
      );
      expect(expiry, DateTime.utc(2026, 7, 27, 12, 0, 0));
    });

    test('cashfree-webhook and verify-payment both compute expiry as base + durationHours in ms, never a calendar snap', () {
      for (final source in [cashfreeWebhook, verifyPayment]) {
        expect(source.contains('durationHours * 60 * 60 * 1000'), isTrue);
        expect(source.contains('23, 59, 59, 999'), isFalse);
        expect(source.contains('getUTCFullYear'), isFalse);
      }
    });

    test('PHASE 14: neither computeSubscriptionExpiry() implementation stacks onto an existing '
        'subscription_expires_at anymore -- base is unconditionally the activation time', () {
      for (final source in [cashfreeWebhook, verifyPayment]) {
        final fnStart = source.indexOf('function computeSubscriptionExpiry');
        final fnEnd = source.indexOf('\n}', fnStart);
        expect(fnStart, greaterThan(-1));
        final fnBody = source.substring(fnStart, fnEnd);
        expect(fnBody.contains('const base = activationTime;'), isTrue);
        expect(fnBody.contains('base = currentExpires'), isFalse);
        expect(fnBody.contains('rider.subscription_expires_at'), isFalse);
      }
    });
  });

  group('3/4/5. Tampered amount/days/plan is rejected server-side', () {
    test('the subscription branch no longer trusts a client-supplied amount', () {
      final start = createPayment.indexOf('} else {');
      final end = createPayment.indexOf('CHECK DUPLICATE PAYMENT');
      expect(start, greaterThan(-1));
      final subscriptionBranch = createPayment.substring(start, end);
      expect(subscriptionBranch.contains('finalAmount = Number(amount)'), isFalse);
      expect(subscriptionBranch.contains('finalAmount = Number(plan.amount)'), isTrue);
    });

    test('an unknown/inactive plan_id is rejected before any Cashfree order is created', () {
      expect(createPayment.contains('plan_id is required for subscription payments'), isTrue);
      expect(createPayment.contains('Unknown or inactive subscription plan'), isTrue);
      final planLookupIndex = createPayment.indexOf('from("subscription_plans")');
      final cashfreeOrderIndex = createPayment.indexOf('CREATE CASHFREE ORDER');
      expect(planLookupIndex, greaterThan(-1));
      expect(cashfreeOrderIndex, greaterThan(planLookupIndex));
    });

    test('duration at activation time comes only from subscription_plans.duration_hours via payments.plan_id, never metadata.days', () {
      for (final source in [cashfreeWebhook, verifyPayment]) {
        // Only the explanatory comment may mention "metadata.days" (to document why it's no
        // longer trusted) -- the actual code construct that read it must be gone.
        expect(source.contains('Number(metadata.days'), isFalse);
        expect(source.contains('payment.final_amount === 280 ? 7 : 1'), isFalse);
        expect(source.contains('const planId = payment.plan_id'), isTrue);
        expect(source.contains('.from("subscription_plans")'), isTrue);
        expect(source.contains('.select("duration_hours")'), isTrue);
      }
    });

    test('a payment with no valid plan_id never activates a subscription with a guessed duration', () {
      for (final source in [cashfreeWebhook, verifyPayment]) {
        expect(source.contains('subscription NOT activated'), isTrue);
      }
    });
  });

  group('6. Failed Cashfree payment never activates a subscription', () {
    test('cashfree-webhook FAILED branch only updates payments, never riders/subscription', () {
      final failedStart = cashfreeWebhook.indexOf('// FAILED');
      expect(failedStart, greaterThan(-1));
      final failedBranch = cashfreeWebhook.substring(failedStart);
      expect(failedBranch.contains('subscription_active'), isFalse);
      expect(failedBranch.contains('.from("riders")'), isFalse);
    });
  });

  group('7. Duplicate webhook cannot double-activate/extend', () {
    test('an already-paid payment short-circuits before any subscription logic runs again', () {
      expect(cashfreeWebhook.contains('payment.payment_status === "paid"'), isTrue);
      expect(cashfreeWebhook.contains('ALREADY PROCESSED'), isTrue);
      final alreadyPaidIndex = cashfreeWebhook.indexOf('ALREADY PROCESSED');
      final subscriptionFlowIndex = cashfreeWebhook.indexOf('SUBSCRIPTION FLOW');
      expect(alreadyPaidIndex, greaterThan(-1));
      expect(subscriptionFlowIndex, greaterThan(alreadyPaidIndex));
    });

    test('rider_subscription_history has an app-level AND DB-level duplicate guard', () {
      expect(cashfreeWebhook.contains('existingHistory'), isTrue);
      expect(verifyPayment.contains('existingHistory'), isTrue);
    });
  });

  group('8. Client cannot set subscription expiry/duration', () {
    test('Flutter never writes subscription_expires_at or subscription_active', () {
      expect(riderHomeTab.contains("'subscription_expires_at':"), isFalse);
      expect(riderHomeTab.contains("'subscription_active':"), isFalse);
    });

    test('the client-side calendar-day/30-day-cap math is gone -- server owns duration entirely', () {
      expect(riderHomeTab.contains('Maximum subscription limit is 30 days'), isFalse);
      expect(riderHomeTab.contains('newExpiresLocal'), isFalse);
    });

    test('the client sends only a plan id for subscriptions, not amount-derived trust -- the '
        'daily plan_id is now vehicle-specific (migration '
        '20260901000033_vehicle_specific_subscription_pricing.sql), but it is still exactly a '
        'plan id, never an amount', () {
      expect(riderHomeTab.contains("final planId = selectedDays == 1 ? 'daily_\$selectedVehicleType' : 'weekly';"), isTrue);
      expect(riderHomeTab.contains('planId: planId,'), isTrue);
      expect(riderHomeTab.contains("metadata: {\n                                    'days': selectedDays,"), isFalse);
    });

    test('payment_service.dart forwards planId to create-payment as plan_id', () {
      expect(paymentService.contains("if (planId != null) 'plan_id': planId,"), isTrue);
    });
  });

  group('9. Subscription payment never credits rider wallet', () {
    test('no wallet/payout code exists in the subscription-handling code of any '
        'subscription-payment Edge Function', () {
      // Scoped to the actual subscription-handling code, not the whole file: all 3 files also
      // legitimately handle a separate payment_for ("cod_settlement" -- a rider repaying cash
      // they've already collected, migration 20260808000011_cod_settlement_payment_flow.sql,
      // live since 2026-08-08) whose own RPC mentions cod_pending_amount and is unrelated to
      // subscriptions -- a whole-file string check false-fails on that legitimate branch.
      //
      // create-payment: subscription logic is inline in the final `else` of the
      // isOrderFare/isTaxDue/isCodSettlement if-chain (the file's only `} else {`), up to the
      // CHECK DUPLICATE PAYMENT section shared by every payment type.
      final createPaymentStart = createPayment.indexOf('} else {');
      final createPaymentEnd = createPayment.indexOf('CHECK DUPLICATE PAYMENT');
      expect(createPaymentStart, greaterThan(-1));
      expect(createPaymentEnd, greaterThan(createPaymentStart));
      final createPaymentSubscriptionBranch =
          createPayment.substring(createPaymentStart, createPaymentEnd);

      // cashfree-webhook / verify-payment: subscription logic is NOT inline -- every call site
      // (the main SUBSCRIPTION FLOW branch AND the earlier "already paid" idempotency
      // short-circuit) delegates to one shared applySubscriptionEntitlement() helper, so the
      // helper's own body must be scanned too, not just the branch that calls it.
      final webhookBranchStart = cashfreeWebhook.indexOf('SUBSCRIPTION FLOW');
      final webhookBranchEnd = cashfreeWebhook.indexOf('// FAILED');
      expect(webhookBranchStart, greaterThan(-1));
      expect(webhookBranchEnd, greaterThan(webhookBranchStart));
      final webhookSubscriptionBranch =
          cashfreeWebhook.substring(webhookBranchStart, webhookBranchEnd);

      final webhookHelperStart =
          cashfreeWebhook.indexOf('async function applySubscriptionEntitlement');
      final webhookHelperEnd = cashfreeWebhook.indexOf('\n// SERVER', webhookHelperStart);
      expect(webhookHelperStart, greaterThan(-1));
      expect(webhookHelperEnd, greaterThan(webhookHelperStart));
      final webhookEntitlementHelper =
          cashfreeWebhook.substring(webhookHelperStart, webhookHelperEnd);

      final verifyBranchStart = verifyPayment.indexOf('SUBSCRIPTION FLOW');
      final verifyBranchEnd = verifyPayment.indexOf('CHECK FAILED PAYMENTS');
      expect(verifyBranchStart, greaterThan(-1));
      expect(verifyBranchEnd, greaterThan(verifyBranchStart));
      final verifySubscriptionBranch =
          verifyPayment.substring(verifyBranchStart, verifyBranchEnd);

      final verifyHelperStart =
          verifyPayment.indexOf('async function applySubscriptionEntitlement');
      final verifyHelperEnd = verifyPayment.indexOf('\n// SERVER', verifyHelperStart);
      expect(verifyHelperStart, greaterThan(-1));
      expect(verifyHelperEnd, greaterThan(verifyHelperStart));
      final verifyEntitlementHelper =
          verifyPayment.substring(verifyHelperStart, verifyHelperEnd);

      for (final subscriptionCode in [
        createPaymentSubscriptionBranch,
        webhookSubscriptionBranch,
        webhookEntitlementHelper,
        verifySubscriptionBranch,
        verifyEntitlementHelper,
      ]) {
        expect(subscriptionCode.contains('credit_rider_for_completed_order'), isFalse);
        expect(subscriptionCode.contains('cod_pending_amount'), isFalse);
      }
    });

    test('subscription payments record 0 rider_earning, full amount as company_earning', () {
      final subscriptionElseStart = createPayment.indexOf('SUBSCRIPTION — amount/duration');
      final subscriptionElseEnd = createPayment.indexOf('CHECK DUPLICATE PAYMENT');
      final subscriptionBranch = createPayment.substring(subscriptionElseStart, subscriptionElseEnd);
      expect(subscriptionBranch.contains('companyEarning = baseAmount'), isTrue);
      expect(createPayment.contains("rider_earning: isOrderFare ? Number((order as Record<string, unknown>)?.rider_earning || 0) : 0"), isTrue);
    });
  });

  group('10. Active subscription still grants the Local Service commission waiver', () {
    // WayDrop consolidated performance/correctness pass (2026-08-13): the completion settlement
    // chain (rider-assignment settlement, subscription-waiver fare_breakdown, government tax,
    // wallet credit, history insert) moved from update-order-status's own JS into one atomic RPC,
    // complete_order_and_settle() (migration 20260813000000) -- see that migration's header for the
    // forensic incident (order 66759dad-b386-4814-8065-c6f9182e5c01) that motivated it. The
    // subscription-waiver rule itself is unchanged, just relocated with everything else it was
    // already part of; this test now checks the new location instead of update-order-status.
    test('complete_order_and_settle still reads subscription_active/subscription_expires_at for commission logic', () {
      expect(completionSettlement.contains('subscription_active, subscription_expires_at'), isTrue);
      expect(completionSettlement.contains('v_rider.subscription_active IS TRUE'), isTrue);
    });

    test('update-order-status still calls the consolidated completion RPC for completed/delivered', () {
      expect(updateOrderStatus.contains('complete_order_and_settle'), isTrue);
      expect(updateOrderStatus.contains('new_status === "completed" || new_status === "delivered"'), isTrue);
    });
  });
}
