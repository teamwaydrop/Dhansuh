import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/main.dart';
import 'package:waydrop/features/auth/screens/login_screen.dart';
import 'package:waydrop/features/auth/screens/permissions_screen.dart';
import 'package:waydrop/features/auth/screens/profile_setup_screen.dart';
import 'package:waydrop/main_navigation_screen.dart';
import 'package:waydrop/features/rider/navigation/rider_main_navigation_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:waydrop/core/providers/app_mode_provider.dart';
import 'package:waydrop/shared/screens/connection_error_screen.dart';
import 'package:waydrop/shared/helpers/global_error_controller.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';
import 'package:waydrop/core/services/session/user_session_service.dart';
import 'package:waydrop/core/services/cache/cache_cleanup_helper.dart';
import 'package:waydrop/shared/helpers/auth_session.dart';
import 'package:waydrop/core/providers/initial_data_provider.dart';
import 'package:waydrop/core/models/today_earnings_seed.dart';
import 'package:waydrop/core/services/location/serviceability_service.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/core/services/developer/developer_mode_service.dart';
import 'package:waydrop/core/services/config/production_config_service.dart';
import 'package:waydrop/shared/screens/maintenance_screen.dart';
import 'package:waydrop/shared/screens/update_required_screen.dart';
import 'package:waydrop/modules/notifications/services/notification_service.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:waydrop/design_system/waydrop_design_system.dart';
import 'package:waydrop/core/navigation/nav_trace.dart';

class AppStartScreen extends ConsumerStatefulWidget {
  const AppStartScreen({super.key});

  @override
  ConsumerState<AppStartScreen> createState() => _AppStartScreenState();
}

class _AppStartScreenState extends ConsumerState<AppStartScreen> {
  final supabase = Supabase.instance.client;
  final ValueNotifier<String> _statusNotifier = ValueNotifier<String>('Preparing your journey...');
  late Widget currentScreen;
  bool _isChecking = false;
  bool _pendingRecheck = false;
  // Phase 1 production control: the non-blocking "update available" recommendation (CASE B) is
  // shown at most once per app session, after the user actually reaches a real app screen -- not
  // during onboarding/login, and not repeated on every checkUserFlow() re-run (auth state changes,
  // pull-to-refresh-style rechecks, etc.).
  bool _updateRecommendationShown = false;

  @override
  void initState() {
    super.initState();
    currentScreen = _BrandSplashView(statusNotifier: _statusNotifier);
    checkUserFlow();
    listenAuthChanges();
  }

  void listenAuthChanges() {
    supabase.auth.onAuthStateChange.listen((data) {
      debugPrint('[TRACE_APPSTART] onAuthStateChange event=${data.event} session=${data.session != null} epoch=${DateTime.now().millisecondsSinceEpoch}');
      // PERF FIX: onAuthStateChange replays the current session as an `initialSession` event to
      // every new subscriber (this listener is attached synchronously right after initState's own
      // direct checkUserFlow() call above), and Supabase's client silently re-emits `tokenRefreshed`
      // on its own refresh cadence (~every session lifetime, no user action) for as long as the app
      // stays open. Both previously re-ran the FULL checkUserFlow() pipeline (profile query, then
      // rider+kyc+earnings or riders+kyc+orders Future.wait) even though neither event represents an
      // actual navigation-relevant change: `initialSession` duplicates the initState call that
      // already ran (was previously masked by the _isChecking/_pendingRecheck guard queuing a SECOND
      // full run right after the first completes, on every single cold start), and `tokenRefreshed`
      // fires deep inside an already-running session where the current screen and provider data are
      // still correct. Every event that DOES require re-evaluating the flow -- signedIn (OTP
      // verification, see otp_screen.dart's comment on why it relies on this listener),
      // signedOut/userDeleted (suspension/account-deletion self-logout paths), userUpdated, and
      // passwordRecovery/mfaChallengeVerified -- is untouched and still triggers checkUserFlow()
      // exactly as before.
      if (data.event == AuthChangeEvent.initialSession || data.event == AuthChangeEvent.tokenRefreshed) {
        NavTrace.mark('AppStartScreen', 'onAuthStateChange event=${data.event} skipped (no-op event, see PERF FIX comment)');
        return;
      }
      NavTrace.mark('AppStartScreen', 'onAuthStateChange event=${data.event} session=${data.session != null} currentScreen=${currentScreen.runtimeType} isChecking=$_isChecking');
      checkUserFlow();
    });
  }

  Future<void> checkUserFlow() async {
    if (_isChecking) {
      _pendingRecheck = true;
      return;
    }
    _isChecking = true;

    final startTime = DateTime.now();
    debugPrint('[PERF_STARTUP] checkUserFlow begin epoch=${DateTime.now().millisecondsSinceEpoch}');
    _statusNotifier.value = 'Preparing your journey...';

    if (currentScreen is ConnectionErrorScreen) {
      await changeScreen(_BrandSplashView(statusNotifier: _statusNotifier));
    }

    try {
      // =====================================================
      // PHASE 1 PRODUCTION CONTROL: maintenance mode + app version gate
      // =====================================================
      // Runs before the `user == null` check below so maintenance_mode/force_update block even a
      // logged-out user from reaching LoginScreen -- not just an already-authenticated one. init()
      // is a single-fetch-per-session no-op on every checkUserFlow() re-run after the first (auth
      // state changes, etc.), so this never causes duplicate network requests. See
      // ProductionConfigService's class doc for the full fail-open staleness policy.
      await ProductionConfigService.instance.init();
      final config = ProductionConfigService.instance;

      if (config.maintenanceMode) {
        await changeScreen(
          MaintenanceScreen(message: config.maintenanceMessage, onRetry: () => checkUserFlow()),
          startTime,
        );
        return;
      }

      final installedVersion = config.appVersion;
      final blockedByVersion = config.forceUpdate ||
          ProductionConfigService.isVersionLower(installedVersion, config.minimumAndroidVersion);
      if (blockedByVersion) {
        await changeScreen(
          UpdateRequiredScreen(message: config.updateMessage, currentVersion: installedVersion),
          startTime,
        );
        return;
      }

      // Pre-fetch active zones in parallel so they are ready instantly on home screen
      unawaited(ServiceabilityService.loadActiveZones().timeout(const Duration(seconds: 4)).catchError((e) {
        debugPrint('Pre-fetching pricing zones failed/timed out: $e');
        return null;
      }));

      final user = supabase.auth.currentUser;
      debugPrint('[TRACE_APPSTART] currentUser=${user?.id} epoch=${DateTime.now().millisecondsSinceEpoch}');
      if (user == null) {
        DeveloperModeService.instance.clear();
        await changeScreen(const LoginScreen(), startTime);
        return;
      }

      // Stage 2: Database checking / security check
      _statusNotifier.value = 'Connecting securely...';

      // 2. Fetch profile with an 8-second timeout limit
      debugPrint('[TRACE_APPSTART] users profile query START epoch=${DateTime.now().millisecondsSinceEpoch}');
      final profile = await supabase
          .from('users')
          .select()
          .eq('id', user.id)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      debugPrint('[PERF_STARTUP] users profile query done at +${DateTime.now().difference(startTime).inMilliseconds}ms epoch=${DateTime.now().millisecondsSinceEpoch}');

      if (profile == null) {
        await changeScreen(const ProfileSetupScreen(), startTime);
        return;
      }

      DeveloperModeService.instance.setFromProfile(profile);

      final isSuspended = profile['is_suspended'] ?? false;
      if (isSuspended) {
        await supabase.auth.signOut();
        await CacheCleanupHelper.clearAllCaches();
        AuthSession.clear();
        DeveloperModeService.instance.clear();
        UserSessionService().stopListening();
        await changeScreen(const LoginScreen(), startTime);
        Future.microtask(() {
          if (mounted) {
            showAppSnackBar(
              context,
              'Your account has been suspended. Please contact support.',
              type: SnackBarType.error,
            );
          }
        });
        return;
      }

      UserSessionService().listenUserSuspension();

      final profileCompleted = profile['profile_completed'] ?? false;
      final onboardingCompleted = profile['onboarding_completed'] ?? false;

      if (!profileCompleted) {
        await changeScreen(const ProfileSetupScreen(), startTime);
        return;
      }

      if (!onboardingCompleted) {
        await changeScreen(const PermissionsScreen(), startTime);
        return;
      }

      if (!mounted) return;
      final preferredMode = profile['preferred_mode'] ?? 'user';
      
      // Stage 3: Fetch rider data / final setup
      _statusNotifier.value = 'Almost ready...';

      if (preferredMode == 'rider') {
        final data = await supabase
            .from('riders')
            .select('''
              *,
              rider_kyc!riders_kyc_id_fkey(
                full_name,
                rider_image
              )
            ''')
            .eq('user_id', user.id)
            .maybeSingle();

        TodayEarningsSeed? earningsSeed;
        if (data != null) {
          final kyc = data['rider_kyc!riders_kyc_id_fkey'] ?? data['rider_kyc'];
          if (kyc is Map) {
            data['full_name'] = kyc['full_name'];
            data['rider_image'] = kyc['rider_image'];
          }

          final nowLocal = DateTime.now();
          final startOfToday = DateTime(nowLocal.year, nowLocal.month, nowLocal.day).toUtc();
          final earningsResponse = await supabase
              .from('orders')
              .select('final_fare, current_fare, rider_earning')
              .eq('rider_id', data['id'])
              .inFilter('order_status', ['completed', 'delivered'])
              .gte('completed_at', startOfToday.toIso8601String())
              .count(CountOption.exact);
          earningsSeed = TodayEarningsSeed.fromRows(userId: user.id,
            riderId: data['id'].toString(), queryLocalDay: nowLocal,
            observedAt: DateTime.now(), rows: earningsResponse.data, exactCount: earningsResponse.count);
        }

        ref.read(initialRiderDataProvider.notifier).state = InitialRiderData(
          userId: user.id,
          rider: data,
          earningsSeed: earningsSeed,
        );

        ref.read(appModeProvider.notifier).switchToRider();
        await changeScreen(const RiderMainNavigationScreen(), startTime);
        unawaited(NotificationService().processPendingNotificationQueue());
        _maybeShowUpdateRecommendation(config, installedVersion);
      } else {
        // 1. Start location initialization in the background, don't block main startup wait!
        // R8 perf fix: main.dart already fires initializeLocation() unconditionally at process
        // start, before this awaited profile query even resolves -- if that call already produced
        // a fresh cache by the time we get here, firing this one too just re-runs a full GPS +
        // OLA reverse-geocode + zone-load pass for no reason (the existing isFetching guard only
        // coalesces a call that's still IN FLIGHT, not one that already finished). hasValidCache
        // uses the same 5-minute policy every other caller already trusts as "fresh enough".
        if (!LocationCacheService.hasValidCache) {
          unawaited(LocationCacheService.initializeLocation().catchError((e) => null));
        }

        // 2. Fetch rider, kyc, and orders in parallel, reuse 'profile' as userProfile to save 1 extra query
        final riderFuture = supabase.from('riders').select().eq('user_id', user.id).maybeSingle();
        final kycFuture = supabase.from('rider_kyc').select().eq('user_id', user.id).maybeSingle();
        final ordersFuture = supabase
            .from('orders')
            .select()
            .eq('user_id', user.id)
            .inFilter('order_status', ['created', 'searching', 'expired', 'accepted', 'rider_arrived', 'picked_up', 'ongoing', 'rider_at_drop', 'payment_pending', 'completed', 'delivered', 'cancelled'])
            .order('created_at', ascending: false)
            .limit(10);

        debugPrint('[TRACE_APPSTART] riders/kyc/orders Future.wait START epoch=${DateTime.now().millisecondsSinceEpoch}');
        final results = await Future.wait([
          riderFuture,
          kycFuture,
          ordersFuture,
        ]).timeout(const Duration(seconds: 8));
        debugPrint('[TRACE_APPSTART] riders/kyc/orders Future.wait DONE epoch=${DateTime.now().millisecondsSinceEpoch}');
        debugPrint('[PERF_STARTUP] initial user data batch (riders/kyc/orders) done at +${DateTime.now().difference(startTime).inMilliseconds}ms epoch=${DateTime.now().millisecondsSinceEpoch}');
        
        final riderProfile = results[0] as Map<String, dynamic>?;
        final kycProfile = results[1] as Map<String, dynamic>?;
        final List<Map<String, dynamic>> rawOrders = List<Map<String, dynamic>>.from(results[2] as List);
        
        rawOrders.sort((a, b) {
          final aStatus = a['order_status']?.toString() ?? 'completed';
          final bStatus = b['order_status']?.toString() ?? 'completed';
          final aActive = ['created', 'searching', 'accepted', 'rider_arrived', 'picked_up', 'ongoing', 'rider_at_drop', 'payment_pending'].contains(aStatus);
          final bActive = ['created', 'searching', 'accepted', 'rider_arrived', 'picked_up', 'ongoing', 'rider_at_drop', 'payment_pending'].contains(bStatus);
          
          if (aActive && !bActive) return -1;
          if (!aActive && bActive) return 1;
          
          final aTime = DateTime.tryParse(a['created_at']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bTime = DateTime.tryParse(b['created_at']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bTime.compareTo(aTime);
        });

        final recentOrders = rawOrders.take(4).toList();

        ref.read(initialUserDataProvider.notifier).state = InitialUserData(
          userProfile: profile,
          riderProfile: riderProfile,
          kycProfile: kycProfile,
          recentOrders: recentOrders,
        );

        ref.read(appModeProvider.notifier).switchToUser();
        debugPrint('[PERF_STARTUP] navigating to MainNavigationScreen at +${DateTime.now().difference(startTime).inMilliseconds}ms epoch=${DateTime.now().millisecondsSinceEpoch}');
        await changeScreen(const MainNavigationScreen(), startTime);
        unawaited(NotificationService().processPendingNotificationQueue());
        _maybeShowUpdateRecommendation(config, installedVersion);
      }
    } on TimeoutException catch (e) {
      debugPrint('[TRACE_APPSTART] TimeoutException caught epoch=${DateTime.now().millisecondsSinceEpoch} elapsedMs=${DateTime.now().difference(startTime).inMilliseconds} => $e');
      // A slow/stalled backend response is not the same failure as no
      // internet access -- labelling it "No Internet Connection" (the
      // ConnectionErrorScreen default errorType) is actively misleading when
      // the device's connection is fine and our servers are just slow.
      await changeScreen(ConnectionErrorScreen(
        errorType: ErrorType.backend,
        onRetry: () => checkUserFlow(),
        errorMessage: "Connection timed out. Our servers are taking too long to respond. Please try again.",
      ), startTime);
    } catch (e, st) {
      debugPrint('[TRACE_APPSTART] generic catch epoch=${DateTime.now().millisecondsSinceEpoch} elapsedMs=${DateTime.now().difference(startTime).inMilliseconds} type=${e.runtimeType} => $e');
      debugPrintStack(stackTrace: st);
      debugPrint('APP FLOW ERROR => $e');
      // An expired/invalid session (JWT expired, refresh token revoked, etc.)
      // is not a connection problem and a Retry button will just fail again
      // with the same error -- route straight to Login instead, matching the
      // user==null path above.
      final isAuthError = e is AuthException ||
          e.toString().contains('JWT') ||
          e.toString().contains('refresh_token_not_found') ||
          e.toString().contains('invalid claim');
      if (isAuthError) {
        DeveloperModeService.instance.clear();
        await changeScreen(const LoginScreen(), startTime);
        return;
      }
      // Only classify as "offline" when the exception actually indicates a
      // connectivity failure (DNS/socket-level). Any other exception here
      // (a Postgrest/RLS error, a parsing bug, etc.) must NOT be shown as
      // "No Internet Connection" -- that previously happened unconditionally
      // because ConnectionErrorScreen's errorType defaults to ErrorType.offline
      // and this catch-all never overrode it, so genuine app/backend bugs were
      // misreported to users as their own internet being down.
      final isConnectivityError = e.toString().contains('SocketException') || e.toString().contains('Failed host lookup');
      final errorMsg = isConnectivityError
          ? "Unable to connect to the internet. Please verify your data/WiFi connection."
          : "Something went wrong while loading your account. Please try again.";
      await changeScreen(ConnectionErrorScreen(
        errorType: isConnectivityError ? ErrorType.offline : ErrorType.general,
        onRetry: () => checkUserFlow(),
        errorMessage: errorMsg,
      ), startTime);
    } finally {
      _isChecking = false;
      if (_pendingRecheck) {
        _pendingRecheck = false;
        checkUserFlow();
      }
    }
  }

  /// CASE B (Phase 1 production control): current version >= minimum but < latest -- a
  /// non-blocking recommendation, shown at most once per app session via the app's existing
  /// showAppSnackBar mechanism (same pattern already used a few lines up for the "account
  /// suspended" message). Never shown when [blockedByVersion] already routed to
  /// UpdateRequiredScreen, and never shown during onboarding/login -- only after the user reaches
  /// a real app screen.
  void _maybeShowUpdateRecommendation(ProductionConfigService config, String? installedVersion) {
    if (_updateRecommendationShown) return;
    if (!ProductionConfigService.isVersionLower(installedVersion, config.latestAndroidVersion)) return;
    _updateRecommendationShown = true;
    Future.microtask(() {
      if (mounted) {
        showAppSnackBar(context, config.updateMessage, type: SnackBarType.info);
      }
    });
  }

  Future<void> changeScreen(Widget screen, [DateTime? startTime]) async {
    debugPrint('[TRACE_APPSTART] changeScreen -> ${screen.runtimeType} epoch=${DateTime.now().millisecondsSinceEpoch}');
    final detail = 'changeScreen ${currentScreen.runtimeType} -> ${screen.runtimeType}';
    final overlapping = NavTrace.begin('AppStartScreen', detail);
    if (overlapping) {
      debugPrint('[NAV_TRACE] *** AppStartScreen.changeScreen($detail) started while another traced navigation was already in flight ***');
    }
    // Captured BEFORE the swap below: LoginScreen is the only AppStartScreen-managed
    // screen that ever has a route pushed on top of it (OtpScreen, via Navigator.push
    // from login_screen.dart). OtpScreen deliberately never navigates itself on
    // success -- it relies entirely on this listener-driven swap -- so once
    // AppStartScreen decides to move away from LoginScreen, that pushed OtpScreen
    // route is orphaned: nothing else ever pops it, leaving the user stuck looking
    // at it while currentScreen changes invisibly underneath. Scoped to exactly this
    // one transition so it can never interrupt in-app navigation elsewhere (e.g. a
    // redundant MainNavigationScreen -> MainNavigationScreen re-run from a routine
    // auth token refresh must never pop screens the user has pushed while using the
    // app).
    final wasLoginScreen = currentScreen is LoginScreen;
    try {
      if (startTime != null) {
        final elapsed = DateTime.now().difference(startTime);
        // Brand-beat floor: brief minimum splash on fast starts so the logo
        // entrance reads; slow starts already exceed it and are never padded.
        if (elapsed.inMilliseconds < 500) {
          await Future.delayed(Duration(milliseconds: 500 - elapsed.inMilliseconds));
        }
      }
      if (!mounted) {
        NavTrace.mark('AppStartScreen', 'changeScreen($detail) ABORTED -- not mounted');
        return;
      }
      setState(() => currentScreen = screen);
      if (wasLoginScreen) {
        navigatorKey.currentState?.popUntil((route) => route.isFirst);
      }
    } finally {
      NavTrace.end('AppStartScreen', detail);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: currentScreen,
    );
  }
}

class _BrandSplashView extends StatelessWidget {
  final ValueNotifier<String> statusNotifier;

  const _BrandSplashView({required this.statusNotifier});

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.of(context).disableAnimations;
    
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.2,
            colors: [
              Colors.white,
              Color(0xFFF6FBF8),
            ],
          ),
        ),
        child: Stack(
          children: [
            // Background dotted route motif
            if (!disableAnimations) const RouteMotifWidget(),
            
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Floating and Animating Logo
                  disableAnimations
                      ? Image.asset(
                          'assets/images/waydrop_logo_transparent.png',
                          height: 140,
                          fit: BoxFit.contain,
                        )
                      : Animate(
                          onPlay: (controller) => controller.repeat(reverse: true),
                          effects: const [
                            MoveEffect(
                              begin: Offset(0, -4),
                              end: Offset(0, 4),
                              duration: Duration(milliseconds: 1500),
                              curve: Curves.easeInOutCubic,
                            ),
                          ],
                          child: Image.asset(
                            'assets/images/waydrop_logo_transparent.png',
                            height: 140,
                            fit: BoxFit.contain,
                          )
                          .animate()
                          .fadeIn(duration: 300.ms)
                          .scale(
                            begin: const Offset(0.92, 0.92),
                            end: const Offset(1.0, 1.0),
                            delay: 300.ms,
                            duration: 400.ms,
                            curve: Curves.easeOutCubic,
                          ),
                        ),
                  const SizedBox(height: 16),
                  
                  // WayDrop Rich Brand Text
                  RichText(
                    text: const TextSpan(
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -1.0,
                      ),
                      children: [
                        TextSpan(
                          text: 'Way',
                          style: TextStyle(
                            color: WayDropColors.primaryEmerald,
                          ),
                        ),
                        TextSpan(
                          text: 'Drop',
                          style: TextStyle(
                            color: WayDropColors.goldAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 48),
                  
                  // Spinner & Dynamic text
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      color: WayDropColors.primaryEmerald,
                      strokeWidth: 3,
                    ),
                  ),
                  const SizedBox(height: 20),
                  
                  ValueListenableBuilder<String>(
                    valueListenable: statusNotifier,
                    builder: (context, statusText, _) {
                      return Text(
                        statusText,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: WayDropColors.secondaryText,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RouteMotifWidget extends StatefulWidget {
  const RouteMotifWidget({super.key});

  @override
  State<RouteMotifWidget> createState() => _RouteMotifWidgetState();
}

class _RouteMotifWidgetState extends State<RouteMotifWidget> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: RouteMotifPainter(_controller.value),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

class RouteMotifPainter extends CustomPainter {
  final double progress;
  RouteMotifPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = WayDropColors.primaryEmerald.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final path = Path();
    path.moveTo(size.width * 0.15, size.height * 0.65);
    path.cubicTo(
      size.width * 0.35,
      size.height * 0.35,
      size.width * 0.65,
      size.height * 0.75,
      size.width * 0.85,
      size.height * 0.45,
    );

    final pathMetrics = path.computeMetrics();
    for (final metric in pathMetrics) {
      double distance = 0.0;
      const double dashLength = 6.0;
      const double gapLength = 6.0;
      while (distance < metric.length) {
        final extractPath = metric.extractPath(distance, distance + dashLength);
        canvas.drawPath(extractPath, paint);
        distance += dashLength + gapLength;
      }

      if (progress > 0.0) {
        final tangent = metric.getTangentForOffset(metric.length * progress);
        if (tangent != null) {
          final pos = tangent.position;
          
          final dotPaint = Paint()..color = WayDropColors.goldAccent;
          canvas.drawCircle(pos, 5.0, dotPaint);

          final glowPaint = Paint()..color = WayDropColors.goldAccent.withValues(alpha: 0.35);
          canvas.drawCircle(pos, 10.0, glowPaint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant RouteMotifPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
