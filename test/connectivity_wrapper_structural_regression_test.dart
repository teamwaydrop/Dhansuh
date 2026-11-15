import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

// Structural regression guards for the connectivity fix (Nov 2026).
//
// Background: ConnectivityWrapper previously rendered the "slow connection"
// state as a full-screen ConnectionErrorScreen (Positioned.fill), blocking the
// entire app whenever a single DNS lookup took longer than the threshold. It
// also declared the app offline on DNS failures alone. The fix made slow a
// non-blocking top banner, required an independent signal before a full-screen
// offline block, and fixed an impossible threshold (slow 3200ms vs 3000ms
// deadline). These guards stop that shape from being reintroduced by a future
// refactor. Runtime behavior is covered separately by
// connectivity_banner_regression_test.dart.

void main() {
  const path = 'lib/shared/helpers/connectivity_wrapper.dart';

  group('connectivity_wrapper structural guards', () {
    final source = File(path).readAsStringSync();
    final noWs = source.replaceAll(RegExp(r'\s+'), '');

    test('slow state is NOT a full-screen ConnectionErrorScreen', () {
      expect(
        noWs.contains('errorType:ErrorType.slow'),
        isFalse,
        reason:
            'The slow state must be a non-blocking banner, never a full-screen '
            'ConnectionErrorScreen(errorType: ErrorType.slow). Reintroducing that '
            'usage means the whole app is blocked on a slow DNS sample again.',
      );
    });

    test('a dedicated non-blocking banner widget exists', () {
      expect(
        source.contains('_ConnectivityBanner'),
        isTrue,
        reason: 'The non-blocking slow/offline warning is rendered by '
            '_ConnectivityBanner. Removing it implies reverting to a blocking overlay.',
      );
    });

    test('the warning banner is anchored to the top, not Positioned.fill', () {
      expect(
        noWs.contains('Positioned(top:0,left:0,right:0,'),
        isTrue,
        reason: 'The banner must be a top-anchored Positioned strip so taps pass '
            'through to the app underneath. A Positioned.fill here would block the UI.',
      );
    });

    test('offline threshold conflict stays fixed: slow < DNS deadline', () {
      expect(noWs.contains('kDnsDeadlineMs=3000'), isTrue,
          reason: 'Shared DNS deadline must remain 3000ms.');
      expect(noWs.contains('kSlowThresholdMs=2000'), isTrue,
          reason: 'Slow threshold must remain 2000ms, strictly below the 3000ms '
              'deadline, otherwise the slow state can never trigger (the original bug).');
    });

    test('offline requires an independent confirmation signal', () {
      expect(source.contains('DeviceOfflineConfirm'), isTrue,
          reason: 'A DeviceOfflineConfirm seam must gate the full-screen offline block.');
      expect(
        noWs.contains('_defaultDeviceOfflineConfirm()async=>false'),
        isTrue,
        reason:
            'Without an independent device-connectivity signal, disconnection must '
            'never be confirmed, so the app is never fully blocked on probe failure alone.',
      );
    });

    test('three consecutive combined failures required before offline', () {
      expect(noWs.contains('kOfflineFailures=3'), isTrue,
          reason: 'Offline is only considered after 3 combined DNS+Supabase failures.');
      expect(noWs.contains('consecutiveFailures>=offlineFailures'), isTrue,
          reason: 'The offline decision must gate on the combined-failure counter.');
    });

    test('two consecutive slow samples required before the banner', () {
      expect(noWs.contains('kSlowSamplesToShow=2'), isTrue,
          reason: 'A single slow sample must not raise the banner (false-positive guard).');
      expect(noWs.contains('consecutiveSlow>=slowSamplesToShow'), isTrue,
          reason: 'The slow banner must gate on the consecutive-slow counter.');
    });

    test('Supabase probe treats ANY HTTP response as reached (not status-gated)', () {
      expect(
        source.contains('statusCode == 200') || source.contains('statusCode==200'),
        isFalse,
        reason: 'Reachability means any HTTP response (2xx..5xx). Gating on a specific '
            'status code would misclassify a reachable server (e.g. HTTP 500) as offline.',
      );
    });

    test('8-second checking interval is preserved', () {
      expect(noWs.contains('Timer.periodic(constDuration(seconds:8)'), isTrue,
          reason: 'The 8-second connectivity check interval must be preserved.');
    });

    test('app-resume rechecking is preserved', () {
      expect(source.contains('AppLifecycleState.resumed'), isTrue,
          reason: 'Connectivity must be rechecked when the app resumes from background.');
    });

    test('mounted guard preserved before setState after the async check', () {
      expect(noWs.contains('if(!mounted)return;'), isTrue,
          reason: 'setState after the async evaluate() must be guarded by a mounted check.');
    });
  });
}
