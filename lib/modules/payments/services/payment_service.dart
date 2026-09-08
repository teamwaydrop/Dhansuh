import 'dart:async';

import 'package:waydrop/models/payment_for.dart';
import 'package:waydrop/modules/payments/screens/payment_processing_screen.dart';
import 'package:waydrop/modules/payments/services/payment_debug_trace.dart';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';

import 'package:flutter/material.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:flutter_cashfree_pg_sdk/api/cfpayment/cfwebcheckoutpayment.dart';

import 'package:flutter_cashfree_pg_sdk/api/cfpaymentgateway/cfpaymentgatewayservice.dart';

import 'package:flutter_cashfree_pg_sdk/api/cfsession/cfsession.dart';

import 'package:flutter_cashfree_pg_sdk/utils/cfenums.dart';

import 'package:flutter_cashfree_pg_sdk/api/cferrorresponse/cferrorresponse.dart';

class PaymentService {

  static final supabase =
      Supabase.instance.client;

  static final CFPaymentGatewayService
      paymentGatewayService =
      CFPaymentGatewayService();

  static bool callbacksInitialized =
      false;

  // ROOT CAUSE (driver "Cashfree QR" -> instant "Still verifying your payment...", checkout/QR
  // never appears): flutter_cashfree_pg_sdk's CFPaymentGatewayService.setCallback() does two
  // things -- it stores your callbacks AND immediately calls native method channel "response",
  // which replays whatever terminal result (success/failed/exception) is still cached from the
  // PREVIOUS payment attempt on this device straight into the callbacks you just passed in. This
  // screen used to call setCallback() again on every single open (to route results to whichever
  // screen instance was currently live), which meant a stale result left over from an earlier
  // cancelled/failed Cashfree attempt got replayed into the BRAND NEW payment's onError handler
  // near-instantly -- well before the fresh doPayment() call (fired moments later) had any chance
  // to actually launch/render the real Cashfree checkout (where the "Scan and Pay" QR lives).
  // Since the new order's own payment_status is genuinely still "pending" at that instant,
  // _onPaymentSDKError's verification check fell into "onStillPending" and flipped the UI straight
  // to "Still verifying your payment..." without the checkout ever being seen.
  //
  // Fix: register with the native SDK via setCallback() exactly ONCE, here, at app startup (see
  // main.dart's PaymentService.initializeCallbacks() call) -- so that stale-response replay only
  // ever happens once, harmlessly, before any driver-initiated payment exists. Each
  // PaymentProcessingScreen instance then registers/clears itself against these mutable fields
  // (registerActivePaymentCallbacks / clearActivePaymentCallbacks) instead of touching the SDK's
  // setCallback() again.
  static void Function(String)? _activeSuccessHandler;
  static void Function(CFErrorResponse, String)? _activeErrorHandler;

  // TEMP DEBUG INSTRUMENTATION: which payment flow (payment_for / paymentForLabel) the currently
  // registered callbacks belong to, purely so the SDK success/error callback logs below can be
  // tagged. See payment_debug_trace.dart.
  static String _activeFlowLabel = 'unknown';

  // TEMP RUNTIME-DEBUG: timestamp of the last doPayment() invocation, so the SDK callback handlers
  // below can log elapsed ms since doPayment() was called. A callback firing within a few hundred ms
  // is strong evidence the native side never actually rendered the checkout Activity/QR (i.e. it
  // threw/failed synchronously before any UI could show) as opposed to a real user interaction,
  // which takes several seconds at minimum.
  static DateTime? _lastDoPaymentAt;

  static void registerActivePaymentCallbacks({
    required void Function(String) onSuccess,
    required void Function(CFErrorResponse, String) onError,
    String flowLabel = 'unknown',
  }) {
    _activeSuccessHandler = onSuccess;
    _activeErrorHandler = onError;
    _activeFlowLabel = flowLabel;
  }

  static void clearActivePaymentCallbacks() {
    _activeSuccessHandler = null;
    _activeErrorHandler = null;
    _activeFlowLabel = 'unknown';
  }

  // =====================================================
  // INITIALIZE CALLBACKS
  // =====================================================

  static void initializeCallbacks() {

    if (callbacksInitialized) {
      return;
    }

    callbacksInitialized = true;

    paymentGatewayService.setCallback(

      (String orderId) {

        final elapsedMs = _lastDoPaymentAt == null
            ? -1
            : DateTime.now().difference(_lastDoPaymentAt!).inMilliseconds;
        debugPrint(
          'STEP 8: SDK SUCCESS CALLBACK => orderId=$orderId elapsedSinceDoPaymentMs=$elapsedMs',
        );
        PaymentTrace.step(
          'CASHFREE_SUCCESS_CALLBACK',
          _activeFlowLabel,
          {'orderId': orderId, 'elapsedSinceDoPaymentMs': elapsedMs},
        );

        _activeSuccessHandler?.call(orderId);
      },

      (CFErrorResponse error,
          String orderId) {

        final elapsedMs = _lastDoPaymentAt == null
            ? -1
            : DateTime.now().difference(_lastDoPaymentAt!).inMilliseconds;
        debugPrint(
          'STEP 8: SDK ERROR CALLBACK => message=${error.getMessage()} '
          'code=${error.getCode()} type=${error.getType()} status=${error.getStatus()} '
          'orderId=$orderId elapsedSinceDoPaymentMs=$elapsedMs',
        );
        PaymentTrace.step(
          'CASHFREE_FAILURE_CALLBACK',
          _activeFlowLabel,
          {'orderId': orderId, 'elapsedSinceDoPaymentMs': elapsedMs},
        );
        PaymentTrace.step('CASHFREE_ERROR_CODE', _activeFlowLabel, error.getCode());
        PaymentTrace.step('CASHFREE_ERROR_MESSAGE', _activeFlowLabel, error.getMessage());

        _activeErrorHandler?.call(error, orderId);
      },
    );
  }

  // =====================================================
  // DISPOSE CALLBACKS


  // =====================================================
  // CREATE PAYMENT
  // =====================================================

  static Future<Map<String, dynamic>?>
      createPayment({

    required PaymentFor paymentFor,

    required double amount,

    required String paymentMethod,

    String? riderId,

    String? referenceId,

    Map<String, dynamic>? metadata,

    // Trip facts (never a price) the server uses to independently
    // calculate the payable amount for a brand-new ride/parcel booking.
    // `amount` above is kept only for local display (e.g. the payment
    // processing screen's "Amount:" line) — the server never trusts it for
    // order/boost payments; see create-payment/index.ts.
    Map<String, dynamic>? pricingContext,

    // The ONLY subscription-related value the server trusts (payment_for: subscription).
    // The real charge amount and duration are derived server-side from the
    // subscription_plans allowlist via this id -- `amount` above is local-display-only
    // for subscriptions too; see create-payment/index.ts and migration
    // 20260726000002_subscription_plan_allowlist.sql.
    String? planId,
  }) async {

    final cleanRiderId = (riderId == null || riderId.isEmpty || riderId == 'null') ? null : riderId;
    final cleanReferenceId = (referenceId == null || referenceId.isEmpty || referenceId == 'null') ? null : referenceId;

    final body = {
      'payment_for': paymentFor.value,
      'amount': amount,
      'payment_method': paymentMethod,
      if (planId != null) 'plan_id': planId,
      'reference_id': cleanReferenceId,
      'rider_id': cleanRiderId,
      'metadata': metadata ?? {},
      if (pricingContext != null) 'pricing_context': pricingContext,
    };

    // create-payment is idempotent per (user, payment_for, reference_id): if a
    // pending/processing payment already exists it returns that same session instead of
    // creating a second Cashfree order (see create-payment/index.ts "CHECK DUPLICATE
    // PAYMENT"). That makes it safe to retry here for transport-level failures only --
    // e.g. the phone's connection dropping after the edge function already finished and
    // wrote the payment row, which otherwise surfaces to the passenger as "Unable to
    // create payment session" even though a valid session was in fact created server-side.
    // A genuine rejection from our own function (bad order, already paid, auth) comes back
    // as a FunctionException with a real HTTP status -- retrying that would just reproduce
    // the same rejection, so only non-FunctionException (network/timeout) errors retry.
    const maxAttempts = 3;
    final flow = paymentFor.value;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        PaymentTrace.step('EDGE_FUNCTION_REQUEST', flow, {'attempt': attempt, 'body': body});

        final response = await supabase.functions
            .invoke('create-payment', body: body)
            .timeout(const Duration(seconds: 20));

        debugPrint('CREATE PAYMENT RESPONSE => ${response.data}');
        PaymentTrace.step('EDGE_FUNCTION_RESPONSE', flow, response.data);

        if (response.data == null) {
          PaymentTrace.abnormalExit('createPayment', flow, 'response.data was null');
          return null;
        }

        final result = Map<String, dynamic>.from(response.data);
        PaymentTrace.step('ORDER_ID', flow, result['order_id']);
        PaymentTrace.step('PAYMENT_SESSION_ID', flow, result['payment_session_id']);
        return result;
      } on FunctionException catch (e, st) {
        debugPrint('CREATE PAYMENT FUNCTION ERROR => status=${e.status} details=${e.details}');
        PaymentTrace.exceptionAt('createPayment (FunctionException)', flow, e, st);
        unawaited(FirebaseCrashlytics.instance.recordError(
          e,
          st,
          reason: 'create-payment function error',
          fatal: false,
        ));
        // Phase 2 fix: previously returned null unconditionally, discarding create-payment's own
        // clear rejection message (e.g. "This order has already been paid", or the new Phase 1
        // "Payments/Subscriptions are temporarily unavailable" 503s) -- startPayment() then always
        // showed the generic "Unable to create payment session", exactly the bug already fixed
        // once before for delete-account (see data_deletion_screen.dart's _extractErrorMessage).
        // Applying the same details['message'] ?? details['error'] extraction here so every
        // create-payment rejection surfaces its real, specific reason instead of a generic one.
        final details = e.details;
        String? serverMessage;
        if (details is Map) {
          serverMessage = (details['message'] ?? details['error'])?.toString();
        }
        return {'_serverRejection': true, '_serverMessage': serverMessage};
      } catch (e, st) {
        debugPrint('CREATE PAYMENT TRANSPORT ERROR (attempt $attempt/$maxAttempts) => $e');
        debugPrintStack(stackTrace: st);
        PaymentTrace.exceptionAt('createPayment (transport, attempt $attempt/$maxAttempts)', flow, e, st);
        unawaited(FirebaseCrashlytics.instance.recordError(
          e,
          st,
          reason: 'create-payment transport error (attempt $attempt/$maxAttempts)',
          fatal: false,
        ));

        if (attempt == maxAttempts) {
          PaymentTrace.abnormalExit('createPayment', flow, 'exhausted $maxAttempts attempts');
          return null;
        }

        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }

    return null;
  }

  // =====================================================
  // VERIFY PAYMENT
  // =====================================================

  static Future<Map<String, dynamic>?>
      verifyPayment(
    String paymentCode, {
    String flowLabel = 'unknown',
  }) async {

    try {

      PaymentTrace.step('VERIFY_PAYMENT_REQUEST', flowLabel, {'payment_code': paymentCode});

      final response =
          await supabase.functions.invoke(

        'verify-payment',

        body: {

          'payment_code':
              paymentCode,
        },
      );

      debugPrint(
        'VERIFY RESPONSE => ${response.data}',
      );
      PaymentTrace.step('VERIFY_PAYMENT_RESPONSE', flowLabel, response.data);

      if (response.data == null) {
        PaymentTrace.abnormalExit('verifyPayment', flowLabel, 'response.data was null');
        return null;
      }

      return Map<String, dynamic>.from(
        response.data,
      );

    } catch (e, st) {

      debugPrint(
        'VERIFY PAYMENT ERROR => $e',
      );

      debugPrintStack(
        stackTrace: st,
      );
      PaymentTrace.exceptionAt('verifyPayment', flowLabel, e, st);

      return null;
    }
  }

  // =====================================================
  // LISTEN PAYMENT STATUS
  // =====================================================

  static Stream<Map<String, dynamic>?>
      listenPaymentStatus(
    String paymentId,
  ) {

    final controller =
        StreamController<
            Map<String, dynamic>?>();

    final channel =
        supabase.channel(
      'payment-$paymentId',
    );

    channel.onPostgresChanges(

      event:
          PostgresChangeEvent
              .update,

      schema: 'public',

      table: 'payments',

      filter:
          PostgresChangeFilter(

        type:
            PostgresChangeFilterType
                .eq,

        column:
            'id',

        value:
            paymentId,
      ),

      callback: (payload) {

        debugPrint(
          'REALTIME PAYMENT UPDATE => '
          '${payload.newRecord}',
        );

        controller.add(
          payload.newRecord,
        );
      },
    ).subscribe();

    controller.onCancel = () async {

      await supabase.removeChannel(channel);
    };

    return controller.stream;
  }

  // =====================================================
  // OPEN PAYMENT
  // =====================================================

  static Future<bool> openPayment({
    required String orderId,
    required String paymentSessionId,
    String flowLabel = 'unknown',
  }) async {

    try {

      PaymentTrace.step(
        'OPEN_PAYMENT_ENTER',
        flowLabel,
        {'orderId': orderId, 'paymentSessionId': paymentSessionId},
      );

      debugPrint(
        'STEP 4: payment_session_id received by openPayment() => '
        'orderId=$orderId '
        'paymentSessionId=$paymentSessionId '
        '(len=${paymentSessionId.length}) '
        'ENV: production',
      );

      PaymentTrace.step('BEFORE_CFSESSIONBUILDER', flowLabel);
      final session =
          CFSessionBuilder()
              .setEnvironment(
                CFEnvironment.PRODUCTION,
              )
              .setOrderId(
                orderId,
              )
              .setPaymentSessionId(
                paymentSessionId,
              )
              .build();
      PaymentTrace.step('AFTER_CFSESSIONBUILDER', flowLabel);

      debugPrint('STEP 5: CFSession created successfully');

      PaymentTrace.step('BEFORE_CFWEBCHECKOUTPAYMENTBUILDER', flowLabel);
      final payment =
          CFWebCheckoutPaymentBuilder()

              .setSession(
                session,
              )

              .build();
      PaymentTrace.step('AFTER_CFWEBCHECKOUTPAYMENTBUILDER', flowLabel);

      debugPrint('STEP 6: CFWebCheckoutPayment built, calling doPayment() now');
      _lastDoPaymentAt = DateTime.now();
      final swBeforeCall = _lastDoPaymentAt!;

      PaymentTrace.step('BEFORE_DOPAYMENT', flowLabel);
      await paymentGatewayService
          .doPayment(
        payment,
      );
      PaymentTrace.step('AFTER_DOPAYMENT', flowLabel);

      // NOTE: doPayment() itself (see flutter_cashfree_pg_sdk's
      // CFPaymentGatewayService.doPayment) does NOT throw/await the actual checkout result -- it
      // fires a MethodChannel.invokeMethod(...).then(...) and returns immediately without waiting
      // for that future. So "doPayment() returned without throwing" only proves the Dart-side call
      // was made and the platform channel accepted the method call; it does NOT prove the native
      // Activity/checkout UI actually launched. STEP 8 (the SUCCESS/ERROR callback log above, with
      // elapsedSinceDoPaymentMs) is what actually proves whether the checkout rendered.
      debugPrint(
        'STEP 7: doPayment() call returned (did not throw) after '
        '${DateTime.now().difference(swBeforeCall).inMilliseconds}ms -- '
        'this does NOT yet confirm the Cashfree Activity/QR actually rendered, '
        'only that the platform channel call was dispatched. Watch for STEP 8.',
      );

      return true;

    } catch (e, st) {

      debugPrint(
        'STEP 6/7 FAILED: doPayment() threw synchronously => $e',
      );

      debugPrintStack(
        stackTrace: st,
      );
      PaymentTrace.exceptionAt('openPayment (Cashfree Exception)', flowLabel, e, st);

      return false;
    }
  }

  // =====================================================
  // CREATE FARE QR (driver's "Cashfree QR" button). Creates/reuses the underlying Cashfree order
  // and returns qr_available:true with payment_session_id/order_id/payment_id/payment_code/amount
  // -- the caller opens PaymentService.openPayment with those to launch Cashfree's own
  // UPI-restricted hosted checkout, which renders Cashfree's own "Scan and Pay" QR. Returns
  // qr_available:false with a reason if this Cashfree account/integration cannot even create the
  // order -- never fabricates a QR client-side. See create-fare-qr/index.ts.
  // =====================================================
  static Future<Map<String, dynamic>> createFareQr({
    required String orderId,
  }) async {
    debugPrint('STEP 2: create-fare-qr Edge Function invoked => orderId=$orderId');
    try {
      final response = await supabase.functions
          .invoke('create-fare-qr', body: {'order_id': orderId})
          .timeout(const Duration(seconds: 20));

      debugPrint('STEP 3: create-fare-qr response received => ${response.data}');

      if (response.data == null) {
        return {'success': false, 'qr_available': false, 'message': _cashfreeQrUnavailableMessage};
      }

      return Map<String, dynamic>.from(response.data);
    } on FunctionException catch (e, st) {
      debugPrint('CREATE FARE QR FUNCTION ERROR => status=${e.status} details=${e.details}');
      unawaited(FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'create-fare-qr function error',
        fatal: false,
      ));
      return {'success': false, 'qr_available': false, 'message': _cashfreeQrUnavailableMessage};
    } catch (e, st) {
      // Never surface a raw exception's .toString() to the driver -- it can contain arbitrary
      // technical/stack detail. Full detail still goes to debugPrint/Crashlytics for diagnosis.
      debugPrint('CREATE FARE QR ERROR => $e');
      debugPrintStack(stackTrace: st);
      unawaited(FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'create-fare-qr unexpected client error',
        fatal: false,
      ));
      return {'success': false, 'qr_available': false, 'message': _cashfreeQrUnavailableMessage};
    }
  }

  static const String _cashfreeQrUnavailableMessage = 'Cashfree QR is temporarily unavailable.';

  // =====================================================
  // START PAYMENT FLOW
  // =====================================================

  static Future<Map<String, dynamic>>
      startPayment({

    required BuildContext context,

    required PaymentFor paymentFor,

    required double amount,

    required String paymentMethod,

    String? riderId,

    String? referenceId,

    Map<String, dynamic>? metadata,

    Map<String, dynamic>? pricingContext,

    // The ONLY subscription-related value the server trusts -- see createPayment().
    String? planId,

    // Header text shown on PaymentProcessingScreen. Defaults to the driver
    // subscription label (the original, only caller of this method) so that
    // call site keeps working unchanged; passenger fare payments pass their
    // own label (e.g. "Ride Fare").
    String? paymentForLabel,
  }) async {

    final flow = paymentFor.value;

    try {
      PaymentTrace.step(
        'START_PAYMENT_ENTER',
        flow,
        {'amount': amount, 'paymentMethod': paymentMethod, 'riderId': riderId, 'planId': planId},
      );

      final cleanRiderId = (riderId == null || riderId.isEmpty || riderId == 'null') ? null : riderId;
      final cleanReferenceId = (referenceId == null || referenceId.isEmpty || referenceId == 'null') ? null : referenceId;

      // ===============================================
      // CREATE PAYMENT
      // ===============================================

      final payment =
          await createPayment(

        paymentFor:
            paymentFor,

        amount:
            amount,

        paymentMethod:
            paymentMethod,

        riderId:
            cleanRiderId,

        referenceId:
            cleanReferenceId,

        pricingContext:
            pricingContext,

        metadata:
            metadata,

        planId:
            planId,
      );

      if (payment != null && payment['_serverRejection'] == true) {
        final serverMessage = payment['_serverMessage']?.toString();
        PaymentTrace.abnormalExit('startPayment', flow, 'createPayment() server rejection: $serverMessage');
        return {
          'success': false,
          'message': serverMessage ?? 'Unable to create payment session',
        };
      }

      if (payment == null) {
        PaymentTrace.abnormalExit('startPayment', flow, 'createPayment() returned null');
        return {
          'success': false,
          'message': 'Unable to create payment session',
        };
      }

      final paymentCode = payment['payment_code'];
      final paymentId = payment['payment_id'];
      final paymentSessionId = payment['payment_session_id'];
      final orderId = payment['order_id'];

      if (paymentCode == null || paymentId == null || orderId == null || paymentSessionId == null) {
        PaymentTrace.abnormalExit(
          'startPayment',
          flow,
          'missing field(s) in create-payment response: $payment',
        );
        return {
          'success': false,
          'message': 'Invalid payment session details returned',
        };
      }

      if (!context.mounted) {
        PaymentTrace.abnormalExit('startPayment', flow, 'context unmounted before navigation');
        return {
          'success': false,
          'message': 'cancelled',
        };
      }

      final label = paymentForLabel ?? 'Drop Partner Subscription';

      PaymentTrace.step(
        'NAVIGATE_TO_PROCESSING_SCREEN',
        flow,
        {'paymentCode': paymentCode, 'paymentId': paymentId, 'orderId': orderId},
      );

      // Navigate to checkout screen process
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => PaymentProcessingScreen(
            paymentCode: paymentCode,
            paymentId: paymentId,
            orderId: orderId,
            paymentSessionId: paymentSessionId,
            amount: amount,
            paymentForLabel: label,
            flowTag: flow,
          ),
        ),
      );

      PaymentTrace.step('NAVIGATION_RETURN', flow, result);

      if (result is Map && result['success'] == true) {
        return {
          'success': true,
          'payment': result['payment'] ?? {
            'id': paymentId,
            'payment_code': paymentCode,
          },
        };
      } else {
        return {
          'success': false,
          'action': result?.toString() ?? 'cancelled',
          'message': 'Payment failed or was cancelled',
        };
      }

    } catch (e, st) {
      debugPrint('START PAYMENT ERROR => $e');
      debugPrintStack(stackTrace: st);
      PaymentTrace.exceptionAt('startPayment', flow, e, st);
      return {
        'success': false,
        'message': e.toString(),
      };
    }
  }
}