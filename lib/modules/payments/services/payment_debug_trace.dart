import 'package:flutter/foundation.dart';

// =====================================================================================
// TEMPORARY RUNTIME INSTRUMENTATION -- added on 2026-07-30 to capture exact runtime evidence
// for the Driver Subscription and Government Tax Due payment flows, per explicit request. Remove
// this file and every PaymentTrace.* call site once the runtime issue is diagnosed.
//
// PaymentService / PaymentProcessingScreen are shared by EVERY payment type (subscription,
// tax_due, order fare, driver QR) -- there is no way to instrument only two of them without
// duplicating that shared code, which was explicitly not wanted. Every log line below is
// therefore tagged with a `flow` string (the payment_for value, or widget.paymentForLabel) so
// subscription/tax_due entries can be filtered out of the full run log, e.g. grep for
// "[PAY-TRACE][subscription]" or "[PAY-TRACE][tax_due]".
//
// 2026-08-31: gated behind kDebugMode so payment session/order/amount identifiers are never
// logged in release builds, without touching any of the call sites below.
// =====================================================================================
class PaymentTrace {
  PaymentTrace._();

  // Canonical expected order of steps for a single payment attempt, used only to guess "NEXT
  // STEP NEVER EXECUTED" when a catch block or early return fires. CASHFREE_SUCCESS_CALLBACK /
  // CASHFREE_FAILURE_CALLBACK / VERIFY_PAYMENT_* / REALTIME_UPDATE / POLLING_UPDATE can legitimately
  // race each other in real execution -- treat the guess as a hint, not gospel.
  static const List<String> _expectedOrder = [
    'BUTTON_CLICKED',
    'PAYMENT_TYPE',
    'AMOUNT',
    'START_PAYMENT_ENTER',
    'EDGE_FUNCTION_REQUEST',
    'EDGE_FUNCTION_RESPONSE',
    'ORDER_ID',
    'PAYMENT_SESSION_ID',
    'NAVIGATE_TO_PROCESSING_SCREEN',
    'OPEN_PAYMENT_ENTER',
    'BEFORE_CFSESSIONBUILDER',
    'AFTER_CFSESSIONBUILDER',
    'BEFORE_CFWEBCHECKOUTPAYMENTBUILDER',
    'AFTER_CFWEBCHECKOUTPAYMENTBUILDER',
    'BEFORE_DOPAYMENT',
    'AFTER_DOPAYMENT',
    'CASHFREE_SUCCESS_CALLBACK',
    'CASHFREE_FAILURE_CALLBACK',
    'VERIFY_PAYMENT_REQUEST',
    'VERIFY_PAYMENT_RESPONSE',
    'REALTIME_UPDATE',
    'POLLING_UPDATE',
    'NAVIGATION_RETURN',
    'PAYMENT_END',
  ];

  // One "last step" per flow tag so a subscription attempt and a tax_due attempt running
  // close together (or a stale screen still polling in the background) don't clobber each
  // other's trail.
  static final Map<String, String> _lastStepByFlow = {};

  static void start(String flow) {
    if (!kDebugMode) return;
    _lastStepByFlow.remove(flow);
    debugPrint('=========================');
    debugPrint('PAYMENT START [$flow]');
    debugPrint('=========================');
  }

  static void end(String flow) {
    if (!kDebugMode) return;
    debugPrint('=========================');
    debugPrint('PAYMENT END [$flow]');
    debugPrint('=========================');
    _lastStepByFlow.remove(flow);
  }

  static void step(String tag, String flow, [Object? data]) {
    if (!kDebugMode) return;
    _lastStepByFlow[flow] = tag;
    debugPrint('[PAY-TRACE][$flow] $tag${data != null ? ' => $data' : ''}');
  }

  /// Every catch block calls this. Logs the exception plus LAST SUCCESSFUL STEP / NEXT STEP
  /// NEVER EXECUTED for this flow.
  static void exceptionAt(String where, String flow, Object error, StackTrace st) {
    if (!kDebugMode) return;
    debugPrint('[PAY-TRACE][$flow] EXCEPTION at $where => $error');
    debugPrint(st.toString());
    _dumpLastStepAndNext(flow);
  }

  /// Every early/abnormal return calls this (e.g. edge function returned null, verification
  /// timed out). Logs LAST SUCCESSFUL STEP / NEXT STEP NEVER EXECUTED for this flow.
  static void abnormalExit(String where, String flow, [Object? reason]) {
    if (!kDebugMode) return;
    debugPrint('[PAY-TRACE][$flow] RETURN/EXIT at $where${reason != null ? ' => $reason' : ''}');
    _dumpLastStepAndNext(flow);
  }

  static void _dumpLastStepAndNext(String flow) {
    final last = _lastStepByFlow[flow];
    debugPrint('[PAY-TRACE][$flow] LAST SUCCESSFUL STEP => ${last ?? "(none logged yet)"}');
    if (last == null) {
      debugPrint('[PAY-TRACE][$flow] NEXT STEP NEVER EXECUTED => ${_expectedOrder.first}');
      return;
    }
    final idx = _expectedOrder.indexOf(last);
    final next = (idx >= 0 && idx + 1 < _expectedOrder.length)
        ? _expectedOrder[idx + 1]
        : '(end of known sequence -- last step was the final expected one)';
    debugPrint('[PAY-TRACE][$flow] NEXT STEP NEVER EXECUTED => $next');
  }
}
