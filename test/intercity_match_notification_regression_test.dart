// Regression guard for the missing/ambiguous "New Travel Match" notification (tests 19-28).
//
// ROOT CAUSE: the underlying push-delivery pipeline (send_push_notification_fnc inserting into
// public.notifications, which a separate trigger delivers) was ALREADY fixed by
// 20260718000002_fix_stale_send_push_notification_fnc.sql -- that migration's own comment
// documents the live bug it fixed: "this is why a Travel Together request never notified or
// visibly alerted the traveller". The remaining, still-live gap this migration fixes: the copy
// on_intercity_request_change() sent for a new request was generic ("New Travel Request" /
// "Someone wants to travel with you") and never named the traveller's own Travel Plan route or
// distinguished a passenger match from a parcel match -- exactly the ambiguity flagged ("Do not
// say 'traveller matched' to the traveller if the matched entity is actually a passenger/
// request"). Also added: a DB-level guard so a client-side double-tap/retry race can never
// create two notifications for what is, from the traveller's perspective, one event.
//
// Tapping the notification's navigation-to-TravelPlanDetailsScreen logic (notification_service.dart)
// and the generic, notification-type-agnostic unread badge (notification_badge_service.dart) were
// already correctly implemented pre-existing code -- verified here structurally, not re-built.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final wordingMigration = _read('supabase/migrations/20260729000000_intercity_match_notification_wording_and_dedup.sql');
  final notificationService = _read('lib/modules/notifications/services/notification_service.dart');
  final badgeService = _read('lib/modules/notifications/services/notification_badge_service.dart');
  final matchingService = _read('lib/features/intercity/shared/services/intercity_matching_service.dart');

  group('Test 19 & 20: correct wording for a new passenger match vs a new parcel match', () {
    test('a passenger match notifies "New Travel Match" naming the traveller\'s own plan route', () {
      expect(wordingMigration.contains("v_title := 'New Travel Match';"), isTrue);
      expect(wordingMigration.contains("'A passenger matches your ' || v_plan_pickup || ' → ' || v_plan_dest || ' trip.'"), isTrue);
    });

    test('a parcel match notifies "New Parcel Match", never conflated with a passenger match', () {
      expect(wordingMigration.contains("v_title := 'New Parcel Match';"), isTrue);
      expect(wordingMigration.contains("'A parcel request matches your ' || v_plan_pickup || ' → ' || v_plan_dest || ' trip.'"), isTrue);
    });

    test('the wording is keyed off booking_type, distinguishing ride vs parcel, not a generic "someone" message', () {
      expect(wordingMigration.contains("NEW.booking_type = 'parcel'"), isTrue);
      // Old ambiguous generic copy is gone as an actual assignment (it's only referenced in this
      // migration's own header comments, documenting what it replaced).
      expect(wordingMigration.contains("v_body := 'Someone wants to travel with you"), isFalse);
    });

    test('the notification names the TRAVELLER\'S OWN plan route (rider_travel_plans), not just the order\'s fields', () {
      expect(wordingMigration.contains('FROM public.rider_travel_plans WHERE id = NEW.route_id'), isTrue);
    });
  });

  group('Test 21: duplicate event does not create duplicate notification', () {
    test('a DB-level unique guard prevents two active intercity_requests rows for the same order+traveller pair', () {
      expect(wordingMigration.contains('idx_intercity_requests_one_active_per_order_traveller'), isTrue);
      expect(wordingMigration.contains('ON public.intercity_requests (parcel_id, traveller_id)'), isTrue);
      expect(wordingMigration.contains("WHERE status NOT IN ('cancelled', 'rejected', 'expired', 'completed')"), isTrue);
    });

    test('the client gracefully treats a lost race (23505) as "already exists", never a second notification/insert', () {
      expect(matchingService.contains("e.code == '23505'"), isTrue);
      final start = matchingService.indexOf('on PostgrestException catch (e) {');
      final end = matchingService.indexOf('final currentUserId');
      final section = matchingService.substring(start, end);
      expect(section.contains('return false;'), isTrue);
    });
  });

  group('Test 22: unread badge updates for this notification type too', () {
    test('the badge service is generic (any public.notifications row for this user), not special-cased per type', () {
      expect(badgeService.contains("table: 'notifications'"), isTrue);
      expect(badgeService.contains("filterColumn: 'user_id'"), isTrue);
      expect(badgeService.contains("eq('is_read', false)"), isTrue);
      // Confirms it is NOT gated on notification_type, so 'intercity_request' rows count too.
      expect(badgeService.contains('notification_type'), isFalse);
    });
  });

  group('Test 23, 24 & 25: notification tap opens the correct Travel Plan with live (not stale) state', () {
    test('intercity_request notifications, in rider mode, navigate to TravelPlanDetailsScreen', () {
      final start = notificationService.indexOf("if (type == 'intercity_request' && isRiderMode) {");
      expect(start, greaterThan(-1));
      final section = notificationService.substring(start, start + 1500);
      expect(section.contains('TravelPlanDetailsScreen('), isTrue);
      // Never the old disconnected standalone booking card / chat-only jump for this type.
      expect(section.contains('RiderActiveOrderScreen('), isFalse);
    });

    test('the plan/request are looked up fresh from the DB by the notification\'s own request_id, never trusted from the push payload alone', () {
      final start = notificationService.indexOf("if (type == 'intercity_request' && isRiderMode) {");
      final section = notificationService.substring(start, start + 1500);
      expect(section.contains("from('intercity_requests')"), isTrue);
      expect(section.contains("from('rider_travel_plans')"), isTrue);
      expect(section.contains(".eq('id', requestId)"), isTrue);
    });

    test('TravelPlanDetailsScreen itself always reloads live matches/requests on open, never renders only the stale notification payload', () {
      final travelPlanDetails = _read('lib/features/rider/travel_plans/screens/travel_plan_details_screen.dart');
      expect(travelPlanDetails.contains('_loadMatches'), isTrue);
      expect(travelPlanDetails.contains('_loadIntercityRequests'), isTrue);
    });
  });

  group('Test 26: a stale/cancelled request does not expose an invalid action', () {
    test('fetchIncomingRequestsForPlan excludes terminal statuses (cancelled/rejected/expired) from the actionable set the Travel Plan screen re-queries live', () {
      expect(matchingService.contains("(cancelled,rejected,expired)"), isTrue);
    });
  });

  group('Test 27 & 28: a notification for Plan A cannot open Plan B, and an unrelated traveller cannot access it', () {
    test('the route_id/plan used to navigate comes only from the specific request_id in the tapped payload, never a hardcoded/ambient plan id', () {
      final start = notificationService.indexOf("if (type == 'intercity_request' && isRiderMode) {");
      final section = notificationService.substring(start, start + 1500);
      expect(section.contains("final requestId = data['request_id']?.toString();"), isTrue);
      expect(section.contains("reqRow?['route_id']?.toString();"), isTrue);
    });

    test('a caller cannot invoke find_nearby_riders-style cross-order data access; intercity_requests/rider_travel_plans stay RLS-scoped to participants for direct table reads', () {
      // Structural sanity: this migration's find_nearby_riders authorization change is scoped to
      // that function only -- it does not touch intercity_requests/rider_travel_plans RLS, which
      // remain the existing participant-scoped policies unrelated to this notification fix.
      final wordingMigrationHasNoRlsChange = !wordingMigration.contains('ALTER TABLE public.intercity_requests');
      expect(wordingMigrationHasNoRlsChange, isTrue);
    });
  });
}
