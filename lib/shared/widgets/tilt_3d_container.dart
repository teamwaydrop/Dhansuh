import 'dart:math' as math;
import 'package:flutter/material.dart';

class Tilt3DContainer extends StatefulWidget {
  final Widget child;
  final double maxTilt; // Max tilt in degrees
  final double scaleOnTouch; // Scale amount on press
  final VoidCallback onTap;

  const Tilt3DContainer({
    super.key,
    required this.child,
    this.maxTilt = 6.0,
    this.scaleOnTouch = 1.015,
    required this.onTap,
  });

  @override
  State<Tilt3DContainer> createState() => _Tilt3DContainerState();
}

class _Tilt3DContainerState extends State<Tilt3DContainer> with SingleTickerProviderStateMixin {
  late AnimationController _springController;
  
  double _tiltX = 0.0;
  double _tiltY = 0.0;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _springController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..addListener(() {
        setState(() {
          // Smoothly interpolate back to flat state (0.0)
          final progress = _springController.value;
          _tiltX = _tiltX * (1.0 - progress);
          _tiltY = _tiltY * (1.0 - progress);
        });
      });
  }

  @override
  void dispose() {
    _springController.dispose();
    super.dispose();
  }

  void _onPanUpdate(DragUpdateDetails details, Size size) {
    if (size.width == 0 || size.height == 0) return;

    final centerX = size.width / 2;
    final centerY = size.height / 2;

    final touchX = details.localPosition.dx.clamp(0.0, size.width);
    final touchY = details.localPosition.dy.clamp(0.0, size.height);

    // Normalized coordinates from -1.0 to 1.0
    final normX = (touchX - centerX) / centerX;
    final normY = (touchY - centerY) / centerY;

    setState(() {
      final double maxTiltRad = widget.maxTilt * math.pi / 180.0;
      // Tilt along X based on Y coordinate, tilt along Y based on X coordinate
      _tiltX = normY * maxTiltRad;
      _tiltY = -normX * maxTiltRad;
    });
  }

  void _onPress() {
    _springController.stop();
    setState(() {
      _isPressed = true;
    });
  }

  void _onRelease() {
    setState(() {
      _isPressed = false;
    });
    _springController.reset();
    _springController.forward();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final cardWidth = size.width - 40.0;
    final estimatedSize = Size(cardWidth > 0 ? cardWidth : 350.0, 180.0);

    return GestureDetector(
      onTapDown: (_) => _onPress(),
      onTapUp: (_) => _onRelease(),
      onTapCancel: () => _onRelease(),
      onPanDown: (_) => _onPress(),
      onPanUpdate: (details) {
        final renderBox = context.findRenderObject() as RenderBox?;
        final actualSize = renderBox?.size ?? estimatedSize;
        _onPanUpdate(details, actualSize);
      },
      onPanEnd: (_) => _onRelease(),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _isPressed ? widget.scaleOnTouch : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        child: Transform(
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0015) // Subtle 3D perspective distortion
            ..rotateX(_tiltX)
            ..rotateY(_tiltY),
          alignment: FractionalOffset.center,
          child: widget.child,
        ),
      ),
    );
  }
}
