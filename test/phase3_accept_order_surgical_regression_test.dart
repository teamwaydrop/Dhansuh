// Phase 3/4 regression guard for the production-config feature-flag gate in accept-order.
//
// HISTORY: the Phase 3 gate was originally drafted and verified only against a staged artifact
// at .audit_backup/phase3_accept_order_status/accept-order_surgical.ts -- this test file
// originally asserted against that staged copy, not the live working-tree file
// (supabase/functions/accept-order/index.ts). That let the staged patch sit undeployed for a
// full audit phase while this suite stayed green, because it was never actually checking
// production's own source. The Phase 4 audit (2026-08-25) proved this drift and this file was
// rewritten to assert against the LIVE source only, exactly as production_control_system_
// regression_test.dart already does for create-order/create-payment/send-push-notification.
//
// SAFETY DECISION (see the Phase 3/4 conversation reports for the full trace): update-order-status
// was deliberately left UNMODIFIED after tracing its transition table and confirming, via a grep
// of every real client call site, that 'accepted' is never actually sent as new_status by the
// Flutter app (both real callers -- rider_active_order_screen.dart, intercity_bookings_screen.dart
// -- only run after acceptance already happened via accept-order). accept-order is therefore the
// sole, exclusive path that finalizes a NEW local/parcel dispatch match, and gating it there (not
// in update-order-status, which only ever progresses/terminates an ALREADY-existing order) is the
// only safe place for this control -- blocking anything in update-order-status would strand
// in-progress trips.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// Mirrors the exact if/else-if chain in accept-order's live PHASE 3 block -- identical shape to
/// create-order's own gate (see create_order_surgical_phase1_regression_test.dart), reused here
/// for real behavioral coverage without duplicating a Deno interpreter.
bool _isRejected(String orderType, Map<String, bool> flags) {
  bool enabled(String key) => flags[key] ?? true;
  if (orderType == 'ride') {
    return !enabled('local_rides_enabled') || !enabled('ride_booking_enabled');
  } else if (orderType == 'local_parcel') {
    return !enabled('parcel_enabled');
  } else if (orderType == 'intercity_ride' || orderType == 'intercity_parcel') {
    return !enabled('intercity_enabled');
  }
  return false;
}

void main() {
  late String liveAcceptOrder;
  late String liveUpdateOrderStatus;

  setUpAll(() {
    liveAcceptOrder = _read('supabase/functions/accept-order/index.ts');
    liveUpdateOrderStatus = _read('supabase/functions/update-order-status/index.ts');
  });

  group('0. The gate is live in the actual deployed source, not just staged', () {
    test('accept-order imports the shared production_config cache', () {
      expect(
        liveAcceptOrder.contains(
          'import { getProductionConfig, isFeatureEnabled } from "../_shared/production_config_cache.ts";',
        ),
        isTrue,
      );
    });

    test('accept-order actually calls getProductionConfig at runtime (not just imports it)', () {
      expect(liveAcceptOrder.contains('const productionConfig = await getProductionConfig(supabase);'), isTrue);
    });
  });

  group('A-F. Mirrored gate logic: real behavioral coverage', () {
    test('all flags true/missing (fail-open default) -> every order type proceeds', () {
      expect(_isRejected('ride', {}), isFalse);
      expect(_isRejected('local_parcel', {}), isFalse);
      expect(_isRejected('intercity_ride', {}), isFalse);
      expect(_isRejected('intercity_parcel', {}), isFalse);
    });

    test('local_rides_enabled=false -> ride acceptance rejected', () {
      expect(_isRejected('ride', {'local_rides_enabled': false, 'ride_booking_enabled': true}), isTrue);
    });

    test('ride_booking_enabled=false -> ride acceptance rejected', () {
      expect(_isRejected('ride', {'local_rides_enabled': true, 'ride_booking_enabled': false}), isTrue);
    });

    test('parcel_enabled=false -> local parcel acceptance rejected', () {
      expect(_isRejected('local_parcel', {'parcel_enabled': false}), isTrue);
    });

    test('intercity_enabled=false -> intercity ride acceptance rejected', () {
      expect(_isRejected('intercity_ride', {'intercity_enabled': false}), isTrue);
    });

    test('intercity_enabled=false -> intercity parcel acceptance rejected', () {
      expect(_isRejected('intercity_parcel', {'intercity_enabled': false}), isTrue);
    });

    test('the mirror matches the live source exactly', () {
      expect(liveAcceptOrder.contains('if (order.order_type === "ride") {'), isTrue);
      expect(liveAcceptOrder.contains('isFeatureEnabled(productionConfig, "local_rides_enabled")'), isTrue);
      expect(liveAcceptOrder.contains('isFeatureEnabled(productionConfig, "ride_booking_enabled")'), isTrue);
      expect(liveAcceptOrder.contains('} else if (order.order_type === "local_parcel") {'), isTrue);
      expect(liveAcceptOrder.contains('isFeatureEnabled(productionConfig, "parcel_enabled")'), isTrue);
      expect(
        liveAcceptOrder.contains(
          '} else if (order.order_type === "intercity_ride" || order.order_type === "intercity_parcel") {',
        ),
        isTrue,
      );
      expect(liveAcceptOrder.contains('isFeatureEnabled(productionConfig, "intercity_enabled")'), isTrue);
    });

    test('a blocked acceptance returns 503, not a silent failure or a generic 500', () {
      final anchor = liveAcceptOrder.indexOf('if (order.order_type === "ride") {');
      final end = liveAcceptOrder.indexOf('// =====================================================\n    // ORDER STATUS VALIDATION');
      expect(anchor, greaterThan(-1));
      expect(end, greaterThan(anchor));
      final block = liveAcceptOrder.substring(anchor, end);
      expect(block.contains('status: 503'), isTrue);
    });
  });

  group('G. Idempotency and existing-order safety are preserved', () {
    test('the flag check runs AFTER the idempotency check -- a rider retrying acceptance of an '
        'order they already hold succeeds regardless of flag state', () {
      final idempotencyIdx = liveAcceptOrder.indexOf('idempotent: true,');
      final flagCheckIdx = liveAcceptOrder.indexOf('PHASE 3 PRODUCTION CONTROL');
      expect(idempotencyIdx, greaterThan(-1));
      expect(flagCheckIdx, greaterThan(idempotencyIdx));
    });

    test('the flag check runs BEFORE order-status validation, so it only ever blocks a '
        'genuinely new acceptance, never an already-accepted order', () {
      final flagCheckIdx = liveAcceptOrder.indexOf('PHASE 3 PRODUCTION CONTROL');
      final statusValidationIdx = liveAcceptOrder.indexOf('ORDER STATUS VALIDATION');
      expect(statusValidationIdx, greaterThan(flagCheckIdx));
    });

    test('a config-fetch failure fails open (isFeatureEnabled default), matching every other '
        'Phase 1/3/4 enforcement point -- a production_config outage can never block dispatch', () {
      expect(liveAcceptOrder.contains('getProductionConfig(supabase)'), isTrue);
    });
  });

  group('H. update-order-status is deliberately, provably left unmodified', () {
    test('no production_config/feature-flag code exists in update-order-status', () {
      expect(liveUpdateOrderStatus.contains('production_config'), isFalse);
      expect(liveUpdateOrderStatus.contains('isFeatureEnabled'), isFalse);
    });

    test('its transition table still allows every existing-order lifecycle transition '
        'unconditionally (accepted->rider_arrived, rider_arrived->ongoing, ->cancelled, and '
        'accepted->searching for rider-side re-entry) -- proving why a blanket gate here would '
        'have been unsafe', () {
      expect(liveUpdateOrderStatus.contains('accepted: ["rider_arrived", "cancelled", "searching"],'), isTrue);
      expect(liveUpdateOrderStatus.contains('rider_arrived: ["ongoing", "cancelled"],'), isTrue);
    });
  });
}
