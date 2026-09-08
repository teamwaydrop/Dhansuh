import 'dart:math' as math;
import 'package:flutter/material.dart';

class WayDrop3dBike extends StatefulWidget {
  final double size;
  const WayDrop3dBike({super.key, this.size = 130});

  @override
  State<WayDrop3dBike> createState() => _WayDrop3dBikeState();
}

class _WayDrop3dBikeState extends State<WayDrop3dBike>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600), // Fluid Swiggy-like frequency
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      width: widget.size,
      height: widget.size * 1.1,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // Bobbing physics (float up & down)
          final bobValue = math.sin(_controller.value * math.pi * 2) * 4.0;
          // Pitching/Tilting physics (tilt slightly side-to-side/back-and-forth)
          final tiltValue = math.sin(_controller.value * math.pi * 2 - (math.pi / 4)) * 0.04;
          // Pulsing shadow scaling & opacity based on bobbing height
          final shadowScale = 1.0 - (math.sin(_controller.value * math.pi * 2).abs() * 0.15);
          final shadowOpacity = 0.35 - (math.sin(_controller.value * math.pi * 2).abs() * 0.1);

          return Stack(
            alignment: Alignment.center,
            children: [
              // 1. Soft Pulsing Radial Shadow beneath the bike
              Positioned(
                bottom: 4,
                child: Transform.scale(
                  scale: shadowScale,
                  child: Container(
                    width: widget.size * 0.7,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: (isDark ? Colors.black : const Color(0xFF0F172A))
                              .withValues(alpha: shadowOpacity),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // 2. Volumetric Glow Behind the 3D Model
              Positioned(
                bottom: widget.size * 0.15 + bobValue,
                child: Transform.rotate(
                  angle: tiltValue,
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    width: widget.size * 0.65,
                    height: widget.size * 0.65,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          const Color(0xFF10B981).withValues(alpha: isDark ? 0.15 : 0.08),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // 3. The Transparent 3D Bike Image with movements applied
              Positioned(
                bottom: widget.size * 0.1 + bobValue,
                child: Transform.rotate(
                  angle: tiltValue,
                  alignment: Alignment.bottomCenter,
                  child: Image.asset(
                    'assets/map/3dbike.png',
                    width: widget.size,
                    height: widget.size * 0.9,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
