import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:waydrop/core/config/env.dart';
import 'package:waydrop/shared/screens/connection_error_screen.dart';
import 'package:waydrop/shared/helpers/global_error_controller.dart';

// ===========================================================================
// Tunables. Production uses these defaults; tests override them (see
// ConnectivityEvaluator's constructor) so timing-sensitive cases run fast.
// ===========================================================================

/// Shared budget for the whole concurrent-DNS race. A single successful probe
/// within this window counts as online; the race only fails once every host
/// has failed or this deadline elapses.
const int kDnsDeadlineMs = 3000;

/// A first DNS success slower than this (but within [kDnsDeadlineMs]) is a
/// "slow" sample. Deliberately below the 3000ms deadline, otherwise the slow
/// condition could never trigger.
const int kSlowThresholdMs = 2000;

/// Consecutive slow samples required before the non-blocking banner appears.
/// Kills single-sample false positives from one cold DNS resolve.
const int kSlowSamplesToShow = 2;

/// Consecutive combined (DNS-failed AND Supabase-unreachable) checks required
/// before offline is considered. Even then, a full-screen block only happens
/// if an independent device-connectivity signal confirms disconnection.
const int kOfflineFailures = 3;

/// Resolve [host] within [timeout]; complete normally on success, throw on
/// failure or timeout. The default uses a DNS lookup.
typedef HostProbe = Future<void> Function(String host, Duration timeout);

/// True if the Supabase REST endpoint was reached at the network level, i.e.
/// ANY HTTP response arrived (2xx/3xx/4xx/5xx). False only for transport
/// failures, DNS errors and timeouts. An HTTP 5xx is NOT offline.
typedef SupabaseReachProbe = Future<bool> Function(Duration timeout);

/// True only when an independent device-connectivity signal confirms the
/// device is disconnected. WayDrop ships no such signal (no connectivity
/// plugin, and none may be added here), so the default returns false:
/// disconnection is never independently confirmed, so the app is never
/// fully blocked on probe failures alone.
typedef DeviceOfflineConfirm = Future<bool> Function();

/// Pure, widget-free connectivity decision engine. Owns the rolling counters
/// and the resulting overlay state so it can be unit-tested without pumping a
/// widget or leaving pending timers.
class ConnectivityEvaluator {
  ConnectivityEvaluator({
    List<String>? hosts,
    HostProbe? hostProbe,
    SupabaseReachProbe? supabaseProbe,
    DeviceOfflineConfirm? deviceOfflineConfirm,
    this.dnsDeadlineMs = kDnsDeadlineMs,
    this.slowThresholdMs = kSlowThresholdMs,
    this.slowSamplesToShow = kSlowSamplesToShow,
    this.offlineFailures = kOfflineFailures,
  })  : hosts = hosts ?? const ['google.com', 'one.one.one.one', 'github.com'],
        _hostProbe = hostProbe ?? _defaultHostProbe,
        _supabaseProbe = supabaseProbe ?? _defaultSupabaseProbe,
        _deviceOfflineConfirm = deviceOfflineConfirm ?? _defaultDeviceOfflineConfirm;

  final List<String> hosts;
  HostProbe _hostProbe;
  SupabaseReachProbe _supabaseProbe;
  final DeviceOfflineConfirm _deviceOfflineConfirm;

  @visibleForTesting
  void setHostProbeForTest(HostProbe probe) => _hostProbe = probe;

  @visibleForTesting
  void setSupabaseProbeForTest(SupabaseReachProbe probe) => _supabaseProbe = probe;
  final int dnsDeadlineMs;
  final int slowThresholdMs;
  final int slowSamplesToShow;
  final int offlineFailures;

  // Rolling state.
  int consecutiveFailures = 0;
  int consecutiveSlow = 0;

  // Current overlay state, read by the widget after each evaluate().
  bool isOffline = false; // full-screen block (only with confirmed disconnection)
  bool showSlowBanner = false; // non-blocking, slow connection
  bool showOfflineBanner = false; // non-blocking, offline not independently confirmed

  bool _inFlight = false;
  bool get isChecking => _inFlight;

  /// Run one connectivity evaluation. Overlapping calls are a no-op: the
  /// second returns immediately while the first is still running.
  Future<void> evaluate() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      final dns = await _runDnsRace();

      if (dns.success) {
        // Online. DNS clearly works -> never offline here.
        consecutiveFailures = 0;
        isOffline = false;
        showOfflineBanner = false;
        if (dns.elapsedMs > slowThresholdMs) {
          consecutiveSlow++;
          if (consecutiveSlow >= slowSamplesToShow) showSlowBanner = true;
        } else {
          // A fast success is the only thing that clears the slow banner.
          consecutiveSlow = 0;
          showSlowBanner = false;
        }
        return;
      }

      // Every DNS host failed within the deadline. DNS failure alone does not
      // prove a slow or offline WayDrop connection -> corroborate against the
      // real Supabase endpoint before doing anything blocking.
      final supabaseReached = await _supabaseProbe(Duration(milliseconds: dnsDeadlineMs));

      if (supabaseReached) {
        // Server reachable; external DNS is just flaky. Treat as online.
        // Reset offline failures. Do NOT touch the slow counter and do NOT
        // create a banner. Any already-visible slow banner is preserved until
        // a fast DNS sample clears it.
        consecutiveFailures = 0;
        isOffline = false;
        showOfflineBanner = false;
        return;
      }

      // Combined failure: DNS down AND Supabase unreachable at transport level.
      consecutiveFailures++;
      if (consecutiveFailures >= offlineFailures) {
        final confirmedOffline = await _deviceOfflineConfirm();
        if (confirmedOffline) {
          // Independently verified disconnection -> full-screen block is justified.
          isOffline = true;
          showOfflineBanner = false;
        } else {
          // Cannot independently confirm the device is offline. Never block the
          // whole app on probe failure alone -> non-blocking warning instead.
          isOffline = false;
          showOfflineBanner = true;
        }
      }
    } finally {
      _inFlight = false;
    }
  }

  /// Concurrent DNS race with true first-success semantics: an early host
  /// failure must not end the race while other hosts can still succeed. The
  /// race resolves as soon as any host succeeds, or fails only once every host
  /// has failed or the shared deadline elapses.
  Future<_DnsRaceResult> _runDnsRace() async {
    final deadline = Duration(milliseconds: dnsDeadlineMs);
    final sw = Stopwatch()..start();
    final completer = Completer<_DnsRaceResult>();
    var remaining = hosts.length;
    Timer? deadlineTimer;

    void finish(_DnsRaceResult result) {
      if (!completer.isCompleted) {
        deadlineTimer?.cancel();
        completer.complete(result);
      }
    }

    for (final host in hosts) {
      _hostProbe(host, deadline).then((_) {
        finish(_DnsRaceResult(success: true, elapsedMs: sw.elapsedMilliseconds));
      }).catchError((_) {
        remaining--;
        if (remaining <= 0) {
          finish(_DnsRaceResult(success: false, elapsedMs: sw.elapsedMilliseconds));
        }
      });
    }

    // Overall deadline guard, in case a host neither resolves nor errors.
    deadlineTimer = Timer(deadline, () {
      finish(_DnsRaceResult(success: false, elapsedMs: sw.elapsedMilliseconds));
    });

    return completer.future;
  }

  static Future<void> _defaultHostProbe(String host, Duration timeout) async {
    final result = await InternetAddress.lookup(host).timeout(timeout);
    if (result.isEmpty || result.first.rawAddress.isEmpty) {
      throw const SocketException('DNS lookup returned no addresses');
    }
  }

  static Future<bool> _defaultSupabaseProbe(Duration timeout) async {
    try {
      final base = Env.supabaseUrl.isNotEmpty ? Env.supabaseUrl : '';
      if (base.isEmpty) return false;
      final uri = Uri.parse('$base/rest/v1/');
      // ANY completed HTTP response (2xx..5xx) means the server was reached.
      await http.get(uri).timeout(timeout);
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } on http.ClientException {
      return false;
    } catch (_) {
      // Any other transport-level failure.
      return false;
    }
  }

  // No independent device-connectivity signal is available without adding a
  // dependency, which is forbidden here. So disconnection is never confirmed.
  static Future<bool> _defaultDeviceOfflineConfirm() async => false;
}

class _DnsRaceResult {
  const _DnsRaceResult({required this.success, required this.elapsedMs});
  final bool success;
  final int elapsedMs;
}

class ConnectivityWrapper extends StatefulWidget {
  final Widget child;

  /// Test seam: inject a pre-configured evaluator. Production leaves this null.
  final ConnectivityEvaluator? evaluator;

  /// Test seam: when false, the periodic timer and the initial check do not
  /// start, so widget tests leave no pending timers.
  final bool autoStart;

  const ConnectivityWrapper({
    super.key,
    required this.child,
    @visibleForTesting this.evaluator,
    @visibleForTesting this.autoStart = true,
  });

  @override
  State<ConnectivityWrapper> createState() => _ConnectivityWrapperState();
}

class _ConnectivityWrapperState extends State<ConnectivityWrapper> with WidgetsBindingObserver {
  final _errorController = GlobalErrorController();
  late final ConnectivityEvaluator _evaluator;
  Timer? _connectivityTimer;

  @override
  void initState() {
    super.initState();
    _evaluator = widget.evaluator ?? ConnectivityEvaluator();
    WidgetsBinding.instance.addObserver(this);
    if (widget.autoStart) {
      // Preserve the 8-second checking interval and the initial check.
      _connectivityTimer =
          Timer.periodic(const Duration(seconds: 8), (_) => _checkConnectivity());
      _checkConnectivity();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivityTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Preserve app-resume rechecking.
    if (state == AppLifecycleState.resumed) {
      _checkConnectivity();
    }
  }

  Future<void> _checkConnectivity() async {
    await _evaluator.evaluate();
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<GlobalAppError?>(
      valueListenable: _errorController.errorNotifier,
      builder: (context, globalError, child) {
        final showBanner =
            !_evaluator.isOffline && (_evaluator.showOfflineBanner || _evaluator.showSlowBanner);
        return Stack(
          children: [
            // Always keep the child alive in the tree so its state is never destroyed.
            child!,

            // Genuine, independently-confirmed offline: full-screen block.
            if (_evaluator.isOffline)
              Positioned.fill(
                child: ConnectionErrorScreen(
                  errorType: ErrorType.offline,
                  errorMessage:
                      "WayDrop requires an active internet connection. Please verify your WiFi or mobile data.",
                  onRetry: () async {
                    await _checkConnectivity();
                  },
                ),
              ),

            // Non-blocking top banner for slow or unconfirmed-offline states.
            // The app underneath stays fully interactive.
            if (showBanner)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: _ConnectivityBanner(
                    offline: _evaluator.showOfflineBanner,
                    onRetry: () async {
                      await _checkConnectivity();
                    },
                  ),
                ),
              ),

            // Unchanged: externally-driven global error (currently no caller).
            if (!_evaluator.isOffline && !showBanner && globalError != null)
              Positioned.fill(
                child: ConnectionErrorScreen(
                  errorType: globalError.type,
                  errorMessage: globalError.message,
                  onRetry: () {
                    final retryAction = globalError.onRetry;
                    _errorController.clearError();
                    if (retryAction != null) {
                      retryAction();
                    }
                  },
                ),
              ),
          ],
        );
      },
      child: widget.child,
    );
  }
}

/// Slim, non-blocking banner anchored to the top of the screen. Only this strip
/// is interactive; taps elsewhere pass through to the app underneath.
class _ConnectivityBanner extends StatelessWidget {
  const _ConnectivityBanner({required this.offline, required this.onRetry});

  /// True = offline (not independently confirmed) wording; false = slow wording.
  final bool offline;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const accent = Color(0xFFF59E0B); // Amber warning tone.
    final bg = isDark ? const Color(0xFF131926) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

    final message = offline
        ? "You appear to be offline. Some features may not work."
        : "Your connection is slow right now, which may delay bookings and updates.";

    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.1),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(offline ? Icons.wifi_off_rounded : Icons.speed_rounded,
                color: accent, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                  height: 1.3,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                onRetry();
              },
              style: TextButton.styleFrom(
                foregroundColor: accent,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Retry',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
