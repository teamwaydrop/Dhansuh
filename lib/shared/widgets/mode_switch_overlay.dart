import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// State definition for the global switch overlay
class ModeSwitchOverlayState {
  final Future<void> Function() asyncAction;
  final VoidCallback onMidpoint;
  final void Function(Object error) onError;

  ModeSwitchOverlayState({
    required this.asyncAction,
    required this.onMidpoint,
    required this.onError,
  });
}

class ModeSwitchOverlayNotifier extends StateNotifier<ModeSwitchOverlayState?> {
  ModeSwitchOverlayNotifier() : super(null);

  void trigger({
    required Future<void> Function() asyncAction,
    required VoidCallback onMidpoint,
    required void Function(Object error) onError,
  }) {
    state = ModeSwitchOverlayState(
      asyncAction: asyncAction,
      onMidpoint: onMidpoint,
      onError: onError,
    );
  }

  void reset() {
    state = null;
  }
}

final modeSwitchOverlayProvider = StateNotifierProvider<ModeSwitchOverlayNotifier, ModeSwitchOverlayState?>((ref) {
  return ModeSwitchOverlayNotifier();
});

class _MoneyParticle {
  double x;
  double y;
  double speedY;
  double speedX;
  double rotation;
  double rotationSpeed;
  double scale;
  final bool isCoin;
  final double opacity;

  _MoneyParticle({
    required this.x,
    required this.y,
    required this.speedY,
    required this.speedX,
    required this.rotation,
    required this.rotationSpeed,
    required this.scale,
    required this.isCoin,
    required this.opacity,
  });
}

class ModeSwitchOverlay extends ConsumerStatefulWidget {
  final Widget child;
  const ModeSwitchOverlay({super.key, required this.child});

  @override
  ConsumerState<ModeSwitchOverlay> createState() => _ModeSwitchOverlayState();
}

class _ModeSwitchOverlayState extends ConsumerState<ModeSwitchOverlay> with TickerProviderStateMixin {
  late AnimationController _sweepController;
  late AnimationController _revealController;
  late Ticker _ticker;
  
  double _wavePhase = 0.0;
  final List<_MoneyParticle> _particles = [];
  bool _isTransitioning = false;
  
  bool _asyncActionFinished = false;
  bool _asyncActionSuccess = false;
  Object? _asyncActionError;
  ModeSwitchOverlayState? _currentTransition;

  @override
  void initState() {
    super.initState();

    _sweepController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _revealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _ticker = createTicker((elapsed) {
      if (mounted && _isTransitioning) {
        setState(() {
          _wavePhase += 0.06;
          final size = MediaQuery.of(context).size;
          if (size.width > 0 && size.height > 0) {
            _initParticles(size.width, size.height);
            _updatePhysics(size.width, size.height);
          }
        });
      }
    });
  }

  void _initParticles(double width, double height) {
    if (_particles.isNotEmpty) return;
    final rand = math.Random();
    for (int i = 0; i < 50; i++) {
      _particles.add(_MoneyParticle(
        x: rand.nextDouble() * width,
        y: rand.nextDouble() * -height, // start fully off-screen above
        speedY: 4.0 + rand.nextDouble() * 5.0,
        speedX: -2.0 + rand.nextDouble() * 4.0,
        rotation: rand.nextDouble() * math.pi * 2,
        rotationSpeed: -0.08 + rand.nextDouble() * 0.16,
        scale: 0.6 + rand.nextDouble() * 0.8,
        isCoin: rand.nextBool(),
        opacity: 0.7 + rand.nextDouble() * 0.3,
      ));
    }
  }

  void _updatePhysics(double width, double height) {
    final rand = math.Random();
    for (final p in _particles) {
      p.y += p.speedY;
      p.x += p.speedX;
      p.rotation += p.rotationSpeed;
      p.x += math.sin(p.y / 35.0) * 0.8;

      if (p.y > height + 20) {
        p.y = -20;
        p.x = rand.nextDouble() * width;
        p.speedY = 4.0 + rand.nextDouble() * 5.0;
        p.speedX = -2.0 + rand.nextDouble() * 4.0;
        p.rotation = rand.nextDouble() * math.pi * 2;
      }
    }
  }

  void _startTransition(ModeSwitchOverlayState transition) {
    if (_isTransitioning) return;
    
    setState(() {
      _currentTransition = transition;
      _isTransitioning = true;
      _asyncActionFinished = false;
      _asyncActionSuccess = false;
      _asyncActionError = null;
      _particles.clear();
      _wavePhase = 0.0;
    });

    _sweepController.reset();
    _revealController.reset();

    // Start running the ticker
    _ticker.start();

    // Run sweep down
    _sweepController.forward().then((_) {
      _checkCompletion();
    });

    // Run async background tasks
    transition.asyncAction().then((_) {
      if (!mounted) return;
      setState(() {
        _asyncActionFinished = true;
        _asyncActionSuccess = true;
      });
      _checkCompletion();
    }).catchError((err) {
      if (!mounted) return;
      setState(() {
        _asyncActionFinished = true;
        _asyncActionSuccess = false;
        _asyncActionError = err;
      });
      _checkCompletion();
    });
  }

  void _checkCompletion() {
    if (!_sweepController.isCompleted) return;
    if (!_asyncActionFinished) return;

    if (_asyncActionSuccess) {
      // Execute UI/route swap instantly under the curtain
      if (_currentTransition != null) {
        _currentTransition!.onMidpoint();
      }

      // Sweep open (reveal new screen)
      _revealController.forward().then((_) {
        _endTransition();
      });
    } else {
      // Background verification failed
      if (_currentTransition != null) {
        _currentTransition!.onError(_asyncActionError ?? 'Unknown error');
      }

      // Retract the wave back up
      _sweepController.reverse().then((_) {
        _endTransition();
      });
    }
  }

  void _endTransition() {
    if (_ticker.isActive) {
      _ticker.stop();
    }
    setState(() {
      _isTransitioning = false;
      _particles.clear();
      _currentTransition = null;
    });
    ref.read(modeSwitchOverlayProvider.notifier).reset();
  }

  @override
  void dispose() {
    _sweepController.dispose();
    _revealController.dispose();
    if (_ticker.isActive) {
      _ticker.stop();
    }
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Listen to changes in transition overlay request state
    ref.listen<ModeSwitchOverlayState?>(modeSwitchOverlayProvider, (previous, next) {
      if (next != null && next != _currentTransition) {
        _startTransition(next);
      }
    });

    return Stack(
      children: [
        widget.child,
        if (_isTransitioning)
          Positioned.fill(
            child: IgnorePointer(
              // Allow touches through only when not covered/transitioning
              ignoring: false,
              child: AnimatedBuilder(
                animation: Listenable.merge([_sweepController, _revealController]),
                builder: (context, child) {
                  return CustomPaint(
                    painter: _ModeSwitchPainter(
                      sweepDownProgress: _sweepController.value,
                      sweepUpProgress: _revealController.value,
                      wavePhase: _wavePhase,
                      particleOpacity: 1.0 - _revealController.value,
                      particles: _particles,
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _ModeSwitchPainter extends CustomPainter {
  final double sweepDownProgress;
  final double sweepUpProgress;
  final double wavePhase;
  final double particleOpacity;
  final List<_MoneyParticle> particles;

  _ModeSwitchPainter({
    required this.sweepDownProgress,
    required this.sweepUpProgress,
    required this.wavePhase,
    required this.particleOpacity,
    required this.particles,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;
    
    // Wave curvature amplitude
    const double waveAmplitude = 18.0;
    
    // Bottom boundary base height (sweeps down)
    final double yBottomBase = sweepDownProgress * (height + waveAmplitude * 4) - waveAmplitude * 2;
    // Top boundary base height (sweeps down to reveal)
    final double yTopBase = sweepUpProgress * (height + waveAmplitude * 4) - waveAmplitude * 2;
    
    final double yBottomLeft = yBottomBase;
    final double yBottomRight = yBottomBase;
    final double yTopLeft = yTopBase;
    final double yTopRight = yTopBase;

    // Draw the curtain region if there is a visible chunk between top and bottom wave boundary
    if (sweepDownProgress > 0.0 && sweepUpProgress < 1.0) {
      final path = Path();
      
      path.moveTo(0, yTopLeft);
      path.lineTo(0, yBottomLeft);
      
      // Bottom bezier wave front
      path.cubicTo(
        width * 0.35, yBottomLeft + waveAmplitude * math.sin(wavePhase),
        width * 0.65, yBottomRight + waveAmplitude * math.cos(wavePhase),
        width, yBottomRight,
      );
      
      path.lineTo(width, yTopRight);
      
      // Top bezier wave front (shifted phase for liquid sway contrast)
      path.cubicTo(
        width * 0.65, yTopRight + waveAmplitude * math.cos(wavePhase + math.pi),
        width * 0.35, yTopLeft + waveAmplitude * math.sin(wavePhase + math.pi),
        0, yTopLeft,
      );
      
      path.close();

      // Paint curtain background gradient
      final paint = Paint()..style = PaintingStyle.fill;
      final grad = LinearGradient(
        colors: [
          const Color(0xFF1E222B), // deep obsidian
          const Color(0xFF064E3B), // emerald green
          const Color(0xFF022C22), // rich dark green
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      );
      paint.shader = grad.createShader(Rect.fromLTRB(0, math.max(0.0, yTopBase), width, math.min(height, yBottomBase)));
      canvas.drawPath(path, paint);

      // Draw bottom glowing wave edge (lime green)
      final bottomEdgePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..color = const Color(0xFFC5FF30); // Primary lime-green indicator
      
      final bottomEdgePath = Path();
      bottomEdgePath.moveTo(0, yBottomLeft);
      bottomEdgePath.cubicTo(
        width * 0.35, yBottomLeft + waveAmplitude * math.sin(wavePhase),
        width * 0.65, yBottomRight + waveAmplitude * math.cos(wavePhase),
        width, yBottomRight,
      );
      canvas.drawPath(bottomEdgePath, bottomEdgePaint);

      // Draw top glowing wave edge during reveal sweep (gold/metallic)
      if (sweepUpProgress > 0.0) {
        final topEdgePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = const Color(0xFFFFD700); // Gold indicator
        
        final topEdgePath = Path();
        topEdgePath.moveTo(width, yTopRight);
        topEdgePath.cubicTo(
          width * 0.65, yTopRight + waveAmplitude * math.cos(wavePhase + math.pi),
          width * 0.35, yTopLeft + waveAmplitude * math.sin(wavePhase + math.pi),
          0, yTopLeft,
        );
        canvas.drawPath(topEdgePath, topEdgePaint);
      }
    }

    // Paint falling money notes and coins
    if (particleOpacity > 0.0) {
      for (final p in particles) {
        final paint = Paint()..style = PaintingStyle.fill;
        final currentOpacity = p.opacity * particleOpacity;
        if (currentOpacity <= 0.0) continue;

        canvas.save();
        canvas.translate(p.x, p.y);
        canvas.rotate(p.rotation);
        canvas.scale(p.scale);

        if (p.isCoin) {
          final coinColor = const Color(0xFFFFD700).withValues(alpha: currentOpacity);
          final coinAccent = const Color(0xFFDAA520).withValues(alpha: currentOpacity);
          final grad = RadialGradient(
            colors: [coinColor, coinAccent],
            center: Alignment.topLeft,
            radius: 0.8,
          );
          final rect = Rect.fromCircle(center: Offset.zero, radius: 8);
          paint.shader = grad.createShader(rect);
          
          canvas.drawCircle(Offset.zero, 8, paint);
          
          final innerPaint = Paint()
            ..color = const Color(0xFFB45309).withValues(alpha: currentOpacity * 0.6)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8;
          canvas.drawCircle(Offset.zero, 5.5, innerPaint);
        } else {
          final billColor = const Color(0xFF10B981).withValues(alpha: currentOpacity);
          final billAccent = const Color(0xFF047857).withValues(alpha: currentOpacity);
          final grad = LinearGradient(
            colors: [billColor, billAccent],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );
          final rect = Rect.fromCenter(center: Offset.zero, width: 22, height: 11);
          paint.shader = grad.createShader(rect);
          
          canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(2)), paint);
          
          final borderPaint = Paint()
            ..color = const Color(0xFFD1FAE5).withValues(alpha: currentOpacity * 0.5)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.6;
          canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: 18, height: 8), const Radius.circular(1.5)), borderPaint);
        }

        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ModeSwitchPainter oldDelegate) => true;
}
