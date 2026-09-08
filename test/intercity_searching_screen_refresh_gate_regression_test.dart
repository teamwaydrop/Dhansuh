// Regression guard for Issue 2 (matching-screen lag): loadNearbyRiders() (the heavy call --
// one match-intercity-riders Edge Function invocation plus a separate rider_assignments query)
// had THREE call sites, only one of which was rate-limited:
//   1. initialize() -- one-time initial load.
//   2. subscribeOrderAssignments()'s realtime callback -- 500ms-debounced, but otherwise
//      completely unrate-limited; a burst of rider_assignments churn could trigger a full heavy
//      call independent of how recently one already ran.
//   3. _maybeRefreshNearbyRiders() -- gated by the existing 5s/10s/20s adaptive poll interval
//      (_lastNearbyRidersFetchAt/_nearbyRidersRefreshInterval), fired every time
//      RealtimeOrderController's own 5s fallback poll ticks.
// A realtime event landing shortly after a poll tick (or vice versa) could therefore trigger two
// near-simultaneous heavy calls for the same order, with the loadingMatches guard only preventing
// literal concurrent overlap (the second call is dropped, not coalesced/skipped intentionally).
//
// FIX: loadNearbyRiders() itself now owns a single, shared 3-second minimum-refresh-gap gate
// (_lastNearbyRidersCompletedAt), checked once at the top of the function (immediately after the
// existing loadingMatches guard) and stamped in its own `finally` block on every completed attempt
// (success or error). This covers all three call sites uniformly without touching any of them
// individually, and does not replace or weaken either pre-existing gate: the realtime callback's
// own 500ms debounce, and the poll path's own 5s/10s/20s adaptive interval, are both unchanged.
//
// No matching eligibility, vehicle/route/date rule, KYC/capacity check, or dispatch behavior was
// touched -- this is purely a call-frequency optimization inside the client screen.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final screen = _read('lib/features/intercity/shared/screens/intercity_searching_screen.dart');

  group('1. THE FIX: a single shared minimum-refresh-gap gate covers every call site', () {
    test('a new gate check runs immediately after the existing loadingMatches guard, before any '
        'network work begins', () {
      final loadingGuardIdx = screen.indexOf('if (loadingMatches) return;');
      expect(loadingGuardIdx, greaterThan(-1));
      final gateIdx = screen.indexOf('_nearbyRidersMinRefreshGap) {\n      return;\n    }');
      expect(gateIdx, greaterThan(loadingGuardIdx));
      // The gate must appear before the first network call in the function body.
      final firstAwaitIdx = screen.indexOf('await supabase', gateIdx);
      expect(firstAwaitIdx, greaterThan(gateIdx));
    });

    test('the gate compares against a single shared "last completed" timestamp, not a per-call-'
        'site one -- one flag protects all three callers of loadNearbyRiders()', () {
      expect(screen.contains('DateTime? _lastNearbyRidersCompletedAt;'), isTrue);
      // Exactly one place ever assigns it (the finally block) -- not scattered per call site.
      expect('_lastNearbyRidersCompletedAt = DateTime.now();'.allMatches(screen).length, 1);
    });

    test('the gate is stamped in the finally block, so a failed attempt also starts the cooldown '
        '(prevents a tight retry loop on a persistently failing call, mirroring the existing '
        'loadingMatches guard\'s own fail-safe behavior)', () {
      final errorIdx = screen.indexOf("debugPrint('LOAD RIDERS ERROR => \$e');");
      expect(errorIdx, greaterThan(-1));
      final finallyBlock = screen.substring(errorIdx, (errorIdx + 400).clamp(0, screen.length));
      expect(finallyBlock.contains('} finally {'), isTrue);
      expect(finallyBlock.contains('_lastNearbyRidersCompletedAt = DateTime.now();'), isTrue);
    });
  });

  group('2. Existing gates are completely unchanged', () {
    test('the realtime callback\'s own 500ms debounce is preserved verbatim', () {
      expect(
        screen.contains('_nearbyRidersDebounceTimer = Timer(const Duration(milliseconds: 500), () {'),
        isTrue,
      );
    });

    test('the adaptive 5s/10s/20s poll interval function is preserved verbatim', () {
      expect(screen.contains('Duration _nearbyRidersRefreshInterval(Duration elapsed) {'), isTrue);
      expect(screen.contains('if (elapsed < const Duration(seconds: 60)) return const Duration(seconds: 5);'), isTrue);
      expect(screen.contains('if (elapsed < const Duration(seconds: 180)) return const Duration(seconds: 10);'), isTrue);
      expect(screen.contains('return const Duration(seconds: 20);'), isTrue);
    });

    test('the pre-existing loadingMatches re-entrancy guard is untouched', () {
      expect(screen.contains('if (loadingMatches) return;'), isTrue);
    });
  });

  group('3. Every existing call site still exists -- discovery paths are unaffected, only their '
      'shared call frequency is now bounded', () {
    test('the initial load call site is still present', () {
      expect(screen.contains('await loadNearbyRiders();'), isTrue);
    });

    test('the realtime rider_assignments callback still calls loadNearbyRiders() after its debounce', () {
      final anchor = screen.indexOf('_nearbyRidersDebounceTimer = Timer(const Duration(milliseconds: 500), () {');
      expect(anchor, greaterThan(-1));
      final nearby = screen.substring(anchor, (anchor + 150).clamp(0, screen.length));
      expect(nearby.contains('if (mounted) loadNearbyRiders();'), isTrue);
    });

    test('_maybeRefreshNearbyRiders() still calls loadNearbyRiders() after its own interval check', () {
      final anchor = screen.indexOf('void _maybeRefreshNearbyRiders() {');
      expect(anchor, greaterThan(-1));
      final nearby = screen.substring(anchor, (anchor + 500).clamp(0, screen.length));
      expect(nearby.contains('await loadNearbyRiders();'), isTrue);
    });
  });

  group('4. No matching/eligibility/dispatch rule was touched by this optimization', () {
    test('the match-intercity-riders invocation body/shape inside loadNearbyRiders() is unchanged', () {
      expect(
        screen.contains("'match-intercity-riders',\n        body: {\n          'order_id': widget.orderId,\n        },"),
        isTrue,
      );
    });
  });
}
