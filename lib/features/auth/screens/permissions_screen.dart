import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/auth/screens/login_screen.dart';
import 'package:waydrop/main_navigation_screen.dart';

import 'package:waydrop/shared/widgets/app_snackbar.dart';

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  bool loading = false;

  Future<void> _redirectToLogin() async {
    await Supabase.instance.client.auth.signOut();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  Future<void> completeOnboarding() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      await _redirectToLogin();
      return;
    }

    try {
      await Supabase.instance.client
          .from('users')
          .update({'onboarding_completed': true}).eq('id', user.id);
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 'Failed to complete setup: $e');
      return;
    }

    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
      (route) => false,
    );
  }

  Future<void> requestPermissions() async {
    if (loading) return;
    setState(() => loading = true);
    try {
      await Permission.notification.request();
      await Permission.location.request();
      await completeOnboarding();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, e.toString());
    }
    if (!mounted) return;
    setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _redirectToLogin();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 12),

                        // Header & Title Section
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: const Color(0xFFF0FDF4),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: const Color(0xFF10B981), width: 1.5),
                              ),
                              child: const Icon(Icons.shield_outlined, color: Color(0xFF10B981), size: 26),
                            ).animate().scale(duration: 600.ms, curve: Curves.easeOutBack),
                            const SizedBox(height: 20),
                            const Text(
                              'Enable Permissions',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF0F172A),
                                letterSpacing: -0.5,
                              ),
                            )
                                .animate()
                                .fadeIn(duration: 500.ms)
                                .slideY(begin: 0.15, end: 0, duration: 500.ms, curve: Curves.easeOutQuad),
                            const SizedBox(height: 8),
                            const Text(
                              'Allow access to use real-time tracking and notifications.',
                              style: TextStyle(fontSize: 14, color: Color(0xFF64748B), height: 1.5),
                            )
                                .animate()
                                .fadeIn(duration: 500.ms, delay: 100.ms)
                                .slideY(begin: 0.15, end: 0, duration: 500.ms, curve: Curves.easeOutQuad),
                          ],
                        ),

                        const SizedBox(height: 24),

                        // Permission cards
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _PermCard(
                              icon: Icons.notifications_outlined,
                              title: 'Notifications',
                              subtitle: 'Get instant delivery updates and alerts',
                              color: const Color(0xFF2563EB),
                            )
                                .animate()
                                .fadeIn(duration: 600.ms, delay: 150.ms)
                                .slideY(begin: 0.1, end: 0, duration: 600.ms, curve: Curves.easeOutQuad),
                            const SizedBox(height: 12),
                            _PermCard(
                              icon: Icons.location_on_outlined,
                              title: 'Location',
                              subtitle: 'Enable maps and accurate partner tracking',
                              color: const Color(0xFF10B981),
                            )
                                .animate()
                                .fadeIn(duration: 600.ms, delay: 250.ms)
                                .slideY(begin: 0.1, end: 0, duration: 600.ms, curve: Curves.easeOutQuad),
                          ],
                        ),

                        const SizedBox(height: 32),

                        // Footer Buttons Section
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: double.infinity,
                              height: 54,
                              child: ElevatedButton(
                                onPressed: loading ? null : requestPermissions,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF10B981),
                                  foregroundColor: Colors.white,
                                  disabledBackgroundColor: const Color(0xFFE2E8F0),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                ),
                                child: loading
                                    ? const SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                                      )
                                    : const Text(
                                        'Allow Permissions',
                                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Center(
                              child: TextButton(
                                onPressed: completeOnboarding,
                                style: TextButton.styleFrom(foregroundColor: const Color(0xFF94A3B8)),
                                child: const Text('Skip for now', style: TextStyle(fontWeight: FontWeight.w600)),
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Center(
                              child: Text(
                                'Manage permissions anytime in Settings.',
                                style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 11),
                              ),
                            ),
                          ],
                        )
                            .animate()
                            .fadeIn(duration: 600.ms, delay: 350.ms)
                            .slideY(begin: 0.1, end: 0, duration: 600.ms, curve: Curves.easeOutQuad),
                        
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PermCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;

  const _PermCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1.2),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A),
                    )),
                const SizedBox(height: 3),
                Text(subtitle,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
