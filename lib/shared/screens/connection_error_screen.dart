import 'package:flutter/material.dart';
import 'package:waydrop/shared/helpers/global_error_controller.dart';

class ConnectionErrorScreen extends StatelessWidget {
  final VoidCallback onRetry;
  final String errorMessage;
  final ErrorType errorType;

  const ConnectionErrorScreen({
    super.key,
    required this.onRetry,
    this.errorType = ErrorType.offline,
    this.errorMessage = "We couldn't connect to the WayDrop servers. Please check your internet connection.",
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtitleColor = isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600;
    final bgColor = isDark ? const Color(0xFF1E222B) : const Color(0xFFF8FAFC);

    IconData iconData;
    String title;
    Color accentColor;

    switch (errorType) {
      case ErrorType.slow:
        iconData = Icons.speed_rounded;
        title = 'Slow Connection';
        accentColor = const Color(0xFFF59E0B); // Amber
        break;
      case ErrorType.backend:
        iconData = Icons.cloud_off_rounded;
        title = 'Server Error';
        accentColor = const Color(0xFFEF4444); // Red
        break;
      case ErrorType.general:
        iconData = Icons.error_outline_rounded;
        title = 'Something Went Wrong';
        accentColor = const Color(0xFF3B82F6); // Blue
        break;
      case ErrorType.offline:
        iconData = Icons.wifi_off_rounded;
        title = 'No Internet Connection';
        accentColor = const Color(0xFFEF4444); // Red
        break;
    }

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
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.2),
                    width: 2,
                  ),
                ),
                child: Center(
                  child: Icon(
                    iconData,
                    color: accentColor,
                    size: 44,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: textColor,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                errorMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: subtitleColor,
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                onPressed: onRetry,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  minimumSize: const Size(180, 52),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 20),
                label: const Text(
                  'Try Again',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
