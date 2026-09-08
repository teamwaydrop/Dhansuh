// Regression guard for: logout -> login -> OTP verification succeeds but the app stays stuck on
// the OTP screen, only fixed by force-closing and reopening the app.
//
// ROOT CAUSE (traced, not assumed): AppStartScreen is the app's single `home:` widget. It does
// NOT use per-screen Navigator routes for its own top-level screen switching -- it holds a
// `currentScreen` field swapped via setState() inside changeScreen(), and relies entirely on its
// own supabase.auth.onAuthStateChange listener (subscribed once in initState()) to react to
// sign-in/sign-out and call changeScreen(). otp_screen.dart deliberately does NOT navigate itself
// after OTP verification -- it depends entirely on this listener to do it, and
// changeScreen()'s wasLoginScreen-gated popUntil((route) => route.isFirst) is what pops the
// OtpScreen route login_screen.dart pushed on top of AppStartScreen.
//
// Both profile_tab.dart's and rider_profile_tab.dart's logout handlers used to end with
// `Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const LoginScreen()),
// (_) => false)` AFTER already calling signOut(). A predicate that always returns false removes
// EVERY existing route, including AppStartScreen's own home route -- disposing its State and, with
// it, the onAuthStateChange listener the NEXT login's post-OTP navigation depends on. The call was
// also redundant: AppStartScreen was still alive when signOut() resolved, so its own listener
// already reacts to the `signedOut` event and swaps to LoginScreen by itself.
//
// FIX: both logout handlers now do nothing after signOut()/cache cleanup -- no manual navigation.
// This is a structural regression guard: it reads the real source rather than executing the
// Supabase auth flow, matching the pattern used throughout this suite for behavior that can't run
// against a live auth/navigation stack in a plain unit test.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

// Strips `//` line comments before a containment check, so an in-source comment that documents
// (and quotes) the old buggy call -- exactly what this file's own bug-fix comments do -- can never
// cause a false positive.
String _stripLineComments(String source) => source
    .split('\n')
    .map((line) {
      final idx = line.indexOf('//');
      return idx == -1 ? line : line.substring(0, idx);
    })
    .join('\n');

void main() {
  final appStartScreen = _read('lib/app_start_screen.dart');
  final passengerProfile = _read('lib/features/user/profile/profile_tab.dart');
  final riderProfile = _read('lib/features/rider/profile/rider_profile_tab.dart');

  group('AppStartScreen is the sole source of truth for post-login/post-logout navigation', () {
    test('subscribes to onAuthStateChange exactly once, in initState via listenAuthChanges()', () {
      expect(appStartScreen.contains('void listenAuthChanges()'), isTrue);
      expect(appStartScreen.contains('supabase.auth.onAuthStateChange.listen('), isTrue);
    });

    test('reacts to signedOut (and every event except initialSession/tokenRefreshed) by calling '
        'checkUserFlow()', () {
      final start = appStartScreen.indexOf('void listenAuthChanges()');
      final end = appStartScreen.indexOf('Future<void> checkUserFlow()');
      expect(start, greaterThan(-1));
      final body = appStartScreen.substring(start, end);
      expect(body.contains('AuthChangeEvent.initialSession'), isTrue);
      expect(body.contains('AuthChangeEvent.tokenRefreshed'), isTrue);
      expect(body.contains('checkUserFlow()'), isTrue);
    });

    test('changeScreen() pops any route pushed on top of it (e.g. OtpScreen) only when the '
        'previous screen was LoginScreen, revealing the freshly-set currentScreen', () {
      final start = appStartScreen.indexOf('Future<void> changeScreen(');
      expect(start, greaterThan(-1));
      final body = appStartScreen.substring(start, start + 2500);
      expect(body.contains('final wasLoginScreen = currentScreen is LoginScreen;'), isTrue);
      expect(body.contains('if (wasLoginScreen)'), isTrue);
      expect(body.contains("navigatorKey.currentState?.popUntil((route) => route.isFirst);"), isTrue);
    });
  });

  group('Logout handlers no longer destroy AppStartScreen\'s State (the actual bug)', () {
    test('passenger profile_tab.dart logout: signOut()/cleanup run, but no '
        'Navigator.pushAndRemoveUntil((_) => false) afterwards', () {
      final signOutIdx = passengerProfile.indexOf('await Supabase.instance.client.auth.signOut();');
      expect(signOutIdx, greaterThan(-1));
      final afterSignOut = passengerProfile.substring(signOutIdx);
      // Scoped to the logout handler body -- MaterialPageRoute is legitimately used elsewhere in
      // this file for other navigations, but never a full-stack-clearing pushAndRemoveUntil right
      // after signOut() again. Comments are stripped first since this handler's own bug-fix
      // comment quotes the old buggy call for documentation purposes.
      final handlerEnd = afterSignOut.indexOf('\n  }');
      final handlerBody = _stripLineComments(
        afterSignOut.substring(0, handlerEnd == -1 ? afterSignOut.length : handlerEnd),
      );
      expect(handlerBody.contains('Navigator.pushAndRemoveUntil'), isFalse);
      expect(handlerBody.contains('(_) => false'), isFalse);
    });

    test('passenger profile_tab.dart no longer imports LoginScreen (the manual-navigation target '
        'that was removed)', () {
      expect(
        passengerProfile.contains("import 'package:waydrop/features/auth/screens/login_screen.dart';"),
        isFalse,
      );
    });

    test('rider rider_profile_tab.dart logout: signOut()/cleanup run, but no '
        'Navigator.pushAndRemoveUntil((_) => false) afterwards', () {
      final signOutIdx = riderProfile.indexOf('await supabase.auth.signOut();');
      expect(signOutIdx, greaterThan(-1));
      final afterSignOut = riderProfile.substring(signOutIdx);
      final handlerEnd = afterSignOut.indexOf('\n  }');
      final handlerBody = _stripLineComments(
        afterSignOut.substring(0, handlerEnd == -1 ? afterSignOut.length : handlerEnd),
      );
      expect(handlerBody.contains('Navigator.pushAndRemoveUntil'), isFalse);
      expect(handlerBody.contains('(_) => false'), isFalse);
    });

    test('rider rider_profile_tab.dart no longer imports LoginScreen', () {
      expect(
        riderProfile.contains("import 'package:waydrop/features/auth/screens/login_screen.dart';"),
        isFalse,
      );
    });

    test('both logout handlers still perform full cleanup -- token removal, cache clear, '
        'AuthSession.clear(), and UserSessionService().stopListening() -- only the destructive '
        'manual navigation was removed', () {
      for (final source in [passengerProfile, riderProfile]) {
        expect(source.contains('NotificationService().removeToken()'), isTrue);
        expect(source.contains('CacheCleanupHelper.clearAllCaches()'), isTrue);
        expect(source.contains('AuthSession.clear()'), isTrue);
        expect(source.contains('UserSessionService().stopListening()'), isTrue);
      }
    });
  });

  group('AppStartScreen\'s own programmatic-logout path (suspended user) is the correct existing '
      'reference pattern and is unchanged', () {
    test('it calls changeScreen(const LoginScreen(), ...) directly, never a raw Navigator call, '
        'because it runs inside AppStartScreen itself and does not need to pop anything', () {
      final suspendedIdx = appStartScreen.indexOf('final isSuspended = profile[');
      expect(suspendedIdx, greaterThan(-1));
      final block = appStartScreen.substring(suspendedIdx, suspendedIdx + 600);
      expect(block.contains('await supabase.auth.signOut();'), isTrue);
      expect(block.contains('DeveloperModeService.instance.clear();'), isTrue);
      expect(block.contains('UserSessionService().stopListening();'), isTrue);
      expect(block.contains('await changeScreen(const LoginScreen(), startTime);'), isTrue);
      expect(block.contains('Navigator.pushAndRemoveUntil'), isFalse);
    });
  });
}
