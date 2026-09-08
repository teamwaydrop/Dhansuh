import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pinput/pinput.dart';
import 'package:smart_auth/smart_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:waydrop/shared/helpers/app_keyboard_wrapper.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';
import 'package:waydrop/shared/helpers/auth_session.dart';
import 'package:waydrop/core/services/database/supabase_service.dart';
import 'package:waydrop/modules/notifications/services/notification_service.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';

class OtpScreen extends StatefulWidget {
  final String phone;

  const OtpScreen({super.key, required this.phone});

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final TextEditingController otpController = TextEditingController();
  final SupabaseService authService = SupabaseService();
  bool loading = false;
  int resendSeconds = 30;
  Timer? timer;
  int pinputSessionKey = 0;

  SmartAuthSmsRetriever get smsRetriever =>
      SmartAuthSmsRetriever(SmartAuth.instance);

  @override
  void initState() {
    super.initState();
    calculateCooldown();
  }

  void calculateCooldown() {
    final attempts = AuthSession.resendAttempts;
    if (attempts > 4) {
      AuthSession.blockedUntil = DateTime.now().add(
        const Duration(minutes: 30),
      );
    }
    resendSeconds = AuthSession.remainingCooldownSeconds;
    startTimer();
  }

  void startTimer() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (resendSeconds == 0) {
        t.cancel();
      } else {
        setState(() => resendSeconds--);
      }
    });
  }

  String get maskedPhone {
    final phone = widget.phone.replaceAll('+91', '').trim();
    if (phone.length >= 8) {
      return '${phone.substring(0, 5)}***${phone.substring(phone.length - 3)}';
    }
    return phone;
  }

  Future<void> resendOtp() async {
    if (loading) return;
    if (AuthSession.isBlocked) {
      final remaining = AuthSession.remainingBlock;
      showAppSnackBar(
        context,
        'Too many attempts. Try again in ${remaining!.inMinutes} mins.',
        type: SnackBarType.error,
      );
      return;
    }
    if (resendSeconds > 0) {
      showAppSnackBar(
        context,
        'Please wait before requesting another OTP.',
        type: SnackBarType.error,
      );
      return;
    }
    setState(() => loading = true);
    try {
      AuthSession.resendAttempts++;
      await authService.sendOtp(widget.phone);
      AuthSession.lastOtpTime = DateTime.now();
      calculateCooldown();
      otpController.clear();
      if (!mounted) return;
      setState(() {
        pinputSessionKey++;
      });
      showAppSnackBar(
        context,
        'OTP resent successfully',
        type: SnackBarType.success,
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, e.toString(), type: SnackBarType.error);
    }
    setState(() => loading = false);
  }

  Future<void> verifyOtp() async {
    if (loading) return;
    final otp = otpController.text.trim();
    if (otp.length != 6) {
      showAppSnackBar(
        context,
        'Enter valid 6 digit OTP',
        type: SnackBarType.error,
      );
      return;
    }
    // Must match login_screen.dart's exact-match bypass check — no
    // contains()/endsWith() substring matching, or any 10-digit number with
    // 8 consecutive 9s becomes a public auth bypass.
    final isBypass = widget.phone == '+91$kReviewerBypassPhone' && otp == '123456';
    FocusScope.of(context).unfocus();
    setState(() => loading = true);
    try {
      if (isBypass) {
        // Bypass verifyOtp completely and sign in anonymously for a valid user session
        await Supabase.instance.client.auth.signInAnonymously();
        
        // Mock default location to Warangal
        await LocationCacheService.saveMockLocationToPrefs(
          lat: 17.9689,
          lng: 79.5941,
          address: 'Warangal, Telangana, India',
        );
      } else {
        final Stopwatch perfVerifyOtp = Stopwatch()..start();
        await authService.verifyOtp(phone: widget.phone, token: otp);
        debugPrint('[PERF_AUTH] verifyOtp took ${perfVerifyOtp.elapsedMilliseconds}ms epoch=${DateTime.now().millisecondsSinceEpoch}');
      }
      AuthSession.clear();

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        throw Exception(
          "Authentication succeeded but session could not be established.",
        );
      }

      // Sync FCM Token
      try {
        await NotificationService().syncToken();
      } catch (_) {}

      // Auto-complete profile in users table for Cashfree bypass logins
      if (isBypass) {
        await Supabase.instance.client.from('users').upsert({
          'id': user.id,
          'full_name': 'Cashfree Tester',
          'profile_completed': true,
          'onboarding_completed': true,
        });
      }

      if (!mounted) return;

      // Navigation is intentionally NOT performed here. This successful
      // verification triggers a SIGNED_IN event on
      // supabase.auth.onAuthStateChange, and AppStartScreen's listener is the
      // sole source of truth for post-login routing (profile/onboarding
      // completion, rider vs user mode, suspension) — see
      // app_start_screen.dart's checkUserFlow()/changeScreen(). Navigating
      // from here too raced with that listener and caused a black screen.
    } catch (e, st) {
      debugPrint('OTP VERIFICATION ERROR => $e');
      debugPrintStack(stackTrace: st);

      // BUG FIX (delete-account -> relogin "OTP Expired" false negative): verifyOTP() can throw
      // (e.g. a slow network response after account deletion's several server round trips) even
      // when the underlying request actually succeeded and Supabase's client already persisted a
      // real session from the response -- the exception alone does not prove verification failed.
      // Ground truth is whether a session now exists, not the shape of the exception message.
      // When it does, this is not a failure at all: skip the error entirely and let the existing,
      // already-correct onAuthStateChange -> AppStartScreen.checkUserFlow() path (see the comment
      // on the success path above) route to Home from a CONFIRMED session -- never navigate here
      // directly. This never bypasses OTP verification itself (verifyOTP() above is unchanged and
      // still the only way a session is created); it only stops a real, established session from
      // being reported to the user as a login failure.
      if (Supabase.instance.client.auth.currentSession != null) {
        debugPrint('OTP VERIFICATION: exception was thrown but a session already exists -- treating as success.');
        AuthSession.clear();
        try {
          await NotificationService().syncToken();
        } catch (_) {}
        if (mounted) setState(() => loading = false);
        return;
      }

      otpController.clear();
      if (!mounted) return;

      final errStr = e.toString().toLowerCase();
      String userFriendlyMessage = 'Invalid or expired OTP';
      if (errStr.contains('expired') || errStr.contains('timeout')) {
        userFriendlyMessage = 'OTP expired. Please request a new code.';
      } else if (errStr.contains('invalid') ||
          errStr.contains('incorrect') ||
          errStr.contains('bad') ||
          errStr.contains('credential')) {
        userFriendlyMessage = 'Invalid OTP code. Please try again.';
      } else {
        userFriendlyMessage = 'OTP expired or invalid. Please try again.';
      }

      showAppSnackBar(context, userFriendlyMessage, type: SnackBarType.error);
    }
    setState(() => loading = false);
  }

  @override
  void dispose() {
    timer?.cancel();
    otpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

    // Premium theme pin styling matching mockup
    final defaultPin = PinTheme(
      width: 52,
      height: 58,
      textStyle: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w900,
        color: Color(0xFF1B7A44),
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.015),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
    );

    final focusedPin = defaultPin.copyWith(
      decoration: defaultPin.decoration!.copyWith(
        border: Border.all(color: const Color(0xFF1B7A44), width: 2.0),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1B7A44).withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
    );

    final submittedPin = defaultPin.copyWith(
      decoration: defaultPin.decoration!.copyWith(
        color: const Color(0xFFF0FDF4),
        border: Border.all(color: const Color(0xFF1B7A44), width: 1.5),
      ),
    );

    final errorPinTheme = defaultPin.copyWith(
      decoration: defaultPin.decoration!.copyWith(
        color: const Color(0xFFFEF2F2),
        border: Border.all(color: const Color(0xFFEF4444), width: 1.5),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Color(0xFF090D1A),
            size: 20,
          ),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: AppKeyboardWrapper(
          padding: EdgeInsets.symmetric(
            horizontal: 24,
            vertical: keyboardVisible ? 6 : 12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Centered Brand Title instead of logo
              if (!keyboardVisible) ...[
                const SizedBox(height: 24),
                Center(
                  child: RichText(
                    text: const TextSpan(
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.8,
                      ),
                      children: [
                        TextSpan(
                          text: 'Way',
                          style: TextStyle(
                            color: Color(0xFF1B7A44),
                          ), // Emerald Green
                        ),
                        TextSpan(
                          text: 'Drop',
                          style: TextStyle(
                            color: Color(0xFFD4AF37),
                          ), // Shiny Gold
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              SizedBox(height: keyboardVisible ? 16 : 36),

              // Mockup title: We Sent You a Code
              const Text(
                'We Sent You a Code',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF090D1A),
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),

              // Mockup inline text with phone number and pencil edit icon
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 14.5,
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w500,
                    height: 1.45,
                  ),
                  children: [
                    const TextSpan(
                      text:
                          "Enter the 6-digit code, we've sent to your phone number ",
                    ),
                    TextSpan(
                      text: maskedPhone,
                      style: const TextStyle(
                        color: Color(0xFF1B7A44),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Icon(
                            Icons.edit_rounded,
                            color: Color(0xFF1B7A44),
                            size: 14,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              SizedBox(height: keyboardVisible ? 20 : 36),
              const Text(
                'Enter OTP',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF090D1A),
                ),
              ),
              const SizedBox(height: 12),

              // Mockup Pinput box styling
              Center(
                child: Pinput(
                  key: ValueKey(pinputSessionKey),
                  controller: otpController,
                  length: 6,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  smsRetriever: smsRetriever,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  defaultPinTheme: defaultPin,
                  focusedPinTheme: focusedPin,
                  submittedPinTheme: submittedPin,
                  errorPinTheme: errorPinTheme,
                  preFilledWidget: Text(
                    '•',
                    style: TextStyle(color: Colors.grey.shade300, fontSize: 24),
                  ),
                  cursor: Container(
                    width: 2,
                    height: 24,
                    color: const Color(0xFF1B7A44),
                  ),
                  onCompleted: (_) => verifyOtp(),
                ),
              ),

              SizedBox(height: keyboardVisible ? 16 : 28),

              // Verification code validity banner
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F7F0).withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.verified_outlined,
                      color: Color(0xFF1B7A44),
                      size: 16,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Your code is valid for ',
                      style: TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      '10 minutes',
                      style: TextStyle(
                        color: Color(0xFF1B7A44),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),

              SizedBox(height: keyboardVisible ? 16 : 28),

              // Verify button (mockup styling)
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: loading ? null : verifyOtp,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1B7A44),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(0xFFE2E8F0),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: loading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.5,
                          ),
                        )
                      : const Text(
                          'Verify',
                          style: TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                ),
              ),

              SizedBox(height: keyboardVisible ? 16 : 32),

              // Premium Resend Button
              Center(
                child: TextButton(
                  onPressed: resendSeconds > 0 || loading ? null : resendOtp,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    foregroundColor: const Color(0xFF1B7A44),
                    disabledForegroundColor: Colors.grey.shade400,
                  ),
                  child: Text(
                    resendSeconds > 0
                        ? 'Resend code in ${resendSeconds}s'
                        : 'Resend Code',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                      decoration: resendSeconds > 0
                          ? TextDecoration.none
                          : TextDecoration.underline,
                    ),
                  ),
                ),
              ),
              SizedBox(height: keyboardVisible ? 12 : 24),
            ],
          ),
        ),
      ),
    );
  }
}

class SmartAuthSmsRetriever implements SmsRetriever {
  const SmartAuthSmsRetriever(this.smartAuth);

  final SmartAuth smartAuth;

  @override
  Future<void> dispose() {
    return smartAuth.removeUserConsentApiListener();
  }

  @override
  Future<String?> getSmsCode() async {
    final res = await smartAuth.getSmsWithUserConsentApi();
    if (res.hasData && res.data?.code != null) {
      return res.data!.code;
    }
    return null;
  }

  @override
  bool get listenForMultipleSms => true;
}
