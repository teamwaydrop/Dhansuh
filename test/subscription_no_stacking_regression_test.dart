// Structural + math regression guard for Phase 14: partner subscription 24-hour no-stacking fix.
//
// CONFIRMED PRODUCTION BUG: computeSubscriptionExpiry() (cashfree-webhook/index.ts,
// verify-payment/index.ts) stacked a new paid subscription's duration on top of an existing
// FUTURE subscription_expires_at -- including the 30-day free trial's expiry, since both write
// the exact same riders.subscription_active/subscription_expires_at columns. A rider on an active
// trial (expires ~Sep 20) who bought a 24-hour paid plan on Sep 5 saw "Active until 20 Sep" (a
// ~1-day extension of the trial) instead of the expected Sep 5 -> Sep 6.
//
// APPROVED BUSINESS RULE (Phase 14):
//   - Every successful paid subscription is valid for exactly activation_time + 24h, full stop --
//     never based on an existing free-trial or paid-subscription expiry (no stacking, ever).
//   - Buying while the free trial is active is still allowed (does not stack onto trial expiry).
//   - Buying while a PAID subscription is currently active is REJECTED server-side (not just
//     hidden in the UI) -- "Subscribe" only becomes available again after the current paid
//     subscription expires.
//
// This does not execute the Edge Functions (Deno/TS) -- it inspects source structure/ordering,
// the same style already used by subscription_plan_regression_test.dart and
// subscription_stale_pending_payment_regression_test.dart for this codebase.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final createPayment = _read('supabase/functions/create-payment/index.ts');
  final cashfreeWebhook = _read('supabase/functions/cashfree-webhook/index.ts');
  final verifyPayment = _read('supabase/functions/verify-payment/index.ts');
  final riderHomeTab = _read('lib/features/rider/home/rider_home_tab.dart');
  final freeTrialMigration = _read('supabase/migrations/20260901000016_rider_free_trial.sql');

  group('1/5. Fresh paid subscription: exactly activation_time + 24h', () {
    for (final source in [cashfreeWebhook, verifyPayment]) {
      test('base is unconditionally activationTime, never a reassigned/stacked value', () {
        final fnStart = source.indexOf('function computeSubscriptionExpiry');
        final fnEnd = source.indexOf('\n}', fnStart);
        expect(fnStart, greaterThan(-1));
        final fnBody = source.substring(fnStart, fnEnd);
        expect(fnBody.contains('const base = activationTime;'), isTrue);
        expect(fnBody.contains('let base'), isFalse);
        expect(fnBody.contains('durationHours * 60 * 60 * 1000'), isTrue);
      });
    }
  });

  group('2. Free trial active: paid subscription does NOT base off the trial expiry', () {
    test('computeSubscriptionExpiry never reads rider.subscription_expires_at anymore', () {
      for (final source in [cashfreeWebhook, verifyPayment]) {
        final fnStart = source.indexOf('function computeSubscriptionExpiry');
        final fnEnd = source.indexOf('\n}', fnStart);
        final fnBody = source.substring(fnStart, fnEnd);
        expect(fnBody.contains('rider.subscription_expires_at'), isFalse);
        expect(fnBody.contains('rider.subscription_active'), isFalse);
      }
    });

    test('buying while only the free trial is active is still permitted by the create-payment '
        'guard (it only blocks when the active expiry differs from free_trial_expires_at)', () {
      final guardStart = createPayment.indexOf('NO-STACKING / DOUBLE-SUBSCRIPTION GUARD');
      final guardEnd = createPayment.indexOf('const { data: plan, error: planError }', guardStart);
      expect(guardStart, greaterThan(-1));
      final guardBlock = createPayment.substring(guardStart, guardEnd);
      expect(
        guardBlock.contains('subRider.subscription_expires_at === subRider.free_trial_expires_at'),
        isTrue,
      );
      expect(guardBlock.contains('isCurrentlyActive && !isCurrentlyOnFreeTrial'), isTrue);
    });
  });

  group('3. Active PAID subscription: second purchase is rejected server-side', () {
    test('create-payment rejects a subscription purchase while a paid subscription is active', () {
      expect(createPayment.contains('isCurrentlyActive && !isCurrentlyOnFreeTrial'), isTrue);
      final guardStart = createPayment.indexOf('NO-STACKING / DOUBLE-SUBSCRIPTION GUARD');
      final rejectionIndex = createPayment.indexOf('status: 409', guardStart);
      expect(rejectionIndex, greaterThan(guardStart));
      expect(createPayment.contains('A new purchase is only allowed after it expires'), isTrue);
    });

    test('the guard runs before any Cashfree order can be created for the subscription branch', () {
      final guardIndex = createPayment.indexOf('NO-STACKING / DOUBLE-SUBSCRIPTION GUARD');
      final cashfreeOrderIndex = createPayment.indexOf('CREATE CASHFREE ORDER');
      expect(guardIndex, greaterThan(-1));
      expect(cashfreeOrderIndex, greaterThan(guardIndex));
    });
  });

  group('4. Expired paid subscription: new purchase allowed', () {
    test('the active-check requires subscription_expires_at strictly in the future', () {
      expect(createPayment.contains('new Date(subRider.subscription_expires_at) > new Date()'), isTrue);
    });
  });

  group('6/7. UI: Subscribe/Extend hidden while a PAID subscription is active, shown once expired', () {
    test('_isPaidSubscriptionActive exists and distinguishes paid-active from trial-active', () {
      expect(riderHomeTab.contains('static bool _isPaidSubscriptionActive'), isTrue);
      expect(
        riderHomeTab.contains("subExpires = rider?['subscription_expires_at']?.toString()"),
        isTrue,
      );
      expect(
        riderHomeTab.contains("trialExpires = rider?['free_trial_expires_at']?.toString()"),
        isTrue,
      );
    });

    test('the Extend button inside the active-subscription card is gated on !_isPaidSubscriptionActive', () {
      final isSubscribedBlockStart = riderHomeTab.indexOf("if (isSubscribed) {");
      final elseIfExpiredIndex = riderHomeTab.indexOf('} else if (hasSubscriptionRecord) {', isSubscribedBlockStart);
      expect(isSubscribedBlockStart, greaterThan(-1));
      expect(elseIfExpiredIndex, greaterThan(isSubscribedBlockStart));
      final activeCardBlock = riderHomeTab.substring(isSubscribedBlockStart, elseIfExpiredIndex);
      expect(activeCardBlock.contains('if (!_isPaidSubscriptionActive(rider)) ...['), isTrue);
      expect(activeCardBlock.contains("child: const Text('Extend'"), isTrue);
    });

    test('the expired-subscription card (hasSubscriptionRecord branch) always shows Extend, '
        'unconditionally -- expiry is exactly when Subscribe becomes available again', () {
      final elseIfExpiredIndex = riderHomeTab.indexOf('} else if (hasSubscriptionRecord) {');
      final expiredBlockEnd = riderHomeTab.indexOf("child: const Text('Extend'", elseIfExpiredIndex);
      expect(elseIfExpiredIndex, greaterThan(-1));
      expect(expiredBlockEnd, greaterThan(elseIfExpiredIndex));
      // No `_isPaidSubscriptionActive` gate between the expired-branch start and its Extend button.
      final expiredBranchSlice = riderHomeTab.substring(elseIfExpiredIndex, expiredBlockEnd);
      expect(expiredBranchSlice.contains('_isPaidSubscriptionActive'), isFalse);
    });
  });

  group('8. Webhook/verify idempotency remains intact', () {
    test('the existingHistory-by-payment_id self-heal path is unchanged', () {
      for (final source in [cashfreeWebhook, verifyPayment]) {
        expect(source.contains('existingHistory'), isTrue);
        expect(source.contains('idx_unique_subscription_payment'), isTrue);
        expect(source.contains('23505'), isTrue);
      }
    });
  });

  group('9. Existing subscription pricing remains unchanged', () {
    test('create-payment still resolves finalAmount only from plan.amount, no new adjustment', () {
      expect(createPayment.contains('finalAmount = Number(plan.amount);'), isTrue);
      expect(createPayment.contains('order_amount: finalAmount,'), isTrue);
    });
  });

  group('10. Existing free-trial creation remains intact', () {
    test('activate_rider_free_trial() migration is untouched by this fix', () {
      expect(freeTrialMigration.contains("v_expires := v_now + interval '30 days';"), isTrue);
      expect(freeTrialMigration.contains('free_trial_used = true'), isTrue);
      expect(
        freeTrialMigration.contains(
          "IF v_rider.subscription_active IS TRUE\n       AND v_rider.subscription_expires_at IS NOT NULL\n       AND v_rider.subscription_expires_at > v_now",
        ),
        isTrue,
      );
    });
  });

  group('11. Passenger/user subscription behavior is unchanged', () {
    test('the no-stacking/double-subscription guard appears exactly once, inside the subscription '
        'branch only -- order-fare/tax_due/cod_settlement (the other payment_for branches) are '
        'untouched by it', () {
      // Subscriptions (WayDrop MAX / commission waiver) are a rider-only product in this codebase
      // -- there is no separate passenger subscription purchase path -- so a guard scoped to
      // create-payment's single subscription branch cannot affect passenger/order-fare/tax_due/
      // cod_settlement payments by construction. This confirms it was added exactly once, not
      // duplicated into (or copy-pasted near) any other branch.
      final occurrences = 'NO-STACKING / DOUBLE-SUBSCRIPTION GUARD'.allMatches(createPayment).length;
      expect(occurrences, 1);
    });

    test('order-fare/tax_due/cod_settlement amount derivation is untouched by this fix', () {
      expect(createPayment.contains('finalAmount = Number(orderRow.final_fare ?? orderRow.current_fare ?? 0);'), isTrue);
      expect(createPayment.contains('finalAmount = dueBalance;'), isTrue);
    });
  });
}
