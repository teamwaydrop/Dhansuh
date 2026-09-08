import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:waydrop/shared/screens/connection_error_screen.dart';
import 'package:waydrop/shared/helpers/global_error_controller.dart';

class ConnectivityWrapper extends StatefulWidget {
  final Widget child;

  const ConnectivityWrapper({
    super.key,
    required this.child,
  });

  @override
  State<ConnectivityWrapper> createState() => _ConnectivityWrapperState();
}

class _ConnectivityWrapperState extends State<ConnectivityWrapper> with WidgetsBindingObserver {
  final _errorController = GlobalErrorController();
  Timer? _connectivityTimer;
  bool _isOffline = false;
  bool _isSlow = false;
  bool _checking = false;
  int _consecutiveFailures = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Start periodic background connectivity check
    _connectivityTimer = Timer.periodic(const Duration(seconds: 8), (_) => _checkConnectivity());
    _checkConnectivity(); // Initial check
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivityTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[TRACE_CONNECTIVITY] didChangeAppLifecycleState=$state epoch=${DateTime.now().millisecondsSinceEpoch}');
    if (state == AppLifecycleState.resumed) {
      // Automatically recheck connectivity when app is brought back from recents/background
      _checkConnectivity();
    }
  }

  Future<void> _checkConnectivity() async {
    if (_checking) return;
    _checking = true;
    debugPrint('[TRACE_CONNECTIVITY] _checkConnectivity START epoch=${DateTime.now().millisecondsSinceEpoch} consecutiveFailures=$_consecutiveFailures isOffline=$_isOffline');

    try {
      final startTime = DateTime.now();

      // Try resolving multiple domains to avoid false-positives
      bool isOnline = false;
      final domains = ['google.com', 'one.one.one.one', 'github.com'];
      for (final domain in domains) {
        try {
          final lookupStart = DateTime.now();
          final result = await InternetAddress.lookup(domain)
              .timeout(const Duration(seconds: 3));
          debugPrint('[TRACE_CONNECTIVITY] lookup($domain) OK in ${DateTime.now().difference(lookupStart).inMilliseconds}ms => ${result.isNotEmpty ? result[0].address : "empty"}');
          if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
            isOnline = true;
            break;
          }
        } catch (e) {
          debugPrint('[TRACE_CONNECTIVITY] lookup($domain) FAILED after ${DateTime.now().difference(startTime).inMilliseconds}ms => $e');
          // Try next domain if this one fails
        }
      }

      final duration = DateTime.now().difference(startTime);

      if (mounted) {
        setState(() {
          if (isOnline) {
            _consecutiveFailures = 0;
            _isOffline = false;
            // If response takes more than 3.2 seconds, treat it as slow connection
            _isSlow = duration.inMilliseconds > 3200;
          } else {
            _consecutiveFailures++;
            if (_consecutiveFailures >= 3 || _isOffline) {
              _isOffline = true;
              _isSlow = false;
            }
          }
        });
      }
      debugPrint('[TRACE_CONNECTIVITY] _checkConnectivity DONE epoch=${DateTime.now().millisecondsSinceEpoch} isOnline=$isOnline totalMs=${duration.inMilliseconds} consecutiveFailures=$_consecutiveFailures isOffline=$_isOffline isSlow=$_isSlow');
    } catch (e) {
      debugPrint('[TRACE_CONNECTIVITY] _checkConnectivity outer catch => $e');
      if (mounted) {
        setState(() {
          _consecutiveFailures++;
          if (_consecutiveFailures >= 3 || _isOffline) {
            _isOffline = true;
            _isSlow = false;
          }
        });
      }
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<GlobalAppError?>(
      valueListenable: _errorController.errorNotifier,
      builder: (context, globalError, child) {
        return Stack(
          children: [
            // Always keep the child alive in the tree so its state is never destroyed!
            child!,
            
            if (_isOffline)
              Positioned.fill(
                child: ConnectionErrorScreen(
                  errorType: ErrorType.offline,
                  errorMessage: "WayDrop requires an active internet connection. Please verify your WiFi or mobile data.",
                  onRetry: () async {
                    await _checkConnectivity();
                  },
                ),
              ),
            
            if (!_isOffline && _isSlow)
              Positioned.fill(
                child: ConnectionErrorScreen(
                  errorType: ErrorType.slow,
                  errorMessage: "Your connection is very slow right now, which may delay bookings and updates.",
                  onRetry: () async {
                    await _checkConnectivity();
                  },
                ),
              ),
            
            if (!_isOffline && !_isSlow && globalError != null)
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
