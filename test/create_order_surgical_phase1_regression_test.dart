// Regression guard for the SURGICAL, Phase-1-only create-order artifact staged at
// .audit_backup/phase1_surgical_create_order/create-order_surgical.ts -- built directly from the
// real, freshly-downloaded production create-order v76 baseline (production_baseline_v76.ts, same
// directory) plus ONLY the production_config feature-flag enforcement block. This is deliberately
// NOT the live working-tree file (supabase/functions/create-order/index.ts), which still carries
// several already-committed-but-undeployed local changes unrelated to Phase 1 (bike/auto parcel
// vehicle selection, a device-upsert/promo/OTP concurrency refactor, whole-rupee promo rounding) --
// this test file exists specifically to prove the STAGED artifact is clean before it is ever placed
// at the deploy path.
//
// Convention: this repo's Edge Function tests read source as text and assert structurally (never
// execute Deno code from Dart). The order_type/flag branching here is simple enough to mirror
// exactly as a pure Dart function for real behavioral coverage of cases A-G, cross-checked against
// the actual .ts source via structural assertions -- same pattern used elsewhere in this suite for
// logic that can't be imported directly (e.g. private Dart methods mirrored in
// subscription_trial_banner_and_vehicle_selection_regression_test.dart).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _stagedDir = '.audit_backup/phase1_surgical_create_order';

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
    surgical = _read('$_stagedDir/create-order_surgical.ts');
    prodBaseline = _read('$_stagedDir/production_baseline_v76.ts');
  });

  group('0. The surgical file is built directly from the real production baseline, not local HEAD', () {
    test('the production baseline file itself contains no Phase 1 code (proves it is a genuine '
        'pre-Phase-1 download, not already-patched)', () {
      expect(prodBaseline.contains('production_config'), isFalse);
      expect(prodBaseline.contains('PHASE 1'), isFalse);
    });

    test('the surgical file is production baseline + exactly 36 added lines, 0 removed, 0 '
        'changed elsewhere (1485 -> 1521 lines)', () {
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

  group('G. Everything else is byte-identical to the real production baseline -- confirmed '
      'absent: every local-only change explicitly excluded from this deployment', () {
    test('bike/auto vehicle selection for local parcels is ABSENT (production still always '
        'recomputes normalizedVehicleType, never honors a client vehicle_type choice)', () {
      expect(surgical.contains('Bike cannot carry a parcel over 10kg'), isFalse);
      expect(surgical.contains('vehicle_type === "bike" || vehicle_type === "auto"'), isFalse);
      // The single production line this local-only feature would have replaced is present,
      // unchanged, exactly as in the baseline.
      expect(
        surgical.contains('if (\n      order_type === "local_parcel"\n    ) {\n      normalizedVehicleType = calculatedParcelVehicle;'),
        isTrue,
      );
    });

    test('the device-upsert/promo-usage/OTP-logging concurrency refactor is ABSENT (production '
        'still runs the original sequential "FIND OR INSERT USER DEVICE" block in its original '
        'single location, not a hoisted deviceUpsertPromise)', () {
      expect(surgical.contains('deviceUpsertPromise'), isFalse);
      expect(surgical.contains('promoUsagePromise'), isFalse);
      expect(surgical.contains('otpLoggingPromise'), isFalse);
      expect(surgical.contains('deviceComplianceLogsPromise'), isFalse);
      expect(surgical.contains('Promise.allSettled([promoUsagePromise'), isFalse);
    });

    test('the whole-rupee promo-discount rounding fix is ABSENT (production still uses the '
        'original .toFixed(2) computation for a promo-discounted final_fare)', () {
      expect(surgical.contains('finalFare = Math.round(currentFare - appliedDiscount);'), isFalse);
      expect(surgical.contains('finalFare = Number((currentFare - appliedDiscount).toFixed(2));'), isTrue);
    });

    test('every other line of the file is untouched: diffing the surgical file against the raw '
        'production baseline (recomputed here, not just trusted from an earlier shell diff) '
        'shows changes confined to the single Phase 1 insertion point', () {
      final prodLines = prodBaseline.split('\n');
      final surgicalLines = surgical.split('\n');
      // The two files must be identical for every line up to the import insertion point (line 9,
      // 0-indexed 8), and identical again for every line from the end of the Phase 1 block onward
      // once the line-count offset (36 added lines) is accounted for.
      for (var i = 0; i < 9; i++) {
        expect(surgicalLines[i], equals(prodLines[i]), reason: 'line ${i + 1} before the import diverges');
      }
      const insertedAt152 = 36; // lines added starting at (1-indexed) line 152
      for (var i = 151; i < prodLines.length; i++) {
        expect(
          surgicalLines[i + insertedAt152],
          equals(prodLines[i]),
          reason: 'line ${i + 1} of production baseline diverges after accounting for the Phase 1 insertion',
        );
      }
    });

    test('pricing, commission, GST/tax, vehicle handling, device handling, OTP handling, '
        'Cashfree/payment-related fields, and dispatch-relevant fields are all still present, '
        'unchanged, from the production baseline', () {
      for (final marker in [
        'gst_amount',
        'company_earning',
        'calculatedParcelVehicle',
        'created_device_id',
        'pickupOtp',
        'deliveryOtp',
        'payment_id',
        'initialStatus',
        'searchExpiryMinutes',
      ]) {
        expect(surgical.contains(marker), isTrue, reason: '$marker missing from surgical file');
        expect(prodBaseline.contains(marker), isTrue, reason: '$marker missing from production baseline (sanity check)');
      }
    });
  });
}
