// Regression guard for "Traveller match notification opens 'No partners available' instead of
// the real match" (PHASE 2, Issue 4).
//
// ROOT CAUSE: notification_service.dart's _openAvailablePartnersFromPayload only forwarded
// order_id/pickup/destination/travel_date to AvailablePartnersScreen, discarding the plan_id
// already present in the 'traveller_available' notification payload
// (match-intercity-riders/index.ts's sendTravellerAvailableNotification). The screen's own load
// (IntercityMatchingService.fetchAvailablePartnersForDate) re-derives matches with a STRICTER
// filter (exact city-string ilike + single calendar-day window) than the matching engine that
// produced the notification (route-corridor/coordinate matching, wider date window) -- so a
// genuinely-matched plan could simply not reappear, showing the empty "No partners available"
// state even though the match was still real.
//
// FIX (superseded by PHASE 3, Issue 2 -- see intercity_match_notification_searching_screen_
// regression_test.dart): originally threaded plan_id through as AvailablePartnersScreen.
// initialPlanId, guaranteeing that specific plan was included even if the generic search missed
// it. Phase 3 replaced AvailablePartnersScreen (a date/browse screen) as the notification-tap
// destination entirely with IntercitySearchingScreen(orderId) -- the canonical per-order matching
// screen -- so notification_service.dart no longer calls into this path at all.
// AvailablePartnersScreen and IntercityMatchingService.fetchPartnerByPlanId/initialPlanId
// themselves are untouched and still guarded below, since the screen remains reachable from its
// own in-screen "browse" entry point and from Home/Activity.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('IntercityMatchingService -- single-plan lookup for notification-driven navigation', () {
    final source = _read('lib/features/intercity/shared/services/intercity_matching_service.dart');

    test('fetchPartnerByPlanId exists and looks up by id, not by date/city filters', () {
      expect(source.contains('static Future<Map<String, dynamic>?> fetchPartnerByPlanId('), isTrue);
      final methodStart = source.indexOf('static Future<Map<String, dynamic>?> fetchPartnerByPlanId(');
      final methodBody = source.substring(methodStart, methodStart + 500);
      expect(methodBody.contains(".eq('id', planId)"), isTrue);
      expect(methodBody.contains(".eq('status', 'active')"), isTrue);
    });

    test('fetchPartnerByPlanId and fetchAvailablePartnersForDate share the same enrichment '
        'pipeline (_enrichPlans) so a single-plan result can never drift out of sync with the '
        'list shape', () {
      final fetchByDateStart = source.indexOf('static Future<List<Map<String, dynamic>>> fetchAvailablePartnersForDate(');
      final fetchByPlanIdStart = source.indexOf('static Future<Map<String, dynamic>?> fetchPartnerByPlanId(');
      final enrichPlansStart = source.indexOf('static Future<List<Map<String, dynamic>>> _enrichPlans(');
      expect(fetchByDateStart, greaterThanOrEqualTo(0));
      expect(fetchByPlanIdStart, greaterThan(fetchByDateStart));
      expect(enrichPlansStart, greaterThan(fetchByPlanIdStart));

      final dateBody = source.substring(fetchByDateStart, fetchByPlanIdStart);
      final planIdBody = source.substring(fetchByPlanIdStart, enrichPlansStart);
      expect(dateBody.contains('_enrichPlans(plans)'), isTrue);
      expect(planIdBody.contains('_enrichPlans(plans)'), isTrue);
    });
  });

  group('AvailablePartnersScreen -- guarantees a notification-matched plan is shown', () {
    final source = _read('lib/features/user/intercity/screens/available_partners_screen.dart');

    test('accepts an optional initialPlanId', () {
      expect(source.contains('final String? initialPlanId;'), isTrue);
    });

    test('_loadPartnersForSelectedDate merges in the specific plan when the generic search '
        'missed it', () {
      final methodStart = source.indexOf('Future<void> _loadPartnersForSelectedDate() async {');
      final methodEnd = source.indexOf('void _selectDate(');
      final methodBody = source.substring(methodStart, methodEnd);
      expect(methodBody.contains('widget.initialPlanId'), isTrue);
      expect(methodBody.contains('IntercityMatchingService.fetchPartnerByPlanId('), isTrue);
      expect(
        methodBody.contains('!partners.any((p) => p[\'id\']?.toString() == initialPlanId)'),
        isTrue,
        reason: 'must only do the extra lookup when the generic search did not already include it',
      );
    });
  });

  group('NotificationService -- no longer routes match notifications through '
      'AvailablePartnersScreen (superseded by Phase 3, Issue 2)', () {
    final source = _read('lib/modules/notifications/services/notification_service.dart');

    test('the old payload-forwarding helper is gone; see intercity_match_notification_searching_'
        'screen_regression_test.dart for the current IntercitySearchingScreen(orderId) routing', () {
      expect(source.contains('_openAvailablePartnersFromPayload'), isFalse);
    });
  });
}
