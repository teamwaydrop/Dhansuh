// Structural regression guard for the Cashfree QR fix (docs/07_Payments.md section 4). Confirmed
// root cause: Cashfree's only documented API for a raw, extractable UPI QR payload is the "Orders
// Pay"/Seamless S2S API (POST /pg/orders/sessions), which requires a separate, Cashfree-approved
// S2S capability this merchant account does not have (HTTP 400, "s2s_enabled_not_approved") -- and
// the flutter_cashfree_pg_sdk's own CFUPIPaymentBuilder has no QR mode either (COLLECT/INTENT
// only). The fix uses Cashfree's own already-working, non-gated hosted checkout (POST /pg/orders +
// CFWebCheckoutPaymentBuilder, order_meta.payment_methods restricted to "upi") -- Cashfree itself
// renders a genuine per-order "Scan and Pay" QR inside that checkout; WayDrop never fabricates,
// parses, or reconstructs a payment payload. This does not run the app or call Cashfree -- it
// inspects the payment/dispatch source files themselves so a future edit that retries the blocked
// S2S endpoint, leaks raw Cashfree error detail to the driver, weakens fare/authorization
// guarantees, or blurs the Personal QR / Cash / Cashfree QR boundary fails CI immediately instead
// of only being caught on a real device.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final createFareQr = _read('supabase/functions/create-fare-qr/index.ts');
  final cashfreeWebhook = _read('supabase/functions/cashfree-webhook/index.ts');
  final updateOrderStatus = _read('supabase/functions/update-order-status/index.ts');
  final completionSettlement = _read('supabase/migrations/20260813000000_atomic_order_completion_settlement.sql');
  final activeOrderScreen = _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');
  final paymentService = _read('lib/modules/payments/services/payment_service.dart');
  final paymentProcessingScreen = _read('lib/modules/payments/screens/payment_processing_screen.dart');

  group('create-fare-qr: authorization and fare security', () {
    test('1. QR only proceeds for a payment_pending order', () {
      expect(createFareQr.contains('order.order_status !== "payment_pending"'), isTrue);
    });

    test('2. an unauthenticated caller is rejected before any order/Cashfree work', () {
      expect(createFareQr.contains('Missing auth token'), isTrue);
      expect(createFareQr.contains('supabaseAdmin.auth.getUser(token)'), isTrue);
      expect(createFareQr.contains('Unauthorized'), isTrue);
    });

    test('3. only the order\'s own passenger or its assigned rider may create/view its QR', () {
      // isAuthorized starts as passenger-match, and the rider branch is scoped to THIS order's own
      // rider_id -- never a caller-supplied rider/order id, so a different driver cannot borrow
      // another order's QR.
      expect(createFareQr.contains('order.user_id === user.id'), isTrue);
      expect(createFareQr.contains('.eq("id", order.rider_id)'), isTrue);
      expect(createFareQr.contains('Forbidden: not a participant on this order'), isTrue);
    });

    test('4. fare is derived from the DB order row, never from the request body', () {
      expect(createFareQr.contains('Number(order.final_fare ?? order.current_fare ?? 0)'), isTrue);
    });

    test('5. the request body is never parsed for an amount/fare field', () {
      // Only order_id is ever read off the client body -- confirms the client cannot influence the
      // Cashfree order_amount even if it tried to send one.
      expect(createFareQr.contains('const orderId = body?.order_id'), isTrue);
      expect(createFareQr.contains('body?.amount'), isFalse);
      expect(createFareQr.contains('body?.fare'), isFalse);
      expect(createFareQr.contains('body.amount'), isFalse);
      expect(createFareQr.contains('body.fare'), isFalse);
    });

    test('6. the checkout opened is restricted to UPI only, not a raw client-fabricated payload', () {
      expect(createFareQr.contains('order_meta'), isTrue);
      expect(createFareQr.contains('payment_methods: "upi"'), isTrue);
    });
  });

  group('create-fare-qr: the blocked S2S QR endpoint is never retried', () {
    test('7. no call to the Orders Pay / Seamless S2S "qrcode" endpoint remains', () {
      // The blocked endpoint is still named in this file's own explanatory doc-comment (why it
      // can't be used) -- what must be gone is an actual fetch() call to it.
      expect(createFareQr.contains('fetch(`\${CASHFREE_BASE_URL}/orders/sessions`'), isFalse);
      expect(createFareQr.contains('channel: "qrcode"'), isFalse);
      expect(createFareQr.contains('payment_method: { upi:'), isFalse);
    });

    test('8. success responds with a checkout session, never a raw qr_payload field', () {
      expect(createFareQr.contains('payment_session_id: paymentSessionId'), isTrue);
      expect(createFareQr.contains('qr_payload'), isFalse);
      expect(createFareQr.contains('qr_is_image'), isFalse);
    });
  });

  group('create-fare-qr: idempotency', () {
    test('9. a second tap reuses the existing pending payment row and Cashfree order instead of minting a new one', () {
      // payment_status_enum has no "processing" member (pending/paid/failed/refunded/
      // partial_refund/cash_collected/cash_pending_settlement only) -- filtering with .in()
      // against an unknown enum literal makes Postgres reject the whole query, which broke the
      // driver's "Cashfree QR" button outright on every call. Fixed to a plain .eq("pending").
      // Guard both: the working .eq() lookup is present, and the broken .in() form never returns.
      expect(createFareQr.contains('.eq("payment_status", "pending")'), isTrue);
      expect(createFareQr.contains('.in("payment_status", ["pending", "processing"])'), isFalse);
      expect(createFareQr.contains('let paymentRow = existingPayment'), isTrue);
    });

    test('10. the reused payment/order lookup is scoped to this order (reference_id), never global', () {
      expect(createFareQr.contains('.eq("reference_id", orderId)'), isTrue);
    });
  });

  group('Driver "Cashfree QR" screen opens Cashfree\'s own checkout, never a client-built QR', () {
    String cashfreeQrSource() {
      final start = activeOrderScreen.indexOf('Future<void> _showCashfreeQrFullscreen');
      final end = activeOrderScreen.indexOf('CONFIRM CANCELLATION BY RIDER');
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      return activeOrderScreen.substring(start, end);
    }

    test('11. on qr_available it navigates to PaymentProcessingScreen with the server-issued session', () {
      final src = cashfreeQrSource();
      expect(src.contains('PaymentProcessingScreen('), isTrue);
      expect(src.contains("paymentSessionId: paymentSessionId"), isTrue);
      expect(src.contains("amount: fare"), isTrue);
    });

    test('12. no QrImageView/Image.memory is built from a Cashfree-derived payload anymore', () {
      final src = cashfreeQrSource();
      expect(src.contains('QrImageView'), isFalse);
      expect(src.contains('Image.memory'), isFalse);
      expect(activeOrderScreen.contains('_decodeDataUriImage'), isFalse);
      expect(activeOrderScreen.contains("import 'package:qr_flutter/qr_flutter.dart'"), isFalse);
    });

    test('13. the unavailable fallback still offers Personal QR / Cash with fixed, non-technical copy', () {
      final src = cashfreeQrSource();
      expect(src.contains("'Cashfree QR is temporarily unavailable.'"), isTrue);
      expect(src.contains("'Please use Personal QR or Cash instead.'"), isTrue);
      expect(src.contains('Order Pay API'), isFalse);
      expect(src.contains('http_status'), isFalse);
      expect(src.contains('s2s_enabled_not_approved'), isFalse);
    });

    test('14. displaying/leaving the checkout screen never itself confirms payment', () {
      final src = cashfreeQrSource();
      // The only thing this method does after the checkout screen returns is `return;` -- no
      // payment_status/order_status write of any kind lives in this function.
      expect(src.contains("updateStatus("), isFalse);
      expect(src.contains("payment_status:"), isFalse);
      expect(src.contains("'paid'"), isFalse);
    });
  });

  group('Personal QR and Cash remain fully independent of Cashfree', () {
    test('15. Personal QR viewer never calls create-fare-qr or any Cashfree service', () {
      final start = activeOrderScreen.indexOf('Future<void> _showPersonalQrFullscreen');
      final end = activeOrderScreen.indexOf('Opens Cashfree\'s own UPI-restricted hosted checkout');
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final personalQrSource = activeOrderScreen.substring(start, end);
      expect(personalQrSource.contains('createFareQr'), isFalse);
      expect(personalQrSource.contains('Cashfree'), isFalse);
      // Egress fix: personal QR is rendered via CachedNetworkImage (disk+mem cache,
      // downsampled to display size) instead of a raw Image.network, but it's still the
      // same signed qrUrl and still no Cashfree/gateway involvement.
      expect(personalQrSource.contains('CachedNetworkImage('), isTrue);
      expect(personalQrSource.contains('imageUrl: qrUrl'), isTrue);
    });

    test('16. Cash settlement never touches Cashfree/create-fare-qr', () {
      expect(updateOrderStatus.contains("settlement_method === \"cash\" ? \"cash\" : \"personal_upi\""), isTrue);
      // The direct-settlement branch (personal_upi/cash) never checks payment_status/Cashfree.
      final directBranchStart = updateOrderStatus.indexOf('Direct settlement (personal_upi / cash');
      final directBranchEnd = updateOrderStatus.indexOf('OTP VALIDATION WITH LOCKOUT');
      expect(directBranchStart, greaterThan(-1));
      final directBranchSource = updateOrderStatus.substring(directBranchStart, directBranchEnd);
      expect(directBranchSource.contains('cashfree'), isFalse);
    });
  });

  group('cashfree-webhook: authoritative gateway confirmation', () {
    test('17. a genuine, correctly-signed SUCCESS webhook marks the gateway payment paid', () {
      expect(cashfreeWebhook.contains('computeSignature(rawBody, timestamp, CASHFREE_SECRET_KEY)'), isTrue);
      expect(cashfreeWebhook.contains('paymentStatus === "SUCCESS"'), isTrue);
      expect(cashfreeWebhook.contains('payment_status: "paid"'), isTrue);
    });

    test('18. an invalid/unsigned webhook is rejected before any DB write', () {
      final sigCheckIndex = cashfreeWebhook.indexOf('WEBHOOK SIGNATURE VERIFICATION');
      expect(sigCheckIndex, greaterThan(-1));
      final beforeDbWrite = cashfreeWebhook.substring(0, cashfreeWebhook.indexOf('FIND PAYMENT'));
      expect(beforeDbWrite.contains('timingSafeEqual(expectedSignature, signature)'), isTrue);
      expect(beforeDbWrite.contains('Invalid signature'), isTrue);
      expect(beforeDbWrite.contains('status: 400'), isTrue);
    });

    test('19. payment/order mapping comes only from Cashfree\'s own order_id (payment_code), and the amount was fixed server-side at order-creation time', () {
      expect(cashfreeWebhook.contains('payload?.data?.order?.order_id'), isTrue);
      expect(cashfreeWebhook.contains('.eq("payment_code", orderId)'), isTrue);
      // A webhook can only confirm the exact pre-fixed order_amount from create-fare-qr's own
      // server-authoritative fare -- never an arbitrary client-chosen one.
      expect(createFareQr.contains('order_amount: finalAmount'), isTrue);
    });

    test('20. a duplicate webhook delivery cannot double-credit (already-paid short-circuit)', () {
      expect(cashfreeWebhook.contains('payment.payment_status === "paid"'), isTrue);
      expect(cashfreeWebhook.contains('ALREADY PROCESSED'), isTrue);
    });
  });

  group('update-order-status: Cashfree cannot be self-attested, and completion cannot double-credit', () {
    test('21. completion is guarded by an optimistic lock, so duplicate completion calls cannot double-credit', () {
      expect(updateOrderStatus.contains('credit_rider_for_completed_order'), isTrue);
      expect(updateOrderStatus.contains("eq('order_status'") || updateOrderStatus.contains('.eq("order_status"'), isTrue);
    });

    test('22. a driver cannot mark an unpaid Cashfree fare as completed via Confirm Payment Received', () {
      expect(updateOrderStatus.contains('if (fareMethod === "cashfree")'), isTrue);
      expect(updateOrderStatus.contains('if (order.payment_status !== "paid")'), isTrue);
      expect(updateOrderStatus.contains('Cannot complete this order before the passenger\'s Cashfree payment has been confirmed'), isTrue);
    });

    // WayDrop consolidated performance/correctness pass (2026-08-13): the settlement chain
    // (wallet credit, government tax, subscription waiver) moved from update-order-status's own JS
    // into one atomic RPC, complete_order_and_settle() (migration 20260813000000) -- see that
    // migration's header for the forensic incident that motivated it. Every rule below is unchanged,
    // just relocated with everything else it was already part of; these tests now check the new
    // location instead of update-order-status.
    test('23. wallet crediting is mutually exclusive between direct collection and Cashfree, exactly once per completion', () {
      expect(completionSettlement.contains("v_fare_method IN ('personal_upi', 'cash')"), isTrue);
      expect(completionSettlement.contains('v_is_direct_collection'), isTrue);
      expect(updateOrderStatus.contains('complete_order_and_settle'), isTrue);
    });

    test('24. Government Tax Due is applied at most once per order and withheld from (not added on top of) the Cashfree wallet credit', () {
      expect(completionSettlement.contains('apply_order_government_tax'), isTrue);
      expect(completionSettlement.contains("(v_tax_result->>'applied')::boolean IS TRUE AND NOT v_is_direct_collection"), isTrue);
      expect(completionSettlement.contains('v_rider_net_earning := ROUND(v_rider_net_earning - v_tax_amount, 2)'), isTrue);
    });

    test('25. Waydrop MAX subscription commission waiver is independent of the tax-due/wallet logic', () {
      expect(completionSettlement.contains('v_has_active_subscription'), isTrue);
      expect(completionSettlement.contains('v_commission_amount := 0.0'), isTrue);
    });
  });

  group('No secrets in the Flutter client; no raw API errors in production UI', () {
    test('26. no Cashfree secret/app-id literal exists in the Flutter client', () {
      expect(paymentService.contains('CASHFREE_SECRET_KEY'), isFalse);
      expect(activeOrderScreen.contains('CASHFREE_SECRET_KEY'), isFalse);
      expect(paymentService.contains('x-client-secret'), isFalse);
      expect(activeOrderScreen.contains('x-client-secret'), isFalse);
    });

    test('27. create-fare-qr never forwards Cashfree\'s raw error detail/HTTP status to the client', () {
      expect(createFareQr.contains('detail: cashfreeData'), isFalse);
      expect(createFareQr.contains('http_status: qrResponse.status,\n        },'), isFalse);
      // Every qr_available:false path returns the single sanitized constant.
      expect(createFareQr.contains('const QR_UNAVAILABLE_MESSAGE ='), isTrue);
      expect('reason: QR_UNAVAILABLE_MESSAGE'.allMatches(createFareQr).length, greaterThanOrEqualTo(2));
    });

    test('28. payment_service.dart never returns a raw exception string as the QR failure message', () {
      final start = paymentService.indexOf('static Future<Map<String, dynamic>> createFareQr');
      final end = paymentService.indexOf('START PAYMENT FLOW');
      expect(start, greaterThan(-1));
      final createFareQrSource = paymentService.substring(start, end);
      expect(createFareQrSource.contains("'message': e.toString()"), isFalse);
      expect(createFareQrSource.contains('_cashfreeQrUnavailableMessage'), isTrue);
    });
  });

  group('PaymentProcessingScreen reuse: driver copy is opt-in, passenger checkout copy is unchanged by default', () {
    test('29. screenTitle/instructionText/successHeadline are optional and null-safe', () {
      expect(paymentProcessingScreen.contains('final String? screenTitle;'), isTrue);
      expect(paymentProcessingScreen.contains('final String? instructionText;'), isTrue);
      expect(paymentProcessingScreen.contains('final String? successHeadline;'), isTrue);
      // Defaults reproduce the original passenger-checkout copy exactly.
      expect(paymentProcessingScreen.contains("widget.successHeadline ?? 'Payment Successful!"), isTrue);
      expect(paymentProcessingScreen.contains('widget.instructionText ??'), isTrue);
    });

    test('30. payment success is only ever driven by a real payment_status change, never by opening this screen', () {
      expect(paymentProcessingScreen.contains("status == 'paid'"), isTrue);
      expect(paymentProcessingScreen.contains('PaymentService.listenPaymentStatus'), isTrue);
      expect(paymentProcessingScreen.contains('PaymentService.verifyPayment'), isTrue);
    });
  });

  // ===========================================================================================
  // Root-cause fix for the real-device "Payment Cancelled -> Retry Payment -> Cashfree QR
  // temporarily unavailable" sequence. Investigation found: (1) a reused pending payment row's
  // Cashfree session was handed back forever with no freshness check, so a driver who cancelled
  // once and immediately retried got the exact same (likely expired) session every time; (2)
  // "Retry Payment" discarded its own result, so even a fresh attempt required the driver to
  // notice the screen closed and manually tap "Cashfree QR" again; (3) the claimed
  // payments.metadata.cashfree_qr_last_error diagnostic was never actually written by any
  // .insert()/.update() call, only asserted in comments/docs.
  // ===========================================================================================
  group('create-fare-qr: stale/expired Cashfree session is never reused (tests 21-24)', () {
    test('an existing pending payment\'s Cashfree order status is checked before reuse', () {
      expect(createFareQr.contains(r'/orders/${cashfreeOrderId}'), isTrue);
      expect(createFareQr.contains('statusData?.order_status === "ACTIVE"'), isTrue);
    });

    test('a PAID order is never re-minted into a second Cashfree order (no double-charge risk)', () {
      expect(createFareQr.contains('statusData?.order_status === "PAID"'), isTrue);
      expect(createFareQr.contains('Payment already received for this order.'), isTrue);
    });

    test('a non-ACTIVE/non-PAID (expired/terminated) session is closed locally and a fresh order is created', () {
      expect(createFareQr.contains('cashfree_session_expired'), isTrue);
      expect(createFareQr.contains('paymentRow = null;'), isTrue);
    });

    test('a Cashfree status-check network failure falls back to the existing session rather than blocking the driver', () {
      expect(createFareQr.contains('catch (statusCheckError)'), isTrue);
    });
  });

  group('create-fare-qr: order-creation failure is now actually persisted for diagnostics (test 27, extended)', () {
    test('a failed Cashfree order-creation writes a queryable failed payment row with the real error', () {
      expect(createFareQr.contains("payment_status: \"failed\""), isTrue);
      expect(createFareQr.contains('metadata: { cashfree_qr_last_error: cashfreeData }'), isTrue);
      // Still never surfaced to the client -- only ever written server-side.
      expect(createFareQr.contains('{ success: true, qr_available: false, reason: QR_UNAVAILABLE_MESSAGE }'), isTrue);
    });
  });

  group('create-fare-qr: concurrent double-tap race is handled gracefully, not as a hard failure (test 22)', () {
    test('a unique-constraint violation on insert re-reads and reuses the winning row instead of erroring', () {
      expect(createFareQr.contains('insertError?.code === "23505"'), isTrue);
      expect(createFareQr.contains('idx_unique_pending_payment'), isTrue);
    });
  });

  group('Driver "Retry Payment" now actually retries instead of silently discarding the result', () {
    test('rider_active_order_screen.dart captures the PaymentProcessingScreen result and re-invokes on retry', () {
      final start = activeOrderScreen.indexOf('Future<void> _showCashfreeQrFullscreen');
      final end = activeOrderScreen.indexOf('CONFIRM CANCELLATION BY RIDER');
      final src = activeOrderScreen.substring(start, end);
      expect(src.contains('final navResult = await Navigator.push'), isTrue);
      expect(src.contains("navResult == 'retry'"), isTrue);
      expect(src.contains('await _showCashfreeQrFullscreen(fare);'), isTrue);
    });
  });
}
