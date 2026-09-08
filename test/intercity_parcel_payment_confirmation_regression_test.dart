// Regression guard for Issue 5: intercity parcel delivery had no explicit payment confirmation
// step -- the order went straight from 'rider_at_drop' to 'delivered' the instant the delivery OTP
// was verified, running full settlement automatically with no "Payment Received?" confirmation
// from the traveller at all, unlike local rides/parcels (which already stop at 'payment_pending'
// and require an explicit driver confirmation).
//
// ROOT CAUSE (confirmed via live function inspection, not assumed): complete_intercity_parcel_
// delivery(p_order_id, p_delivery_otp) did OTP verification AND full settlement in one call,
// transitioning 'rider_at_drop' -> 'delivered' directly.
//
// FIX (20260830000000_intercity_parcel_payment_confirmation_step.sql):
//   1. complete_intercity_parcel_delivery() (same name/params, no client change needed for the
//      OTP-entry step) now only verifies the OTP and moves 'rider_at_drop' -> 'payment_pending'.
//   2. confirm_intercity_parcel_payment_received(p_order_id) -- NEW -- requires 'payment_pending'
//      and runs the settlement logic reproduced byte-for-byte from the original function, gated
//      behind this explicit second call -- 'payment_pending' -> 'delivered'.
//   3. rider_active_order_screen.dart's updateStatus() routes intercity_parcel's payment_pending
//      confirmation through the new RPC (not the generic update-order-status edge function),
//      reusing the EXISTING "Confirm Payment Received" swipe-sheet UI unchanged.
//   4. intercity_bookings_screen.dart's OTP-entry list action now hands off to
//      RiderActiveOrderScreen after OTP verification, mirroring the exact same pattern already
//      used for rides, instead of claiming "Delivery completed successfully!" before payment was
//      ever confirmed.
//
// This file is a structural regression guard (reads the real migration/Dart source, following the
// pattern already used throughout this test suite for backend correctness that can't run against a
// live Supabase instance in a plain unit test).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read(
    'supabase/migrations/20260830000000_intercity_parcel_payment_confirmation_step.sql',
  );
  final activeOrderScreen = _read(
    'lib/features/rider/orders/screens/rider_active_order_screen.dart',
  );
  final bookingsScreen = _read('lib/features/rider/intercity/intercity_bookings_screen.dart');

  group('Issue 5 -- complete_intercity_parcel_delivery() now stops at payment_pending', () {
    test('OTP verification transitions rider_at_drop -> payment_pending, not -> delivered', () {
      final start = migration.indexOf(
        'CREATE OR REPLACE FUNCTION public.complete_intercity_parcel_delivery',
      );
      final end = migration.indexOf(
        'CREATE OR REPLACE FUNCTION public.confirm_intercity_parcel_payment_received',
      );
      expect(start, greaterThan(-1));
      final body = migration.substring(start, end);
      expect(
        body.contains(
          "SET order_status = 'payment_pending'::public.order_status_enum,\n        updated_at = v_now\n    WHERE id = v_order.id\n      AND order_status = 'rider_at_drop';",
        ),
        isTrue,
      );
      expect(body.contains("order_status = 'delivered'::public.order_status_enum"), isFalse,
          reason: 'the OTP-verify step must never itself mark the order delivered');
      // No settlement logic (fare breakdown, tax, wallet credit) in this function anymore.
      expect(body.contains('calculate_fare_breakdown'), isFalse);
      expect(body.contains('credit_rider_for_completed_order'), isFalse);
      expect(body.contains('apply_order_government_tax'), isFalse);
    });

    test('the OTP check itself is unchanged', () {
      expect(
        migration.contains(
          'IF v_order.delivery_otp IS NULL OR p_delivery_otp IS NULL OR v_order.delivery_otp <> p_delivery_otp THEN',
        ),
        isTrue,
      );
    });
  });

  group('Issue 5 -- confirm_intercity_parcel_payment_received() (the new explicit confirmation)',
      () {
    test('requires order_status = payment_pending before running settlement', () {
      final start = migration.indexOf(
        'CREATE OR REPLACE FUNCTION public.confirm_intercity_parcel_payment_received',
      );
      expect(start, greaterThan(-1));
      final body = migration.substring(start);
      expect(
        body.contains("IF v_order.order_status::text <> 'payment_pending' THEN"),
        isTrue,
      );
    });

    test('settlement logic (fare breakdown, tax, subscription waiver, wallet credit, completion '
        'sync) is preserved', () {
      final start = migration.indexOf(
        'CREATE OR REPLACE FUNCTION public.confirm_intercity_parcel_payment_received',
      );
      final body = migration.substring(start);
      for (final clause in [
        'public.calculate_fare_breakdown(',
        'public.apply_order_government_tax(',
        'public.credit_rider_for_completed_order(',
        "UPDATE public.intercity_requests\n    SET status = 'completed'",
        "UPDATE public.rider_travel_plans\n        SET status = 'completed'",
      ]) {
        expect(body.contains(clause), isTrue, reason: 'missing/altered: $clause');
      }
    });

    test('the authoritative fare (including any boost) is read exactly as before -- final_fare '
        'first, current_fare fallback', () {
      expect(
        migration.contains('v_fare := COALESCE(v_order.final_fare, v_order.current_fare, 0);'),
        isTrue,
      );
    });

    test('financial/state guards use the same authorized bypass pattern, never a raw write', () {
      expect(migration.contains("set_config('app.bypass_rider_financial_guard', 'true', true)"),
          isTrue);
      expect(migration.contains("set_config('app.bypass_financial_guard', 'true', true)"), isTrue);
      expect(migration.contains("set_config('app.bypass_order_state_guard', 'true', true)"),
          isTrue);
    });

    test('is granted to authenticated', () {
      expect(
        migration.contains(
          'GRANT EXECUTE ON FUNCTION public.confirm_intercity_parcel_payment_received(uuid) TO authenticated;',
        ),
        isTrue,
      );
    });
  });

  group('Issue 5 -- client wiring', () {
    test('updateStatus() routes intercity_parcel payment_pending confirmation through the new '
        'RPC, not the generic edge function', () {
      final start = activeOrderScreen.indexOf('Future<bool> updateStatus(');
      expect(start, greaterThan(-1));
      final body = activeOrderScreen.substring(start, start + 3000);
      expect(
        body.contains(
          "orderType == 'intercity_parcel' &&\n          currentOrderStatus == 'payment_pending'",
        ),
        isTrue,
      );
      expect(
        body.contains("rpc('confirm_intercity_parcel_payment_received'"),
        isTrue,
      );
      final rpcIndex = body.indexOf('confirm_intercity_parcel_payment_received');
      final edgeFnIndex = body.indexOf("'update-order-status'");
      expect(rpcIndex, greaterThan(-1));
      expect(edgeFnIndex, greaterThan(-1));
      expect(rpcIndex, lessThan(edgeFnIndex),
          reason: 'the intercity_parcel branch must be checked and return before ever reaching '
              'the generic update-order-status call');
    });

    test('every other order type/transition still goes through the unchanged generic '
        'update-order-status path', () {
      expect(activeOrderScreen.contains("'update-order-status'"), isTrue);
    });

    test('intercity_bookings_screen hands off to RiderActiveOrderScreen after OTP verification, '
        'instead of claiming delivery is complete before payment is confirmed', () {
      final start = bookingsScreen.indexOf('Future<void> _completeParcel(');
      expect(start, greaterThan(-1));
      final end = bookingsScreen.indexOf('\n  }', start);
      final body = bookingsScreen.substring(start, end > start ? end : start + 1500);
      expect(
        body.contains('MaterialPageRoute(builder: (context) => RiderActiveOrderScreen(orderId: orderId))'),
        isTrue,
      );
      expect(body.contains('Delivery completed successfully!'), isFalse,
          reason: 'must never claim completion before the payment-confirmation step has run');
    });
  });
}
