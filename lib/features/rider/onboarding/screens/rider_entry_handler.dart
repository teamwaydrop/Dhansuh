import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/session/identity_operation_scope.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:waydrop/core/providers/app_mode_provider.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_kyc_screen.dart';
import 'package:waydrop/shared/widgets/mode_switch_overlay.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_kyc_pending_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_payout_details_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/service_mode_selection_screen.dart';
import 'package:waydrop/features/rider/services/rider_status_service.dart';
import 'package:waydrop/features/rider/navigation/rider_main_navigation_screen.dart';

class RiderEntryHandler extends StatefulWidget {
  const RiderEntryHandler({
    super.key,
  });

  @override
  State<RiderEntryHandler> createState() => _RiderEntryHandlerState();
}

class _RiderEntryHandlerState extends State<RiderEntryHandler> {
  bool loading = true;
  String state = 'none';
  Map<String, dynamic>? kyc;
  bool riderExists = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final supabase = Supabase.instance.client;
      final user = supabase.auth.currentUser;

      if (user == null) {
        return;
      }

      // Egress fix: narrowed to the fields read off kycResponse/kyc in this file (here and in
      // KycRejectedScreen/KycBlockedScreen, both of which receive this exact map wholesale).
      final kycResponse = await supabase
          .from('rider_kyc')
          .select('blocked_until, kyc_status, rejection_reason')
          .eq('user_id', user.id)
          .maybeSingle();

      if (kycResponse == null) {
        state = 'none';
      } else {
        kyc = kycResponse;

        // Egress fix: only existence + service_mode are read below.
        final riderResponse = await supabase
            .from('riders')
            .select('service_mode')
            .eq('user_id', user.id)
            .maybeSingle();

        riderExists = riderResponse != null;

        final String? blockedUntilStr = kycResponse['blocked_until'];
        if (blockedUntilStr != null) {
          final blockedUntil = DateTime.tryParse(blockedUntilStr);
          if (blockedUntil != null && blockedUntil.isAfter(DateTime.now())) {
            state = 'blocked';
          }
        }

        if (state != 'blocked') {
          final String kycStatus = kycResponse['kyc_status'] ?? 'pending';
          if (kycStatus == 'pending' || kycStatus == 'under_review' || kycStatus == 'resubmitted') {
            state = 'pending';
          } else if (kycStatus == 'rejected') {
            state = 'rejected';
          } else if (kycStatus == 'approved' && !riderExists) {
            state = 'approved_waiting';
          } else if (riderExists) {
            // Egress fix: only existence is checked below.
            final payoutResponse = await supabase
                .from('rider_payout_accounts')
                .select('id')
                .eq('user_id', user.id)
                .eq('cashfree_beneficiary_status', 'active')
                .maybeSingle();

            if (payoutResponse == null) {
              state = 'payout_details_required';
            } else if (riderResponse!['service_mode'] == null) {
              state = 'service_mode_required';
            } else {
              state = 'rider_ready';
            }
          }
        }
      }
    } catch (e) {
      debugPrint('RIDER RATING ENTRANCE ERROR => $e');
    }

    if (mounted) {
      setState(() {
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: CircularProgressIndicator(
            color: Color(0xFF10B981),
            strokeWidth: 2,
          ),
        ),
      );
    }

    if (state == 'none') {
      return const RiderKycScreen();
    }

    if (state == 'pending') {
      return const RiderKycPendingScreen();
    }

    if (state == 'blocked') {
      return KycBlockedScreen(
        kyc: kyc!,
      );
    }

    if (state == 'rejected') {
      return KycRejectedScreen(
        kyc: kyc!,
      );
    }

    if (state == 'approved_waiting') {
      return const KycVerifiedWaitingScreen();
    }

    if (state == 'payout_details_required') {
      return const RiderPayoutDetailsScreen();
    }

    if (state == 'service_mode_required') {
      return const ServiceModeSelectionScreen();
    }

    return const WelcomeRiderScreen();
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

class WelcomeRiderScreen extends ConsumerStatefulWidget {
  const WelcomeRiderScreen({super.key});
  @override
  ConsumerState<WelcomeRiderScreen> createState() => _WelcomeRiderScreenState();
}

class _WelcomeRiderScreenState extends ConsumerState<WelcomeRiderScreen> {
  late final _modeOperations = IdentityOperationScope.forWidget(() => mounted);
  @override
  void dispose() { _modeOperations.dispose(); super.dispose(); }

  Future<void> switchMode(BuildContext context, WidgetRef ref) async {
    final operation = _modeOperations.begin();
    try {
      operation.requireCurrent();
      await RiderStatusService.switchToRiderMode();
      operation.requireCurrent();
      ref.read(appModeProvider.notifier).switchToRider();
      if (context.mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const RiderMainNavigationScreen()),
          (_) => false,
        );
      }
    } catch (e) {
      if (operation.isCurrent) {
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
  Widget build(BuildContext context) {
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
                    final operation = _modeOperations.begin();
                    ref.read(modeSwitchOverlayProvider.notifier).trigger(
                      asyncAction: () async {
                        operation.requireCurrent();
                        await RiderStatusService.switchToRiderMode();
                        operation.requireCurrent();
                        ref.read(appModeProvider.notifier).switchToRider();
                      },
                      onMidpoint: () {
                        if (!operation.isCurrent) return;
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
                        if (!operation.isCurrent) return;
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
