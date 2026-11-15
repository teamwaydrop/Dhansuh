import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/shared/helpers/connectivity_wrapper.dart';
import 'package:waydrop/shared/screens/connection_error_screen.dart';

// Fast, deterministic thresholds for the evaluator under test. The production
// defaults (3000ms deadline / 2000ms slow) are preserved in the source; tests
// only shrink them so a few milliseconds of real delay crosses the boundary.
const int _deadlineMs = 500;
const int _slowMs = 40;

/// Builds a HostProbe from a per-host outcome map. A null value means "never
/// resolves and never errors" (exercises the deadline path); a positive delay
/// means success after that delay; a negative delay means failure after its
/// absolute delay.
HostProbe hostProbe(Map<String, int?> outcomes) {
  return (host, timeout) async {
    final ms = outcomes[host];
    if (ms == null) {
      // Hang until the evaluator's own deadline guard fires.
      await Completer<void>().future;
      return;
    }
    if (ms >= 0) {
      if (ms > 0) await Future<void>.delayed(Duration(milliseconds: ms));
      return; // success
    }
    await Future<void>.delayed(Duration(milliseconds: -ms));
    throw const _FakeDnsFailure();
  };
}

class _FakeDnsFailure implements Exception {
  const _FakeDnsFailure();
}

ConnectivityEvaluator buildEvaluator({
  required Map<String, int?> dns,
  bool supabaseReached = false,
  bool deviceOffline = false,
  List<String>? hosts,
}) {
  final hostList = hosts ?? dns.keys.toList();
  return ConnectivityEvaluator(
    hosts: hostList,
    hostProbe: hostProbe(dns),
    supabaseProbe: (_) async => supabaseReached,
    deviceOfflineConfirm: () async => deviceOffline,
    dnsDeadlineMs: _deadlineMs,
    slowThresholdMs: _slowMs,
    // slowSamplesToShow and offlineFailures keep their production defaults (2, 3).
  );
}

void main() {
  group('ConnectivityEvaluator — slow banner lifecycle', () {
    test('1+2: first slow sample shows no banner; second consecutive slow does', () async {
      final e = buildEvaluator(dns: {'a': _slowMs + 40}); // success, but slow
      await e.evaluate();
      expect(e.consecutiveSlow, 1);
      expect(e.showSlowBanner, isFalse, reason: 'one slow sample must not raise the banner');

      await e.evaluate();
      expect(e.consecutiveSlow, 2);
      expect(e.showSlowBanner, isTrue, reason: 'two consecutive slow samples raise the banner');
      expect(e.isOffline, isFalse);
    });

    test('3: a fast sample clears a visible slow banner', () async {
      final e = buildEvaluator(dns: {'a': _slowMs + 40});
      await e.evaluate();
      await e.evaluate();
      expect(e.showSlowBanner, isTrue);

      // Next check resolves fast.
      e.setHostProbeForTest(hostProbe({'a': 0}));
      await e.evaluate();
      expect(e.showSlowBanner, isFalse, reason: 'a fast success clears the banner');
      expect(e.consecutiveSlow, 0);
    });
  });

  group('ConnectivityEvaluator — DNS race first-success', () {
    test('4: one host fails early, another succeeds -> remains online, no banner', () async {
      // 'a' fails after 5ms, 'b' succeeds after 20ms (fast, under the slow threshold).
      final e = buildEvaluator(dns: {'a': -5, 'b': 20});
      await e.evaluate();
      expect(e.isOffline, isFalse);
      expect(e.showSlowBanner, isFalse);
      expect(e.showOfflineBanner, isFalse);
      expect(e.consecutiveFailures, 0);
    });
  });

  group('ConnectivityEvaluator — DNS fail + Supabase reachable means online', () {
    test('5/6: all DNS fail + Supabase 5xx/2xx (reached) -> online, no new banner', () async {
      final e = buildEvaluator(dns: {'a': -5, 'b': -5}, supabaseReached: true);
      await e.evaluate();
      expect(e.isOffline, isFalse);
      expect(e.showOfflineBanner, isFalse, reason: 'reachable server is not offline');
      expect(e.showSlowBanner, isFalse, reason: 'DNS-probe failure must not create a slow banner');
      expect(e.consecutiveSlow, 0, reason: 'slow counter must not increment here');
      expect(e.consecutiveFailures, 0, reason: 'offline failures reset when server is reachable');
    });

    test('7: all DNS fail + Supabase reachable preserves an already-visible slow banner', () async {
      // Raise the slow banner first via two slow samples.
      final e = buildEvaluator(dns: {'a': _slowMs + 40});
      await e.evaluate();
      await e.evaluate();
      expect(e.showSlowBanner, isTrue);

      // Now all DNS fail but Supabase is reachable.
      e.setHostProbeForTest(hostProbe({'a': -5}));
      e.setSupabaseProbeForTest((_) async => true);
      await e.evaluate();
      expect(e.showSlowBanner, isTrue, reason: 'existing banner persists until a fast DNS sample');
      expect(e.consecutiveSlow, 2, reason: 'slow counter untouched on the reachable path');
      expect(e.isOffline, isFalse);
    });
  });

  group('ConnectivityEvaluator — offline policy', () {
    test('8a: 3 combined failures WITHOUT independent confirmation -> non-blocking banner', () async {
      final e = buildEvaluator(dns: {'a': -5}, supabaseReached: false, deviceOffline: false);
      await e.evaluate();
      expect(e.isOffline, isFalse);
      expect(e.showOfflineBanner, isFalse, reason: '1 failure is not yet offline');
      await e.evaluate();
      expect(e.showOfflineBanner, isFalse, reason: '2 failures is not yet offline');
      await e.evaluate();
      expect(e.consecutiveFailures, 3);
      expect(e.isOffline, isFalse, reason: 'no independent signal -> never full-screen block');
      expect(e.showOfflineBanner, isTrue, reason: 'show a non-blocking warning instead');
    });

    test('8b: 3 combined failures WITH independent confirmation -> full-screen offline', () async {
      final e = buildEvaluator(dns: {'a': -5}, supabaseReached: false, deviceOffline: true);
      await e.evaluate();
      await e.evaluate();
      await e.evaluate();
      expect(e.consecutiveFailures, 3);
      expect(e.isOffline, isTrue, reason: 'confirmed disconnection justifies the full-screen block');
      expect(e.showOfflineBanner, isFalse);
    });

    test('10: HTTP 5xx counts as reached, so it does NOT increment the offline counter', () async {
      // supabaseReached:true models the probe returning true for any HTTP status (incl 500).
      final e = buildEvaluator(dns: {'a': -5}, supabaseReached: true);
      await e.evaluate();
      await e.evaluate();
      await e.evaluate();
      expect(e.consecutiveFailures, 0, reason: '5xx is server-reached, not offline');
      expect(e.isOffline, isFalse);
      expect(e.showOfflineBanner, isFalse);
    });
  });

  group('ConnectivityEvaluator — overlap guard', () {
    test('9: a second evaluate() while one is in flight is a no-op', () async {
      final gate = Completer<void>();
      final e = ConnectivityEvaluator(
        hosts: const ['a'],
        hostProbe: (host, timeout) async {
          await gate.future; // hold the first evaluation open
        },
        supabaseProbe: (_) async => false,
        deviceOfflineConfirm: () async => false,
        dnsDeadlineMs: _deadlineMs,
        slowThresholdMs: _slowMs,
      );

      final first = e.evaluate();
      expect(e.isChecking, isTrue);
      final second = e.evaluate(); // must return immediately, no-op
      await second;
      expect(e.isChecking, isTrue, reason: 'first check still running after the no-op second');

      gate.complete();
      await first;
      expect(e.isChecking, isFalse);
    });
  });

  group('ConnectivityWrapper — overlay mapping', () {
    testWidgets('confirmed offline renders the full-screen ConnectionErrorScreen', (tester) async {
      final e = buildEvaluator(dns: {'a': -5}, supabaseReached: false, deviceOffline: true);
      // Real timers inside evaluate() must run against the real clock, not the
      // widget-test fake-async clock, so drive them via runAsync().
      await tester.runAsync(() async {
        await e.evaluate();
        await e.evaluate();
        await e.evaluate();
      });
      expect(e.isOffline, isTrue);

      await tester.pumpWidget(MaterialApp(
        home: ConnectivityWrapper(
          evaluator: e,
          autoStart: false,
          child: const Text('APP_CONTENT', textDirection: TextDirection.ltr),
        ),
      ));
      // Trigger a rebuild that reads the evaluator state.
      await tester.pump();

      expect(find.byType(ConnectionErrorScreen), findsOneWidget);
    });

    testWidgets('unconfirmed offline shows a banner and keeps app content present', (tester) async {
      final e = buildEvaluator(dns: {'a': -5}, supabaseReached: false, deviceOffline: false);
      await tester.runAsync(() async {
        await e.evaluate();
        await e.evaluate();
        await e.evaluate();
      });
      expect(e.showOfflineBanner, isTrue);
      expect(e.isOffline, isFalse);

      await tester.pumpWidget(MaterialApp(
        home: ConnectivityWrapper(
          evaluator: e,
          autoStart: false,
          child: const Scaffold(body: Text('APP_CONTENT')),
        ),
      ));
      await tester.pump();

      expect(find.byType(ConnectionErrorScreen), findsNothing,
          reason: 'no full-screen block when disconnection is unconfirmed');
      expect(find.text('Retry'), findsOneWidget, reason: 'non-blocking banner is shown');
      expect(find.text('APP_CONTENT'), findsOneWidget, reason: 'app stays interactive underneath');
    });
  });
}
