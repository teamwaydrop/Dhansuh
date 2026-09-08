// Regression guard for PHASE 3, Issue 5 (HIGH PRIORITY security/privacy): the intercity parcel
// delivery/completion OTP must never be generated or exposed to the traveller before the mandatory
// delivery-proof photo is captured.
//
// ROOT CAUSE: mark_intercity_trip_at_dropoff() generated and returned a real delivery_otp
// unconditionally the instant order_status became 'rider_at_drop' -- before any photo-proof step
// exists or runs. Both client call sites (rider_active_order_screen.dart,
// intercity_bookings_screen.dart) immediately showed it via SnackBar. Photo-proof was a client-
// side-only UI gate that ran AFTER this call, so it never actually gated OTP exposure.
//
// FIX: for intercity_parcel only, mark_intercity_trip_at_dropoff() no longer generates/returns an
// OTP. A new function, generate_intercity_delivery_otp_after_proof(), generates it (and notifies
// the passenger directly) only once a verified/bypassed order_verifications dropoff row exists,
// and never returns the OTP value. regenerate_intercity_delivery_otp() gets the same photo-proof
// precondition so it can't be used to bypass. intercity_ride is unchanged in both functions.
//
// Structural guard (reads the real source + migration SQL), matching the pattern used throughout
// this suite for backend correctness that can't run against a live Supabase instance here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read('supabase/migrations/20260823000000_phase3_intercity_fixes.sql');

  group('mark_intercity_trip_at_dropoff() -- parcels get no OTP at arrival time', () {
    final start = migration.indexOf('CREATE OR REPLACE FUNCTION public.mark_intercity_trip_at_dropoff(');
    final end = migration.indexOf('CREATE OR REPLACE FUNCTION public.regenerate_intercity_delivery_otp(');
    final body = migration.substring(start, end);

    test('the intercity_parcel branch marks arrival without ever generating/setting delivery_otp', () {
      final parcelBranchStart = body.indexOf("IF v_order.order_type::text = 'intercity_parcel' THEN");
      final parcelBranchEnd = body.indexOf('-- intercity_ride: unchanged behavior');
      final parcelBranch = body.substring(parcelBranchStart, parcelBranchEnd);
      // The branch's own explanatory comment legitimately mentions "delivery_otp" by name (to
      // explain why it's absent) -- what matters is the SQL itself never assigns it. Check the
      // actual UPDATE statement's SET clause, not the whole branch text.
      final updateStart = parcelBranch.indexOf('UPDATE public.orders');
      final updateEnd = parcelBranch.indexOf('WHERE id = v_order.id;');
      final updateStatement = parcelBranch.substring(updateStart, updateEnd);
      expect(updateStatement.contains('delivery_otp'), isFalse);
      expect(parcelBranch.contains("order_status = 'rider_at_drop'::public.order_status_enum"), isTrue);
      expect(
        parcelBranch.contains("RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_id', v_order.id);"),
        isTrue,
      );
    });

    test('intercity_ride keeps generating and returning delivery_otp exactly as before (no '
        'photo-proof concept exists for rides -- unrelated, must not change)', () {
      expect(
        body.contains("RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_id', v_order.id, 'delivery_otp', v_otp);"),
        isTrue,
      );
    });

    test("the already-at-dropoff idempotent replay also withholds the OTP for parcels", () {
      expect(
        body.contains(
          "'delivery_otp', CASE WHEN v_order.order_type::text = 'intercity_ride' THEN v_order.delivery_otp ELSE NULL END",
        ),
        isTrue,
      );
    });
  });

  group('generate_intercity_delivery_otp_after_proof() -- the only place a parcel delivery OTP is '
      'ever generated', () {
    final start = migration.indexOf('CREATE OR REPLACE FUNCTION public.generate_intercity_delivery_otp_after_proof(');
    final end = migration.indexOf('GRANT EXECUTE ON FUNCTION public.generate_intercity_delivery_otp_after_proof');
    final body = migration.substring(start, end);

    test('requires order_status = rider_at_drop', () {
      expect(body.contains("v_order.order_status::text <> 'rider_at_drop'"), isTrue);
    });

    test('requires a verified or bypassed dropoff order_verifications row before generating', () {
      expect(body.contains("verification_type = 'dropoff'"), isTrue);
      expect(body.contains("verification_status IN ('verified', 'bypassed')"), isTrue);
      expect(body.contains("'code', 'PROOF_REQUIRED'"), isTrue);
    });

    test('is idempotent -- a retry after the OTP already exists is a safe no-op, not a silent '
        'regeneration', () {
      expect(body.contains('IF v_order.delivery_otp IS NOT NULL THEN'), isTrue);
      expect(body.contains("'code', 'ALREADY_GENERATED'"), isTrue);
    });

    test('notifies the PASSENGER directly with the OTP (this transition does not change '
        'order_status, so the generic trigger never fires it automatically)', () {
      expect(body.contains('send_push_notification_fnc(\n            v_order.user_id,'), isTrue);
      expect(body.contains('Please share OTP'), isTrue);
    });

    test('the response never includes the OTP value -- the traveller\'s client has nothing to '
        'render even if it tried', () {
      final returnStatements = RegExp(r"RETURN jsonb_build_object\([^;]*?\);", dotAll: true)
          .allMatches(body)
          .map((m) => m.group(0)!)
          .toList();
      for (final stmt in returnStatements) {
        expect(stmt.contains('delivery_otp'), isFalse, reason: 'found delivery_otp in: $stmt');
      }
    });
  });

  group('regenerate_intercity_delivery_otp() -- cannot be used to bypass the photo-proof gate', () {
    final start = migration.indexOf('CREATE OR REPLACE FUNCTION public.regenerate_intercity_delivery_otp(');
    final end = migration.indexOf('-- New: the gated "first generation" step');
    final body = migration.substring(start, end);

    test('for intercity_parcel, requires the same verified/bypassed dropoff proof before '
        'resending/regenerating', () {
      final parcelGuardStart = body.indexOf("IF v_order.order_type::text = 'intercity_parcel' THEN");
      final parcelGuardEnd = body.indexOf('LOOP', parcelGuardStart);
      final guard = body.substring(parcelGuardStart, parcelGuardEnd);
      expect(guard.contains("verification_type = 'dropoff'"), isTrue);
      expect(guard.contains("verification_status IN ('verified', 'bypassed')"), isTrue);
      expect(guard.contains("'code', 'PROOF_REQUIRED'"), isTrue);
    });

    test('notifies the passenger on every parcel (re)generation, so a resent OTP is never silently '
        'unknown to the passenger', () {
      expect(
        body.contains("IF v_order.order_type::text = 'intercity_parcel' AND v_order.user_id IS NOT NULL THEN"),
        isTrue,
      );
    });
  });

  group('rider_active_order_screen.dart -- traveller never sees the OTP digits', () {
    final source = _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');

    test('_markIntercityParcelAtDropoff() SnackBar no longer contains the OTP value', () {
      final start = source.indexOf('Future<void> _markIntercityParcelAtDropoff() async {');
      final end = source.indexOf('} catch (e) {', start);
      final body = source.substring(start, end);
      expect(body.contains('Completion OTP generated'), isFalse);
      expect(body.contains("data['delivery_otp']"), isFalse);
      expect(
        body.contains('Marked arrived at drop-off. Please capture the delivery proof photo to continue.'),
        isTrue,
      );
    });

    test('a successful dropoff photo (camera capture) automatically calls the gated OTP-'
        'generation RPC', () {
      final start = source.indexOf("Future<void> _takeVerificationPhoto(String type) async {");
      final end = source.indexOf('Future<void> _showBypassDialog(');
      final body = source.substring(start, end);
      expect(body.contains('await _maybeGenerateIntercityDeliveryOtpAfterProof(type);'), isTrue);
    });

    test('a successful dropoff photo BYPASS also triggers the same gated OTP-generation call '
        '(bypassed proof is an accepted form of proof server-side too)', () {
      final start = source.indexOf('Future<void> _bypassVerification(String type, String reason) async {');
      final end = source.indexOf('ScaffoldMessenger.of(context).showSnackBar(\n        SnackBar(', start);
      final body = source.substring(start, end);
      expect(body.contains('await _maybeGenerateIntercityDeliveryOtpAfterProof(type);'), isTrue);
    });

    test('_maybeGenerateIntercityDeliveryOtpAfterProof calls the correct RPC and is scoped to '
        'dropoff + intercity_parcel only', () {
      final start = source.indexOf('Future<void> _maybeGenerateIntercityDeliveryOtpAfterProof(String type) async {');
      expect(start, greaterThanOrEqualTo(0));
      final body = source.substring(start, start + 500);
      expect(body.contains("if (type != 'dropoff' || order?['order_type'] != 'intercity_parcel') return;"), isTrue);
      expect(body.contains("supabase.rpc('generate_intercity_delivery_otp_after_proof'"), isTrue);
    });

    test('the OtpSheetContent resend flow still never renders the returned OTP digits (pre-'
        'existing, unrelated, confirmed unchanged)', () {
      expect(source.contains("_successMessage = 'OTP regenerated successfully!';"), isTrue);
    });
  });

  group('intercity_bookings_screen.dart -- parcels can no longer reach the unguarded direct '
      'Arrived/OTP flow (this screen has no photo-capture UI at all)', () {
    final source = _read('lib/features/rider/intercity/intercity_bookings_screen.dart');

    test('the Arrived/Verify OTP button redirects parcel bookings to RiderActiveOrderScreen '
        'instead of calling _markRideArrived/_showOtpDialog directly', () {
      final commentStart = source.indexOf('// Phase 3 fix (Issue 5): intercity_parcel');
      final blockEnd = source.indexOf("_showOtpDialog(req, isRide: isRide);", commentStart);
      expect(commentStart, greaterThanOrEqualTo(0));
      expect(blockEnd, greaterThan(commentStart));
      final body = source.substring(commentStart, blockEnd);
      expect(body.contains('if (!isRide) {'), isTrue);
      expect(body.contains("RiderActiveOrderScreen(orderId: req['parcel_id'])"), isTrue);
    });

    test('ride behavior (isRide == true) through this button is completely unchanged', () {
      expect(source.contains("_showOtpDialog(req, isRide: isRide);"), isTrue);
      expect(source.contains('_markRideArrived(req);'), isTrue);
    });
  });
}
