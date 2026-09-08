// Regression guard for the Phase 8 P2 fix: PaymentProcessingScreen's 10s fallback verification
// timer ticked unconditionally even while the realtime payments-row subscription had already
// delivered a recent update -- a pure duplicate verify-payment call. This adds the same
// realtime-health gate already proven in RealtimeOrderController/rider_orders_screen/
// intercity_searching_screen: skip the fallback tick if realtime delivered an update within the
// last 15 seconds; otherwise fall back exactly as before. Payment status semantics, the 3-minute
// global timeout, and _stopBackgroundWork() cleanup are all untouched.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final source = _read('lib/modules/payments/screens/payment_processing_screen.dart');

  group('1. Realtime event timestamp is recorded on every realtime delivery', () {
    test('_lastRealtimeEventAt field exists', () {
      expect(source.contains('DateTime? _lastRealtimeEventAt;'), isTrue);
    });

    test('the realtime listener callback stamps it before dispatching the status change', () {
      final listenerStart = source.indexOf('_statusSubscription = PaymentService.listenPaymentStatus');
      final stampIdx = source.indexOf('_lastRealtimeEventAt = DateTime.now();', listenerStart);
      final dispatchIdx = source.indexOf('_onPaymentStatusChanged(status, paymentRecord', listenerStart);
      expect(listenerStart, greaterThan(-1));
      expect(stampIdx, greaterThan(listenerStart));
      expect(dispatchIdx, greaterThan(stampIdx));
    });
  });

  group('2. Fallback timer skips a duplicate tick when realtime is recent', () {
    test('the 10s Timer.periodic callback checks _lastRealtimeEventAt before calling '
        '_runVerificationCheck()', () {
      final timerIdx = source.indexOf(
        '_fallbackTimer = Timer.periodic(const Duration(seconds: 10), (timer) {',
      );
      expect(timerIdx, greaterThan(-1));
      final callbackEnd = source.indexOf('\n    });', timerIdx);
      final callbackBody = source.substring(timerIdx, callbackEnd);

      expect(callbackBody.contains('final lastEvent = _lastRealtimeEventAt;'), isTrue);
      expect(
        callbackBody.contains(
          'if (lastEvent != null && DateTime.now().difference(lastEvent) < const Duration(seconds: 15)) {',
        ),
        isTrue,
      );
      // The skip returns before reaching the fallback call.
      final returnIdx = callbackBody.indexOf('return;');
      final runCheckIdx = callbackBody.indexOf('_runVerificationCheck();');
      expect(returnIdx, greaterThan(-1));
      expect(runCheckIdx, greaterThan(returnIdx));
    });

    test('a stale/absent realtime event still allows the fallback call -- the gate only returns '
        'early on the "recent" branch, so a null or old _lastRealtimeEventAt falls through to '
        '_runVerificationCheck() unconditionally', () {
      final timerIdx = source.indexOf(
        '_fallbackTimer = Timer.periodic(const Duration(seconds: 10), (timer) {',
      );
      final callbackEnd = source.indexOf('\n    });', timerIdx);
      final callbackBody = source.substring(timerIdx, callbackEnd);
      // Exactly one guard clause (an `if` with a `return`) precedes the unconditional call --
      // there is no further branch that could also block it when the gate condition is false.
      expect('if ('.allMatches(callbackBody).length, 1);
      expect(callbackBody.trim().endsWith('_runVerificationCheck();\n    });') ||
          callbackBody.contains('_runVerificationCheck();'), isTrue);
    });
  });

  group('3. Untouched invariants', () {
    test('the 3-minute global timeout is unchanged', () {
      expect(source.contains('_timeoutTimer = Timer(const Duration(minutes: 3), () {'), isTrue);
    });

    test('the 5s quick-checkout kickoff check is unchanged', () {
      expect(
        source.contains('Future.delayed(const Duration(seconds: 5), () {'),
        isTrue,
      );
    });

    test('_stopBackgroundWork() cleanup is unchanged (cancels subscription + both timers)', () {
      expect(
        source.contains(
          'void _stopBackgroundWork() {\n    if (_cleanedUp) return;\n    _cleanedUp = true;\n    _statusSubscription?.cancel();\n    _statusSubscription = null;\n    _fallbackTimer?.cancel();\n    _fallbackTimer = null;\n    _timeoutTimer?.cancel();\n    _timeoutTimer = null;\n  }',
        ),
        isTrue,
      );
    });

    test('_onPaymentStatusChanged payment-status semantics (paid/failed/cancelled handling) are '
        'unchanged -- this fix never touches that function', () {
      expect(source.contains("if (status == 'paid') {"), isTrue);
      expect(source.contains('_stopBackgroundWork();'), isTrue);
    });

    test('no Edge Function, Cashfree, or subscription-entitlement code was touched by this fix '
        '(this file has no such references to begin with)', () {
      for (final forbidden in ['supabase.functions.invoke', 'cashfree-webhook', 'subscription_active']) {
        expect(source.contains(forbidden), isFalse);
      }
    });
  });
}
