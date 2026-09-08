import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PipService {
  static const MethodChannel _channel = MethodChannel('com.waydrop.app/pip');
  static final ValueNotifier<bool> isInPipMode = ValueNotifier<bool>(false);
  static bool _initialized = false;

  static VoidCallback? onPipRecenter;
  static VoidCallback? onPipZoomIn;
  static VoidCallback? onPipZoomOut;

  /// Initialize the method call handler to receive PiP state changes from Android.
  static void initialize() {
    if (_initialized) return;
    if (kIsWeb || !Platform.isAndroid) return;
    
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'pipModeChanged') {
        final bool inPip = call.arguments as bool? ?? false;
        isInPipMode.value = inPip;
        debugPrint('Picture-in-Picture mode changed: $inPip');
      } else if (call.method == 'pipRecenter') {
        onPipRecenter?.call();
      } else if (call.method == 'pipZoomIn') {
        onPipZoomIn?.call();
      } else if (call.method == 'pipZoomOut') {
        onPipZoomOut?.call();
      }
    });
    _initialized = true;
  }

  /// Check if the current device/OS version supports Picture-in-Picture.
  static Future<bool> isPipSupported() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final bool? supported = await _channel.invokeMethod<bool>('isPipSupported');
      return supported ?? false;
    } catch (e) {
      debugPrint('Error checking PiP support: $e');
      return false;
    }
  }

  /// Enable or disable automatic PiP mode on app switch/leave.
  static Future<void> setPipEnabled(bool enabled) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      initialize(); // Ensure listener is registered
      await _channel.invokeMethod('setPipEnabled', {'enabled': enabled});
      debugPrint('Picture-in-Picture enabled state set to: $enabled');
    } catch (e) {
      debugPrint('Error setting PiP enabled: $e');
    }
  }

  /// Manually trigger entering Picture-in-Picture mode.
  static Future<bool> enterPipMode() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      initialize();
      final bool? entered = await _channel.invokeMethod<bool>('enterPipMode');
      return entered ?? false;
    } catch (e) {
      debugPrint('Error entering PiP mode: $e');
      return false;
    }
  }
}
