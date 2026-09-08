// Structural regression guard for Phase 11: three real-device-reported bugs.
//
// ISSUE 1 (fare consistency): travel_plan_details_screen.dart's two "Accept Request (₹$amt)"
// button labels read intercity_requests.proposed_fare RAW (`.toString()`, no parsing/rounding)
// whenever the linked order had no final_fare/current_fare yet -- showing e.g. "₹65.79" before
// acceptance. accept_intercity_request() (20260901000018_whole_rupee_fare_rounding.sql) rounds
// that exact field to a whole rupee the instant it writes orders.final_fare/current_fare, so every
// screen reading the order's own fare afterward showed a different, whole-rupee number (e.g.
// "₹66.00") -- the reported jump. Fixed with the existing roundFareForDisplay() helper (already
// used correctly elsewhere in this app, e.g. intercity_bookings_screen.dart's pending tab) instead
// of a second pricing formula. A handful of already-authoritative (already-whole) fare displays in
// the same rider fare journey also had a stray ".00" formatting inconsistency, fixed alongside it
// for full visual consistency -- no value changes there, format only.
//
// ISSUE 2 (rating notification "Open Chat"): notification_detail_screen.dart's _canOpenChat getter
// only checked whether the tap payload carried an order_id -- a new_rating notification always
// does (20260901000032_rating_notification_full_feedback.sql), so the button rendered and tapping
// it opened a chat channel for a completed order the backend then refused.
//
// ISSUE 3 (vehicle type/visual correctness): the data layer (realtime_order_controller.dart,
// get-live-order-status) already correctly resolves an intercity traveller's actual vehicle_type
// (prior "Issue 3 fix" pass). The remaining bug was purely visual: intercity_tracking_screen.dart's
// "Vehicle Verification" row rendered a hardcoded two_wheeler icon regardless of vehicle_type, so a
// CAR trip showed the correct text label next to a bike icon.
//
// 3D VEHICLE VISUALS: assets/map/tracking_engine.js (the file every live trip-tracking screen
// actually loads via ola_map_tracking_user.html) rendered the active-rider marker with hand-drawn
// flat SVG shapes (vehicle_marker_templates.js's VEHICLE_REGISTRY) instead of real 3D-rendered
// transparent assets. Phase 11 wired in the first-generation assets (3dbike.png/3dauto.png/
// 3dcar.svg); Phase 11B swapped those for the final art direction (3d_bike.png/3d_auto.png/
// 3d_car.png, both here and in ola_map.html's own rider marker) -- isolated to this file's own
// active-rider marker (getVehicleMarkerHTML()/VEHICLE_REGISTRY, used elsewhere for nearby-rider
// browsing markers, are untouched).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final travelPlanDetails =
      _read('lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart');
  final intercityBookingsScreen =
      _read('lib/features/rider/intercity/intercity_bookings_screen.dart');
  final riderOrdersScreen = _read('lib/features/rider/orders/rider_orders_screen.dart');
  final notificationDetailScreen =
      _read('lib/modules/notifications/screens/notification_detail_screen.dart');
  final intercityTrackingScreen =
      _read('lib/features/intercity/shared/screens/intercity_tracking_screen.dart');
  final trackingEngine = _read('assets/map/tracking_engine.js');

  group('Issue 1: travel_plan_details_screen.dart Accept Request fare must never show the raw, '
      'unrounded proposed_fare', () {
    test('imports roundFareForDisplay', () {
      expect(
        travelPlanDetails.contains(
          "import 'package:waydrop/shared/helpers/fare_presentation_helper.dart';",
        ),
        isTrue,
      );
    });

    test('both "Accept Request" fare computations route the proposed_fare fallback through '
        'roundFareForDisplay() -- never a raw req[\'proposed_fare\'] .toString()', () {
      final occurrences = RegExp(r"btnLabel = 'Accept Request \(₹\$amt\)'").allMatches(travelPlanDetails);
      expect(occurrences.length, 2, reason: 'expected exactly 2 Accept Request fare button sites');

      // Neither surviving computation may pass proposed_fare straight to .toString() (the bug) --
      // every fallback to proposed_fare must go through roundFareForDisplay(double.tryParse(...)).
      expect(
        travelPlanDetails.contains("req['proposed_fare'])?.toString() ?? '0';"),
        isFalse,
        reason: 'raw unrounded proposed_fare fallback must not reappear on the Accept Request button',
      );
      expect(
        'roundFareForDisplay(double.tryParse(req'.allMatches(travelPlanDetails).length,
        greaterThanOrEqualTo(2),
      );
    });

    test('already-authoritative fare displays in this screen use whole-rupee formatting, not 2 '
        'decimal places (visual consistency, no value change)', () {
      expect(travelPlanDetails.contains("'₹\${actualFare.toStringAsFixed(2)}'"), isFalse);
    });
  });

  group('Issue 1: rider-side intercity/orders fare cards use whole-rupee formatting throughout', () {
    test('intercity_bookings_screen.dart Upcoming/Active/History tabs no longer show ".00" where '
        'the pending tab already shows a bare whole-rupee amount', () {
      expect(intercityBookingsScreen.contains("'₹\${totalFare.toStringAsFixed(2)}'"), isFalse);
      expect(intercityBookingsScreen.contains("'₹\${fare.toStringAsFixed(2)}'"), isFalse);
      // The already-fixed Pending tab card must still be intact.
      expect(intercityBookingsScreen.contains('roundFareForDisplay('), isTrue);
    });

    test('rider_orders_screen.dart nearby-order fare (details sheet + slide-to-accept) is '
        'whole-rupee, matching the identical, already-fixed widget in incoming_order_card.dart', () {
      expect(riderOrdersScreen.contains("'₹\${fare.toStringAsFixed(2)}'"), isFalse);
      expect(riderOrdersScreen.contains("'₹\${widget.fare.toStringAsFixed(2)}'"), isFalse);
    });
  });

  group('Issue 2: rating notifications must never offer Open Chat', () {
    test('_canOpenChat excludes new_rating regardless of order_id presence', () {
      final anchor = notificationDetailScreen.indexOf('bool get _canOpenChat');
      expect(anchor, greaterThan(-1));
      final body = notificationDetailScreen.substring(anchor, anchor + 1400);
      expect(body.contains("_notificationType == 'new_rating'"), isTrue);
      expect(body.contains('return false;'), isTrue);
    });

    test('the full untruncated body is still rendered unconditionally (rating feedback visible '
        'regardless of chat eligibility)', () {
      expect(
        notificationDetailScreen.contains('SelectableText(\n                    _body'),
        isTrue,
      );
    });

    test('a genuine chat-context notification (order_id present, not new_rating, not a whole-'
        'travel-plan deletion) can still reach _openChat', () {
      expect(notificationDetailScreen.contains('void _openChat()'), isTrue);
      expect(notificationDetailScreen.contains('NotificationService().openChatForOrder('), isTrue);
    });
  });

  group('Issue 3: intercity trip screen vehicle icon must match the actual vehicle_type', () {
    test('the Vehicle Verification row icon is no longer unconditionally two_wheeler', () {
      final anchor = intercityTrackingScreen.indexOf("'Vehicle Verification'");
      expect(anchor, greaterThan(-1));
      final before = intercityTrackingScreen.substring(anchor - 400, anchor);
      expect(before.contains("vt == 'cab' || vt == 'car'"), isTrue);
      expect(before.contains("vt == 'auto'"), isTrue);
      expect(before.contains('Icons.directions_car_rounded'), isTrue);
    });
  });

  group('3D vehicle visuals: the live tracking-engine marker uses the real 3D asset files', () {
    test('tracking_engine.js selects 3d_bike.png / 3d_auto.png / 3d_car.png by vehicle type for '
        'the active-rider marker', () {
      expect(trackingEngine.contains("'3d_bike.png'"), isTrue);
      expect(trackingEngine.contains("'3d_auto.png'"), isTrue);
      expect(trackingEngine.contains("'3d_car.png'"), isTrue);
    });

    test('the marker image keeps the rider-vehicle-icon class so heading rotation is unaffected', () {
      final anchor = trackingEngine.indexOf("iconEl.className = 'rider-vehicle-icon';");
      expect(anchor, greaterThan(-1));
      // animateActiveRider() must still be able to find this element by the same class.
      expect(
        trackingEngine.contains("querySelector('.rider-vehicle-icon')"),
        isTrue,
      );
    });

    test('unrelated marker systems (getVehicleMarkerHTML / VEHICLE_REGISTRY, ola_map.html) were '
        'not modified by this change -- tracking_engine.js no longer calls getVehicleMarkerHTML '
        'for the active-rider marker', () {
      expect(trackingEngine.contains('window.getVehicleMarkerHTML(currentType'), isFalse);
    });

    final assetDir = Directory('assets/map');
    test('the referenced 3D asset files actually exist on disk', () {
      expect(File('${assetDir.path}/3d_bike.png').existsSync(), isTrue);
      expect(File('${assetDir.path}/3d_auto.png').existsSync(), isTrue);
      expect(File('${assetDir.path}/3d_car.png').existsSync(), isTrue);
    });
  });
}
