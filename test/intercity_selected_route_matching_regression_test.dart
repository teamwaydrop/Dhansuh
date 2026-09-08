// Regression guard for "Intercity Declared-Route Corridor Matching" (docs/13_Business_Logic.md
// section 5).
//
// The traveller's declared route (Origin -> Via 1 -> ... -> Destination, stored in
// selected_route_geometry / selected_route_meta) participates in match-intercity-riders' matching
// decision in BOTH modes -- but strictly ADDITIVELY:
//   * it can only ever set isMatched = true,
//   * it never sets isMatched = false and is never AND-composed,
//   * it is skipped entirely for any plan with selected_route_geometry = NULL (every pre-feature
//     plan, and every new plan created without Via locations).
//
// This test reads the deployed edge function's source as text (this repo's established
// structural-regression-guard convention) so an accidental future edit that makes the block
// subtractive / unguarded fails CI instead of silently changing production matching behavior.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final indexSource = _read('supabase/functions/match-intercity-riders/index.ts');

  group('1. selected-route-corridor.ts is imported and used in both modes', () {
    test('index.ts imports computeSelectedRouteMatch from selected-route-corridor.ts', () {
      expect(
        indexSource.contains(
          'import {\n  computeSelectedRouteMatch,\n  DEFAULT_SELECTED_ROUTE_CONFIG,\n  type RouteWaypoint,\n  type SelectedRouteConfig,\n} from "./selected-route-corridor.ts";',
        ),
        isTrue,
      );
    });

    test('computeSelectedRouteMatch is called exactly twice (Mode 1 and Mode 2)', () {
      final callSites = RegExp(r'computeSelectedRouteMatch\(').allMatches(indexSource);
      expect(callSites.length, 2, reason: 'expected one call site in Mode 1 and one in Mode 2');
    });
  });

  group('2. [MatchIntercity][SelectedRoute] diagnostic log exists for both modes', () {
    test('mode=1 and mode=2 log lines are present with the required fields', () {
      for (final marker in ['mode=1', 'mode=2']) {
        final idx = indexSource.indexOf('[MatchIntercity][SelectedRoute] $marker');
        expect(idx, greaterThanOrEqualTo(0), reason: 'missing SelectedRoute log for $marker');
        final window = indexSource.substring(idx, (idx + 600).clamp(0, indexSource.length));
        for (final field in [
          'planId=',
          'orderId=',
          'oldDecision=',
          'newDecision=',
          'reason=',
          'tP=',
          'tQ=',
          'snappedP=',
          'snappedQ=',
          'routeKm=',
        ]) {
          expect(window.contains(field), isTrue, reason: 'SelectedRoute log for $marker missing "$field"');
        }
      }
    });
  });

  group('3. declared-route block is guarded by selected_route_geometry presence, both modes', () {
    test('Mode 1 guard checks p.selected_route_geometry', () {
      expect(indexSource.contains('if (p.selected_route_geometry &&'), isTrue);
    });

    test('Mode 2 guard checks plan.selected_route_geometry', () {
      expect(indexSource.contains('if (plan.selected_route_geometry &&'), isTrue);
    });
  });

  group('4. ADDITIVE-ONLY: the declared-route result can only ever set isMatched = true', () {
    test('every declared-route promotion is exactly `if (declaredRoute.isMatch) { isMatched = true; }`', () {
      final promotions =
          RegExp(r'if \(declaredRoute\.isMatch\) \{\s*isMatched = true;\s*\}').allMatches(indexSource);
      expect(promotions.length, 2, reason: 'expected the additive promotion once per mode');
    });

    test('the only `isMatched = false` occurrences are the two `let` declarations (one per mode)', () {
      // A reassignment `isMatched = false` anywhere would mean some signal can demote a match.
      final all = RegExp(r'isMatched = false').allMatches(indexSource).length;
      final declarations = RegExp(r'let isMatched = false;').allMatches(indexSource).length;
      expect(declarations, 2);
      expect(all, declarations, reason: 'found an isMatched=false that is not a declaration');
    });

    test('the declared-route result is NEVER AND-composed into isMatched', () {
      expect(RegExp(r'isMatched\s*=\s*isMatched\s*&&').hasMatch(indexSource), isFalse);
      expect(indexSource.contains('isMatched && declaredRoute'), isFalse);
      expect(indexSource.contains('declaredRoute.isMatch &&'), isFalse);
      // The only assignment to isMatched from the declared-route result is the additive `= true`.
      for (final m in RegExp(r'computeSelectedRouteMatch\(').allMatches(indexSource)) {
        final window = indexSource.substring(m.start, (m.start + 900).clamp(0, indexSource.length));
        final assigns = RegExp(r'\bisMatched\s*=(?!=)').allMatches(window).length;
        expect(assigns, 1, reason: 'declared-route call site must assign isMatched exactly once (= true)');
        expect(window.contains('isMatched = true;'), isTrue);
      }
    });

    test('the geometric-corridor shadow is still shadow-only (never reassigns isMatched)', () {
      // Only the DECLARED-route signal was promoted to gating. The geometric-corridor block must
      // still be read-only -- guard against an accidental promotion of that one too.
      final geoIdx = indexSource.indexOf('computeGeometricCorridorMatch(');
      expect(geoIdx, greaterThan(0));
      // No `isMatched = ` assignment in the ~1200 chars following either geometric call site.
      for (final m in RegExp(r'computeGeometricCorridorMatch\(').allMatches(indexSource)) {
        final window = indexSource.substring(m.start, (m.start + 1400).clamp(0, indexSource.length));
        expect(RegExp(r'\bisMatched\s*=(?!=)').hasMatch(window), isFalse,
            reason: 'geometric-corridor block must stay shadow-only');
      }
    });
  });

  group('5. Mode 1 plans query carries the declared-route columns', () {
    test('rider_travel_plans select includes selected_route_geometry, selected_route_meta, route_selection_status', () {
      expect(
        indexSource.contains(
            'selected_route_geometry,\n          selected_route_meta,\n          route_selection_status,'),
        isTrue,
      );
    });
  });
}
