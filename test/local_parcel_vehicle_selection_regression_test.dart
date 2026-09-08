// Regression guard for "local parcel booking auto-decides Bike vs Auto from weight instead of
// letting the user choose" (PHASE 1, Issue 2).
//
// ROOT CAUSE (traced client -> pricing -> order creation):
//   1. pricing_controller.dart's _fetchPricingFallback collapsed every non-ride order type
//      (including local_parcel) to a single vehicle picked from weight, so the UI never even
//      received both Bike and Auto pricing to offer.
//   2. parcel_booking_screen.dart auto-assigned selectedVehicle from whatever single vehicle came
//      back, with no selector UI at all.
//   3. create-order/index.ts unconditionally overrode vehicle_type for local_parcel with a
//      server-recomputed weight-based value, discarding any client selection.
//   4. calculate-order-pricing/index.ts trusted an explicit client vehicle_type with no weight
//      validation at all.
//
// FIX: pricing_controller now returns every weight-eligible vehicle for local_parcel; the booking
// screen renders a Bike/Auto selector (reusing ride_location_screen.dart's card pattern) and no
// longer auto-picks; both edge functions now honor an explicit, weight-valid client selection and
// reject (not silently override) an invalid Bike/weight combination. intercity_parcel is
// deliberately left on its original weight-based auto-pick everywhere (out of Phase 1 scope).
//
// Structural guard (reads the real source), matching the pattern used throughout this suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('PricingController -- local_parcel offers every weight-eligible vehicle', () {
    final source = _read('lib/modules/payments/controllers/pricing_controller.dart');
    final fallbackBody = source.substring(
      source.indexOf('Future<void> _fetchPricingFallback('),
      source.indexOf('Future<MapEntry<String, dynamic>?> _fetchSinglePricing('),
    );

    test('local_parcel is branched separately from the generic weight->single-vehicle fallback', () {
      expect(fallbackBody.contains("orderType == 'local_parcel'"), isTrue);
    });

    test('local_parcel offers both Bike and Auto for a light parcel, not a forced single pick', () {
      expect(
        fallbackBody.contains("weight > 10.0 ? ['auto'] : ['bike', 'auto']"),
        isTrue,
        reason: 'the user must be able to choose between Bike and Auto whenever both are eligible',
      );
    });

    test('intercity_parcel keeps the original single-vehicle weight-based behavior untouched', () {
      // The generic else-branch (still `[weight > 10.0 ? 'auto' : 'bike']`) must still exist for
      // every order type that isn't ride/local_parcel -- Phase 1 does not touch Intercity.
      expect(fallbackBody.contains("vehicles = [weight > 10.0 ? 'auto' : 'bike'];"), isTrue);
    });
  });

  group('ParcelBookingScreen -- user selects Bike/Auto, app never auto-decides for local_parcel', () {
    final source = _read('lib/features/local_parcels/booking/screens/parcel_booking_screen.dart');

    test('_fetchPricing() does not auto-assign selectedVehicle for local_parcel', () {
      final fetchPricingBody = source.substring(
        source.indexOf('Future<void> _fetchPricing() async {'),
        source.indexOf('void _selectVehicle('),
      );
      final localParcelBranchStart = fetchPricingBody.indexOf("widget.orderType == 'local_parcel'");
      expect(localParcelBranchStart, greaterThanOrEqualTo(0));
      final localParcelBranch = fetchPricingBody.substring(
        localParcelBranchStart,
        fetchPricingBody.indexOf('return;', localParcelBranchStart),
      );
      expect(
        localParcelBranch.contains('selectedVehicle = pricingController.pricingData.keys.first'),
        isFalse,
        reason: 'local_parcel must never have its vehicle auto-picked by the app',
      );
    });

    test('a Bike/Auto selector is rendered, gated to local_parcel and to vehicles pricing '
        'actually resolved as eligible', () {
      expect(source.contains("widget.orderType == 'local_parcel' && !loading"), isTrue);
      expect(source.contains("pricingData.containsKey('bike')"), isTrue);
      expect(source.contains("pricingData.containsKey('auto')"), isTrue);
      expect(source.contains('_selectVehicle('), isTrue);
    });

    test('the booking button stays disabled until a vehicle is selected (pre-existing guard, '
        'must survive this change)', () {
      expect(source.contains('(selectedVehicle == null || isLocked) ? null : _createOrder'), isTrue);
    });
  });

  group('create-order edge function -- honors and validates the client vehicle selection for '
      'local_parcel', () {
    final source = _read('supabase/functions/create-order/index.ts');
    final localParcelBlockStart = source.indexOf('order_type === "local_parcel"');
    final localParcelBlockEnd = source.indexOf('order_type ===\n      "intercity_parcel"');
    final localParcelBlock = source.substring(localParcelBlockStart, localParcelBlockEnd);

    test('an explicit bike/auto selection from the client is honored instead of always being '
        'overridden', () {
      expect(localParcelBlock.contains('normalizedVehicleType = vehicle_type;'), isTrue);
    });

    test('an over-weight Bike selection is rejected (400), not silently swapped to Auto', () {
      expect(localParcelBlock.contains('vehicle_type === "bike" && parcelWeight > 10'), isTrue);
      expect(localParcelBlock.contains('throw new HttpError('), isTrue);
    });

    test('missing/invalid vehicle_type still falls back to the weight-based default '
        '(back-compat for other callers)', () {
      expect(localParcelBlock.contains('normalizedVehicleType = calculatedParcelVehicle;'), isTrue);
    });

    test('intercity_parcel branch is untouched (still always server-recomputed)', () {
      final intercityBlockStart = localParcelBlockEnd;
      final intercityBlock = source.substring(intercityBlockStart, intercityBlockStart + 190);
      expect(intercityBlock.contains('normalizedVehicleType = calculatedParcelVehicle;'), isTrue);
      expect(intercityBlock.contains('vehicle_type ==='), isFalse);
    });
  });

  group('calculate-order-pricing edge function -- rejects invalid Bike/weight combos for '
      'local_parcel before pricing', () {
    final source = _read('supabase/functions/calculate-order-pricing/index.ts');

    test('a Bike selection over 10kg is rejected for local_parcel', () {
      expect(
        source.contains(
          'order_type === "local_parcel" && resolvedVehicleType === "bike" && inputWeight > 10',
        ),
        isTrue,
      );
    });

    test('intercity_parcel keeps its original weight-based auto-resolve without the new bike '
        'rejection branch applying to it', () {
      // The rejection condition is explicitly scoped to order_type === "local_parcel" (checked
      // above); intercity_parcel only ever hits the pre-existing "!resolvedVehicleType" branch.
      expect(source.contains('resolvedVehicleType = inputWeight > 10 ? "auto" : "bike";'), isTrue);
    });
  });
}
