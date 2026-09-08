import 'package:flutter/material.dart';

/// Shown instead of the normal app flow when the installed version is below
/// `production_config.minimum_android_version`, or when `force_update = true` (see
/// ProductionConfigService / app_start_screen.dart's checkUserFlow, CASE A / CASE D).
///
/// Deliberately does NOT link out to a Play Store URL or attempt any in-app download/update
/// mechanism -- there is no existing Play Store listing URL anywhere in this codebase to link to,
/// and Phase 1 explicitly requires this screen to state the requirement clearly without faking an
/// update path. It has no "Continue"/retry action -- CASE A/D means normal app usage must stay
/// blocked until the app itself is actually updated and relaunched.
class UpdateRequiredScreen extends StatelessWidget {
  final String message;
  final String? currentVersion;

  const UpdateRequiredScreen({
    super.key,
    required this.message,
    this.currentVersion,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtitleColor = isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600;
    final bgColor = isDark ? const Color(0xFF1E222B) : const Color(0xFFF8FAFC);
    const accentColor = Color(0xFF3B82F6); // Blue -- matches ConnectionErrorScreen's "general" tone

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(color: accentColor.withValues(alpha: 0.2), width: 2),
                ),
                child: const Center(
                  child: Icon(Icons.system_update_rounded, color: accentColor, size: 44),
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Update Required',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: textColor, letterSpacing: -0.5),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: subtitleColor, height: 1.45, fontWeight: FontWeight.w500),
              ),
              if (currentVersion != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Installed version: $currentVersion',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: subtitleColor.withValues(alpha: 0.8), fontWeight: FontWeight.w500),
                ),
              ],
              const SizedBox(height: 32),
              Text(
                'Please update WayDrop from the Play Store to continue.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: textColor.withValues(alpha: 0.8), fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
