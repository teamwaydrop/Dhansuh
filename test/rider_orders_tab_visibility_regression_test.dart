// Regression guard for the "Orders tab disappears after a local ride completes" bug.
//
// ROOT CAUSE: initialRiderDataProvider (lib/core/providers/initial_data_provider.dart) is written
// exactly once, at cold app start (app_start_screen.dart), and never refreshed anywhere else.
// RiderMainNavigationScreen._isIntercity gates whether the Orders tab exists at all in the bottom
// nav, and used to seed _serviceMode from that one-time snapshot as final -- skipping a live
// re-fetch whenever the snapshot was non-null. Since a local ride's completion recreates this
// screen from scratch (local_ride_home_navigator.dart's pushAndRemoveUntil), any service-mode
// change made mid-session (after the snapshot was captured) was silently reverted every time a
// ride finished, wrongly hiding the Orders tab until the next realtime service_mode UPDATE
// happened to arrive (e.g. a manual mode toggle).
//
// FIX: initState() now always calls _loadServiceMode() (a live DB re-fetch), using the stale
// snapshot only as an optimistic value for the first frame -- mirroring the exact pattern
// RiderHomeTab.initState() already used correctly for the same provider (seed optimistically, then
// unconditionally re-fetch and overwrite via setState).
//
// This is a structural regression guard (reads the real source, following the pattern already used
// throughout this test suite for cases that can't run against a live Supabase instance in a plain
// unit test), not a widget test -- it asserts the initState()/live-refresh shape can never regress
// back to trusting the stale snapshot as final.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('RiderMainNavigationScreen -- Orders tab visibility survives ride completion', () {
    final source = _read('lib/features/rider/navigation/rider_main_navigation_screen.dart');
    final initStateBody = source.substring(
      source.indexOf('void initState() {'),
      source.indexOf('void dispose() {'),
    );

    test('a true cold start may call _loadServiceMode(skipQuery: seedUsable), reusing the '
        'app-start snapshot instead of forcing a live re-fetch', () {
      // R1 FIX #2: skipQuery is only ever true when a fresh, unconsumed app-start snapshot
      // exists -- gated by the static, process-lifetime _hasConsumedColdStartSeed flag -- so
      // this is safe exactly once per app launch, and never on a mid-session screen recreation.
      expect(
        source.contains('static bool _hasConsumedColdStartSeed'),
        isTrue,
        reason: 'the cold-start seed path must be gated by a process-lifetime one-shot flag, '
            'not just presence of the snapshot, so a mid-session recreation cannot reuse a '
            'stale seed',
      );
      expect(
        RegExp(r'_loadServiceMode\(\s*skipQuery:\s*seedUsable\s*\)').hasMatch(initStateBody),
        isTrue,
        reason: 'initState() must pass skipQuery to _loadServiceMode() so a true cold start can '
            'skip the redundant riders query while still calling _loadServiceMode() '
            'unconditionally',
      );
    });

    test('the call to _loadServiceMode() is not reintroduced as an if/else branch keyed on the '
        'snapshot', () {
      // The original bug was exactly this shape: `if (initialRider != null) { ... } else {
      // _loadServiceMode(); }` -- only fetching live data when there was NO snapshot at all. R1
      // FIX #2 still seeds _serviceMode/_riderId from the snapshot inside an `if`, but whether to
      // skip the query is now carried as the skipQuery argument to a single call made
      // unconditionally afterward -- so initState() must contain no `else` at all.
      expect(
        initStateBody.contains('else'),
        isFalse,
        reason: '_loadServiceMode() must be called unconditionally, with skipQuery carrying the '
            'cold-start decision -- not reintroduced as a branch that skips calling it entirely',
      );
    });

    test('initState() no longer subscribes to realtime directly from the stale snapshot branch',
        () {
      // _subscribeServiceMode() must be called exactly once per initState(), from inside
      // _loadServiceMode() after the live re-fetch resolves -- never eagerly from the optimistic
      // snapshot branch, which would risk a duplicate RealtimeManager subscription once
      // _loadServiceMode()'s own call to _subscribeServiceMode() also runs.
      expect(
        initStateBody.contains('_subscribeServiceMode('),
        isFalse,
        reason: 'initState() itself must never call _subscribeServiceMode() directly -- only '
            '_loadServiceMode() should, to avoid a duplicate realtime subscription',
      );
    });

    test('_loadServiceMode() remains the single place that (re)subscribes to service_mode '
        'realtime updates', () {
      final loadServiceModeBody = source.substring(
        source.indexOf('Future<void> _loadServiceMode('),
        source.indexOf('void _subscribeServiceMode('),
      );
      expect(loadServiceModeBody.contains('_subscribeServiceMode(_riderId!);'), isTrue);
    });

    test('_isIntercity still gates the Orders tab (business rule preserved, not weakened)', () {
      expect(
        source.contains("if (!_isIntercity) RiderOrdersScreen(key: const ValueKey('orders')"),
        isTrue,
        reason: 'the Orders tab must still be Local-mode-only -- this fix corrects WHEN '
            '_serviceMode is refreshed, not the business rule that hides Orders for Intercity '
            'partners. (No longer a `const RiderOrdersScreen(...)` literal: it now also passes '
            'isActive: _index == 1, the same IndexedStack-visibility flag already wired to '
            'RiderHomeTab, so the constructor can no longer be const.)',
      );
    });
  });
}
