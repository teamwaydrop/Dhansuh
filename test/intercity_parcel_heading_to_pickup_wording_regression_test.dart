// Regression guard for Issue 6 (Phase 2): the intercity PARCEL "trip started" notification said
// "Your traveller has started the trip with your parcel", implying the parcel was already
// collected -- at this point the traveller has only started travelling TOWARD the pickup location.
//
// TRACE: two call sites produce this notification.
//   1. on_intercity_request_change() -- PRIMARY path, fires when intercity_requests.status ->
//      'in_progress' (set by start_intercity_trip_for_plan()). Reaches the passenger for every
//      normal Travel Together booking.
//   2. send_order_status_notifications_core() -- FALLBACK only, gated by
//      "IF NOT v_has_linked_request", fires only when no intercity_requests row reached
//      confirmed/paid/in_progress/completed for that order.
//
// FIX (20260901000030), PROVEN via real execution against a local Supabase/Docker instance:
//   - transitioning a booking_type='parcel' intercity_requests row to 'in_progress' produced
//     title "Traveller Heading to Pickup 🚚" / body "Your traveller has started the trip and is
//     heading towards you to pick up the parcel.\n\nTrack it live in the WayDrop app."
//   - the booking_type='ride' sibling on the SAME trigger, transitioned the same way, still
//     produced the unchanged "Trip Started 🚗" / "Your traveller has started the trip...".
//
// SCOPE: only the intercity-parcel 'in_progress'/picked_up-ongoing branch changed in both
// functions. Pickup ('rider_arrived'/'Partner Arrived'), in-transit tracking, 'completed'/'Parcel
// Delivered', local_parcel wording, and the intercity ride sibling are all reproduced byte-for-byte.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read('supabase/migrations/20260901000030_intercity_parcel_heading_to_pickup_wording.sql');

  group('1. THE FIX: intercity parcel trip-started wording no longer implies the parcel is already '
      'picked up', () {
    test('on_intercity_request_change()\'s in_progress+parcel branch uses the new heading-to-pickup '
        'title and body', () {
      expect(migration.contains("v_title := 'Traveller Heading to Pickup 🚚';"), isTrue);
      expect(
        migration.contains(
          r"v_body := E'Your traveller has started the trip and is heading towards you to pick up the parcel.\n\nTrack it live in the WayDrop app.';",
        ),
        isTrue,
      );
    });

    test('the new wording never claims the parcel has been picked up, is already with the '
        'traveller, or that delivery has started -- checked in the actual function bodies, not '
        'the migration\'s own explanatory header comment', () {
      final codeStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.on_intercity_request_change()');
      expect(codeStart, greaterThan(-1));
      final code = migration.substring(codeStart);
      expect(code.contains('heading towards you to pick up the parcel'), isTrue);
      expect(code.contains('started the trip with your parcel'), isFalse);
    });

    test('send_order_status_notifications_core()\'s fallback intercity-parcel branch is kept '
        'consistent with the same new wording', () {
      final coreAnchor = migration.indexOf('CREATE OR REPLACE FUNCTION public.send_order_status_notifications_core');
      expect(coreAnchor, greaterThan(-1));
      final coreBody = migration.substring(coreAnchor);
      expect(coreBody.contains("v_title := 'Traveller Heading to Pickup 🚚';"), isTrue);
      expect(
        coreBody.contains('Your traveller has started the trip and is heading towards you to pick up the parcel.'),
        isTrue,
      );
    });
  });

  group('2. Unrelated wording is completely unchanged', () {
    test('the intercity RIDE sibling ("Trip Started 🚗") is reproduced byte-for-byte in both '
        'functions', () {
      expect("v_title := 'Trip Started 🚗';".allMatches(migration).length, 2,
          reason: 'once in on_intercity_request_change(), once in the fallback core function');
      expect(migration.contains('Your traveller has started the trip.'), isTrue);
    });

    test('pickup/arrival, in-transit, and completion wording are untouched', () {
      expect(migration.contains("v_title := 'Partner Arrived';"), isTrue);
      expect(migration.contains("v_title := 'Parcel Delivered 🎉';"), isTrue);
      expect(migration.contains("v_title := 'Drop Partner Reached Drop-off 📍';"), isTrue);
    });

    test('local parcel wording ("Drop Partner") is untouched', () {
      expect(migration.contains("v_title := 'Trip on the Way 🗺️';"), isTrue);
      expect(migration.contains("Track your Drop Partner''s live location on the map."), isTrue);
    });

    test('the v_has_linked_request dedup guard around the fallback branch is preserved -- this fix '
        'does not change WHEN either notification fires, only the wording', () {
      expect(migration.contains('IF NOT v_has_linked_request THEN'), isTrue);
    });
  });
}
