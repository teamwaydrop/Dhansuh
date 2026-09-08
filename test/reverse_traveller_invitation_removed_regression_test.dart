// Regression guard: WayDrop Intercity is strictly User-initiated. The USER chooses/requests a
// Traveller; the TRAVELLER only posts a Travel Plan and receives requests FROM Users. A prior
// session had built a fully symmetric "mirror" feature letting a Traveller browse matching
// passenger orders and press "Travel Together" themselves (AvailableTravelersScreen, reachable via
// a "Browse" button on travel_plan_details_screen.dart and via the aggregate
// 'new_travelers_available' push notification) -- proven live in production via two real,
// timestamped notification rows 31 seconds apart: a "New Travelers Available" push to the
// traveller at 15:03:48 IST, followed by a "Travel Invitation" push to the user at 15:04:19 IST
// for a plan the traveller had just browsed to.
//
// FIX: removed every reachable Flutter call site that can create an `intercity_requests` row with
// initiated_by='traveller' (AvailableTravelersScreen, deleted entirely; the dead/unreachable
// _sendProposal branch inside travel_plan_details_screen.dart's own match list), removed the
// Traveller-side "Available Orders Preview" composing-time preview (post_travel_plan_screen.dart,
// display-only, no writes), and removed the "new_travelers_available" aggregate notification (its
// only tap destination no longer exists) from match-intercity-riders/index.ts's Mode 2 background
// branch.
//
// NOT changed: the DB schema, the `initiated_by` CHECK constraint, on_intercity_request_change()'s
// SQL trigger, Migration 31, match-intercity-riders' matching/scoring logic (Mode 1, Mode 2,
// travel_matches, recordMatchIfNew, sendTravellerAvailableNotification, the expiry hotfix, the
// vehicle_type null guard), or either correct-flow initiatedBy: 'sender' caller.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('1. AvailableTravelersScreen (the reverse-flow screen) no longer exists', () {
    test('the file itself was deleted', () {
      expect(
        File('lib/features/rider/intercity/screens/available_travelers_screen.dart').existsSync(),
        isFalse,
      );
    });
  });

  group('2. Zero reachable Flutter callers create a traveller-initiated negotiation', () {
    test('no source file under lib/ calls sendTravelTogetherRequest with '
        'initiatedBy: \'traveller\'', () {
      final libDir = Directory('lib');
      final offenders = <String>[];
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final content = entity.readAsStringSync();
        if (content.contains("initiatedBy: 'traveller'")) {
          offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty, reason: 'reverse-flow caller(s) found: $offenders');
    });
  });

  group('3. Correct-flow User -> Traveller callers are untouched', () {
    test('available_partners_screen.dart still sends initiatedBy: \'sender\'', () {
      final source = _read('lib/features/user/intercity/screens/available_partners_screen.dart');
      expect(source.contains("initiatedBy: 'sender'"), isTrue);
    });

    test('intercity_searching_screen.dart\'s contactTraveller still sends '
        'initiatedBy: \'sender\'', () {
      final source = _read('lib/features/intercity/shared/screens/intercity_searching_screen.dart');
      expect(source.contains("initiatedBy: 'sender'"), isTrue);
    });
  });

  group('4. post_travel_plan_screen.dart: composing-time "Available Orders Preview" removed', () {
    final source = _read('lib/features/rider/travel_plans/screens/post_travel_plan_screen.dart');

    test('the preview UI strings are gone', () {
      expect(source.contains('Available Orders Preview'), isFalse);
      expect(source.contains('matches found'), isFalse);
      expect(source.contains('Intercity Passenger Request'), isFalse);
    });

    test('the preview-only match-intercity-riders call and its state are gone', () {
      expect(source.contains('_fetchRouteAndPreviewOrders'), isFalse);
      expect(source.contains('previewOrders'), isFalse);
      expect(source.contains('loadingPreview'), isFalse);
    });

    test('the actual plan submission (_submitTravelPlan -> rider_travel_plans insert) is untouched', () {
      expect(source.contains('Future<void> _submitTravelPlan() async {'), isTrue);
      expect(source.contains("final insertedPlan = await supabase.from('rider_travel_plans').insert({"), isTrue);
    });
  });

  group('4b. IntercityMatchingService.fetchAvailableTravelersForPlan() removed once unused', () {
    test('the method itself is gone (its only two callers -- the composing-time preview and '
        'AvailableTravelersScreen -- were both removed)', () {
      final source = _read('lib/features/intercity/shared/services/intercity_matching_service.dart');
      expect(source.contains('fetchAvailableTravelersForPlan'), isFalse);
    });

    test('no source file under lib/ still calls it', () {
      final libDir = Directory('lib');
      final offenders = <String>[];
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.readAsStringSync().contains('fetchAvailableTravelersForPlan')) {
          offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty, reason: 'stale caller(s) found: $offenders');
    });
  });

  group('5. travel_plan_details_screen.dart: Browse entry point and reverse "send offer" '
      'branches removed', () {
    final source = _read('lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart');

    test('the "Browse" button that opened AvailableTravelersScreen is gone', () {
      expect(source.contains("import 'package:waydrop/features/rider/intercity/screens/available_travelers_screen.dart';"), isFalse);
      expect(source.contains('builder: (_) => AvailableTravelersScreen('), isFalse);
      expect(source.contains("label: 'Browse'"), isFalse);
    });

    test('_sendProposal (the traveller-initiated negotiation sender) was removed, not left dead', () {
      expect(source.contains('_sendProposal'), isFalse);
      expect(source.contains("initiatedBy: 'traveller'"), isFalse);
    });

    test('_buildSheetActionButton no longer offers "Send Ride Offer"/"Send Delivery Offer"', () {
      expect(source.contains('Send Ride Offer'), isFalse);
      expect(source.contains('Send Delivery Offer'), isFalse);
    });

    test('the Traveller\'s legitimate "Matched Passengers"/"Matched Drop Partners" list and its '
        'data source (fetchIncomingRequestsForPlan, requests already received from Users) are '
        'untouched', () {
      expect(source.contains("'Matched Passengers (\${matches.length})'"), isTrue);
      expect(source.contains("'Matched Drop Partners (\${matches.length})'"), isTrue);
      expect(source.contains('IntercityMatchingService.fetchIncomingRequestsForPlan('), isTrue);
    });

    test('Accept/Reject for a genuine User-sent request is untouched', () {
      expect(source.contains("req['initiated_by'] == 'sender'"), isTrue);
      expect(source.contains('_acceptIntercityRequest('), isTrue);
      expect(source.contains("label: 'Reject Request'"), isTrue);
    });
  });

  group('6. notification_service.dart: dead-end "New Travelers Available" navigation removed', () {
    final source = _read('lib/modules/notifications/services/notification_service.dart');

    test("the 'new_travelers_available' -> AvailableTravelersScreen handler is gone", () {
      expect(source.contains("if (type == 'new_travelers_available') {"), isFalse);
      expect(source.contains('available_travelers_screen.dart'), isFalse);
    });

    test('every other notification type routing is untouched', () {
      expect(source.contains("if (type == 'travel_partners_available' || type == 'traveller_available') {"), isTrue);
      expect(source.contains("if (type == 'order_assignment') {"), isTrue);
      expect(source.contains("} else if (type == 'cod_settlement') {"), isTrue);
    });
  });

  group('7. match-intercity-riders/index.ts: surgical removal only', () {
    final source = _read('supabase/functions/match-intercity-riders/index.ts');

    test('the "new_travelers_available" aggregate notification call is gone', () {
      expect(
        source.contains(
          'await sendMatchAvailableNotification(\n          supabase,\n          riderUserId,\n          "new_travelers_available",',
        ),
        isFalse,
      );
      // The type union on sendMatchAvailableNotification's signature intentionally still mentions
      // "new_travelers_available" (a surgical, call-site-only removal, not a signature change) --
      // what must be gone is the one call site that passed it.
      expect(
        source.contains('notificationType: "travel_partners_available" | "new_travelers_available",'),
        isTrue,
      );
    });

    test('the correct-flow "Traveller Available" per-match notification to the User is untouched', () {
      expect(source.contains('async function sendTravellerAvailableNotification('), isTrue);
      expect(source.contains('async function recordMatchIfNew('), isTrue);
    });

    test('Mode 1\'s "travel_partners_available" notification to the User (unrelated) is untouched', () {
      expect(source.contains('"travel_partners_available"'), isTrue);
    });

    test('the production travel_date expiry hotfix is untouched', () {
      expect(source.contains('if (orderTravelDate && new Date(orderTravelDate).getTime() < Date.now()) {'), isTrue);
      expect(source.contains('.or(`travel_date.is.null,travel_date.gte.\${now}`);'), isTrue);
    });

    test('the Mode 2 vehicle_type null guard fix (deployed v45) is untouched', () {
      expect(
        source.contains(
          'if (isRideOrder && order.vehicle_type && planVehicle !== "both" && planVehicle !== "all" && planVehicle !== null && planVehicle !== "") {',
        ),
        isTrue,
      );
    });

    test('the is_background branch still performs the per-order Traveller Available loop', () {
      // Mode 1 has its own, unrelated 'if (is_background) {' branch earlier in the file --
      // anchor on Mode 2's section first so this doesn't match the wrong one.
      final mode2Anchor = source.indexOf('MODE 2: MATCH ORDERS');
      expect(mode2Anchor, greaterThan(-1));
      final anchor = source.indexOf('if (is_background) {', mode2Anchor);
      expect(anchor, greaterThan(-1));
      final nearby = source.substring(anchor, (anchor + 1500).clamp(0, source.length));
      expect(nearby.contains('if (riderIsVerified && plan.id) {'), isTrue);
      expect(nearby.contains('recordMatchIfNew(supabase, o.id, plan.id, "plan_first")'), isTrue);
    });
  });

  group('8. Migration 31 is completely untouched', () {
    test('the trigger and function definition file has no new edits (still exists verbatim)', () {
      final migration = _read(
        'supabase/migrations/20260901000031_travel_plan_insert_triggers_matching_server_side.sql',
      );
      expect(migration.contains('AFTER INSERT ON public.rider_travel_plans'), isTrue);
      expect(migration.contains('EXECUTE FUNCTION public.on_rider_travel_plan_insert();'), isTrue);
      expect(migration.contains("url := v_supabase_url || '/functions/v1/match-intercity-riders',"), isTrue);
    });

    test('no new migration file was added for this cleanup (schema/CHECK constraint left as-is)', () {
      final migrationsDir = Directory('supabase/migrations');
      final files = migrationsDir
          .listSync()
          .whereType<File>()
          .map((f) => f.path.replaceAll('\\', '/').split('/').last)
          .where((name) => name.endsWith('.sql'))
          .toList();
      // The highest-numbered migration remains the one that was already live before this task --
      // no 202609010000XX file beyond 31 was introduced for this Flutter/Edge-Function-only fix.
      final travelPlanRelated = files.where((f) => f.contains('travel_plan_insert_triggers'));
      expect(travelPlanRelated.length, 1);
    });
  });
}
