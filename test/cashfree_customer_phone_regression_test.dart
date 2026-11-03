// Regression guard: Cashfree checkout must show the REAL customer's phone number
// ("Payment Options for +91 98XXXXXXXX"), never the hardcoded "+91 9999999999".
//
// Root cause that was fixed:
//   - create-payment/index.ts built customer_details.customer_phone as
//     `user.phone ?? "9999999999"` -- any account whose phone wasn't populated on the
//     JWT (notably the reviewer bypass account, but also any transient case) got the
//     literal test number.
//   - create-fare-qr/index.ts hardcoded `customer_phone: "9999999999"` unconditionally,
//     so EVERY passenger's QR checkout showed the test number.
//
// The fix: a shared helper supabase/functions/_shared/customer_phone.ts resolves the
// real verified number from auth.users.phone (mirrored to public.users.phone). The
// reviewer bypass account (is_anonymous) keeps the test number; a real user with no
// phone on file is rejected / falls back rather than being shown an invented number.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  final helper = _read('supabase/functions/_shared/customer_phone.ts');
  final createPayment = _read('supabase/functions/create-payment/index.ts');
  final createFareQr = _read('supabase/functions/create-fare-qr/index.ts');

  // Only the guarded reviewer-bypass constant may carry the string literal; no
  // customer_phone field may be assigned it directly.
  final forbiddenLiterals = [
    'customer_phone: "9999999999"',
    "customer_phone: '9999999999'",
    'customer_phone: user.phone ?? "9999999999"',
    'customer_phone: order.user_id',
  ];

  group('1. shared helper exists and is the single source of truth', () {
    test('normalizeIndianPhone + resolveCashfreeCustomerPhone are exported', () {
      expect(helper.contains('export function normalizeIndianPhone('), isTrue);
      expect(helper.contains('export async function resolveCashfreeCustomerPhone('), isTrue);
    });

    test('the test number is a named, documented constant -- not an inline literal', () {
      expect(helper.contains('export const CASHFREE_REVIEWER_TEST_PHONE = "9999999999";'), isTrue);
    });

    test('the test number is gated behind an explicit is_anonymous check', () {
      expect(helper.contains('is_anonymous === true'), isTrue);
      // and it only returns the test number inside that branch
      final idxGate = helper.indexOf('is_anonymous === true');
      final idxReturn = helper.indexOf('return { phone: CASHFREE_REVIEWER_TEST_PHONE');
      expect(idxGate, greaterThanOrEqualTo(0));
      expect(idxReturn, greaterThan(idxGate));
    });

    test('falls back to public.users.phone, then returns null (never invents a number)', () {
      expect(helper.contains('.from("users").select("phone")'), isTrue);
      expect(helper.contains('return phone ? { phone, isReviewer: false } : { phone: null, isReviewer: false };'), isTrue);
    });

    test('normalizeIndianPhone strips a leading 91 country code to 10 digits', () {
      expect(helper.contains(r'/^\d{10}$/'), isTrue);
      expect(helper.contains('digits.startsWith("91")'), isTrue);
    });
  });

  group('2. create-payment uses the helper, not a phone literal', () {
    test('imports resolveCashfreeCustomerPhone from the shared module', () {
      expect(
        createPayment.contains('import { resolveCashfreeCustomerPhone } from "../_shared/customer_phone.ts";'),
        isTrue,
      );
    });

    test('resolves the caller\'s phone and passes it through to Cashfree', () {
      expect(createPayment.contains('await resolveCashfreeCustomerPhone(supabaseAdmin, user.id)'), isTrue);
      expect(createPayment.contains('customer_phone: customerPhone,'), isTrue);
    });

    test('rejects with HTTP 422 when no real phone is on file', () {
      expect(createPayment.contains('resolvedPhone.phone === null'), isTrue);
      expect(createPayment.contains('"phone_number_missing"'), isTrue);
      expect(createPayment.contains('status: 422'), isTrue);
    });

    test('no forbidden phone literal remains', () {
      for (final bad in forbiddenLiterals) {
        expect(createPayment.contains(bad), isFalse, reason: 'create-payment still contains: $bad');
      }
    });
  });

  group('3. create-fare-qr uses the helper for the PASSENGER, not a phone literal', () {
    test('imports resolveCashfreeCustomerPhone from the shared module', () {
      expect(
        createFareQr.contains('import { resolveCashfreeCustomerPhone } from "../_shared/customer_phone.ts";'),
        isTrue,
      );
    });

    test('resolves order.user_id (the passenger) -- caller may be the driver', () {
      expect(createFareQr.contains('await resolveCashfreeCustomerPhone(supabaseAdmin, order.user_id)'), isTrue);
      expect(createFareQr.contains('customer_phone: customerPhone,'), isTrue);
    });

    test('missing passenger phone falls back to qr_available:false, not an invented number', () {
      expect(createFareQr.contains('resolvedPhone.phone === null'), isTrue);
      expect(createFareQr.contains('qr_available: false, reason: QR_UNAVAILABLE_MESSAGE'), isTrue);
    });

    test('no forbidden phone literal remains', () {
      for (final bad in forbiddenLiterals) {
        expect(createFareQr.contains(bad), isFalse, reason: 'create-fare-qr still contains: $bad');
      }
    });
  });

  group('4. nothing else changed in the Cashfree order payload', () {
    test('create-payment order payload keeps amount/currency untouched', () {
      expect(createPayment.contains('order_amount: finalAmount,'), isTrue);
      expect(createPayment.contains('order_currency: "INR",'), isTrue);
    });
    test('create-fare-qr order payload keeps UPI-only restriction + amount', () {
      expect(createFareQr.contains('payment_methods: "upi"'), isTrue);
      expect(createFareQr.contains('order_amount: finalAmount,'), isTrue);
    });
  });
}
