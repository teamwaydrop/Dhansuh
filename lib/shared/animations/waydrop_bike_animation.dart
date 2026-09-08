import 'dart:math' as math;
import 'package:flutter/material.dart';

class WayDropBikeAnimation extends StatefulWidget {
  final double size;
  const WayDropBikeAnimation({super.key, this.size = 130});

  @override
  State<WayDropBikeAnimation> createState() => _WayDropBikeAnimationState();
}

class _WayDropBikeAnimationState extends State<WayDropBikeAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400), // Energetic speed
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
    const primaryColor = Color(0xFF10B981); // WayDrop Emerald Green
    final secondaryColor = isDark ? Colors.white : const Color(0xFF0F172A);

    return SizedBox(
      width: widget.size * 1.6,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // Bobbing physics (up & down)
          final bobValue = math.sin(_controller.value * math.pi * 4) * 2.5;
          // Pitching physics (slight rotation tilt back & forth)
          final pitchValue = math.sin(_controller.value * math.pi * 4 - (math.pi / 4)) * 0.025;
          // Spinning rotation for wheels
          final wheelRotation = _controller.value * math.pi * 2;

          return Stack(
            alignment: Alignment.center,
            children: [
              // 1. Ground and Parallax Speed Trails/Particles
              Positioned(
                bottom: 12,
                left: 0,
                right: 0,
                child: CustomPaint(
                  size: Size(widget.size * 1.6, 40),
                  painter: _GroundAndSpeedPainter(
                    progress: _controller.value,
                    color: isDark ? const Color(0x33FFFFFF) : const Color(0x1A000000),
                    speedColor: primaryColor.withValues(alpha: isDark ? 0.3 : 0.15),
                  ),
                ),
              ),

              // 2. Volumetric Headlight Beam (projected in front)
              Positioned(
                bottom: 22 + bobValue,
                left: widget.size * 1.08, // Aligned directly with front LED headlight
                child: Transform.rotate(
                  angle: pitchValue,
                  alignment: Alignment.centerLeft,
                  child: CustomPaint(
                    size: Size(widget.size * 0.5, widget.size * 0.35),
                    painter: _HeadlightBeamPainter(
                      color: const Color(0xFFFBBF24).withValues(alpha: isDark ? 0.35 : 0.18),
                    ),
                  ),
                ),
              ),

              // 3. Main Delivery Scooter & Rider
              Positioned(
                bottom: 20 + bobValue,
                child: Transform.rotate(
                  angle: pitchValue,
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: widget.size,
                    height: widget.size * 0.8,
                    child: Stack(
                      children: [
                        // Chassis, body panels, rider, windshield, decals
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _ScooterBodyPainter(
                              primaryColor: primaryColor,
                              secondaryColor: secondaryColor,
                              isDark: isDark,
                              progress: _controller.value,
                            ),
                          ),
                        ),

                        // Rear Wheel
                        Positioned(
                          left: widget.size * 0.11,
                          bottom: 0,
                          width: widget.size * 0.22,
                          height: widget.size * 0.22,
                          child: Transform.rotate(
                            angle: -wheelRotation,
                            child: CustomPaint(
                              painter: _WheelPainter(color: secondaryColor, isDark: isDark),
                            ),
                          ),
                        ),

                        // Front Wheel
                        Positioned(
                          right: widget.size * 0.11,
                          bottom: 0,
                          width: widget.size * 0.22,
                          height: widget.size * 0.22,
                          child: Transform.rotate(
                            angle: -wheelRotation,
                            child: CustomPaint(
                              painter: _WheelPainter(color: secondaryColor, isDark: isDark),
                            ),
                          ),
                        ),
                      ],
                    ),
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

class _ScooterBodyPainter extends CustomPainter {
  final Color primaryColor;
  final Color secondaryColor;
  final bool isDark;
  final double progress;

  _ScooterBodyPainter({
    required this.primaryColor,
    required this.secondaryColor,
    required this.isDark,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Paint systems
    final paintOutline = Paint()
      ..color = secondaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round;

    final paintFill = Paint()
      ..color = secondaryColor
      ..style = PaintingStyle.fill;

    // Soft drop shadow under the chassis for grounding
    final shadowPaint = Paint()
      ..color = isDark ? Colors.black.withValues(alpha: 0.4) : Colors.black.withValues(alpha: 0.1)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);
    canvas.drawOval(
      Rect.fromLTRB(w * 0.15, h * 0.85, w * 0.85, h * 0.90),
      shadowPaint,
    );

    // 1. CARGO BOX SUPPORT RACK
    final rackPaint = Paint()
      ..color = isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final rackPath = Path()
      ..moveTo(w * 0.15, h * 0.62)
      ..lineTo(w * 0.36, h * 0.62)
      ..moveTo(w * 0.22, h * 0.62)
      ..lineTo(w * 0.24, h * 0.77)
      ..moveTo(w * 0.31, h * 0.62)
      ..lineTo(w * 0.29, h * 0.77);
    canvas.drawPath(rackPath, rackPaint);
    canvas.drawPath(rackPath, paintOutline);

    // 2. MAIN SCOOTER DECK / FLOORBOARD
    final floorboardPaint = Paint()
      ..color = isDark ? const Color(0xFF0F172A) : const Color(0xFF334155)
      ..style = PaintingStyle.fill;
    final floorRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * 0.32, h * 0.76, w * 0.70, h * 0.82),
      Radius.circular(w * 0.015),
    );
    canvas.drawRRect(floorRect, floorboardPaint);
    canvas.drawRRect(floorRect, paintOutline);

    // Neon green deck strip
    final deckPadPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.fill;
    final deckPadRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * 0.36, h * 0.76, w * 0.66, h * 0.78),
      Radius.circular(w * 0.008),
    );
    canvas.drawRRect(deckPadRect, deckPadPaint);

    // 3. REAR PANEL / MOTOR COVER (Curved body panel)
    final bodyPaint = Paint()
      ..color = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)
      ..style = PaintingStyle.fill;
    final bodyPath = Path()
      ..moveTo(w * 0.22, h * 0.77) // rear hub
      ..cubicTo(w * 0.28, h * 0.54, w * 0.36, h * 0.54, w * 0.44, h * 0.54)
      ..lineTo(w * 0.62, h * 0.54)
      ..cubicTo(w * 0.68, h * 0.62, w * 0.70, h * 0.77, w * 0.72, h * 0.77)
      ..lineTo(w * 0.62, h * 0.77)
      ..cubicTo(w * 0.48, h * 0.77, w * 0.30, h * 0.77, w * 0.22, h * 0.77)
      ..close();
    canvas.drawPath(bodyPath, bodyPaint);
    canvas.drawPath(bodyPath, paintOutline);

    // Elegant neon green side accent decal
    final decalPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final decalPath = Path()
      ..moveTo(w * 0.30, h * 0.65)
      ..cubicTo(w * 0.35, h * 0.58, w * 0.42, h * 0.58, w * 0.50, h * 0.58)
      ..quadraticBezierTo(w * 0.56, h * 0.58, w * 0.61, h * 0.68);
    canvas.drawPath(decalPath, decalPaint);

    // 4. SUSPENSION SPRINGS
    final shockPaint = Paint()
      ..color = isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    canvas.drawLine(Offset(w * 0.27, h * 0.56), Offset(w * 0.22, h * 0.77), shockPaint);
    
    // Spring Coil overlay
    final springPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    for (int i = 0; i < 6; i++) {
      final ratio = i / 6.0;
      final startY = h * 0.56 + (h * 0.77 - h * 0.56) * ratio;
      final startX = w * 0.27 + (w * 0.22 - w * 0.27) * ratio;
      canvas.drawLine(
        Offset(startX - 2.5, startY),
        Offset(startX + 2.5, startY + 2),
        springPaint,
      );
    }

    // 5. CARGO DELIVERY BOX
    final boxRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * 0.08, h * 0.18, w * 0.38, h * 0.58),
      Radius.circular(w * 0.035),
    );
    final boxGradient = LinearGradient(
      colors: [primaryColor, const Color(0xFF047857)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ).createShader(Rect.fromLTRB(w * 0.08, h * 0.18, w * 0.38, h * 0.58));
    final boxPaint = Paint()
      ..shader = boxGradient
      ..style = PaintingStyle.fill;
    canvas.drawRRect(boxRect, boxPaint);
    canvas.drawRRect(boxRect, paintOutline);

    // Cargo box glossy reflex highlight overlay
    final reflexPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    final reflexPath = Path()
      ..moveTo(w * 0.08, h * 0.18)
      ..lineTo(w * 0.38, h * 0.18)
      ..lineTo(w * 0.38, h * 0.28)
      ..lineTo(w * 0.08, h * 0.38)
      ..close();
    canvas.drawPath(reflexPath, reflexPaint);

    // Red Reflector Light on the back of Cargo Box
    final reflectorPaint = Paint()
      ..color = const Color(0xFFEF4444)
      ..style = PaintingStyle.fill;
    final reflectorRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * 0.08, h * 0.32, w * 0.095, h * 0.38),
      Radius.circular(w * 0.005),
    );
    canvas.drawRRect(reflectorRect, reflectorPaint);
    canvas.drawRRect(reflectorRect, paintOutline);

    // White Arrow Chevron (WayDrop Identity)
    final arrowPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final arrowPath = Path()
      ..moveTo(w * 0.20, h * 0.33)
      ..lineTo(w * 0.28, h * 0.38)
      ..lineTo(w * 0.20, h * 0.43);
    canvas.drawPath(arrowPath, arrowPaint);

    // 6. SPORTY RIDER SEAT
    final seatRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * 0.41, h * 0.50, w * 0.62, h * 0.54),
      Radius.circular(w * 0.015),
    );
    final seatPaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(seatRect, seatPaint);
    canvas.drawRRect(seatRect, paintOutline);

    // Accent stitched line on seat
    final seatStitch = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(w * 0.43, h * 0.53), Offset(w * 0.60, h * 0.53), seatStitch);

    // 7. FRONT SHIELD & AERODYNAMIC APRON
    final apronGradient = LinearGradient(
      colors: [primaryColor, const Color(0xFF047857)],
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
    ).createShader(Rect.fromLTRB(w * 0.65, h * 0.32, w * 0.81, h * 0.76));
    final shieldPaint = Paint()
      ..shader = apronGradient
      ..style = PaintingStyle.fill;
    final shieldPath = Path()
      ..moveTo(w * 0.68, h * 0.77)
      ..quadraticBezierTo(w * 0.82, h * 0.74, w * 0.80, h * 0.43)
      ..quadraticBezierTo(w * 0.77, h * 0.38, w * 0.73, h * 0.38)
      ..lineTo(w * 0.70, h * 0.54)
      ..close();
    canvas.drawPath(shieldPath, shieldPaint);
    canvas.drawPath(shieldPath, paintOutline);

    // Dynamic color stripe on shield
    final apronStripe = Paint()
      ..color = const Color(0xFF34D399)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawLine(Offset(w * 0.74, h * 0.43), Offset(w * 0.77, h * 0.68), apronStripe);

    // Front fork & Handlebar stem
    final forkPaint = Paint()
      ..color = isDark ? const Color(0xFF64748B) : const Color(0xFF334155)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(w * 0.77, h * 0.77), Offset(w * 0.72, h * 0.32), forkPaint);
    canvas.drawLine(Offset(w * 0.77, h * 0.77), Offset(w * 0.72, h * 0.32), paintOutline);

    // Front Wheel Mudguard / Fender
    final fenderPath = Path()
      ..moveTo(w * 0.71, h * 0.66)
      ..quadraticBezierTo(w * 0.78, h * 0.60, w * 0.84, h * 0.68);
    canvas.drawPath(fenderPath, paintOutline);

    // Chrome coil spring details on front fork
    final forkSpringPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    for (int i = 0; i < 4; i++) {
      final ratio = 0.3 + (i / 4.0) * 0.4;
      final y = h * 0.77 + (h * 0.32 - h * 0.77) * ratio;
      final x = w * 0.77 + (w * 0.72 - w * 0.77) * ratio;
      canvas.drawLine(Offset(x - 2, y), Offset(x + 2, y + 1.5), forkSpringPaint);
    }

    // Static red brake calipers
    final caliperPaint = Paint()
      ..color = const Color(0xFFEF4444)
      ..style = PaintingStyle.fill;
    // Rear Caliper
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(w * 0.19, h * 0.72, w * 0.22, h * 0.77), const Radius.circular(2)),
      caliperPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(w * 0.19, h * 0.72, w * 0.22, h * 0.77), const Radius.circular(2)),
      paintOutline,
    );
    // Front Caliper
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(w * 0.72, h * 0.72, w * 0.75, h * 0.77), const Radius.circular(2)),
      caliperPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(w * 0.72, h * 0.72, w * 0.75, h * 0.77), const Radius.circular(2)),
      paintOutline,
    );

    // 8. WINDSHIELD (Glassmorphism)
    final glassPaint = Paint()
      ..color = Colors.cyan.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    final glassOutline = Paint()
      ..color = Colors.cyan.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final glassPath = Path()
      ..moveTo(w * 0.72, h * 0.32)
      ..lineTo(w * 0.75, h * 0.14)
      ..lineTo(w * 0.78, h * 0.17)
      ..lineTo(w * 0.73, h * 0.32)
      ..close();
    canvas.drawPath(glassPath, glassPaint);
    canvas.drawPath(glassPath, glassOutline);

    // Rearview Mirror
    final mirrorPaint = Paint()
      ..color = isDark ? const Color(0xFF64748B) : const Color(0xFF334155)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawLine(Offset(w * 0.71, h * 0.30), Offset(w * 0.65, h * 0.20), mirrorPaint);
    canvas.drawOval(
      Rect.fromLTRB(w * 0.62, h * 0.17, w * 0.67, h * 0.21),
      paintFill,
    );
    canvas.drawOval(
      Rect.fromLTRB(w * 0.62, h * 0.17, w * 0.67, h * 0.21),
      paintOutline,
    );
    canvas.drawOval(
      Rect.fromLTRB(w * 0.625, h * 0.175, w * 0.665, h * 0.205),
      Paint()..color = Colors.cyan.withValues(alpha: 0.4),
    );

    // 9. THE RIDER (Detailed Delivery Hero)
    final riderPaint = Paint()
      ..color = isDark ? const Color(0xFF0F172A) : const Color(0xFF334155)
      ..style = PaintingStyle.fill;
    
    // Flapping jacket tail animation
    final flapOffset = math.sin(progress * math.pi * 8) * 4.5;
    final flapPath = Path()
      ..moveTo(w * 0.46, h * 0.36)
      ..quadraticBezierTo(w * 0.39, h * 0.38 + flapOffset, w * 0.34, h * 0.40 + flapOffset)
      ..quadraticBezierTo(w * 0.40, h * 0.44 + flapOffset, w * 0.46, h * 0.45)
      ..close();
    canvas.drawPath(flapPath, riderPaint);
    canvas.drawPath(flapPath, paintOutline);

    // Rider Torso/Jacket
    final riderPath = Path()
      ..moveTo(w * 0.46, h * 0.50)
      ..lineTo(w * 0.53, h * 0.28)
      ..lineTo(w * 0.61, h * 0.28)
      ..lineTo(w * 0.55, h * 0.50)
      ..close();
    canvas.drawPath(riderPath, riderPaint);
    canvas.drawPath(riderPath, paintOutline);

    // Jacket Neon detail stripes
    final jacketStripe = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawLine(Offset(w * 0.49, h * 0.39), Offset(w * 0.57, h * 0.39), jacketStripe);

    // 10. HELMET (Sleek sports shape with race stripe)
    final helmetCenter = Offset(w * 0.57, h * 0.18);
    final helmetRadius = w * 0.08;
    canvas.drawCircle(helmetCenter, helmetRadius, paintFill);
    canvas.drawCircle(helmetCenter, helmetRadius, paintOutline);

    // Neon racing stripe on helmet
    final helmetStripePaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2;
    canvas.drawArc(
      Rect.fromCircle(center: helmetCenter, radius: helmetRadius - 1.5),
      math.pi * 0.8,
      math.pi * 0.6,
      false,
      helmetStripePaint,
    );

    // Glossy Cyan Visor
    final paintVisor = Paint()
      ..color = Colors.cyan
      ..style = PaintingStyle.fill;
    final visorPath = Path()
      ..arcTo(
        Rect.fromCircle(center: helmetCenter, radius: helmetRadius),
        -math.pi / 8,
        math.pi / 2.8,
        false,
      )
      ..lineTo(helmetCenter.dx + helmetRadius * 0.25, helmetCenter.dy + helmetRadius * 0.25)
      ..close();
    canvas.drawPath(visorPath, paintVisor);
    canvas.drawPath(visorPath, paintOutline);

    // Gloss white reflection spark on visor
    final visorSpark = Paint()
      ..color = Colors.white.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawArc(
      Rect.fromCircle(center: helmetCenter, radius: helmetRadius - 1.0),
      -math.pi / 16,
      math.pi / 6,
      false,
      visorSpark,
    );

    // Rider Arm leaning to steer
    final paintArm = Paint()
      ..color = isDark ? const Color(0xFF0F172A) : const Color(0xFF334155)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 4.5;
    final armPath = Path()
      ..moveTo(w * 0.53, h * 0.31)
      ..lineTo(w * 0.62, h * 0.34)
      ..lineTo(w * 0.70, h * 0.28);
    canvas.drawPath(armPath, paintArm);
    canvas.drawPath(armPath, paintOutline);

    // Grip point/Hand
    canvas.drawCircle(Offset(w * 0.70, h * 0.28), 3, paintFill);

    // Rider Leg
    final legPaint = Paint()
      ..color = isDark ? const Color(0xFF0F172A) : const Color(0xFF334155)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 4.5;
    final legPath = Path()
      ..moveTo(w * 0.48, h * 0.50)
      ..lineTo(w * 0.55, h * 0.62)
      ..lineTo(w * 0.55, h * 0.76);
    canvas.drawPath(legPath, legPaint);
    canvas.drawPath(legPath, paintOutline);

    // 11. HEADLIGHT LENS
    final headlightLens = Paint()
      ..color = const Color(0xFFFFD166)
      ..style = PaintingStyle.fill;
    final headlightRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * 0.77, h * 0.42, w * 0.81, h * 0.47),
      Radius.circular(w * 0.01),
    );
    canvas.drawRRect(headlightRect, headlightLens);
    canvas.drawRRect(headlightRect, paintOutline);
  }

  @override
  bool shouldRepaint(covariant _ScooterBodyPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.primaryColor != primaryColor ||
        oldDelegate.secondaryColor != secondaryColor ||
        oldDelegate.isDark != isDark;
  }
}

class _WheelPainter extends CustomPainter {
  final Color color;
  final bool isDark;

  _WheelPainter({required this.color, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Tire Paint (thick slate/charcoal rubber)
    final paintTire = Paint()
      ..color = isDark ? const Color(0xFF1E293B) : const Color(0xFF475569)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.8;

    // Alloy rim paint
    final paintRim = Paint()
      ..color = const Color(0xFF10B981) // WayDrop bright green rim stripe
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Inner rim base
    final paintRimBase = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Hub center
    final paintHub = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // Draw tire
    canvas.drawCircle(center, radius - 2.4, paintTire);
    // Draw rim outlines
    canvas.drawCircle(center, radius - 4.8, paintRim);
    canvas.drawCircle(center, radius - 6.0, paintRimBase);
    // Draw hub
    canvas.drawCircle(center, radius * 0.22, paintHub);

    // Silver disc brake rotor (metallic details)
    final paintDisc = Paint()
      ..color = isDark ? const Color(0xFF64748B) : const Color(0xFFCBD5E1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, radius * 0.45, paintDisc);

    // Draw Spokes (5 detailed Y-shaped alloy spokes)
    final paintSpoke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < 5; i++) {
      final angle = i * 2 * math.pi / 5;
      final start = center + Offset(math.cos(angle) * (radius * 0.22), math.sin(angle) * (radius * 0.22));
      final split = center + Offset(math.cos(angle) * (radius * 0.55), math.sin(angle) * (radius * 0.55));
      final end1 = center + Offset(math.cos(angle - 0.16) * (radius - 6.5), math.sin(angle - 0.16) * (radius - 6.5));
      final end2 = center + Offset(math.cos(angle + 0.16) * (radius - 6.5), math.sin(angle + 0.16) * (radius - 6.5));
      
      canvas.drawLine(start, split, paintSpoke);
      canvas.drawLine(split, end1, paintSpoke);
      canvas.drawLine(split, end2, paintSpoke);
    }
  }

  @override
  bool shouldRepaint(covariant _WheelPainter oldDelegate) => false;
}

class _HeadlightBeamPainter extends CustomPainter {
  final Color color;

  _HeadlightBeamPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Volumetric beam cone
    final path = Path()
      ..moveTo(0, h * 0.5) // Starts at headlight center
      ..lineTo(w, h * 0.1) // Upper beam
      ..lineTo(w, h * 0.9) // Lower beam
      ..close();

    // Dual-gradient paint to give a volumetric light feel
    final paintBeam = Paint()
      ..shader = LinearGradient(
        colors: [
          color.withValues(alpha: 0.35),
          color.withValues(alpha: 0.12),
          Colors.transparent,
        ],
        stops: const [0.0, 0.4, 1.0],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(Rect.fromLTRB(0, 0, w, h))
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, paintBeam);

    // Draw a bright hot-spot core beam close to the headlight
    final corePath = Path()
      ..moveTo(0, h * 0.5)
      ..lineTo(w * 0.4, h * 0.3)
      ..lineTo(w * 0.4, h * 0.7)
      ..close();

    final paintCore = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0.6),
          color.withValues(alpha: 0.25),
          Colors.transparent,
        ],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(Rect.fromLTRB(0, 0, w * 0.4, h))
      ..style = PaintingStyle.fill;

    canvas.drawPath(corePath, paintCore);
  }

  @override
  bool shouldRepaint(covariant _HeadlightBeamPainter oldDelegate) => oldDelegate.color != color;
}

class _GroundAndSpeedPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color speedColor;

  _GroundAndSpeedPainter({
    required this.progress,
    required this.color,
    required this.speedColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // 1. Sleek road base
    final roadPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    // Road dashed line
    final dashWidth = w * 0.15;
    final spaceWidth = w * 0.08;
    final totalWidth = dashWidth + spaceWidth;
    final offset = progress * totalWidth;

    double startX = -offset;
    while (startX < w) {
      if (startX + dashWidth > 0) {
        canvas.drawLine(
          Offset(startX, h * 0.6),
          Offset(math.min(startX + dashWidth, w), h * 0.6),
          roadPaint,
        );
      }
      startX += totalWidth;
    }

    // 2. Parallax Speed Streaks (sleek wind trails)
    // Level 1: Background slow streaks
    final List<Map<String, double>> slowStreaks = [
      {'x': 0.15, 'y': 0.15, 'len': 0.18},
      {'x': 0.65, 'y': 0.30, 'len': 0.12},
      {'x': 0.85, 'y': 0.75, 'len': 0.14},
    ];
    for (var streak in slowStreaks) {
      final startX = ((streak['x']! - (progress * 0.4)) % 1.0) * w;
      final len = streak['len']! * w;
      _drawSpeedLine(canvas, startX, h * streak['y']!, len, speedColor.withValues(alpha: 0.15), 1.0);
    }

    // Level 2: Mid-speed streaks
    final List<Map<String, double>> midStreaks = [
      {'x': 0.45, 'y': 0.22, 'len': 0.22},
      {'x': 0.05, 'y': 0.45, 'len': 0.28},
      {'x': 0.75, 'y': 0.68, 'len': 0.16},
    ];
    for (var streak in midStreaks) {
      final startX = ((streak['x']! - (progress * 0.8)) % 1.0) * w;
      final len = streak['len']! * w;
      _drawSpeedLine(canvas, startX, h * streak['y']!, len, speedColor.withValues(alpha: 0.35), 1.6);
    }

    // Level 3: Foreground fast particle speed specks
    final List<Map<String, double>> particles = [
      {'x': 0.3, 'y': 0.12, 'r': 1.8},
      {'x': 0.9, 'y': 0.26, 'r': 1.2},
      {'x': 0.1, 'y': 0.38, 'r': 2.2},
      {'x': 0.7, 'y': 0.52, 'r': 1.5},
      {'x': 0.5, 'y': 0.78, 'r': 2.0},
    ];
    final particlePaint = Paint()..style = PaintingStyle.fill;
    for (var p in particles) {
      final startX = ((p['x']! - (progress * 1.6)) % 1.0) * w;
      particlePaint.color = speedColor.withValues(alpha: 0.5);
      canvas.drawCircle(Offset(startX, h * p['y']!), p['r']!, particlePaint);
    }
  }

  void _drawSpeedLine(Canvas canvas, double x, double y, double length, Color color, double strokeWidth) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    paint.shader = LinearGradient(
      colors: [color.withValues(alpha: 0.0), color, color.withValues(alpha: 0.0)],
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    ).createShader(Rect.fromLTRB(x, y, x + length, y + 2));

    canvas.drawLine(Offset(x, y), Offset(x + length, y), paint);
  }

  @override
  bool shouldRepaint(covariant _GroundAndSpeedPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.speedColor != speedColor;
}


