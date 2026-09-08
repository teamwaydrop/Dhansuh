import 'package:flutter/material.dart';

// Centralized Color System
class WayDropColors {
  static const Color primaryEmerald = Color(0xFF1B7A44);
  static const Color emeraldLight = Color(0xFFEAF7EF);
  static const Color goldAccent = Color(0xFFD4AF37);
  static const Color primaryText = Color(0xFF0F172A);
  static const Color secondaryText = Color(0xFF475569);
  static const Color background = Color(0xFFF8FAFC);
  static const Color card = Color(0xFFFFFFFF);
}

// Reusable Premium Card Widget
class WayDropCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final Border? border;
  final List<BoxShadow>? boxShadow;
  final double? borderRadius;

  const WayDropCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.onTap,
    this.border,
    this.boxShadow,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final cardContent = Padding(
      padding: padding ?? const EdgeInsets.all(20),
      child: child,
    );

    return Container(
      margin: margin ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171A21) : WayDropColors.card,
        borderRadius: BorderRadius.circular(borderRadius ?? 22),
        border: border ?? Border.all(
          color: isDark 
              ? Colors.white.withValues(alpha: 0.08) 
              : WayDropColors.primaryEmerald.withValues(alpha: 0.1),
          width: 1.5,
        ),
        boxShadow: boxShadow ?? [
          BoxShadow(
            color: isDark 
                ? Colors.black.withValues(alpha: 0.2) 
                : WayDropColors.primaryEmerald.withValues(alpha: 0.03),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: onTap != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(borderRadius ?? 22),
              child: InkWell(
                onTap: onTap,
                splashColor: WayDropColors.primaryEmerald.withValues(alpha: 0.05),
                highlightColor: WayDropColors.primaryEmerald.withValues(alpha: 0.02),
                child: cardContent,
              ),
            )
          : cardContent,
    );
  }
}

// Reusable Primary Button Widget
class WayDropPrimaryButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final Widget? icon;
  final bool loading;
  final double? width;
  final double height;

  const WayDropPrimaryButton({
    super.key,
    required this.text,
    this.onPressed,
    this.icon,
    this.loading = false,
    this.width,
    this.height = 54,
  });

  @override
  Widget build(BuildContext context) {
    final buttonContent = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (loading) ...[
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              color: Colors.white,
              strokeWidth: 2.5,
            ),
          ),
        ] else ...[
          if (icon != null) ...[
            icon!,
            const SizedBox(width: 8),
          ],
          Text(
            text,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ],
    );

    return SizedBox(
      width: width ?? double.infinity,
      height: height,
      child: ElevatedButton(
        onPressed: (loading || onPressed == null) ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: WayDropColors.primaryEmerald,
          disabledBackgroundColor: const Color(0xFFE2E8F0),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: buttonContent,
      ),
    );
  }
}

// Reusable Secondary Button Widget
class WayDropSecondaryButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final Widget? icon;
  final double? width;
  final double height;

  const WayDropSecondaryButton({
    super.key,
    required this.text,
    this.onPressed,
    this.icon,
    this.width,
    this.height = 54,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final buttonContent = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          icon!,
          const SizedBox(width: 8),
        ],
        Text(
          text,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: WayDropColors.primaryEmerald,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );

    return SizedBox(
      width: width ?? double.infinity,
      height: height,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          side: BorderSide(
            color: isDark 
                ? WayDropColors.primaryEmerald.withValues(alpha: 0.4) 
                : WayDropColors.primaryEmerald.withValues(alpha: 0.2),
            width: 1.5,
          ),
          backgroundColor: isDark ? Colors.transparent : WayDropColors.emeraldLight,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: buttonContent,
      ),
    );
  }
}

// Reusable Section Title Widget
class WayDropSectionTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const WayDropSectionTitle({
    super.key,
    required this.title,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            color: isDark ? Colors.white : WayDropColors.primaryText,
            letterSpacing: -0.5,
            fontStyle: FontStyle.italic,
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

// Reusable Icon Container Widget
class WayDropIconCircle extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final Color? bgColor;
  final double size;
  final double iconSize;

  const WayDropIconCircle({
    super.key,
    required this.icon,
    this.iconColor,
    this.bgColor,
    this.size = 44,
    this.iconSize = 22,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bgColor ?? (isDark 
            ? const Color(0xFF1E293B) 
            : WayDropColors.primaryEmerald.withValues(alpha: 0.08)),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Icon(
          icon,
          color: iconColor ?? (isDark ? Colors.white : WayDropColors.primaryEmerald),
          size: iconSize,
        ),
      ),
    );
  }
}
