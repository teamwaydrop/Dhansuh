import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// A single well-known UPI app WayDrop can offer as an "open this app" shortcut.
///
/// This is never used to build a payment request -- only to bring the app itself to the
/// foreground so the passenger can use ITS OWN QR scanner on the driver's displayed Personal QR.
/// Neither the package name/scheme lookup nor the launch call in [UpiAppLauncher] ever carries a
/// payee VPA, amount, order code, or note -- see docs/07_Payments.md section 3.
class UpiApp {
  final String name;
  final String androidPackage;

  /// Bare URL scheme (no "://" suffix) this app registers for iOS deep linking. Null means the
  /// app is only offered on Android, where its package name lets us detect/launch it directly
  /// without depending on a scheme registration at all.
  final String? iosScheme;

  const UpiApp({required this.name, required this.androidPackage, this.iosScheme});
}

/// Detects and opens installed UPI apps WITHOUT ever constructing a `upi://pay` (or any other)
/// payment intent.
///
/// [getAvailableApps] only *checks* whether an app can be resolved -- it never fabricates
/// availability. [open] only brings the app to its own home screen, exactly as if the passenger
/// had tapped its home-screen icon: no data, no query parameters, no extras.
///
/// On Android this goes through a small platform channel (`com.waydrop.app/upi_apps`, see
/// MainActivity.kt) backed by `PackageManager.getLaunchIntentForPackage`. An earlier version used
/// the `android_intent_plus` package's `canResolveActivity()`, which calls
/// `PackageManager.resolveActivity(intent, MATCH_DEFAULT_ONLY)` -- that flag requires the target
/// activity to declare `category.DEFAULT`, which LAUNCHER-only activities (i.e. every app's home
/// icon, including GPay/PhonePe/Paytm/BHIM) never do. That made detection silently return empty on
/// every real device regardless of the AndroidManifest `<queries>` block being correct, permanently
/// falling through to the plain-instructions sheet.
class UpiAppLauncher {
  static const MethodChannel _channel = MethodChannel('com.waydrop.app/upi_apps');

  static const List<UpiApp> _knownApps = [
    UpiApp(name: 'Google Pay', androidPackage: 'com.google.android.apps.nbu.paisa.user', iosScheme: 'gpay'),
    UpiApp(name: 'PhonePe', androidPackage: 'com.phonepe.app', iosScheme: 'phonepe'),
    UpiApp(name: 'Paytm', androidPackage: 'net.one97.paytm', iosScheme: 'paytmmp'),
    UpiApp(name: 'BHIM', androidPackage: 'in.org.npci.upiapp'),
  ];

  /// Returns only the apps this device can actually open right now. An app that fails its own
  /// resolvability check is simply left out -- the passenger is never shown an option that would
  /// silently fail, and the caller falls back to plain instructions if this list comes back empty.
  static Future<List<UpiApp>> getAvailableApps() async {
    final available = <UpiApp>[];
    for (final app in _knownApps) {
      final found = await _canOpen(app);
      debugPrint('UPI DETECT => package=${app.androidPackage} name=${app.name} installed=$found');
      if (found) available.add(app);
    }
    debugPrint('UPI DETECT => total installed apps found: ${available.length}');
    return available;
  }

  static Future<bool> _canOpen(UpiApp app) async {
    try {
      if (Platform.isAndroid) {
        final installed = await _channel.invokeMethod<bool>('isAppInstalled', {'package': app.androidPackage});
        return installed ?? false;
      }
      if (Platform.isIOS && app.iosScheme != null) {
        return await canLaunchUrl(Uri(scheme: app.iosScheme));
      }
    } catch (e) {
      debugPrint('UPI APP LAUNCHER => resolve check failed for ${app.name}: $e');
    }
    return false;
  }

  /// Opens the app to its own home screen. No data, no extras, no payment intent of any kind --
  /// the equivalent of the passenger tapping the app's icon on their home screen.
  static Future<bool> open(UpiApp app) async {
    try {
      if (Platform.isAndroid) {
        final opened = await _channel.invokeMethod<bool>('openApp', {'package': app.androidPackage});
        debugPrint('UPI LAUNCH => package=${app.androidPackage} name=${app.name} opened=${opened ?? false}');
        return opened ?? false;
      }
      if (Platform.isIOS && app.iosScheme != null) {
        return await launchUrl(Uri(scheme: app.iosScheme), mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('UPI APP LAUNCHER => open failed for ${app.name}: $e');
    }
    return false;
  }
}
