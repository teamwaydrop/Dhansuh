import 'dart:async';
import 'package:waydrop/core/services/session/auth_routing_policy.dart';
import 'package:waydrop/core/services/session/rider_access_service.dart';
import 'package:waydrop/core/providers/initial_data_provider.dart';
import 'package:waydrop/features/auth/screens/login_screen.dart';
import 'package:waydrop/shared/screens/connection_error_screen.dart';
import 'package:waydrop/shared/helpers/global_error_controller.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:waydrop/core/providers/app_mode_provider.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_kyc_screen.dart';
import 'package:waydrop/shared/widgets/mode_switch_overlay.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_kyc_pending_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_payout_details_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/service_mode_selection_screen.dart';
import 'package:waydrop/features/rider/services/rider_status_service.dart';
import 'package:waydrop/features/rider/navigation/rider_main_navigation_screen.dart';

class RiderEntryHandler extends ConsumerStatefulWidget {
  final Widget? readyScreen;
  const RiderEntryHandler({super.key, this.readyScreen});

  @override
  ConsumerState<RiderEntryHandler> createState() => _RiderEntryHandlerState();
}

class _RiderEntryHandlerState extends ConsumerState<RiderEntryHandler> {
  bool loading = true;
  RiderAccess? access;
  Object? error;
  StreamSubscription<AuthState>? _authSubscription;
  int _generation = 0;
  late final AuthRoutingPolicy _authRoutingPolicy;

  @override
  void initState() {
    super.initState();
    _authRoutingPolicy = AuthRoutingPolicy(Supabase.instance.client.auth.currentUser?.id);
    _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((event) {
      if (_authRoutingPolicy.shouldRecheck(event)) load();
    }, onError: (Object failure, StackTrace stack) {
      if (mounted && Supabase.instance.client.auth.currentSession == null) load();
    });
    load();
  }

  Future<void> load() async {
    final generation = ++_generation;
    if (mounted) setState(() { loading = true; error = null; });
    try {
      final result = await RiderAccessService.instance.resolve();
      if (!mounted || generation != _generation) return;
      access = result;
      if (result.state == RiderAccessState.ready) {
        final rider = result.rider!;
        final kyc = rider['rider_kyc!riders_kyc_id_fkey'] ?? rider['rider_kyc'];
        if (kyc is Map) {
          rider['full_name'] = kyc['full_name'];
          rider['rider_image'] = kyc['rider_image'];
        }
        ref.read(initialRiderDataProvider.notifier).state = InitialRiderData(
          rider: rider, todayEarnings: null);
      }
    } catch (failure) {
      if (!mounted || generation != _generation) return;
      if (RiderAccessService.requiresLogin(failure)) {
        access = const RiderAccess(RiderAccessState.unauthenticated);
      } else {
        error = failure;
      }
    } finally {
      if (mounted && generation == _generation) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    ++_generation;
    unawaited(_authSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B0F19),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                color: Color(0xFFC5FF30),
                strokeWidth: 2,
              ),
              SizedBox(height: 16),
              Text('Checking partner access…', style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      );
    }

    if (error != null) {
      return ConnectionErrorScreen(errorType: ErrorType.backend,
        errorMessage: 'Unable to check your partner account. Please try again.', onRetry: load);
    }
    switch (access?.state) {
      case RiderAccessState.unauthenticated:
        return const LoginScreen();
      case RiderAccessState.none:
        return const RiderKycScreen();
      case RiderAccessState.pending:
        return const RiderKycPendingScreen();
      case RiderAccessState.blocked:
        return KycBlockedScreen(kyc: access!.kyc!);
      case RiderAccessState.rejected:
        return KycRejectedScreen(kyc: access!.kyc!);
      case RiderAccessState.approvedWaiting:
        return const KycVerifiedWaitingScreen();
      case RiderAccessState.payoutRequired:
        return const RiderPayoutDetailsScreen();
      case RiderAccessState.serviceModeRequired:
        return const ServiceModeSelectionScreen();
      case RiderAccessState.ready:
        return widget.readyScreen ?? const WelcomeRiderScreen();
      case null:
        return ConnectionErrorScreen(errorType: ErrorType.general, onRetry: load);
    }
  }
}

// =============================================
// REJECTED SCREEN
// =============================================

class KycRejectedScreen extends StatelessWidget {
  final Map<String, dynamic> kyc;

  const KycRejectedScreen({
    super.key,
    required this.kyc,
  });

  @override
  Widget build(BuildContext context) {
    final reason = kyc['rejection_reason'] ?? 'Documents could not be verified';

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFB),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 60),

              // Icon
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.3), width: 1.5),
                ),
                child: const Icon(
                  Icons.close_rounded,
                  size: 48,
                  color: Color(0xFFEF4444),
                ),
              ),
              const SizedBox(height: 28),

              const Text(
                'KYC Rejected',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF0F172A),
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Unfortunately, your verification was rejected. Please review the details below.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF64748B),
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 32),

              // Rejection Details Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Rejection Reason',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      reason,
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(),

              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const RiderKycScreen(),
                      ),
                    );
                  },
                  child: const Text(
                    'Submit Fresh Request',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================
// VERIFIED WAITING SCREEN
// =============================================

class KycVerifiedWaitingScreen extends StatelessWidget {
  const KycVerifiedWaitingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFB),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: const Color(0xFFF0FDF4),
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3), width: 1.5),
                ),
                child: const Center(
                  child: Icon(
                    Icons.verified_rounded,
                    size: 48,
                    color: Color(0xFF10B981),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'KYC Verified',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF0F172A),
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Your identity has been successfully verified. Please wait while your rider profile is being activated.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF64748B),
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 36),
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  color: Color(0xFF10B981),
                  strokeWidth: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================
// WELCOME RIDER SCREEN
// =============================================

class WelcomeRiderScreen extends ConsumerWidget {
  const WelcomeRiderScreen({super.key});

  Future<void> switchMode(BuildContext context, WidgetRef ref) async {
    try {
      await RiderStatusService.switchToRiderMode();
      ref.read(appModeProvider.notifier).switchToRider();
      if (context.mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const RiderMainNavigationScreen()),
          (_) => false,
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFB),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const Spacer(),
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: const Color(0xFFF0FDF4),
                  borderRadius: BorderRadius.circular(36),
                  border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3), width: 1.5),
                ),
                child: const Center(
                  child: Text(
                    '🎉',
                    style: TextStyle(
                      fontSize: 48,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'You’re Now a Drop Partner',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF0F172A),
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Your rider profile is now active. Start earning with rides and parcel deliveries.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF64748B),
                  height: 1.55,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () {
                    ref.read(modeSwitchOverlayProvider.notifier).trigger(
                      asyncAction: () async {
                        await RiderStatusService.switchToRiderMode();
                        ref.read(appModeProvider.notifier).switchToRider();
                      },
                      onMidpoint: () {
                        Navigator.pushAndRemoveUntil(
                          context,
                          PageRouteBuilder(
                            pageBuilder: (context, animation, secondaryAnimation) => const RiderMainNavigationScreen(),
                            transitionDuration: Duration.zero,
                            reverseTransitionDuration: Duration.zero,
                          ),
                          (_) => false,
                        );
                      },
                      onError: (err) {
                        final errorMsg = err.toString();
                        if (errorMsg.contains('Payout details not registered')) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const RiderPayoutDetailsScreen()),
                          );
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(errorMsg.replaceFirst('Exception: ', '')),
                              backgroundColor: const Color(0xFFEF4444),
                            ),
                          );
                        }
                      },
                    );
                  },
                  child: const Text(
                    'Enter Drop Partner Mode',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================
// BLOCKED/COOLDOWN SCREEN
// =============================================

class KycBlockedScreen extends StatefulWidget {
  final Map<String, dynamic> kyc;

  const KycBlockedScreen({
    super.key,
    required this.kyc,
  });

  @override
  State<KycBlockedScreen> createState() => _KycBlockedScreenState();
}

class _KycBlockedScreenState extends State<KycBlockedScreen> {
  late DateTime blockedUntil;
  Timer? _timer;
  Duration _timeLeft = Duration.zero;

  @override
  void initState() {
    super.initState();
    final blockedUntilStr = widget.kyc['blocked_until'] ?? '';
    blockedUntil = DateTime.tryParse(blockedUntilStr) ?? DateTime.now();
    _updateTimeLeft();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateTimeLeft();
    });
  }

  void _updateTimeLeft() {
    if (!mounted) return;
    final now = DateTime.now();
    setState(() {
      _timeLeft = blockedUntil.isAfter(now) ? blockedUntil.difference(now) : Duration.zero;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final days = d.inDays;
    final hours = d.inHours.remainder(24);
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);

    final parts = <String>[];
    if (days > 0) parts.add('${days}d');
    if (hours > 0 || days > 0) parts.add('${hours}h');
    if (minutes > 0 || hours > 0 || days > 0) parts.add('${minutes}m');
    parts.add('${seconds}s');

    return parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final reason = widget.kyc['rejection_reason'] ?? 'Too many invalid submissions. Cool down active.';

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFB),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              // Warning Icon
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(color: const Color(0xFFD97706).withValues(alpha: 0.3), width: 1.5),
                ),
                child: const Icon(
                  Icons.hourglass_empty_rounded,
                  size: 48,
                  color: Color(0xFFD97706),
                ),
              ),
              const SizedBox(height: 28),

              const Text(
                'Submission Blocked',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF0F172A),
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Your account submission has been temporarily locked due to multiple verification rejections.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF64748B),
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 32),

              // Countdown Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFFFBEB), Color(0xFFFEF3C7)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFFFDE68A)),
                ),
                child: Column(
                  children: [
                    const Text(
                      'RESUBMISSION LOCK ACTIVE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFFB45309),
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _timeLeft == Duration.zero ? 'Lock Expired' : _formatDuration(_timeLeft),
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                        color: const Color(0xFF78350F),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Reason Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Last Rejection Reason',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      reason,
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(),
              // Check status button
              SizedBox(
                width: double.infinity,
                height: 54,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: _timeLeft == Duration.zero ? const Color(0xFF0F172A) : const Color(0xFFCBD5E1),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: _timeLeft == Duration.zero ? () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const RiderEntryHandler(),
                      ),
                    );
                  } : null,
                  child: Text(
                    _timeLeft == Duration.zero ? 'Check Unlock Status' : 'Locked',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: _timeLeft == Duration.zero ? const Color(0xFF0F172A) : const Color(0xFF94A3B8),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
            ],
          ),
        ),
      ),
    );
  }
}
