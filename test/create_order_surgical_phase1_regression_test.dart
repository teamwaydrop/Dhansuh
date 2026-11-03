// Regression checks for the tracked create-order production-control insertion.
// The former test depended on unversioned .audit_backup deployment files that are
// absent from this checkout. The immutable fixture is the real pre-control source
// from commit ed24dee (provenance and SHA-256 alongside it). It is not claimed to
// be the historical deployed v76 artifact. Current business features are preserved.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _baselinePath = 'test/fixtures/create_order_before_production_control.ts';

String _read(String path) => File(path).readAsStringSync();

/// Mirrors the exact if/else-if chain in the surgical file's PHASE 1 block.
/// Returns true if order creation should be REJECTED (503) for this order_type given these flags.
bool _isRejected(String orderType, Map<String, bool> flags) {
  bool enabled(String key) => flags[key] ?? true; // isFeatureEnabled's own default is true
  if (orderType == 'ride') {
    return !enabled('local_rides_enabled') || !enabled('ride_booking_enabled');
  } else if (orderType == 'local_parcel') {
    return !enabled('parcel_enabled');
  } else if (orderType == 'intercity_ride' || orderType == 'intercity_parcel') {
    return !enabled('intercity_enabled');
  }
  return false; // batch_delivery/food_delivery/grocery_delivery and anything else: never gated
}

void main() {
  late String surgical;
  late String prodBaseline;

  setUpAll(() {
    surgical = _read('supabase/functions/create-order/index.ts').replaceAll('\r\n', '\n');
    prodBaseline = _read(_baselinePath).replaceAll('\r\n', '\n');
  });

  group('0. The current create-order file preserves the tracked pre-control implementation', () {
    test('the tracked baseline file contains no Phase 1 code (the fixture is '
        'pre-control source, not the patched working copy)', () {
      expect(prodBaseline.contains('production_config'), isFalse);
      expect(prodBaseline.contains('PHASE 1'), isFalse);
    });

    test('the current file is tracked baseline + exactly 36 added lines, 0 removed, 0 '
        'changed elsewhere (one import plus the 35-line control insertion)', () {
      final prodLines = prodBaseline.split('\n').length;
      final surgicalLines = surgical.split('\n').length;
      expect(surgicalLines - prodLines, equals(36));
    });
  });

  group('A-F. Mirrored gate logic: real behavioral coverage of every required case', () {
    test('A. all flags true (or omitted -- defaults true) -> every order type proceeds '
        '(local ride, local parcel, intercity ride, intercity parcel)', () {
      final allTrue = {
        'local_rides_enabled': true,
        'ride_booking_enabled': true,
        'parcel_enabled': true,
        'intercity_enabled': true,
      };
      expect(_isRejected('ride', allTrue), isFalse);
      expect(_isRejected('local_parcel', allTrue), isFalse);
      expect(_isRejected('intercity_ride', allTrue), isFalse);
      expect(_isRejected('intercity_parcel', allTrue), isFalse);
      // Missing config (fail-open default) behaves identically to all-true.
      expect(_isRejected('ride', {}), isFalse);
      expect(_isRejected('local_parcel', {}), isFalse);
      expect(_isRejected('intercity_ride', {}), isFalse);
      expect(_isRejected('intercity_parcel', {}), isFalse);
    });

    test('B. local_rides_enabled=false -> local ride (order_type=ride) rejected', () {
      expect(
        _isRejected('ride', {'local_rides_enabled': false, 'ride_booking_enabled': true}),
        isTrue,
      );
    });

    test('C. ride_booking_enabled=false -> local ride (order_type=ride) rejected', () {
      expect(
        _isRejected('ride', {'local_rides_enabled': true, 'ride_booking_enabled': false}),
        isTrue,
      );
    });

    test('D. parcel_enabled=false -> local parcel (order_type=local_parcel) rejected', () {
      expect(_isRejected('local_parcel', {'parcel_enabled': false}), isTrue);
    });

    test('E. intercity_enabled=false -> intercity ride (order_type=intercity_ride) rejected', () {
      expect(_isRejected('intercity_ride', {'intercity_enabled': false}), isTrue);
    });

    test('F. intercity_enabled=false -> intercity parcel (order_type=intercity_parcel) rejected', () {
      expect(_isRejected('intercity_parcel', {'intercity_enabled': false}), isTrue);
    });

    test('parcel_enabled/intercity_enabled are fully independent -- disabling one never affects '
        'the other', () {
      expect(_isRejected('local_parcel', {'intercity_enabled': false}), isFalse);
      expect(_isRejected('intercity_parcel', {'parcel_enabled': false}), isFalse);
    });

    test('batch_delivery/food_delivery/grocery_delivery are never gated by any Phase 1 flag '
        '(no flag was requested for them)', () {
      final allFalse = {
        'local_rides_enabled': false,
        'ride_booking_enabled': false,
        'parcel_enabled': false,
        'intercity_enabled': false,
      };
      expect(_isRejected('batch_delivery', allFalse), isFalse);
      expect(_isRejected('food_delivery', allFalse), isFalse);
      expect(_isRejected('grocery_delivery', allFalse), isFalse);
    });

    test('the mirror above matches the real surgical source exactly (order_type branches, flag '
        'keys, and the 503/FEATURE_DISABLED rejection)', () {
      expect(surgical.contains('if (order_type === "ride") {'), isTrue);
      expect(surgical.contains('isFeatureEnabled(productionConfig, "local_rides_enabled")'), isTrue);
      expect(surgical.contains('isFeatureEnabled(productionConfig, "ride_booking_enabled")'), isTrue);
      expect(surgical.contains('} else if (order_type === "local_parcel") {'), isTrue);
      expect(surgical.contains('isFeatureEnabled(productionConfig, "parcel_enabled")'), isTrue);
      expect(
        surgical.contains('} else if (order_type === "intercity_ride" || order_type === "intercity_parcel") {'),
        isTrue,
      );
      expect(surgical.contains('isFeatureEnabled(productionConfig, "intercity_enabled")'), isTrue);
      expect(surgical.contains('throw new HttpError(503,'), isTrue);
      expect(surgical.contains('"FEATURE_DISABLED"'), isTrue);
    });

    test('the check runs after AUTH and after order_type is known, before any DB write (order '
        'INSERT, pricing calc, device/promo/OTP logging all happen later in the file)', () {
      final checkIdx = surgical.indexOf('if (order_type === "ride") {');
      final authIdx = surgical.indexOf('const { data: authData, error: authError } = await supabase.auth.getUser(authToken);');
      final insertOrderIdx = surgical.indexOf('INSERT ORDER');
      expect(authIdx, greaterThan(-1));
      expect(checkIdx, greaterThan(authIdx));
      expect(insertOrderIdx, greaterThan(checkIdx));
    });
  });

  group('G. Existing pricing, devices, OTP and vehicle behavior is preserved', () {
    test('verified bike/auto parcel selection already in the baseline remains', () {
      for (final marker in ['Bike cannot carry a parcel over 10kg', 'vehicle_type === "bike" || vehicle_type === "auto"']) {
        expect(prodBaseline.contains(marker), isTrue);
        expect(surgical.contains(marker), isTrue);
      }
    });

    test('existing parallel device/promo/OTP work remains rather than being reverted', () {
      for (final marker in ['deviceUpsertPromise', 'promoUsagePromise', 'otpLoggingPromise']) {
        expect(prodBaseline.contains(marker), isTrue);
        expect(surgical.contains(marker), isTrue);
      }
    });

    test('existing whole-rupee promo rounding is preserved', () {
      const expression = 'finalFare = Math.round(currentFare - appliedDiscount);';
      expect(prodBaseline.contains(expression), isTrue);
      expect(surgical.contains(expression), isTrue);
    });

    test('removing only the config import and control insertion reproduces the immutable baseline', () {
      const configImport = 'import { getProductionConfig, isFeatureEnabled } from "../_shared/production_config_cache.ts";\n';
      final withoutImport = surgical.replaceFirst(configImport, '');
      final start = withoutImport.indexOf('    // =====================================================\n    // PHASE 1 PRODUCTION CONTROL:');
      final end = withoutImport.indexOf('    // =====================================================\n    // NORMALIZE PARCEL TYPE', start);
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final restored = withoutImport.replaceRange(start, end, '');
      expect(restored, prodBaseline, reason: 'no pricing, authentication, financial, OTP or dispatch behavior outside the control insertion may change unnoticed');
    });

    test('all payment, financial, device, OTP and dispatch fields remain present', () {
      for (final marker in ['gst_amount', 'company_earning', 'calculatedParcelVehicle',
        'created_device_id', 'pickupOtp', 'deliveryOtp', 'payment_id', 'initialStatus', 'searchExpiryMinutes']) {
        expect(prodBaseline.contains(marker), isTrue, reason: 'baseline missing $marker');
        expect(surgical.contains(marker), isTrue, reason: 'implementation missing $marker');
      }
    });
  });
}
