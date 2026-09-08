// Regression guard for the 2026-08-22 Cashfree hardening pass, Items 1 and 3 (Item 2 -- webhook
// timestamp freshness -- is explicitly OUT OF SCOPE and untouched; see the "Item 2 untouched" group
// below).
//
// ITEM 1 -- rider_subscription_history insert observability. The audit found (and this fix
// confirms, correcting the earlier audit's own inaccuracy) that a DB-level unique index --
// idx_unique_subscription_payment on rider_subscription_history(payment_id), defined in
// 20260529000000_baseline_foundational_schema.sql and confirmed present in
// migrations_baseline_wip/prod_schema_dump.sql -- already makes a duplicate payment_id insert
// impossible at the database level, even under a genuine verify-payment/cashfree-webhook race.
// NO migration and NO change to that index, to free-trial rows (payment_id IS NULL, unaffected by
// a unique index since Postgres never treats two NULLs as equal), or to subscription activation/
// duration logic. The only change: the insert's own `error` is now checked -- a 23505
// (unique_violation) is logged as an informational, expected idempotent-duplicate event instead of
// being silently discarded; any OTHER insert error is still logged loudly, not swallowed.
//
// PHASE 7A UPDATE: Item 1's exact code shape below was superseded by the broader Phase 7A
// subscription-entitlement-reliability fix (see
// test/phase7a_subscription_entitlement_reliability_regression_test.dart for that fix's own
// coverage), which extracted this logic into a shared `applySubscriptionEntitlement()` helper in
// each file and reordered the history INSERT to run before the `riders` UPDATE. Item 1's
// SUBSTANCE -- the 23505 duplicate is informational, any other insert error is logged loudly, no
// new migration/index -- is preserved and re-asserted below against the new shape; only the exact
// byte-for-byte code-shape assertions were updated to match.
//
// ITEM 3 -- payout 2FA (CASHFREE_PAYOUT_PUBLIC_KEY) fail-fast. The audit found this account has
// Payouts 2FA enabled (confirmed live in production, per the existing Get Beneficiary V2 lookup
// comment) -- every Beneficiary/Transfer call requires the RSA-OAEP X-Cf-Signature header derived
// from this key. Previously, a missing/empty key silently omitted the header rather than failing,
// producing a confusing generic Cashfree gateway error instead of a clear server-misconfiguration
// one. Fixed by extending the exact same fail-fast pattern already used for
// CASHFREE_PAYOUT_CLIENT_ID to this key too, in the same three places: create-rider-payout's single
// early check (covers its Delete/Add/Get-lookup calls, all of which happen after it), and BOTH of
// create-rider-withdrawal's two independent CLIENT_ID checks (its GET/sync handler and its POST/
// Create Transfer handler) -- the POST path additionally rolls back the wallet deduction via the
// existing fail_withdrawal() RPC, exactly like its own CLIENT_ID check does; the GET path needs no
// rollback since it never deducts a wallet balance. No new wallet/accounting mechanism, no change
// to signature generation, no change to any Cashfree endpoint, no change to payout amounts,
// beneficiary logic, or the 5 existing conditional signature blocks themselves.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final verifyPayment = _read('supabase/functions/verify-payment/index.ts');
  final cashfreeWebhook = _read('supabase/functions/cashfree-webhook/index.ts');
  final createRiderPayout = _read('supabase/functions/create-rider-payout/index.ts');
  final createRiderWithdrawal = _read('supabase/functions/create-rider-withdrawal/index.ts');

  group('Item 1: rider_subscription_history insert -- normal behavior unchanged', () {
    test('both files insert the exact same fields, unconditionally when no existing history row, '
        'via the shared applySubscriptionEntitlement helper', () {
      for (final source in [verifyPayment, cashfreeWebhook]) {
        expect(
          RegExp(
            r'const \{ error: historyInsertError \} = await supabaseAdmin\.from\("rider_subscription_history"\)\.insert\(\{\s*\n\s*rider_id: payment\.rider_id,\s*\n\s*amount: payment\.final_amount,\s*\n\s*payment_status: "paid",\s*\n\s*payment_id: payment\.id,\s*\n\s*starts_at: startsStr,\s*\n\s*expires_at: expiresStr,\s*\n\s*is_active: true,',
          ).hasMatch(source),
          isTrue,
          reason: 'the insert payload fields must be unchanged',
        );
      }
    });

    test('the existingHistory fast-path pre-check now also selects expires_at (needed to '
        'self-heal riders to the exact same value on retry, per Phase 7A) in both files', () {
      for (final source in [verifyPayment, cashfreeWebhook]) {
        expect(
          source.contains(
            'const { data: existingHistory, error: existingHistoryError } = await supabaseAdmin\n    .from("rider_subscription_history")\n    .select("id, expires_at")\n    .eq("payment_id", payment.id)\n    .maybeSingle();',
          ),
          isTrue,
        );
      }
    });
  });

  group('Item 1: 23505 duplicate is detected and logged as informational, not fatal', () {
    test('both files check the insert error and branch on code 23505', () {
      for (final source in [verifyPayment, cashfreeWebhook]) {
        expect(
          RegExp(
            r'if \(historyInsertError\) \{\s*\n\s*if \(historyInsertError\.code === "23505"\) \{\s*\n\s*// idx_unique_subscription_payment[\s\S]{0,600}console\.log\(',
          ).hasMatch(source),
          isTrue,
        );
        expect(source.contains('was a duplicate'), isTrue);
        expect(source.contains('Idempotent, no action needed'), isTrue);
      }
    });

    test('the duplicate case is never treated as a fatal subscription failure (no throw/error-status return in that branch)', () {
      for (final source in [verifyPayment, cashfreeWebhook]) {
        final dupLogIdx = source.indexOf('was a duplicate');
        expect(dupLogIdx, greaterThan(-1));
        // The 23505 branch is a plain console.log with no throw/500 in the next 300 chars.
        final branchSnippet = source.substring(dupLogIdx, (dupLogIdx + 300).clamp(0, source.length));
        expect(branchSnippet.contains('throw'), isFalse);
        expect(branchSnippet.contains('status: 500'), isFalse);
      }
    });
  });

  group('Item 1: other (non-23505) insert errors are NOT silently swallowed', () {
    test('both files log a real, non-swallowed error for any non-duplicate insert failure', () {
      for (final source in [verifyPayment, cashfreeWebhook]) {
        expect(
          source.contains('rider_subscription_history insert failed for payment'),
          isTrue,
        );
        // The non-duplicate branch is a console.error, not a silent no-op.
        final elseIdx = source.indexOf('} else {', source.indexOf('historyInsertError.code === "23505"'));
        final errorIdx = source.indexOf('console.error(', elseIdx);
        expect(elseIdx, greaterThan(-1));
        expect(errorIdx, greaterThan(elseIdx));
        expect(errorIdx - elseIdx, lessThan(50));
      }
    });
  });

  group('Item 1: both files contain the protection (parity check)', () {
    test('both verify-payment and cashfree-webhook have the 23505-aware insert', () {
      for (final source in [verifyPayment, cashfreeWebhook]) {
        expect(source.contains('historyInsertError.code === "23505"'), isTrue);
      }
    });
  });

  group('Item 1: untouched by this fix (explicit non-regression checks)', () {
    test('subscription duration/expiry calculation is unchanged', () {
      for (final source in [verifyPayment, cashfreeWebhook]) {
        expect(source.contains('computeSubscriptionExpiry(rider ?? null, plan.duration_hours, new Date())'), isTrue);
      }
    });

    test('subscription_active/subscription_expires_at write (first-touch activation) is unchanged', () {
      for (final source in [verifyPayment, cashfreeWebhook]) {
        expect(
          source.contains(
            'commission_waiver_active: true,\n      subscription_active: true,\n      subscription_expires_at: expiresStr,',
          ),
          isTrue,
        );
      }
    });

    test('the subscription_plans allowlist lookup (server-authoritative amount/duration) is unchanged', () {
      for (final source in [verifyPayment, cashfreeWebhook]) {
        expect(source.contains('.from("subscription_plans")'), isTrue);
        expect(source.contains('.eq("plan_id", planId)'), isTrue);
      }
    });

    test('free-trial activation (activate_rider_free_trial) is not referenced/touched by either payment function', () {
      for (final source in [verifyPayment, cashfreeWebhook]) {
        expect(source.contains('activate_rider_free_trial'), isFalse);
      }
    });

    test('payment verification / signature logic is untouched', () {
      expect(verifyPayment.contains('const verifyResponse = await fetchWithTimeout('), isTrue);
      expect(cashfreeWebhook.contains('async function computeSignature(rawBody: string, timestamp: string, secret: string)'), isTrue);
    });
  });

  group('Item 3: CASHFREE_PAYOUT_PUBLIC_KEY fail-fast -- create-rider-payout.dart (single check point)', () {
    test('the existing CASHFREE_PAYOUT_CLIENT_ID check is unchanged', () {
      expect(
        createRiderPayout.contains(
          'if (!cashfreeClientId) {\n      console.error("Missing CASHFREE_PAYOUT_CLIENT_ID secret!");\n      return Response.json(\n        { success: false, message: "Server configuration missing Client ID. Please contact support." },\n        { status: 500, headers: corsHeaders }\n      );\n    }',
        ),
        isTrue,
      );
    });

    test('a new fail-fast check exists for the public key, immediately after the client ID check', () {
      expect(
        createRiderPayout.contains(
          'if (!cashfreePublicKeyPEM || cashfreePublicKeyPEM.trim() === "") {\n      console.error("Missing CASHFREE_PAYOUT_PUBLIC_KEY secret!");\n      return Response.json(\n        { success: false, message: "Server configuration missing signing key. Please contact support." },\n        { status: 500, headers: corsHeaders }\n      );\n    }',
        ),
        isTrue,
      );
    });

    test('the fail-fast check runs before the first Cashfree beneficiary API call', () {
      final idxCheck = createRiderPayout.indexOf('Missing CASHFREE_PAYOUT_PUBLIC_KEY secret!');
      final idxFirstFetch = createRiderPayout.indexOf('cashfreeBaseUrl}/beneficiary');
      expect(idxCheck, greaterThan(-1));
      expect(idxFirstFetch, greaterThan(-1));
      expect(idxCheck, lessThan(idxFirstFetch));
    });

    test('the secret value itself is never interpolated into a log or response', () {
      // Only the boolean presence/emptiness check reads the variable; no log/response line embeds it.
      final checkBlockStart = createRiderPayout.indexOf('Missing CASHFREE_PAYOUT_PUBLIC_KEY secret!');
      final checkBlockEnd = createRiderPayout.indexOf('}', checkBlockStart + 400);
      final block = createRiderPayout.substring(checkBlockStart - 10, checkBlockEnd);
      expect(block.contains('\${cashfreePublicKeyPEM}'), isFalse);
      expect(block.contains('cashfreePublicKeyPEM}'), isFalse);
    });

    test('the existing 5 conditional signature blocks in this file are untouched (behavior unchanged when secret present)', () {
      expect(
        'if (cashfreePublicKeyPEM && cashfreePublicKeyPEM.trim() !== "")'.allMatches(createRiderPayout).length,
        equals(3),
        reason: 'create-rider-payout has 3 such blocks: Delete, Add, and the conflict-recovery lookup',
      );
    });
  });

  group('Item 3: CASHFREE_PAYOUT_PUBLIC_KEY fail-fast -- create-rider-withdrawal.dart (two check points)', () {
    test('the GET/sync path: existing CLIENT_ID check is unchanged', () {
      expect(
        createRiderWithdrawal.contains(
          'if (!cashfreeClientId) {\n        console.error("Missing CASHFREE_PAYOUT_CLIENT_ID secret for sync!");\n        return Response.json(\n          { success: false, message: "Server configuration missing client ID for sync." },\n          { status: 500, headers: corsHeaders }\n        );\n      }',
        ),
        isTrue,
      );
    });

    test('the GET/sync path: new public-key check exists and requires NO wallet rollback', () {
      expect(
        createRiderWithdrawal.contains(
          'if (!cashfreePublicKeyPEM || cashfreePublicKeyPEM.trim() === "") {\n        console.error("Missing CASHFREE_PAYOUT_PUBLIC_KEY secret for sync!");\n        return Response.json(\n          { success: false, message: "Server configuration missing signing key for sync." },\n          { status: 500, headers: corsHeaders }\n        );\n      }',
        ),
        isTrue,
      );
      // No fail_withdrawal call inside the sync-path check block specifically.
      final idx = createRiderWithdrawal.indexOf('Missing CASHFREE_PAYOUT_PUBLIC_KEY secret for sync!');
      final block = createRiderWithdrawal.substring(idx, idx + 250);
      expect(block.contains('fail_withdrawal'), isFalse);
    });

    test('the POST/Create Transfer path: existing CLIENT_ID check (with wallet rollback) is unchanged', () {
      expect(
        createRiderWithdrawal.contains(
          'if (!cashfreeClientId) {\n      console.error("Missing CASHFREE_PAYOUT_CLIENT_ID secret!");\n      // Revert wallet balance\n      await supabase.rpc("fail_withdrawal", {\n        p_withdrawal_id: withdrawal_id,\n        p_error_response: { error: "CASHFREE_PAYOUT_CLIENT_ID is not configured on the server" },\n      });',
        ),
        isTrue,
      );
    });

    test('the POST/Create Transfer path: new public-key check exists and DOES roll back the wallet via fail_withdrawal', () {
      expect(
        RegExp(
          r'if \(!cashfreePublicKeyPEM \|\| cashfreePublicKeyPEM\.trim\(\) === ""\) \{\s*\n\s*console\.error\("Missing CASHFREE_PAYOUT_PUBLIC_KEY secret!"\);\s*\n\s*// Revert wallet balance\s*\n\s*await supabase\.rpc\("fail_withdrawal", \{\s*\n\s*p_withdrawal_id: withdrawal_id,\s*\n\s*p_error_response: \{ error: "CASHFREE_PAYOUT_PUBLIC_KEY is not configured on the server" \},',
        ).hasMatch(createRiderWithdrawal),
        isTrue,
      );
    });

    test('the POST path check uses the exact same fail_withdrawal RPC name/shape as the existing CLIENT_ID rollback (no new mechanism)', () {
      expect('await supabase.rpc("fail_withdrawal", {'.allMatches(createRiderWithdrawal).length, greaterThanOrEqualTo(2));
    });

    test('both new checks run before their respective Cashfree API calls', () {
      final idxSyncCheck = createRiderWithdrawal.indexOf('Missing CASHFREE_PAYOUT_PUBLIC_KEY secret for sync!');
      final idxSyncFetch = createRiderWithdrawal.indexOf('/transfers?transfer_id=');
      expect(idxSyncCheck, greaterThan(-1));
      expect(idxSyncFetch, greaterThan(-1));
      expect(idxSyncCheck, lessThan(idxSyncFetch));

      final idxTransferCheck = createRiderWithdrawal.indexOf('Missing CASHFREE_PAYOUT_PUBLIC_KEY secret!');
      final idxTransferFetch = createRiderWithdrawal.indexOf('cashfreeBaseUrl}/transfers`');
      expect(idxTransferCheck, greaterThan(-1));
      expect(idxTransferFetch, greaterThan(-1));
      expect(idxTransferCheck, lessThan(idxTransferFetch));
    });

    test('the secret value itself is never interpolated into any new log or response', () {
      for (final marker in [
        'Missing CASHFREE_PAYOUT_PUBLIC_KEY secret for sync!',
        'Missing CASHFREE_PAYOUT_PUBLIC_KEY secret!',
      ]) {
        final idx = createRiderWithdrawal.indexOf(marker);
        final block = createRiderWithdrawal.substring(idx - 10, idx + 400);
        expect(block.contains('\${cashfreePublicKeyPEM}'), isFalse);
        expect(block.contains('cashfreePublicKeyPEM}'), isFalse);
      }
    });

    test('the existing 2 conditional signature blocks in this file are untouched (behavior unchanged when secret present)', () {
      expect(
        'if (cashfreePublicKeyPEM && cashfreePublicKeyPEM.trim() !== "")'.allMatches(createRiderWithdrawal).length,
        equals(2),
        reason: 'create-rider-withdrawal has 2 such blocks: the GET-sync status check and the POST Create Transfer call',
      );
    });
  });

  group('Item 3: untouched by this fix (explicit non-regression checks)', () {
    test('signature generation itself (generateSignature/importPublicKey) is byte-for-byte unchanged in both files', () {
      const sigFn = 'async function generateSignature(clientId: string, pemKey: string): Promise<string> {';
      const keyFn = 'async function importPublicKey(pem: string): Promise<CryptoKey> {';
      for (final source in [createRiderPayout, createRiderWithdrawal]) {
        expect(source.contains(sigFn), isTrue);
        expect(source.contains(keyFn), isTrue);
      }
    });

    test('Cashfree endpoints/base URLs are unchanged', () {
      expect(createRiderPayout.contains('https://api.cashfree.com/payout'), isTrue);
      expect(createRiderPayout.contains('https://sandbox.cashfree.com/payout'), isTrue);
      expect(createRiderWithdrawal.contains('https://api.cashfree.com/payout'), isTrue);
      expect(createRiderWithdrawal.contains('https://sandbox.cashfree.com/payout'), isTrue);
    });

    test('withdrawal amount/wallet math (initiate_withdrawal call site) is unchanged', () {
      expect(createRiderWithdrawal.contains('supabase.rpc(\n      "initiate_withdrawal",'), isTrue);
    });

    test('beneficiary registration payload shape is unchanged', () {
      expect(createRiderPayout.contains('beneficiary_instrument_details: instrumentDetails,'), isTrue);
    });
  });

  group('Item 2 untouched (webhook timestamp freshness -- explicitly out of scope for this change)', () {
    test('no timestamp-freshness/replay check was added to cashfree-webhook', () {
      expect(cashfreeWebhook.contains('Date.now() - '), isFalse);
      expect(cashfreeWebhook.contains('TOLERANCE'), isFalse);
      expect(cashfreeWebhook.toLowerCase().contains('stale'), isFalse);
      expect(cashfreeWebhook.toLowerCase().contains('replay'), isFalse);
    });

    test('the existing signature verification (unrelated to timestamp freshness) is unchanged', () {
      expect(
        cashfreeWebhook.contains(
          'const expectedSignature = await computeSignature(rawBody, timestamp, CASHFREE_SECRET_KEY);',
        ),
        isTrue,
      );
      expect(cashfreeWebhook.contains('if (!timingSafeEqual(expectedSignature, signature)) {'), isTrue);
    });
  });

  group('Business rules untouched (pricing/GST/government tax/commission/free-trial scope)', () {
    test('none of the four changed files reference pricing/GST/commission/dispatch business logic', () {
      for (final forbidden in [
        'calculate-order-pricing',
        'find_nearby_riders',
        'start-dispatch',
        'commission_percentage',
        'gst_percentage',
        'apply_order_government_tax',
        'complete_order_and_settle',
      ]) {
        for (final source in [verifyPayment, cashfreeWebhook, createRiderPayout, createRiderWithdrawal]) {
          expect(source.contains(forbidden), isFalse, reason: '"$forbidden" must not appear');
        }
      }
    });
  });
}
