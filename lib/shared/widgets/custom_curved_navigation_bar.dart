import 'package:flutter/material.dart';

class CustomNavBarItem {
  final IconData iconActive;
  final IconData iconInactive;
  final String label;

  const CustomNavBarItem({
    required this.iconActive,
    required this.iconInactive,
    required this.label,
  });
}

class CustomCurvedNavigationBar extends StatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<CustomNavBarItem> items;
  final Color activeIconColor;
  final Color backgroundColor;
  final Map<int, int> badges;

  const CustomCurvedNavigationBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
    required this.activeIconColor,
    this.backgroundColor = const Color(0xFF181A20),
    this.badges = const {},
  });

  @override
  State<CustomCurvedNavigationBar> createState() => _CustomCurvedNavigationBarState();
}

class _CustomCurvedNavigationBarState extends State<CustomCurvedNavigationBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  double _prevIndex = 0.0;

  @override
  void initState() {
    super.initState();
    _prevIndex = widget.currentIndex.toDouble();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _animation = Tween<double>(begin: _prevIndex, end: _prevIndex).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic),
    );
  }

  @override
  void didUpdateWidget(CustomCurvedNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _prevIndex = _animation.value;
      _controller.reset();
      _animation = Tween<double>(
        begin: _prevIndex,
        end: widget.currentIndex.toDouble(),
      ).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic),
      );
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final totalHeight = 88.0 + bottomPadding;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inactiveIconColor = isDark 
        ? Colors.white.withValues(alpha: 0.65) 
        : const Color(0xFF64748B);
    final activeTextColor = isDark 
        ? Colors.white 
        : const Color(0xFF0F172A);

    return LayoutBuilder(
      builder: (context, constraints) {
        final W = constraints.maxWidth;
        final N = widget.items.length;
        if (W == 0 || N == 0) return const SizedBox.shrink();
        final cellWidth = W / N;

        return SizedBox(
          height: totalHeight,
          child: AnimatedBuilder(
            animation: _animation,
            builder: (context, child) {
              final indexValue = _animation.value;
              final currentCx = (indexValue + 0.5) * cellWidth;

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // 1. Curved Background with Hump
                  Positioned.fill(
                    child: CustomPaint(
                      painter: CurvedNavigationBarPainter(
                        cx: currentCx,
                        backgroundColor: widget.backgroundColor,
                        isDark: isDark,
                      ),
                    ),
                  ),

                  // 2. Inactive Icons (fading out when active circle is on them)
                  ...List.generate(N, (i) {
                    final cxI = (i + 0.5) * cellWidth;
                    final distance = (indexValue - i).abs();
                    // Fade out inactive icon as active badge gets close
                    final inactiveOpacity = distance.clamp(0.0, 1.0);
                    final badgeCount = widget.badges[i] ?? 0;

                    return Positioned(
                      left: cxI - 24,
                      top: 42,
                      width: 48,
                      child: IgnorePointer(
                        child: Stack(
                          alignment: Alignment.center,
                          clipBehavior: Clip.none,
                          children: [
                            Opacity(
                              opacity: inactiveOpacity,
                              child: Icon(
                                widget.items[i].iconInactive,
                                size: 24,
                                color: inactiveIconColor,
                              ),
                            ),
                            if (badgeCount > 0)
                              Positioned(
                                right: 2,
                                top: -2,
                                child: Opacity(
                                  opacity: inactiveOpacity,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEF4444),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    constraints: const BoxConstraints(
                                      minWidth: 16,
                                      minHeight: 16,
                                    ),
                                    child: Text(
                                      '$badgeCount',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }),

                  // 3. Active Text Labels (fading in when active circle is on them)
                  ...List.generate(N, (i) {
                    final cxI = (i + 0.5) * cellWidth;
                    final distance = (indexValue - i).abs();
                    // Fade in active text label as active badge gets close
                    final labelOpacity = (1.0 - distance * 2.0).clamp(0.0, 1.0);

                    return Positioned(
                      left: cxI - 50,
                      top: 66, // Below the active white circle
                      width: 100,
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: labelOpacity,
                          child: Text(
                            widget.items[i].label,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: activeTextColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.1,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),

                  // 4. Active Floating Circle
                  Positioned(
                    left: currentCx - 27,
                    top: 3, // Positioned so it sits elegantly over the hump
                    width: 54,
                    height: 54,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B7A44), // Emerald Circle
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF1B7A44).withValues(alpha: isDark ? 0.4 : 0.2),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            widget.items[widget.currentIndex].iconActive,
                            key: ValueKey<int>(widget.currentIndex),
                            size: 28,
                            color: Colors.white, // White Icon
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 5. Tap Targets (spans the active area)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 24,
                    bottom: bottomPadding,
                    child: Row(
                      children: List.generate(
                        N,
                        (index) => Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => widget.onTap(index),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class CurvedNavigationBarPainter extends CustomPainter {
  final double cx;
  final Color backgroundColor;
  final bool isDark;

  const CurvedNavigationBarPainter({
    required this.cx,
    required this.backgroundColor,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const double capsuleTop = 24.0;
    const double humpPeak = 7.0; // The highest point of the hump
    const double humpHalfWidth = 45.0; // Width of the curve on each side of the center

    final path = Path();
    
    // Start at top-left corner
    path.moveTo(0, capsuleTop);

    // Top edge line to start of hump
    path.lineTo(cx - humpHalfWidth, capsuleTop);

    // Smooth curve up to the peak of the hump
    path.cubicTo(
      cx - humpHalfWidth * 0.65, capsuleTop,
      cx - humpHalfWidth * 0.35, humpPeak,
      cx, humpPeak,
    );

    // Smooth curve down from the peak of the hump
    path.cubicTo(
      cx + humpHalfWidth * 0.35, humpPeak,
      cx + humpHalfWidth * 0.65, capsuleTop,
      cx + humpHalfWidth, capsuleTop,
    );

    // Top edge line to top-right corner
    path.lineTo(size.width, capsuleTop);

    // Right edge to bottom-right corner
    path.lineTo(size.width, size.height);

    // Bottom edge line to bottom-left corner
    path.lineTo(0, size.height);

    path.close();

    // Paint the filled path
    final fillPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);
  }

  @override
  bool shouldRepaint(covariant CurvedNavigationBarPainter oldDelegate) {
    return oldDelegate.cx != cx || oldDelegate.backgroundColor != backgroundColor || oldDelegate.isDark != isDark;
  }
}
