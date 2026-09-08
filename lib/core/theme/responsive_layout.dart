import 'package:flutter/material.dart';

class ResponsiveLayout {
  // Max width of content on larger screens (tablets, desktop)
  static const double maxContentWidth = 600.0;

  // Calculates horizontal padding dynamically
  static double horizontalPadding(BuildContext context) {
    final double width = MediaQuery.of(context).size.width;
    if (width > maxContentWidth) {
      return (width - maxContentWidth) / 2 + 16.0;
    }
    return 12.0; // Safe horizontal padding on mobile devices to prevent going out of bounds
  }

  // Helper widget to wrap screen body for centering and constraining on large screens
  static Widget buildPage({
    required BuildContext context,
    required Widget child,
    double verticalPadding = 16.0,
  }) {
    final double width = MediaQuery.of(context).size.width;
    final isLargeScreen = width > maxContentWidth;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxContentWidth),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isLargeScreen ? 16.0 : 0.0,
            vertical: verticalPadding,
          ),
          child: child,
        ),
      ),
    );
  }
}
