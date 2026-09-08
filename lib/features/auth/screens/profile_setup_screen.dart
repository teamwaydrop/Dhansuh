import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:waydrop/shared/helpers/app_keyboard_wrapper.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';
import 'package:waydrop/features/auth/screens/login_screen.dart';
import 'package:waydrop/features/auth/screens/permissions_screen.dart';

class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final FocusNode nameFocus = FocusNode();
  final FocusNode emailFocus = FocusNode();
  
  bool loading = false;
  String? nameError;
  String? emailError;

  Future<void> _redirectToLogin() async {
    await Supabase.instance.client.auth.signOut();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  void initState() {
    super.initState();
    nameController.addListener(_validateName);
    emailController.addListener(_validateEmail);
  }

  void _validateName() {
    final val = nameController.text.trim();
    if (nameError != null && val.isNotEmpty) {
      setState(() => nameError = null);
    }
  }

  void _validateEmail() {
    final val = emailController.text.trim();
    if (emailError != null) {
      if (val.isEmpty || RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(val)) {
        setState(() => emailError = null);
      }
    }
  }

  Future<void> saveProfile() async {
    if (loading) return;
    FocusScope.of(context).unfocus();

    final name = nameController.text.trim();
    final email = emailController.text.trim();

    bool hasValidationError = false;

    // Validate Name
    if (name.isEmpty) {
      setState(() => nameError = 'Full name is required');
      hasValidationError = true;
    }

    // Validate Email (Optional, but if filled, must be valid)
    if (email.isNotEmpty && !RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email)) {
      setState(() => emailError = 'Enter a valid email address');
      hasValidationError = true;
    }

    if (hasValidationError) {
      showAppSnackBar(
        context,
        'Please correct the errors in the form before continuing',
        type: SnackBarType.error,
      );
      return;
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      await _redirectToLogin();
      return;
    }

    setState(() => loading = true);

    try {
      await Supabase.instance.client.from('users').update({
        'full_name': name,
        'email': email.isEmpty ? null : email,
        'profile_completed': true,
      }).eq('id', user.id);

      if (!mounted) return;
      
      showAppSnackBar(
        context,
        'Profile completed successfully!',
        type: SnackBarType.success,
      );

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const PermissionsScreen()),
      );
    } catch (e) {
      showAppSnackBar(
        context,
        e.toString(),
        type: SnackBarType.error,
      );
    }

    setState(() => loading = false);
  }

  @override
  void dispose() {
    nameController.removeListener(_validateName);
    emailController.removeListener(_validateEmail);
    nameController.dispose();
    emailController.dispose();
    nameFocus.dispose();
    emailFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;
    final logoHeight = keyboardVisible ? 0.0 : 90.0;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _redirectToLogin();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: AppKeyboardWrapper(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: keyboardVisible ? 10 : 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: keyboardVisible ? 12 : 36),

                // Branded Header Badge
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  height: logoHeight,
                  alignment: Alignment.center,
                  child: logoHeight > 20
                      ? Container(
                          width: 110,
                          height: 90,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: const Color(0xFF10B981).withOpacity(0.2),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF10B981).withOpacity(0.04),
                                blurRadius: 8,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Image.asset(
                            'assets/images/waydrop_logo_transparent.png',
                            fit: BoxFit.contain,
                          ),
                        )
                      : const SizedBox.shrink(),
                ).animate().scale(duration: 600.ms, curve: Curves.easeOutBack),
                SizedBox(height: keyboardVisible ? 8 : 20),

                // Branded Title
                Center(
                  child: RichText(
                    text: const TextSpan(
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                      ),
                      children: [
                        TextSpan(
                          text: 'Way',
                          style: TextStyle(color: Color(0xFF10B981)), // Emerald Green
                        ),
                        TextSpan(
                          text: 'Drop',
                          style: TextStyle(color: Color(0xFFD4AF37)), // Shiny Gold
                        ),
                      ],
                    ),
                  ),
                )
                    .animate()
                    .fadeIn(duration: 500.ms)
                    .slideY(begin: 0.15, end: 0, duration: 500.ms, curve: Curves.easeOutQuad),
                const SizedBox(height: 8),
                Text(
                  'Complete your profile to get started',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14.5,
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w500,
                  ),
                )
                    .animate()
                    .fadeIn(duration: 500.ms, delay: 100.ms)
                    .slideY(begin: 0.15, end: 0, duration: 500.ms, curve: Curves.easeOutQuad),
                SizedBox(height: keyboardVisible ? 16 : 40),

                // Form Section with entrance animation
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Name Field Section
                    const Text(
                      'Full Name *',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _InputField(
                      controller: nameController,
                      focusNode: nameFocus,
                      hint: 'Your full name',
                      icon: Icons.person_outline_rounded,
                      inputAction: TextInputAction.next,
                      onSubmit: (_) => emailFocus.requestFocus(),
                      errorText: nameError,
                    ),
                    SizedBox(height: keyboardVisible ? 12 : 24),

                    // Email Field Section
                    const Text(
                      'Email (Optional)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _InputField(
                      controller: emailController,
                      focusNode: emailFocus,
                      hint: 'your@email.com',
                      icon: Icons.email_outlined,
                      keyboardType: TextInputType.emailAddress,
                      inputAction: TextInputAction.done,
                      onSubmit: (_) => saveProfile(),
                      errorText: emailError,
                    ),
                    SizedBox(height: keyboardVisible ? 20 : 48),

                    // Continue Action Button
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        onPressed: loading ? null : saveProfile,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xFFE2E8F0),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: loading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              )
                            : const Text(
                                'Continue',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                ),
                              ),
                      ),
                    ),
                  ],
                )
                    .animate()
                    .fadeIn(duration: 600.ms, delay: 200.ms)
                    .slideY(begin: 0.1, end: 0, duration: 600.ms, curve: Curves.easeOutQuad),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InputField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final IconData icon;
  final TextInputType keyboardType;
  final TextInputAction inputAction;
  final ValueChanged<String>? onSubmit;
  final String? errorText;

  const _InputField({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.icon,
    this.keyboardType = TextInputType.text,
    required this.inputAction,
    this.onSubmit,
    this.errorText,
  });

  @override
  State<_InputField> createState() => _InputFieldState();
}

class _InputFieldState extends State<_InputField> {
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    setState(() {
      _isFocused = widget.focusNode.hasFocus;
    });
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasError = widget.errorText != null;

    Color borderColor = const Color(0xFFE2E8F0);
    Color bgColor = const Color(0xFFF8FAFC);
    Color iconColor = const Color(0xFF94A3B8);

    if (hasError) {
      borderColor = const Color(0xFFFCA5A5); // Soft red border
      bgColor = const Color(0xFFFEF2F2); // Soft red background
      iconColor = const Color(0xFFEF4444); // Error red icon
    } else if (_isFocused) {
      borderColor = const Color(0xFF10B981); // Emerald active border
      bgColor = const Color(0xFFF0FDF4); // Soft green background
      iconColor = const Color(0xFF10B981); // Active emerald icon
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: 1.5),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 20, color: iconColor),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  keyboardType: widget.keyboardType,
                  textInputAction: widget.inputAction,
                  onSubmitted: widget.onSubmit,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                  cursorColor: const Color(0xFF10B981),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: widget.hint,
                    hintStyle: const TextStyle(
                      color: Color(0xFFCBD5E1),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              widget.errorText!,
              style: const TextStyle(
                color: Color(0xFFEF4444),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}