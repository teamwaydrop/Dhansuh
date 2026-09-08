import 'package:flutter/material.dart';

/// Shown instead of the normal app flow when `production_config.maintenance_mode = true`
/// (see ProductionConfigService / app_start_screen.dart's checkUserFlow). Styled to match
/// ConnectionErrorScreen so a full-screen blocking state always looks consistent across the app,
/// but deliberately distinct (construction icon/amber) so a user can tell "we're doing planned
/// maintenance" apart from "your connection failed".
class MaintenanceScreen extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const MaintenanceScreen({
    super.key,
    required this.onRetry,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtitleColor = isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600;
    final bgColor = isDark ? const Color(0xFF1E222B) : const Color(0xFFF8FAFC);
    const accentColor = Color(0xFFF59E0B); // Amber -- matches ConnectionErrorScreen's "slow" tone

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
                  child: Icon(Icons.build_rounded, color: accentColor, size: 44),
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Under Maintenance',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: textColor, letterSpacing: -0.5),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: subtitleColor, height: 1.45, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                onPressed: onRetry,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  minimumSize: const Size(180, 52),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 20),
                label: const Text('Check Again', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
