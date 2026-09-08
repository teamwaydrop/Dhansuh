import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/app_start_screen.dart';
import 'package:waydrop/core/config/env.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/modules/notifications/services/notification_service.dart';
import 'package:waydrop/modules/payments/services/payment_service.dart';
import 'package:waydrop/core/providers/app_mode_provider.dart';
import 'package:waydrop/shared/helpers/connectivity_wrapper.dart';
import 'package:waydrop/shared/widgets/mode_switch_overlay.dart';
import 'package:waydrop/core/services/cache/cache_service.dart';
import 'package:waydrop/core/services/session/feature_flag_service.dart';
import 'package:waydrop/core/navigation/nav_trace_observer.dart';

final providerContainer = ProviderContainer();
final navigatorKey = GlobalKey<NavigatorState>();

/// [TRACE] TEMPORARY instrumentation — delete after root-cause capture.
/// Logs every AppLifecycleState transition (resumed/inactive/paused/detached/
/// hidden) so a logcat pull can show whether a "hang" coincided with the OS
/// backgrounding or killing the process.
class _TraceLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[TRACE_LIFECYCLE] main.dart AppLifecycleState=$state epoch=${DateTime.now().millisecondsSinceEpoch}');
  }
}

final _traceLifecycleObserver = _TraceLifecycleObserver();

Future<void> main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      WidgetsBinding.instance.addObserver(_traceLifecycleObserver);
      debugPrint('[TRACE_LIFECYCLE] observer attached epoch=${DateTime.now().millisecondsSinceEpoch}');

      // Enable Android edge-to-edge support and transparent status/navigation bars
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarContrastEnforced: false,
        ),
      );

      // =====================================
      // VALIDATE REQUIRED CONFIGURATION
      // =====================================
      // Fail gracefully with a clear, user-visible message instead of
      // crashing with a null-check-operator error if the required
      // --dart-define-from-file=.env values weren't supplied at build time.
      final supabaseUrl = Env.supabaseUrl;
      final supabaseAnonKey = Env.supabaseAnonKey;

      if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
        runApp(const _ConfigurationErrorApp());
        return;
      }

      // =====================================
      // FIREBASE + SUPABASE + CACHE
      // =====================================
      // These three inits are mutually independent, so they run concurrently to
      // overlap their latencies instead of stacking them serially. All three
      // still complete before runApp(), preserving every downstream ordering:
      // Firebase is ready before the Crashlytics error handlers below, and
      // Supabase is ready before PaymentService/NotificationService first touch
      // the client. (Failure semantics unchanged - any error still propagates
      // to the runZonedGuarded handler exactly as before.)
      await Future.wait([
        Firebase.initializeApp(),
        Supabase.initialize(
          url: supabaseUrl,
          anonKey: supabaseAnonKey,
        ),
        CacheService.instance.init(),
      ]);

      // Initialize Feature Flags in the background so it doesn't block app launch
      unawaited(FeatureFlagService.instance.init().catchError((e) => null));

      PaymentService.initializeCallbacks();
      
      // Initialize Notifications in the background so it doesn't block app launch
      // Phase 5 F2: this was a silent blind spot -- a NotificationService().initialize() failure
      // previously vanished entirely (debugPrint is silenced in release builds, and nothing else
      // observed it). Now reported non-fatally to Crashlytics before returning null, exactly as
      // before -- initialization still never blocks app launch and still never throws upward.
      unawaited(NotificationService().initialize().catchError((e, stackTrace) {
        FirebaseCrashlytics.instance.recordError(
          e,
          stackTrace,
          reason: 'NotificationService.initialize() failed',
          fatal: false,
        );
        return null;
      }));

      // =====================================
      // LOCATION CACHE
      // =====================================

      unawaited(
        LocationCacheService.initializeLocation().catchError((e) => null),
      );

      // =====================================
      // FLUTTER FRAMEWORK ERRORS
      // =====================================
      FlutterError.onError = (FlutterErrorDetails details) {
        debugPrint(
          '[NAV_TRACE] ${DateTime.now().toIso8601String()} FlutterError.onError '
          'exception=${details.exception} library=${details.library} '
          'context=${details.context} epoch=${DateTime.now().millisecondsSinceEpoch}',
        );
        debugPrintStack(stackTrace: details.stack);
        FlutterError.presentError(details);
        FirebaseCrashlytics.instance.recordFlutterFatalError(details);
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        debugPrint(
          '[NAV_TRACE] ${DateTime.now().toIso8601String()} PlatformDispatcher.instance.onError '
          'error=$error epoch=${DateTime.now().millisecondsSinceEpoch}',
        );
        debugPrintStack(stackTrace: stack);
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };

      // =====================================
      // APP
      // =====================================

      // Silence all debugPrint statements globally to protect user privacy in production.
      // (Left active in debug builds so kDebugMode/debugPrint-based diagnostics stay visible.)
      if (kReleaseMode) {
        debugPrint = (String? message, {int? wrapWidth}) {};
      }

      runApp(
        UncontrolledProviderScope(
          container: providerContainer,
          child: const WayDropApp(),
        ),
      );
    },
    (error, stack) {
      // Uncaught async exceptions handler
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    },
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        // Silence standard print statements globally to protect user privacy in production.
        // (Left active in debug builds so print()-based diagnostics stay visible.)
        if (!kReleaseMode) {
          parent.print(zone, line);
        }
      },
    ),
  );
}

class WayDropApp extends ConsumerWidget {
  const WayDropApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appMode = ref.watch(appModeProvider);
    final isRider = appMode == AppMode.rider;

    // Dynamic edge-to-edge system bars styling based on theme
    final isDarkTheme = isRider;
    final brightness = isDarkTheme ? Brightness.light : Brightness.dark;

    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: brightness,
        statusBarBrightness: isDarkTheme ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: brightness,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
    );

    final riderTheme = ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFF0B0F19), // darkBg
      canvasColor: const Color(0xFF0B0F19),
      cardColor: const Color(0xFF131926),
      dialogBackgroundColor: const Color(0xFF131926),
      appBarTheme: const AppBarTheme(
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarContrastEnforced: false,
        ),
      ),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFFC5FF30), // primaryLime
        background: Color(0xFF0B0F19),
        surface: Color(0xFF131926),
      ),
      textTheme: GoogleFonts.plusJakartaSansTextTheme(
        ThemeData.dark().textTheme,
      ),
    );

    final userLightTheme = ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: Colors.white,
      canvasColor: Colors.white,
      cardColor: const Color(0xFFF8FAFC),
      dialogBackgroundColor: const Color(0xFFF8FAFC),
      dividerColor: const Color(0xFFE2E8F0),
      appBarTheme: const AppBarTheme(
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.dark,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarContrastEnforced: false,
        ),
      ),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF1B7A44),
        primary: const Color(0xFF1B7A44), // Primary Green
        secondary: const Color(0xFFD4AF37), // Gold Accent
        brightness: Brightness.light,
      ),
      textTheme: GoogleFonts.plusJakartaSansTextTheme(
        ThemeData.light().textTheme,
      ),
    );

    return MaterialApp(
      navigatorKey: navigatorKey,
      // [NAV_TRACE] TEMPORARY instrumentation — delete after root-cause capture (see
      // nav_trace_observer.dart). Gives global visibility into every real push/pop/replace/remove
      // regardless of which of the app's three navigation sources triggered it.
      navigatorObservers: [NavTraceObserver()],
      debugShowCheckedModeBanner: false,
      title: 'WayDrop',
      theme: isRider ? riderTheme : userLightTheme,
      darkTheme: isRider ? riderTheme : userLightTheme,
      themeMode: isRider ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) => ConnectivityWrapper(
        child: ModeSwitchOverlay(child: child ?? const SizedBox.shrink()),
      ),
      home: const AppStartScreen(),
    );
  }
}

/// Shown instead of crashing when required startup configuration
/// (SUPABASE_URL / SUPABASE_ANON_KEY) is missing or empty in `.env`.
class _ConfigurationErrorApp extends StatelessWidget {
  const _ConfigurationErrorApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'Configuration Error',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "WayDrop could not start because required configuration "
                    "(SUPABASE_URL / SUPABASE_ANON_KEY) is missing from the "
                    "app's environment file. Please contact support.",
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
