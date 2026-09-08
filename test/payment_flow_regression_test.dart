// Structural regression guard for the QR-based direct-payment architecture
// (docs/07_Payments.md). This does not run the app -- it inspects the payment-flow source files
// themselves so a future edit that reintroduces a raw UPI payment intent, or that starts feeding
// the fare/order code into the driver's Personal QR, fails CI immediately instead of only being
// caught on a real device.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('Personal QR / UPI app launcher never builds a payment request', () {
    final passengerPanel = _read('lib/core/navigation/flow_modules.dart');
    final upiLauncher = _read('lib/modules/payments/services/upi_app_launcher.dart');
    final driverScreen = _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');

    // Quote-adjacent forms only -- a Dart string literal actually building the URI, e.g.
    // 'upi://pay?pa=...'. Plain mentions of "upi://pay" inside `//`/`///` comments (explaining why
    // it was retired) are expected and must not trip this guard.
    const forbiddenUriLiterals = ["'upi://pay", '"upi://pay'];
    const forbiddenParams = ['pa=', 'pn=', 'tr=', 'tn='];

    void assertNoRawUpiIntent(String source, String label) {
      for (final piece in forbiddenUriLiterals) {
        expect(source.contains(piece), isFalse, reason: '$piece found as a string literal in $label');
      }
      for (final piece in forbiddenParams) {
        expect(source.contains(piece), isFalse, reason: '"$piece" found in $label');
      }
    }

    test('passenger payment panel never constructs a upi://pay intent', () {
      assertNoRawUpiIntent(passengerPanel, 'flow_modules.dart');
    });

    test('UPI app launcher never constructs a upi://pay intent', () {
      assertNoRawUpiIntent(upiLauncher, 'upi_app_launcher.dart');
      // The only Uri/AndroidIntent construction allowed here carries no query data at all.
      expect(upiLauncher.contains('Uri(scheme:'), isTrue);
      expect(upiLauncher.contains('queryParameters'), isFalse);
    });

    test('driver screen never renders a Cashfree/Personal QR built from a upi://pay string', () {
      assertNoRawUpiIntent(driverScreen, 'rider_active_order_screen.dart');
    });

    test('the old raw-UPI-intent helper is gone, not just unused', () {
      expect(passengerPanel.contains('_payViaPersonalUpi'), isFalse);
    });

    test('Personal QR viewer displays the uploaded image, not a locally-built payload', () {
      // The driver's Personal QR must come from the signed storage URL (qrUrl), never a
      // QrImageView built from fare/order data (that is legitimate ONLY for the separate,
      // gateway-issued Cashfree QR elsewhere in this same file). Egress fix: rendered via
      // CachedNetworkImage (disk+mem cache, downsampled to display size) instead of a raw
      // Image.network, but still the same signed qrUrl.
      expect(driverScreen.contains('CachedNetworkImage('), isTrue);
      expect(driverScreen.contains('imageUrl: qrUrl'), isTrue);
    });

    test('Pay button detects installed apps and branches to the picker, not straight to instructions', () {
      // _handlePayTap must call UpiAppLauncher.getAvailableApps() and only fall back to the
      // no-apps-detected sheet when that list comes back empty -- otherwise it must show the picker.
      expect(passengerPanel.contains('UpiAppLauncher.getAvailableApps()'), isTrue);
      expect(passengerPanel.contains('if (apps.isEmpty)'), isTrue);
      expect(passengerPanel.contains('_showUpiInstructionsSheet()'), isTrue);
      expect(passengerPanel.contains('_showChooseUpiAppSheet(apps)'), isTrue);
    });

    test('the old "Pay by UPI / Got it" dead-end sheet is gone', () {
      // A previous fallback showed plain instructions with only a "Got it" acknowledgement button
      // and no way to retry detection or fall through to cash -- it must not come back.
      expect(passengerPanel.contains('Pay by UPI'), isFalse);
      expect(passengerPanel.contains('Got it'), isFalse);
      expect(passengerPanel.contains('Open any UPI app and scan'), isFalse);
      expect(passengerPanel.contains('_acknowledgeUpiInstructions'), isFalse);
      // Its replacement must offer a retry and a direct cash fallback instead.
      expect(passengerPanel.contains('No supported UPI apps detected'), isTrue);
      expect(passengerPanel.contains('Try Again'), isTrue);
    });

    test('Android UPI app detection/launch never depends on android_intent_plus canResolveActivity', () {
      // canResolveActivity(intent, MATCH_DEFAULT_ONLY) requires category.DEFAULT, which
      // LAUNCHER-only activities (every app's home icon) never declare -- it silently returns
      // false for every installed app on a real device. Detection/launch must instead go through
      // the native getLaunchIntentForPackage platform channel. (Checks for actual code use, not
      // just prose mentions -- this file's own doc comment explains the old bug by name.)
      expect(upiLauncher.contains("import 'package:android_intent_plus"), isFalse);
      expect(upiLauncher.contains('AndroidIntent('), isFalse);
      expect(upiLauncher.contains('.canResolveActivity()'), isFalse);
      expect(upiLauncher.contains("MethodChannel('com.waydrop.app/upi_apps')"), isTrue);
      expect(upiLauncher.contains("'isAppInstalled'"), isTrue);
      expect(upiLauncher.contains("'openApp'"), isTrue);
    });

    test('picking an installed UPI app opens it with no fare/order data attached', () {
      // _payViaUpiApp(app) must take only the chosen UpiApp -- no fare/order argument -- and
      // UpiAppLauncher.open(app) must likewise take only the app, never a payment payload.
      expect(passengerPanel.contains('Future<void> _payViaUpiApp(UpiApp app)'), isTrue);
      expect(passengerPanel.contains('UpiAppLauncher.open(app)'), isTrue);
    });

    test('driver swipe-to-confirm still gates completion of a personal_upi fare', () {
      // Opening a UPI app must never itself complete the order -- only the driver's own
      // "Swipe to Confirm ... Received" advances the order to 'completed'.
      expect(driverScreen.contains('SwipeToConfirmButton'), isTrue);
      expect(driverScreen.contains("settlementMethod: 'personal_upi'"), isTrue);
      expect(upiLauncher.contains("updateStatus"), isFalse);
      expect(upiLauncher.contains("'completed'"), isFalse);
    });
  });

  group('Choose Payment Method is the first sheet, with Cash as a prominent equal option', () {
    final passengerPanel = _read('lib/core/navigation/flow_modules.dart');
    final rideTracking = _read('lib/features/local_rides/tracking/screens/ride_tracking_screen.dart');
    final intercityTracking = _read('lib/features/intercity/shared/screens/intercity_tracking_screen.dart');

    test('Pay tap opens Choose Payment Method, not the UPI app picker directly', () {
      // _handlePayTap must only open the method chooser -- UPI app detection must not run until
      // the passenger explicitly picks "UPI Apps" from that chooser.
      final handlePayTapStart = passengerPanel.indexOf('Future<void> _handlePayTap() async {');
      final handlePayTapEnd = passengerPanel.indexOf('Future<void> _showChoosePaymentMethodSheet()');
      expect(handlePayTapStart, greaterThan(-1));
      expect(handlePayTapEnd, greaterThan(handlePayTapStart));
      final handlePayTapSource = passengerPanel.substring(handlePayTapStart, handlePayTapEnd);
      expect(handlePayTapSource.contains('_showChoosePaymentMethodSheet();'), isTrue);
      expect(handlePayTapSource.contains('UpiAppLauncher.getAvailableApps()'), isFalse);
      expect(passengerPanel.contains("'Choose Payment Method'"), isTrue);
    });

    test('UPI Apps and Cash are both rendered via the same prominent card widget, not a text link', () {
      // Both options in the top-level chooser must go through _buildSheetOption (icon + title +
      // subtitle + chevron card) -- Cash must not be a bare TextButton at this level.
      final sheetStart = passengerPanel.indexOf('Future<void> _showChoosePaymentMethodSheet()');
      final sheetEnd = passengerPanel.indexOf('_handleUpiAppsTap() async {');
      expect(sheetStart, greaterThan(-1));
      expect(sheetEnd, greaterThan(sheetStart));
      final sheetSource = passengerPanel.substring(sheetStart, sheetEnd);
      expect(sheetSource.contains("title: 'UPI Apps'"), isTrue);
      expect(sheetSource.contains("subtitle: 'Pay using a UPI app'"), isTrue);
      expect(sheetSource.contains("title: 'Cash'"), isTrue);
      expect(sheetSource.contains('_buildSheetOption('), isTrue);
      expect(sheetSource.contains('TextButton'), isFalse);
    });

    test('UPI Apps card routes to app detection; Cash card routes straight to _payViaCash', () {
      expect(passengerPanel.contains('_handleUpiAppsTap();'), isTrue);
      final sheetStart = passengerPanel.indexOf('Future<void> _showChoosePaymentMethodSheet()');
      final sheetEnd = passengerPanel.indexOf('_handleUpiAppsTap() async {');
      final sheetSource = passengerPanel.substring(sheetStart, sheetEnd);
      expect(sheetSource.contains('_payViaCash();'), isTrue);
    });

    test('passenger-facing payment copy says Drop Partner, not driver', () {
      final transportOrderModel = _read('lib/models/transport_order.dart');
      expect(passengerPanel.contains('Drop Partner'), isTrue);
      expect(rideTracking.contains("Pay your Drop Partner to complete the trip."), isTrue);
      expect(intercityTracking.contains("Pay your Drop Partner to complete the trip."), isTrue);
      expect(transportOrderModel.contains('Pay your Drop Partner to complete the trip'), isTrue);
      // No leftover "your driver" wording in this passenger payment flow.
      expect(passengerPanel.contains('your driver'), isFalse);
      expect(rideTracking.contains('Pay your driver'), isFalse);
      expect(intercityTracking.contains('Pay your driver'), isFalse);
      expect(transportOrderModel.contains('Pay your driver'), isFalse);
    });
  });

  group('Android native UPI app detection', () {
    final mainActivity = _read('android/app/src/main/kotlin/com/waydrop/app/MainActivity.kt');

    test('MainActivity resolves apps via getLaunchIntentForPackage, not resolveActivity', () {
      expect(mainActivity.contains('com.waydrop.app/upi_apps'), isTrue);
      expect(mainActivity.contains('getLaunchIntentForPackage'), isTrue);
      // Checks for actual use of the broken flag, not just this file's own doc-comment mention of
      // why it was replaced.
      expect(mainActivity.contains('resolveActivity(intent'), isFalse);
      expect(mainActivity.contains('PackageManager.MATCH_DEFAULT_ONLY'), isFalse);
    });
  });

  group('AndroidManifest UPI package visibility', () {
    final manifest = _read('android/app/src/main/AndroidManifest.xml');

    test('queries the specific UPI app packages, not a generic upi:// scheme intent', () {
      const knownPackages = [
        'com.google.android.apps.nbu.paisa.user',
        'com.phonepe.app',
        'net.one97.paytm',
        'in.org.npci.upiapp',
      ];
      for (final pkg in knownPackages) {
        expect(manifest.contains('android:name="$pkg"'), isTrue, reason: 'missing package query for $pkg');
      }
      // The old generic upi://pay-style scheme query must not be restored.
      expect(manifest.contains('android:scheme="upi"'), isFalse);
    });

    test('<queries> is a direct child of <manifest>, not nested inside <application>', () {
      final appIndex = manifest.indexOf('<application');
      final appCloseIndex = manifest.indexOf('</application>');
      final queriesIndex = manifest.indexOf('<queries>');
      expect(queriesIndex, greaterThan(appCloseIndex),
          reason: '<queries> must come after </application>, as a sibling under <manifest>');
      expect(appIndex, greaterThan(-1));
    });
  });
}
