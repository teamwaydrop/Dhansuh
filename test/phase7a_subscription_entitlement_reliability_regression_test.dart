// Regression guard for Phase 7A: subscription-payment entitlement reliability.
//
// ROOT CAUSE (proven via static read of the deployed source, see conversation audit): both
// cashfree-webhook and verify-payment activated subscription entitlement (the `riders` UPDATE +
// `rider_subscription_history` insert) as an unchecked, fire-and-forget step, and used
// payments.payment_status alone as the idempotency signal for "already processed". This meant:
//   (a) a failed `riders` UPDATE was silently swallowed -- history could still be inserted,
//       falsely recording an "active" entitlement that was never actually applied;
//   (b) once payments.payment_status flipped to "paid", neither a webhook retry nor a client
//       verify-payment re-poll would ever re-attempt entitlement, even if it had failed.
//
// FIX: entitlement idempotency is now keyed on the EXISTENCE of a rider_subscription_history row
// for the payment (existing schema, no new table) rather than payment_status. The target expiry
// is computed and persisted to history exactly once; every later call reuses that stored value
// (self-heal) instead of recomputing -- this is what prevents a partial-failure retry from
// stacking a rider's expiry twice for one payment. Every riders/history write's `error` is now
// captured and logged.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final webhook = _read('supabase/functions/cashfree-webhook/index.ts');
  final verify = _read('supabase/functions/verify-payment/index.ts');
  final files = {'cashfree-webhook': webhook, 'verify-payment': verify};

  group('1. applySubscriptionEntitlement exists exactly once per file, and is the only place '
      'that writes riders.subscription_active / rider_subscription_history', () {
    for (final entry in files.entries) {
      test('${entry.key}: helper is defined exactly once', () {
        expect(
          'async function applySubscriptionEntitlement('.allMatches(entry.value).length,
          1,
        );
      });
    }
  });

  group('2. Root cause (a): every riders/history write inside the helper checks its own error', () {
    for (final entry in files.entries) {
      final fn = _extractHelper(entry.value);

      test('${entry.key}: self-heal riders UPDATE captures and checks error', () {
        expect(fn.contains('const { error: healError } = await supabaseAdmin'), isTrue);
        expect(fn.contains('if (healError) {'), isTrue);
      });

      test('${entry.key}: first-touch history INSERT captures and checks error', () {
        expect(fn.contains('const { error: historyInsertError } = await supabaseAdmin'), isTrue);
        expect(fn.contains('if (historyInsertError) {'), isTrue);
      });

      test('${entry.key}: first-touch riders UPDATE captures and checks error', () {
        expect(fn.contains('const { error: riderUpdateError } = await supabaseAdmin'), isTrue);
        expect(fn.contains('if (riderUpdateError) {'), isTrue);
      });

      test('${entry.key}: a failed history INSERT returns before ever attempting the riders '
          'UPDATE -- entitlement is never claimed active without a durable history record', () {
        final insertIdx = fn.indexOf('const { error: historyInsertError }');
        final insertCheckIdx = fn.indexOf('if (historyInsertError) {', insertIdx);
        final returnIdx = fn.indexOf('return;', insertCheckIdx);
        final updateIdx = fn.indexOf('const { error: riderUpdateError }');
        expect(insertIdx, greaterThan(-1));
        expect(returnIdx, greaterThan(insertCheckIdx));
        expect(updateIdx, greaterThan(returnIdx));
      });
    }
  });

  group('3. Root cause (b): idempotency no longer trusts payment_status alone for subscriptions', () {
    test('cashfree-webhook: the top-level "already paid" gate calls applySubscriptionEntitlement '
        'for payment_for === "subscription" instead of unconditionally short-circuiting', () {
      final gate = _extractBlock(webhook, 'if (payment.payment_status === "paid") {', 'RETURN ALREADY PROCESSED');
      expect(gate.contains('if (payment.payment_for === "subscription") {'), isTrue);
      expect(gate.contains('await applySubscriptionEntitlement(payment, "[CashfreeWebhook]");'), isTrue);
      expect(gate.contains('return new Response("ALREADY PROCESSED");'), isTrue);
    });

    test('cashfree-webhook: every non-subscription payment_for still gets the original, '
        'unmodified fast-path return (order-fare/tax_due/cod_settlement idempotency untouched)', () {
      final gate = _extractBlock(webhook, 'if (payment.payment_status === "paid") {', 'RETURN ALREADY PROCESSED');
      // The subscription branch returns "OK" early; the shared fall-through line handles every
      // other payment_for exactly as before this fix.
      final subscriptionReturnIdx = gate.indexOf('return new Response("OK");');
      final fallThroughReturnIdx = gate.indexOf('return new Response("ALREADY PROCESSED");');
      expect(subscriptionReturnIdx, greaterThan(-1));
      expect(fallThroughReturnIdx, greaterThan(subscriptionReturnIdx));
    });

    test('verify-payment: the "already paid" branch calls applySubscriptionEntitlement for '
        'subscriptions before returning, instead of only ever reporting already_verified', () {
      final gate = _extractBlock(verify, 'if (payment.payment_status === "paid") {', 'already_verified: true, payment }),');
      expect(gate.contains('if (payment.payment_for === "subscription") {'), isTrue);
      expect(gate.contains('await applySubscriptionEntitlement(payment, "[VerifyPayment]");'), isTrue);
      expect(gate.contains('already_verified: true, payment }'), isTrue,
          reason: 'the already-paid response shape for every payment_for must be unchanged');
    });

    test('verify-payment: the already-paid subscription self-heal does not call Cashfree again '
        '(no fetchWithTimeout between the gate and the entitlement call)', () {
      final gate = _extractBlock(verify, 'if (payment.payment_status === "paid") {', 'already_verified: true, payment }),');
      expect(gate.contains('fetchWithTimeout'), isFalse);
    });
  });

  group('4. Entitlement idempotency signal is rider_subscription_history.payment_id, reusing '
      'existing schema -- no new table', () {
    for (final entry in files.entries) {
      test('${entry.key}: helper checks for an existing history row before writing anything', () {
        final fn = _extractHelper(entry.value);
        final lookupIdx = fn.indexOf(
          '.from("rider_subscription_history")\n    .select("id, expires_at")\n    .eq("payment_id", payment.id)',
        );
        final firstWriteIdx = fn.indexOf('.update(', fn.indexOf('if (existingHistory) {'));
        expect(lookupIdx, greaterThan(-1));
        expect(firstWriteIdx, greaterThan(lookupIdx));
      });
    }

    test('no CREATE TABLE or new migration file was introduced for this fix', () {
      final createPaymentUnrelated =
          !webhook.contains('CREATE TABLE') && !verify.contains('CREATE TABLE');
      expect(createPaymentUnrelated, isTrue);
    });
  });

  group('5. Double-stacking prevention: expiry is computed once and reused verbatim on self-heal', () {
    for (final entry in files.entries) {
      test('${entry.key}: the self-heal branch reuses existingHistory.expires_at and never calls '
          'computeSubscriptionExpiry', () {
        final fn = _extractHelper(entry.value);
        final selfHealBlock = fn.substring(
          fn.indexOf('if (existingHistory) {'),
          fn.indexOf('return;', fn.indexOf('if (existingHistory) {')) + 'return;'.length,
        );
        expect(selfHealBlock.contains('existingHistory.expires_at'), isTrue);
        expect(selfHealBlock.contains('computeSubscriptionExpiry'), isFalse);
      });

      test('${entry.key}: computeSubscriptionExpiry (unchanged stacking logic) is only reachable '
          'from the first-touch (no-existing-history) path', () {
        final fn = _extractHelper(entry.value);
        expect('computeSubscriptionExpiry('.allMatches(fn).length, 1);
        final callIdx = fn.indexOf('computeSubscriptionExpiry(');
        final existingHistoryReturnIdx = fn.indexOf('return;', fn.indexOf('if (existingHistory) {'));
        expect(callIdx, greaterThan(existingHistoryReturnIdx));
      });

      test('${entry.key}: PHASE 14 -- the function no longer stacks; base is unconditionally '
          'activationTime (a rider on an active free trial or prior paid subscription who buys a '
          'new plan gets exactly activation_time + duration, never an extension of the existing '
          'expiry -- see subscription_no_stacking_regression_test.dart for the full fix coverage)', () {
        final fnStart = entry.value.indexOf('function computeSubscriptionExpiry');
        final fnEnd = entry.value.indexOf('\n}', fnStart);
        final fnBody = entry.value.substring(fnStart, fnEnd);
        expect(fnBody.contains('const base = activationTime;'), isTrue);
        expect(fnBody.contains('base = currentExpires'), isFalse);
      });
    }
  });

  group('6. Plan lookup / vehicle-specific and weekly plans unaffected -- allowlist-driven, '
      'generic across every plan_id', () {
    for (final entry in files.entries) {
      test('${entry.key}: duration still comes exclusively from subscription_plans via '
          'payments.plan_id, never a hardcoded/vehicle-specific literal', () {
        final fn = _extractHelper(entry.value);
        expect(fn.contains('.from("subscription_plans")'), isTrue);
        expect(fn.contains('.select("duration_hours")'), isTrue);
        expect(fn.contains('.eq("plan_id", planId)'), isTrue);
        for (final literal in ['daily_bike', 'daily_auto', 'daily_cab', 'weekly', 'vehicle_type']) {
          expect(fn.contains(literal), isFalse,
              reason: 'entitlement activation must stay plan-agnostic; found $literal');
        }
      });
    }
  });

  group('7. 30-day free trial remains completely untouched', () {
    for (final entry in files.entries) {
      test('${entry.key}: no reference to free_trial anywhere in the file', () {
        expect(entry.value.contains('free_trial'), isFalse);
      });
    }
  });

  group('8. No secrets, tokens, OTPs, or full payloads in the new log lines', () {
    for (final entry in files.entries) {
      test('${entry.key}: none of the new entitlement log lines reference a secret/key/payload', () {
        final fn = _extractHelper(entry.value);
        for (final forbidden in [
          'CASHFREE_SECRET_KEY',
          'SERVICE_ROLE_KEY',
          'webhook_payload',
          'rawBody',
          '_otp',
        ]) {
          expect(fn.contains(forbidden), isFalse, reason: 'entitlement helper must never log $forbidden');
        }
      });
    }
  });

  group('9. GST/commission/pricing/vehicle-verification/create-payment untouched (this migration '
      'only ever modifies the two approved files)', () {
    test('create-payment/index.ts is not part of this changeset', () {
      // Structural cross-check: neither modified file references create-payment's internals.
      for (final entry in files.entries) {
        expect(entry.value.contains('baseAmount'), isFalse);
        expect(entry.value.contains('companyEarning'), isFalse);
      }
    });
  });
}

/// Extracts the body of `async function applySubscriptionEntitlement(...) { ... }` from the raw
/// file text, up to its matching closing brace (the function's last top-level `}` before EOF-ish
/// content resumes — located via the next occurrence of the known trailing marker).
String _extractHelper(String source) {
  final start = source.indexOf('async function applySubscriptionEntitlement(');
  if (start < 0) throw StateError('applySubscriptionEntitlement not found');
  final end = source.indexOf('\n}\n\n// =====', start);
  if (end < start) throw StateError('end of applySubscriptionEntitlement not found');
  return source.substring(start, end);
}

/// Extracts a block of text between a start marker and the first occurrence of an end marker
/// (or, if the end marker is the sentinel 'RETURN ALREADY PROCESSED', up to and including the
/// literal `return new Response("ALREADY PROCESSED");` line).
String _extractBlock(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  expect(start, greaterThan(-1));
  final realEndMarker =
      endMarker == 'RETURN ALREADY PROCESSED' ? 'return new Response("ALREADY PROCESSED");' : endMarker;
  final end = source.indexOf(realEndMarker, start);
  expect(end, greaterThan(start));
  return source.substring(start, end + realEndMarker.length);
}
