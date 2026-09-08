// Structural regression guard for Phase 11C: two real-device-reported traveller-side bugs on the
// intercity offer/searching screen. Phase 11 already fixed the equivalent RIDER-side fare rounding
// (intercity_bookings_screen.dart, travel_plan_details_screen.dart) and the rider-side tracking
// screen's "Vehicle Verification" icon -- this phase covers the TRAVELLER (passenger) side, which
// was never touched by that pass.
//
// ISSUE 1 (fare rounding): intercity_searching_screen.dart's "Your Offer" fare (the primary figure
// on the traveller/intercity offer screen, shown while searching for a Drop Partner) rendered
// order.current_fare with `.toStringAsFixed(2)`, e.g. "₹346.87". orders.current_fare is only
// rounded to a whole rupee once a Drop Partner accepts the request (accept_intercity_request()) --
// before that it can legitimately carry decimals, so this is exactly the situation
// roundFareForDisplay() (lib/shared/helpers/fare_presentation_helper.dart) exists for: a display-only
// whole-rupee rounding of a not-yet-authoritative figure, never a second pricing formula. The same
// raw-decimal pattern was also present on the "New Offer"/"Confirm Fare of" boost-confirmation labels
// and the Base Fare/Boosted Amount/GST/Estimated Fare breakdown directly beneath them (all in the
// same live widget, _buildBoostFareSection) -- fixed alongside for internal consistency (no widget
// mixing a rounded top-line figure with an unrounded breakdown underneath it).
//
// ISSUE 2 (vehicle icon): partner_card.dart's "Available Drop Partners" card (used by both
// intercity_searching_screen.dart's traveller matching list and available_partners_screen.dart) drew
// an unconditional Icons.directions_car_filled_rounded next to the vehicle text
// ("${vehicleType.toUpperCase()} • $vehicleNumber", e.g. "CAB • TS 03 U 2862") -- the icon never
// reflected the same authoritative vehicle_type the text already used. Fixed with a shared
// _vehicleIconFor(vehicleType) mapping (bike/auto/cab, matching the existing app-wide convention),
// applied to both the compact card row and the "View Profile" detail sheet's Vehicle row.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final intercitySearchingScreen =
      _read('lib/features/intercity/shared/screens/intercity_searching_screen.dart');
  final partnerCard = _read('lib/features/intercity/shared/widgets/partner_card.dart');

  group('Issue 1: traveller intercity offer screen fare must never show a raw decimal', () {
    test('imports roundFareForDisplay', () {
      expect(
        intercitySearchingScreen.contains(
          "import 'package:waydrop/shared/helpers/fare_presentation_helper.dart';",
        ),
        isTrue,
      );
    });

    test('"Your Offer" primary fare (346.87 -> 347 case) uses roundFareForDisplay, not '
        'toStringAsFixed(2)', () {
      expect(
        intercitySearchingScreen.contains(
          "currentFare > 0.0 ? '₹\${roundFareForDisplay(currentFare)}' : '—'",
        ),
        isTrue,
      );
      expect(
        intercitySearchingScreen.contains("'₹\${currentFare.toStringAsFixed(2)}' : '—'"),
        isFalse,
      );
    });

    test('boost-confirmation labels ("New Offer" / "Confirm Fare of") are whole-rupee too', () {
      expect(
        intercitySearchingScreen.contains("'New Offer: ₹\${roundFareForDisplay(localFare)}'"),
        isTrue,
      );
      expect(
        intercitySearchingScreen.contains("'Confirm Fare of ₹\${roundFareForDisplay(localFare)}'"),
        isTrue,
      );
      expect(intercitySearchingScreen.contains("'New Offer: ₹\${localFare.toStringAsFixed(2)}'"), isFalse);
      expect(
        intercitySearchingScreen.contains("'Confirm Fare of ₹\${localFare.toStringAsFixed(2)}'"),
        isFalse,
      );
    });

    test('_buildFareBreakup (Base Fare / Boosted Amount / GST / Estimated Fare) uses '
        'roundFareForDisplay throughout -- no raw decimal fare remains in this widget', () {
      final start = intercitySearchingScreen.indexOf(
        'Widget _buildFareBreakup(double targetFare, double actualFare, Color primaryColor) {');
      final end = intercitySearchingScreen.indexOf('Widget buildBoostCard()', start);
      expect(start, greaterThanOrEqualTo(0));
      final body = intercitySearchingScreen.substring(start, end);
      expect(body.contains('roundFareForDisplay(actualFare)'), isTrue);
      expect(body.contains('roundFareForDisplay(boostAmt'), isTrue);
      expect(body.contains('roundFareForDisplay(gstAmt)'), isTrue);
      expect(body.contains('roundFareForDisplay(targetFare)'), isTrue);
      expect(body.contains('.toStringAsFixed(2)'), isFalse);
    });

    test('the underlying currentFare/localFare doubles used for boost math and RPC calls are '
        'untouched -- only the display Text strings changed', () {
      // increaseFare/_syncProposedFareToRequest/the boost RPC call must still receive the raw
      // double, never a pre-rounded int, so the server remains the sole source of the real value.
      expect(intercitySearchingScreen.contains('await increaseFare(localFare, 0);'), isTrue);
    });
  });

  group('Issue 2: traveller Available Drop Partner card icon must match the vehicle_type text', () {
    test('a shared _vehicleIconFor(vehicleType) helper maps the three authoritative values', () {
      final start = partnerCard.indexOf('IconData _vehicleIconFor(String vehicleType) {');
      expect(start, greaterThanOrEqualTo(0));
      final body = partnerCard.substring(start, start + 400);
      expect(body.contains("case 'bike':"), isTrue);
      expect(body.contains('Icons.two_wheeler_rounded'), isTrue);
      expect(body.contains("case 'auto':"), isTrue);
      expect(body.contains('Icons.electric_rickshaw_rounded'), isTrue);
      expect(body.contains('Icons.directions_car_filled_rounded'), isTrue);
    });

    test('the compact card row icon is driven by _vehicleIconFor(vehicleType), not a hardcoded '
        'Icons.directions_car_filled_rounded literal', () {
      expect(partnerCard.contains('Icon(_vehicleIconFor(vehicleType), size: 14'), isTrue);
    });

    test('the "View Profile" detail sheet Vehicle row uses the same helper', () {
      expect(
        partnerCard.contains("_ProfileRow(icon: _vehicleIconFor(vehicleType), label: 'Vehicle'"),
        isTrue,
      );
    });

    test('no remaining unconditional car-icon literal on either vehicle row (both now route '
        'through the shared mapping)', () {
      final vehicleRowIcons =
          RegExp(r'Icon\(Icons\.directions_car_filled_rounded').allMatches(partnerCard).length;
      expect(vehicleRowIcons, 0);
    });
  });
}
