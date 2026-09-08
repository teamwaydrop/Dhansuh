// Regression guard for PHASE 2, Issue 9 (most important): Intercity parcel final delivery flow.
//
// ROOT CAUSE: once an intercity_parcel order reached order_status == 'rider_at_drop',
// rider_active_order_screen.dart showed "CONTINUE IN TRAVEL PLAN" and bounced the traveller to
// IntercityBookingsScreen instead of continuing the delivery in place -- the parcel was never
// actually completed from this screen. This routing was itself a deliberate earlier fix (this
// screen's GENERIC parcel OTP path, validateOtp()/update-order-status, is a second, uncoordinated
// implementation of delivery-OTP verification that can race with complete_intercity_parcel_
// delivery()'s own OTP regeneration) -- but closing it off left no replacement.
//
// FIX: removed the bounce-away branch. intercity_parcel now falls through to the same mandatory
// drop-photo step local_parcel already uses (order-type-agnostic verification mechanism), then
// opens a NEW OTP sheet wired exclusively to complete_intercity_parcel_delivery() (never
// validateOtp()/update-order-status for this order type -- that exclusion is preserved, just
// re-implemented in place instead of by bouncing away). complete_intercity_parcel_delivery()
// itself, and the two financial-guard-bypass migrations it depends on
// (20260820000000/20260820000001), are NOT touched by this fix.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final source = _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');

  group('"CONTINUE IN TRAVEL PLAN" is gone for the intercity_parcel drop step', () {
    test('the literal button text no longer exists anywhere in this screen', () {
      expect(source.contains('CONTINUE IN TRAVEL PLAN'), isFalse);
    });

    test('the dead IntercityBookingsScreen import was removed (no longer referenced)', () {
      expect(
        source.contains("import 'package:waydrop/features/rider/intercity/intercity_bookings_screen.dart';"),
        isFalse,
      );
      expect(source.contains('IntercityBookingsScreen('), isFalse);
    });
  });

  group('intercity_parcel drop flow: mandatory photo, then OTP through the correct RPC only', () {
    final riderAtDropStart = source.indexOf("if (status == 'rider_at_drop') {");
    // Bounded to this parcel branch of buildBottomButton -- ends where the next top-level status
    // branch/comment block begins.
    final riderAtDropEnd = source.indexOf('Local parcel now stops at payment_pending', riderAtDropStart);
    final riderAtDropBlock = source.substring(riderAtDropStart, riderAtDropEnd);

    test('the mandatory drop-photo gate (dropoffPhotoCompleted) still exists and still comes '
        'before OTP entry -- Step 5 of the requested flow', () {
      expect(riderAtDropBlock.contains('final photoCompleted = dropoffPhotoCompleted;'), isTrue);
      expect(riderAtDropBlock.contains("_takeVerificationPhoto('dropoff')"), isTrue);
    });

    test('intercity_parcel opens the dedicated completion sheet; every other parcel type keeps '
        'the original generic OTP sheet', () {
      expect(
        riderAtDropBlock.contains("if (order?['order_type'] == 'intercity_parcel') {"),
        isTrue,
      );
      expect(riderAtDropBlock.contains('openIntercityParcelDropOtpSheet();'), isTrue);
      expect(riderAtDropBlock.contains('openOtpSheet(pickup: false);'), isTrue);
    });

    test('intercity_parcel completion never CALLS validateOtp()/update-order-status through this '
        'branch (the exact race this screen was previously fixed to avoid) -- validateOtp() is '
        'only ever invoked, if at all, in the non-intercity_parcel else-branch', () {
      // validateOtp() is legitimately mentioned in this block's own explanatory comment (describing
      // what must NOT happen) -- what matters is that it's never actually CALLED with intercity
      // parcel's delivery OTP (pickup: false) outside the else-branch that excludes intercity_parcel.
      expect(riderAtDropBlock.contains('validateOtp(pickup:'), isFalse);
    });
  });

  group('the new intercity completion methods call the correct, authoritative, already-guarded '
      'RPCs -- never a generic/local completion path', () {
    test('openIntercityParcelDropOtpSheet reuses the existing OtpSheetContent widget, wired to '
        'the new completion/resend methods', () {
      final start = source.indexOf('void openIntercityParcelDropOtpSheet() {');
      final end = source.indexOf('Future<String?> _completeIntercityParcelDelivery(');
      final body = source.substring(start, end);
      expect(body.contains('OtpSheetContent('), isTrue);
      expect(body.contains('onVerify: (enteredOtp) => _completeIntercityParcelDelivery(enteredOtp)'), isTrue);
      expect(body.contains('onResend: () => _resendIntercityDeliveryOtp()'), isTrue);
    });

    test('_completeIntercityParcelDelivery calls complete_intercity_parcel_delivery with the '
        'server-verified OTP -- the same RPC intercity_bookings_screen.dart already uses, never a '
        'client-side comparison', () {
      final start = source.indexOf('Future<String?> _completeIntercityParcelDelivery(');
      final end = source.indexOf('Future<String?> _resendIntercityDeliveryOtp(');
      final body = source.substring(start, end);
      expect(body.contains("supabase.rpc('complete_intercity_parcel_delivery', params: {"), isTrue);
      expect(body.contains("'p_order_id': widget.orderId,"), isTrue);
      expect(body.contains("'p_delivery_otp': enteredOtp.trim(),"), isTrue);
    });

    test('_resendIntercityDeliveryOtp calls regenerate_intercity_delivery_otp -- the same '
        'server-generated-OTP RPC, never a client-side OTP generator', () {
      final start = source.indexOf('Future<String?> _resendIntercityDeliveryOtp(');
      final body = source.substring(start, start + 700);
      expect(body.contains("supabase.rpc('regenerate_intercity_delivery_otp', params: {"), isTrue);
    });

    test('on successful completion, order_status is optimistically set to delivered so this '
        "screen's existing completed-status redirect takes over automatically (no new completion "
        'screen built)', () {
      final start = source.indexOf('Future<String?> _completeIntercityParcelDelivery(');
      final end = source.indexOf('Future<String?> _resendIntercityDeliveryOtp(');
      final body = source.substring(start, end);
      expect(body.contains("order!['order_status'] = 'delivered';"), isTrue);
    });
  });

  group('drop-photo mechanism is confirmed order-type-agnostic (safe to reuse verbatim for '
      'intercity_parcel)', () {
    test('_takeVerificationPhoto uses a generic orders/ storage path and the generic '
        'process-verification-photo edge function -- still no order_type branching in its OWN '
        'body (Phase 3, Issue 5 added a call to a separate, dedicated, order_type-aware helper '
        'right after it -- see intercity_parcel_otp_exposure_regression_test.dart -- not inline '
        'branching within this function itself)', () {
      final start = source.indexOf('Future<void> _takeVerificationPhoto(String type) async {');
      final end = source.indexOf(
        'Future<void> _maybeGenerateIntercityDeliveryOtpAfterProof(String type) async {',
      );
      expect(end, greaterThan(start));
      final body = source.substring(start, end);
      expect(body.contains("'orders/\${widget.orderId}/verifications/\$type/"), isTrue);
      expect(body.contains("supabase.functions.invoke(\n        'process-verification-photo',"), isTrue);
      expect(body.contains("order_type"), isFalse);
    });
  });
}
