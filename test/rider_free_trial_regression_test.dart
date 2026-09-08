// Structural regression guard for the WayDrop launch offer: a one-time, 30-day,
// zero-commission free trial granted on a new partner's first "Go Online".
//
// BUSINESS REQUIREMENT (see migration 20260901000016_rider_free_trial.sql):
//   - No payment/Cashfree checkout for an eligible partner's first Go Online.
//   - Enforced server-side: free_trial_used is a permanent, one-time flag, and
//     the grant RPC re-checks it (and any currently-active paid subscription)
//     inside the same transaction as the write, so it can never be re-granted
//     by going offline/online, reinstalling, logging out/in, or racing two
//     concurrent taps.
//   - Commission waiver reuses the EXISTING riders.subscription_active /
//     subscription_expires_at mechanism that every settlement path already
//     reads -- so this test also guards that the RPC writes exactly those two
//     columns (not a parallel, unenforced commission path) and that the
//     already-proven commission call sites are untouched.
//
// This does not run the Postgres function or the Flutter widget -- it inspects
// source for the specific patterns above, so a future edit that reintroduces a
// client-trusted grant, a resettable trial, or a parallel commission path fails
// CI immediately.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read('supabase/migrations/20260901000016_rider_free_trial.sql');
  final riderHomeTab = _read('lib/features/rider/home/rider_home_tab.dart');
  final paymentSettings = _read('lib/features/rider/settings/rider_payment_settings_screen.dart');
  final acceptOrder = _read('supabase/functions/accept-order/index.ts');
  final completionSettlement = _read('supabase/migrations/20260813000000_atomic_order_completion_settlement.sql');

  group('1. Schema: dedicated, permanent trial-tracking columns', () {
    test('riders gains free_trial_started_at/expires_at/used', () {
      expect(migration.contains('"free_trial_started_at" timestamp with time zone'), isTrue);
      expect(migration.contains('"free_trial_expires_at" timestamp with time zone'), isTrue);
      expect(migration.contains('"free_trial_used" boolean NOT NULL DEFAULT false'), isTrue);
    });
  });

  group('2. The trial columns are guarded exactly like other rider financial columns', () {
    test('protect_rider_financial_columns() also protects the 3 new columns', () {
      final fnStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.protect_rider_financial_columns');
      final fnEnd = migration.indexOf('activate_rider_free_trial');
      expect(fnStart, greaterThan(-1));
      final fnBody = migration.substring(fnStart, fnEnd);
      expect(fnBody.contains('NEW.free_trial_started_at IS DISTINCT FROM OLD.free_trial_started_at'), isTrue);
      expect(fnBody.contains('NEW.free_trial_expires_at IS DISTINCT FROM OLD.free_trial_expires_at'), isTrue);
      expect(fnBody.contains('NEW.free_trial_used IS DISTINCT FROM OLD.free_trial_used'), isTrue);
      // Same escape hatch as every other server-only writer -- never disabled.
      expect(fnBody.contains("auth.role() <> 'service_role'"), isTrue);
      expect(fnBody.contains("current_setting('app.bypass_rider_financial_guard', true)"), isTrue);
    });
  });

  group('3. Grant RPC is server-authoritative and one-time', () {
    test('resolves the caller\'s own rider row from auth.uid(), never a client-supplied id', () {
      final fnStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.activate_rider_free_trial');
      expect(fnStart, greaterThan(-1));
      final fnBody = migration.substring(fnStart);
      expect(fnBody.contains('WHERE r.user_id = auth.uid()'), isTrue);
      expect(fnBody.contains('FOR UPDATE'), isTrue);
    });

    test('the initial lookup is table-qualified, not a bare column list (regression: PL/pgSQL '
        'ambiguous-column-reference bug confirmed live against TEST -- RETURNS TABLE(...) '
        'implicitly declares subscription_active/subscription_expires_at as variables in scope, '
        'colliding with the identically-named riders columns in an unqualified SELECT)', () {
      final fnStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.activate_rider_free_trial');
      final fnBody = migration.substring(fnStart);
      expect(fnBody.contains('SELECT r.id, r.free_trial_used, r.subscription_active, r.subscription_expires_at'), isTrue);
      expect(fnBody.contains('FROM public.riders r'), isTrue);
      expect(fnBody.contains('SELECT id, free_trial_used, subscription_active, subscription_expires_at\n'), isFalse);
    });

    test('an already-used trial is rejected before any write', () {
      final fnStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.activate_rider_free_trial');
      final fnBody = migration.substring(fnStart);
      final usedCheck = fnBody.indexOf('IF v_rider.free_trial_used THEN');
      final firstUpdate = fnBody.indexOf('UPDATE public.riders');
      expect(usedCheck, greaterThan(-1));
      expect(firstUpdate, greaterThan(usedCheck));
    });

    test('an active paid subscription is never replaced by the trial', () {
      final fnStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.activate_rider_free_trial');
      final fnBody = migration.substring(fnStart);
      expect(fnBody.contains("'already_subscribed'"), isTrue);
      expect(fnBody.contains('v_rider.subscription_active IS TRUE'), isTrue);
      expect(fnBody.contains('v_rider.subscription_expires_at > v_now'), isTrue);
    });

    test('free_trial_used is set true in the SAME update as the grant, not separately', () {
      final fnStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.activate_rider_free_trial');
      final fnBody = migration.substring(fnStart);
      final updateStart = fnBody.indexOf('UPDATE public.riders');
      final updateEnd = fnBody.indexOf('WHERE id = v_rider.id');
      expect(updateStart, greaterThan(-1));
      final updateStatement = fnBody.substring(updateStart, updateEnd);
      expect(updateStatement.contains('free_trial_used = true'), isTrue);
      expect(updateStatement.contains('subscription_active = true'), isTrue);
      expect(updateStatement.contains('subscription_expires_at = v_expires'), isTrue);
    });

    test('the trial window is exactly 30 days from activation, not a client-supplied value', () {
      expect(migration.contains("v_expires := v_now + interval '30 days';"), isTrue);
    });

    test('is granted to authenticated (rider-callable directly, no Cashfree round trip needed)', () {
      expect(migration.contains('GRANT EXECUTE ON FUNCTION public.activate_rider_free_trial() TO authenticated'), isTrue);
    });
  });

  group('4. Commission waiver reuses the existing, already-proven mechanism', () {
    test('the migration does not touch accept-order or complete_order_and_settle commission logic', () {
      // The whole point of reusing subscription_active/subscription_expires_at is that these
      // already-authoritative commission call sites need zero changes -- guard that they still
      // contain their original check, unmodified by this feature.
      expect(acceptOrder.contains('rider.subscription_active === true'), isTrue);
      expect(acceptOrder.contains('rider.subscription_expires_at'), isTrue);
      expect(completionSettlement.contains('v_rider.subscription_active IS TRUE'), isTrue);
    });
  });

  group('5. Flutter: no payment order for an eligible free-trial partner', () {
    test('the free trial sheet never calls PaymentService.startPayment or Cashfree', () {
      final sheetStart = riderHomeTab.indexOf('void _showFreeTrialBottomSheet()');
      final sheetEnd = riderHomeTab.indexOf('void _showFreeTrialActivatedDialog');
      expect(sheetStart, greaterThan(-1));
      expect(sheetEnd, greaterThan(sheetStart));
      final sheetBody = riderHomeTab.substring(sheetStart, sheetEnd);
      expect(sheetBody.contains('PaymentService.startPayment'), isFalse);
      expect(sheetBody.contains('cashfree'), isFalse);
      expect(sheetBody.contains("supabase.rpc('activate_rider_free_trial')"), isTrue);
    });

    test('the free trial sheet calls the shared _bringRiderOnline() atomic go-online path', () {
      final sheetStart = riderHomeTab.indexOf('void _showFreeTrialBottomSheet()');
      final sheetEnd = riderHomeTab.indexOf('void _showFreeTrialActivatedDialog');
      final sheetBody = riderHomeTab.substring(sheetStart, sheetEnd);
      expect(sheetBody.contains('await _bringRiderOnline();'), isTrue);
    });

    test('Flutter never writes free_trial_used/started_at/expires_at directly', () {
      expect(riderHomeTab.contains("'free_trial_used':"), isFalse);
      expect(riderHomeTab.contains("'free_trial_started_at':"), isFalse);
      expect(riderHomeTab.contains("'free_trial_expires_at':"), isFalse);
    });
  });

  group('6. Go-online routing: eligible partners skip the paid MAX sheet entirely', () {
    test('toggleOnlineStatus checks free-trial eligibility before falling back to the paid sheet', () {
      final toggleStart = riderHomeTab.indexOf('Future<void> toggleOnlineStatus()');
      final toggleEnd = riderHomeTab.indexOf('Future<bool> _bringRiderOnline()');
      expect(toggleStart, greaterThan(-1));
      final toggleBody = riderHomeTab.substring(toggleStart, toggleEnd);
      expect(toggleBody.contains('_isFreeTrialEligible(rider)'), isTrue);
      expect(toggleBody.contains('_showFreeTrialBottomSheet()'), isTrue);
      expect(toggleBody.contains('_showSubscriptionBottomSheet(goingOnline: true)'), isTrue);
      // Trial branch must be checked before falling back to the paid sheet.
      final eligibleIdx = toggleBody.indexOf('_isFreeTrialEligible(rider)');
      final paidSheetIdx = toggleBody.indexOf('_showSubscriptionBottomSheet(goingOnline: true)');
      expect(eligibleIdx, lessThan(paidSheetIdx));
    });

    test('eligibility is read from the server-written free_trial_used field, not derived/guessed', () {
      expect(riderHomeTab.contains("rider?['free_trial_used'] != true"), isTrue);
    });
  });

  group('7. Remaining trial time is always computed live, never hard-coded', () {
    test('_freeTrialDaysRemaining derives from free_trial_expires_at, not a literal 30', () {
      final fnStart = riderHomeTab.indexOf('static int _freeTrialDaysRemaining');
      final fnEnd = riderHomeTab.indexOf('void _showAddUpiVpaSheet()');
      expect(fnStart, greaterThan(-1));
      expect(fnEnd, greaterThan(fnStart));
      final fnBody = riderHomeTab.substring(fnStart, fnEnd);
      expect(fnBody.contains("rider?['free_trial_expires_at']"), isTrue);
      expect(fnBody.contains('DateTime.tryParse'), isTrue);
      expect(fnBody.contains('inSeconds'), isTrue);
    });
  });

  group('8. RPC call fires only on explicit button tap, never merely on sheet open', () {
    test('activate_rider_free_trial is only called inside the primary button onPressed handler', () {
      final sheetStart = riderHomeTab.indexOf('void _showFreeTrialBottomSheet()');
      final sheetEnd = riderHomeTab.indexOf('void _showFreeTrialActivatedDialog');
      final buttonStart = riderHomeTab.indexOf('onPressed: sheetProcessing', sheetStart);
      expect(buttonStart, greaterThan(-1));
      expect(buttonStart, lessThan(sheetEnd));
      // Nothing between the sheet function's start and its primary button's onPressed may call
      // the RPC -- i.e. the call site is strictly inside the button handler, not in the
      // showModalBottomSheet/builder setup that runs the instant the sheet opens.
      final beforeButton = riderHomeTab.substring(sheetStart, buttonStart);
      expect(beforeButton.contains("supabase.rpc('activate_rider_free_trial')"), isFalse);
      final buttonBody = riderHomeTab.substring(buttonStart, sheetEnd);
      expect(buttonBody.contains("supabase.rpc('activate_rider_free_trial')"), isTrue);
    });

    test('"Maybe later" never calls the RPC or _bringRiderOnline -- rider stays offline, trial untouched', () {
      final maybeLaterStart = riderHomeTab.indexOf("'Maybe later'");
      // Search the TextButton's own onPressed, immediately preceding this label in source.
      final onPressedStart = riderHomeTab.lastIndexOf('onPressed:', maybeLaterStart);
      final snippet = riderHomeTab.substring(onPressedStart, maybeLaterStart);
      expect(snippet.contains('activate_rider_free_trial'), isFalse);
      expect(snippet.contains('_bringRiderOnline'), isFalse);
      expect(snippet.contains('Navigator.pop(sheetCtx)'), isTrue);
    });
  });

  group('9. RPC failure never shows raw exception text or marks the trial active', () {
    test('the catch block shows a friendly message, not the interpolated exception', () {
      final sheetStart = riderHomeTab.indexOf('void _showFreeTrialBottomSheet()');
      final sheetEnd = riderHomeTab.indexOf('void _showFreeTrialActivatedDialog');
      final sheetBody = riderHomeTab.substring(sheetStart, sheetEnd);
      final catchStart = sheetBody.indexOf('} catch (e) {');
      expect(catchStart, greaterThan(-1));
      final catchBody = sheetBody.substring(catchStart);
      expect(catchBody.contains(r"Text('Could not activate free trial: $e')"), isFalse);
      // The SnackBar shown to the rider (inside showSnackBar(...)) must never interpolate the raw
      // exception -- a debugPrint of $e just above it, for developer-only console diagnostics, is
      // fine and expected, so this is scoped to the showSnackBar(...) call specifically rather
      // than the whole catch block.
      final showSnackBarStart = catchBody.indexOf('showSnackBar(');
      expect(showSnackBarStart, greaterThan(-1));
      final snackBarCall = catchBody.substring(showSnackBarStart);
      expect(snackBarCall.contains(r'$e'), isFalse);
      expect(catchBody.contains('_bringRiderOnline'), isFalse);
    });
  });

  group('10. Success messaging matches the required copy', () {
    test('the activation dialog announces the trial and 0% commission clearly', () {
      final dialogStart = riderHomeTab.indexOf('void _showFreeTrialActivatedDialog');
      expect(dialogStart, greaterThan(-1));
      final dialogBody = riderHomeTab.substring(dialogStart, dialogStart + 2000);
      expect(dialogBody.contains('30 Days Free Activated'), isTrue);
      expect(dialogBody.contains('0% company commission'), isTrue);
    });

    test('the home banner shows "30 Days Free • 0% Commission" and a live days-remaining line', () {
      expect(riderHomeTab.contains('30 Days Free • 0% Commission'), isTrue);
      expect(riderHomeTab.contains('remaining • Until \$expirationText'), isTrue);
    });
  });

  group('11. "Activated" success is never claimed unless the rider actually went online '
      '(regression: production incident where the sheet showed "30 Days Free Activated!" and '
      'closed even when GPS/location was unavailable, because the trialActivated branch called '
      '_bringRiderOnline() without inspecting its bool result -- the rider stayed offline while the '
      'UI reported success)', () {
    test('_bringRiderOnline()\'s return value is captured, not discarded', () {
      final sheetStart = riderHomeTab.indexOf('void _showFreeTrialBottomSheet()');
      final sheetEnd = riderHomeTab.indexOf('void _showFreeTrialActivatedDialog');
      final trialActivatedStart = riderHomeTab.indexOf('if (trialActivated) {', sheetStart);
      expect(trialActivatedStart, greaterThan(-1));
      expect(trialActivatedStart, lessThan(sheetEnd));
      final branchBody = riderHomeTab.substring(trialActivatedStart, sheetEnd);
      expect(branchBody.contains('final wentOnline = await _bringRiderOnline();'), isTrue);
    });

    test('the "30 Days Free Activated!" dialog is only shown when wentOnline is true', () {
      final sheetStart = riderHomeTab.indexOf('void _showFreeTrialBottomSheet()');
      final sheetEnd = riderHomeTab.indexOf('void _showFreeTrialActivatedDialog');
      final trialActivatedStart = riderHomeTab.indexOf('if (trialActivated) {', sheetStart);
      final branchBody = riderHomeTab.substring(trialActivatedStart, sheetEnd);
      final wentOnlineCheck = branchBody.indexOf('if (wentOnline) {');
      final dialogCall = branchBody.indexOf('_showFreeTrialActivatedDialog(expiresAtStr);');
      expect(wentOnlineCheck, greaterThan(-1));
      expect(dialogCall, greaterThan(wentOnlineCheck));
      // And the failure branch must show a distinct message, not silently do nothing --
      // the rider needs to know the trial is banked and to retry going online.
      expect(branchBody.contains('Tap Go Online again once location is available'), isTrue);
    });
  });

  group('12. Active free trial never re-triggers the UPI/payment-setup prompt '
      '(regression: a partner who finished onboarding with bank-only payout -- Payout Details '
      'labels UPI "Personal UPI (Optional)" -- was blocked from going online and re-prompted for '
      'UPI every single time, because toggleOnlineStatus required upi_vpa unconditionally for every '
      '"subscribed" rider, and an active free trial IS subscription_active=true)', () {
    test('the UPI-vpa gate is skipped while _isFreeTrialActive(rider) is true', () {
      final anchor = riderHomeTab.indexOf('A passenger paying via UPI intent needs somewhere');
      expect(anchor, greaterThan(-1));
      final blockEnd = riderHomeTab.indexOf('await _bringRiderOnline();', anchor);
      expect(blockEnd, greaterThan(anchor));
      final nearby = riderHomeTab.substring(anchor, blockEnd);
      expect(nearby.contains('if (riderId != null && !_isFreeTrialActive(rider)) {'), isTrue);
    });

    test('paid-subscriber UPI gating is untouched -- the skip is scoped to the free trial only, '
        'not to isSubscribed/subscription_active in general', () {
      // A bare `if (riderId != null) {` immediately preceding the upi_vpa lookup would mean the
      // free-trial condition was dropped again; the ONLY acceptable guard combines both.
      final anchor = riderHomeTab.indexOf('A passenger paying via UPI intent needs somewhere');
      final blockEnd = riderHomeTab.indexOf('await _bringRiderOnline();', anchor);
      final nearby = riderHomeTab.substring(anchor, blockEnd);
      expect(nearby.contains('if (riderId != null) {\n'), isFalse);
    });

    test('GO ONLINE during an active trial reaches _bringRiderOnline() directly, with the UPI '
        'check and _showAddUpiVpaSheet() both structurally skippable in that path', () {
      final toggleStart = riderHomeTab.indexOf('Future<void> toggleOnlineStatus()');
      final toggleEnd = riderHomeTab.indexOf('Future<bool> _bringRiderOnline()');
      final toggleBody = riderHomeTab.substring(toggleStart, toggleEnd);
      final upiGateIdx = toggleBody.indexOf('_isFreeTrialActive(rider)');
      final bringOnlineCallIdx = toggleBody.lastIndexOf('await _bringRiderOnline();');
      expect(upiGateIdx, greaterThan(-1));
      expect(bringOnlineCallIdx, greaterThan(upiGateIdx));
    });
  });

  group('13. Payment Settings remains the only voluntary UPI-change surface, reusing the same '
      'field the go-online gate reads -- no duplicate/parallel UPI state was introduced', () {
    test('Payment Settings still reads and can update rider_payout_accounts.upi_vpa', () {
      expect(paymentSettings.contains('rider_payout_accounts'), isTrue);
      expect(paymentSettings.contains("'upi_vpa'"), isTrue);
    });

    test('toggleOnlineStatus only ever reads upi_vpa (a .select), never writes it -- going online '
        'can never silently change a partner\'s saved UPI', () {
      final toggleStart = riderHomeTab.indexOf('Future<void> toggleOnlineStatus()');
      final toggleEnd = riderHomeTab.indexOf('Future<bool> _bringRiderOnline()');
      final toggleBody = riderHomeTab.substring(toggleStart, toggleEnd);
      expect(toggleBody.contains("select('upi_vpa')"), isTrue);
      expect(toggleBody.contains("'upi_vpa':"), isFalse);
    });
  });

  group('14. Free-trial sheet clearly distinguishes 0% company commission from applicable '
      'government tax/GST -- never implies tax itself is waived', () {
    test('the sheet states the required commission and tax-transparency copy', () {
      final sheetStart = riderHomeTab.indexOf('void _showFreeTrialBottomSheet()');
      final sheetEnd = riderHomeTab.indexOf('void _showFreeTrialActivatedDialog');
      final sheetBody = riderHomeTab.substring(sheetStart, sheetEnd);
      expect(sheetBody.contains('0% Company Commission'), isTrue);
      expect(sheetBody.contains('You pay ₹0 company commission during your free 30-day period.'), isTrue);
      // Source-text check: the tax note is written as adjacent Dart string literals (wrapped
      // across multiple lines in source), so each literal fragment is checked separately rather
      // than as one impossible concatenated match against raw file text.
      expect(
        sheetBody.contains('Government taxes/GST are separate from company commission and will be handled '),
        isTrue,
      );
      expect(
        sheetBody.contains('according to applicable GST rules. See your earnings breakdown for applicable '),
        isTrue,
      );
      expect(sheetBody.contains("'deductions/settlement.',"), isTrue);
      expect(sheetBody.contains('Your 30-day free period starts when you activate it.'), isTrue);
      expect(sheetBody.contains('ACTIVATE & GO ONLINE'), isTrue);
    });

    test('the sheet never claims government tax itself is free, waived, or zero -- only company '
        'commission is', () {
      final sheetStart = riderHomeTab.indexOf('void _showFreeTrialBottomSheet()');
      final sheetEnd = riderHomeTab.indexOf('void _showFreeTrialActivatedDialog');
      final sheetLower = riderHomeTab.substring(sheetStart, sheetEnd).toLowerCase();
      expect(sheetLower.contains('tax is free'), isFalse);
      expect(sheetLower.contains('tax-free'), isFalse);
      expect(sheetLower.contains('no tax'), isFalse);
      expect(sheetLower.contains('everything is free'), isFalse);
      expect(sheetLower.contains('no deductions'), isFalse);
      // The one legally-loaded claim this task explicitly forbids hard-coding without the
      // underlying tax structure actually establishing it -- the partner must never be told they
      // personally pay/owe GST (a "you pay ... GST" style claim), only that GST is separate and
      // handled per applicable rules.
      expect(sheetLower.contains('section 9(5)'), isFalse);
      expect(sheetLower.contains('you pay gst'), isFalse);
      expect(sheetLower.contains('gst payable'), isFalse);
      expect(sheetLower.contains('you owe'), isFalse);
    });

    test('the activated dialog restates the same commission-vs-tax distinction', () {
      final dialogStart = riderHomeTab.indexOf('void _showFreeTrialActivatedDialog');
      final dialogEnd = riderHomeTab.indexOf('Future<void> _showSubscriptionBottomSheet', dialogStart);
      final dialogBody = riderHomeTab.substring(dialogStart, dialogEnd > dialogStart ? dialogEnd : dialogStart + 3000);
      expect(dialogBody.contains('0% company commission'), isTrue);
      expect(
        dialogBody.contains('Applicable government taxes/GST remain separate from company commission.'),
        isTrue,
      );
    });
  });

  group('15. Paid-subscription flow is unaffected by this fix', () {
    test('_showSubscriptionBottomSheet still routes to the paid MAX flow when the free trial is '
        'not eligible/active -- now async (Future<void>) to load vehicle-specific pricing before '
        'opening, per the vehicle-specific subscription pricing work '
        '(20260901000033_vehicle_specific_subscription_pricing.sql); its goingOnline parameter '
        'and role in the go-online flow are otherwise unchanged', () {
      expect(riderHomeTab.contains('Future<void> _showSubscriptionBottomSheet({bool goingOnline = false}) async {'), isTrue);
      final toggleStart = riderHomeTab.indexOf('Future<void> toggleOnlineStatus()');
      final toggleEnd = riderHomeTab.indexOf('Future<bool> _bringRiderOnline()');
      final toggleBody = riderHomeTab.substring(toggleStart, toggleEnd);
      expect(toggleBody.contains('_showSubscriptionBottomSheet(goingOnline: true)'), isTrue);
    });
  });
}
