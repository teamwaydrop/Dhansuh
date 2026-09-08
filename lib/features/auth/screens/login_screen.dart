import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:waydrop/shared/helpers/app_keyboard_wrapper.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';
import 'package:waydrop/shared/helpers/auth_session.dart';
import 'package:waydrop/features/auth/screens/otp_screen.dart';
import 'package:waydrop/core/services/database/supabase_service.dart';
import 'package:waydrop/modules/support/screens/customer_support_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController phoneController = TextEditingController();
  final SupabaseService authService = SupabaseService();
  final FocusNode phoneFocusNode = FocusNode();
  bool loading = false;
  bool termsAccepted = true;
  bool _isPhoneFocused = false;
  bool _navigatingToOtp = false;
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    phoneController.addListener(_onPhoneChanged);
    phoneFocusNode.addListener(_onPhoneFocusChange);
    _startUpdateTimer();
  }

  void _onPhoneFocusChange() {
    setState(() {
      _isPhoneFocused = phoneFocusNode.hasFocus;
    });
  }

  void _onPhoneChanged() {
    final phone = phoneController.text.trim();
    if (phone.length == 10) {
      FocusScope.of(context).unfocus();
    }
    setState(() {});
  }

  void _startUpdateTimer() {
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final phone = phoneController.text.trim();
      final formattedPhone = '+91$phone';
      if (AuthSession.activePhone == formattedPhone) {
        setState(() {});
      }
    });
  }

  bool get _isButtonDisabled {
    final phone = phoneController.text.trim();
    if (phone.length != 10) return true;
    final formattedPhone = '+91$phone';
    if (AuthSession.activePhone == formattedPhone) {
      if (AuthSession.isBlocked) return true;
      if (AuthSession.remainingCooldownSeconds > 0) return true;
    }
    return false;
  }

  String get _buttonText {
    final phone = phoneController.text.trim();
    final formattedPhone = '+91$phone';
    if (AuthSession.activePhone == formattedPhone) {
      if (AuthSession.isBlocked) {
        final remaining = AuthSession.remainingBlock;
        if (remaining != null && remaining.inSeconds > 0) {
          final minutes = remaining.inMinutes;
          final seconds = remaining.inSeconds % 60;
          return 'Blocked for ${minutes}m ${seconds}s';
        }
        return 'Blocked';
      }
      final remainingCooldown = AuthSession.remainingCooldownSeconds;
      if (remainingCooldown > 0) {
        return 'Resend in ${remainingCooldown}s';
      }
      return 'Resend OTP';
    }
    return 'Send OTP';
  }

  Future<void> sendOtp() async {
    if (loading) return;
    if (!termsAccepted) {
      showAppSnackBar(
        context,
        'Please accept the Terms & Privacy Policy to continue',
        type: SnackBarType.error,
      );
      return;
    }

    final phone = phoneController.text.trim();
    // Reserved test-only login (Cashfree/Play Store review + internal dummy
    // payment testing). Must be an EXACT match — do not broaden this to
    // startsWith/contains, as that turns it into a public auth bypass.
    final isBypass = phone == kReviewerBypassPhone;

    if (!isBypass && !RegExp(r'^[0-9]{10}$').hasMatch(phone)) {
      showAppSnackBar(
        context,
        'Enter valid 10 digit mobile number',
        type: SnackBarType.error,
      );
      return;
    }

    final formattedPhone = '+91$phone';

    if (AuthSession.isBlocked) {
      final remaining = AuthSession.remainingBlock;
      showAppSnackBar(
        context,
        'Too many attempts. Try again in ${remaining!.inMinutes} mins.',
        type: SnackBarType.error,
      );
      return;
    }

    final isSamePhone = AuthSession.activePhone == formattedPhone;
    final remainingCooldown = AuthSession.remainingCooldownSeconds;

    if (isSamePhone && remainingCooldown > 0) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => OtpScreen(phone: formattedPhone)),
      );
      return;
    }

    setState(() => loading = true);

    try {
      if (isBypass) {
        AuthSession.clear();
        AuthSession.activePhone = formattedPhone;
        AuthSession.lastOtpTime = DateTime.now();
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => OtpScreen(phone: formattedPhone)),
        );
      } else {
        if (isSamePhone) {
          AuthSession.resendAttempts++;
        } else {
          AuthSession.clear();
          AuthSession.activePhone = formattedPhone;
        }

        final Stopwatch perfSendOtp = Stopwatch()..start();
        await authService.sendOtp(formattedPhone);
        debugPrint('[PERF_AUTH] sendOtp took ${perfSendOtp.elapsedMilliseconds}ms epoch=${DateTime.now().millisecondsSinceEpoch}');
        AuthSession.lastOtpTime = DateTime.now();
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => OtpScreen(phone: formattedPhone)),
        );
      }
    } catch (e) {
      showAppSnackBar(context, e.toString(), type: SnackBarType.error);
    }

    setState(() => loading = false);
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    phoneController.removeListener(_onPhoneChanged);
    phoneFocusNode.removeListener(_onPhoneFocusChange);
    phoneController.dispose();
    phoneFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phone = phoneController.text.trim();
    final isSamePhone =
        phone.length == 10 && AuthSession.activePhone == '+91$phone';
    final screenHeight = MediaQuery.of(context).size.height;
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

    // When keyboard is visible, collapse logo to avoid overlays
    final logoHeight = keyboardVisible
        ? 50.0
        : (screenHeight * 0.28).clamp(140.0, 240.0);

    return Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: AppKeyboardWrapper(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),

              // Animated Logo container
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                height: logoHeight,
                alignment: Alignment.center,
                child: logoHeight > 40
                    ? Image.asset(
                        'assets/images/waydrop_logo_transparent.png',
                        fit: BoxFit.contain,
                      )
                    : const SizedBox.shrink(),
              ),

              // Brand Title below logo (Way in Emerald, Drop in Gold)
              if (!keyboardVisible) ...[
                const SizedBox(height: 8),
                Center(
                  child: RichText(
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

              SizedBox(height: keyboardVisible ? 16 : 40),

              // Welcome Title and Subtitle matching the mockup
              const Text(
                "Let's Get You Started",
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF090D1A),
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                "Enter your phone number, we'll send a one-time code to verify it.",
                style: TextStyle(
                  fontSize: 14.5,
                  color: Color(0xFF64748B),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 32),

              // Spacious Phone Input Field Box
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 58,
                decoration: BoxDecoration(
                  color: _isPhoneFocused
                      ? const Color(0xFFF0FDF4)
                      : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _isPhoneFocused
                        ? const Color(0xFF1B7A44)
                        : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                child: Row(
                  children: [
                    // Spaced country prefix (no flag, no dropdown)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '+91',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF090D1A),
                        ),
                      ),
                    ),
                    // Elegant divider line
                    Container(
                      height: 24,
                      width: 1.5,
                      color: _isPhoneFocused
                          ? const Color(0xFF1B7A44).withValues(alpha: 0.3)
                          : const Color(0xFFCBD5E1),
                    ),
                    const SizedBox(width: 16),
                    // Actual editable phone field
                    Expanded(
                      child: TextField(
                        controller: phoneController,
                        focusNode: phoneFocusNode,
                        keyboardType: TextInputType.phone,
                        maxLength: 10,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        cursorColor: const Color(0xFF1B7A44),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF090D1A),
                          letterSpacing: 1.0,
                        ),
                        decoration: const InputDecoration(
                          hintText: '9876543210',
                          hintStyle: TextStyle(
                            color: Color(0xFF94A3B8),
                            fontWeight: FontWeight.w500,
                            letterSpacing: 1.0,
                          ),
                          border: InputBorder.none,
                          counterText: '',
                          contentPadding: EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 28),

              // Action button Continue (solid Green, centered text)
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: (loading || _isButtonDisabled) ? null : sendOtp,
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
                      : Text(
                          _buttonText == 'Send OTP' ? 'Continue' : _buttonText,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                ),
              ),

              const SizedBox(height: 20),

              // Mockup Terms text
              Text.rich(
                TextSpan(
                  text: 'By continuing, you agree to our ',
                  style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                  children: [
                    TextSpan(
                      text: 'Terms & Conditions',
                      style: const TextStyle(
                        color: Color(0xFF1B7A44),
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.underline,
                      ),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => LegalReaderScreen(
                                title: 'Terms & Conditions',
                                lastUpdated: 'May 22, 2026',
                                paragraphs: termsAndConditionsContent,
                              ),
                            ),
                          );
                        },
                    ),
                    TextSpan(
                      text: ' and ',
                      style: TextStyle(color: Colors.grey.shade500),
                    ),
                    TextSpan(
                      text: 'Privacy Policy',
                      style: const TextStyle(
                        color: Color(0xFF1B7A44),
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.underline,
                      ),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => LegalReaderScreen(
                                title: 'Privacy Policy',
                                lastUpdated: 'May 22, 2026',
                                paragraphs: privacyPolicyContent,
                              ),
                            ),
                          );
                        },
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
              ),

              // Shortcut row for active session
              if (isSamePhone) ...[
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'OTP already sent.',
                      style: TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        if (_navigatingToOtp) return;
                        _navigatingToOtp = true;
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                OtpScreen(phone: AuthSession.activePhone!),
                          ),
                        ).then((_) {
                          if (mounted) _navigatingToOtp = false;
                        });
                      },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: const Color(0xFF1B7A44),
                      ),
                      child: const Text(
                        'Enter OTP',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
              ],

              const SizedBox(height: 48),

              // Bottom Secure Lock Banner
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.lock_outline_rounded,
                    color: Color(0xFF1B7A44),
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Your data is 100% secure and encrypted',
                    style: TextStyle(
                      color: Colors.grey.shade400,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
