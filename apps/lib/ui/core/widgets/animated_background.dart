import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A subtle, living backdrop of drifting gradient "blobs" with twinkling stars
/// that light up as a blob passes over them.
///
/// The effect ramps in while [active] (i.e. while the assistant is generating)
/// and gently fades back out when idle. The blobs are mostly transparent
/// (~90%) so they read as ambient color rather than solid shapes; stars peak
/// around 40-60% opacity and only shine where a blob overlaps them.
class AnimatedBackground extends StatefulWidget {
  const AnimatedBackground({super.key, required this.active});

  final bool active;

  @override
  State<AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<AnimatedBackground>
    with TickerProviderStateMixin {
  // Drives the continuous drift of blobs and the twinkle of stars.
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );

  // Ramps the whole effect in and out so it doesn't pop on/off abruptly.
  late final AnimationController _intensity = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  late final List<_Star> _stars = _buildStars(46);

  @override
  void initState() {
    super.initState();
    _intensity.addStatusListener(_onIntensityStatus);
    if (widget.active) {
      _motion.repeat();
      _intensity.forward();
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active == widget.active) return;
    if (widget.active) {
      if (!_motion.isAnimating) _motion.repeat();
      _intensity.forward();
    } else {
      _intensity.reverse();
    }
  }

  void _onIntensityStatus(AnimationStatus status) {
    // Stop the (otherwise endless) motion controller once fully faded out to
    // avoid burning frames while idle.
    if (status == AnimationStatus.dismissed) {
      _motion.stop();
    }
  }

  static List<_Star> _buildStars(int count) {
    final math.Random rng = math.Random(42);
    return List<_Star>.generate(count, (int i) {
      return _Star(
        position: Offset(rng.nextDouble(), rng.nextDouble()),
        radius: 0.7 + rng.nextDouble() * 1.6,
        phase: rng.nextDouble() * math.pi * 2,
        twinkleSpeed: 0.6 + rng.nextDouble() * 1.4,
      );
    });
  }

  @override
  void dispose() {
    _intensity.removeStatusListener(_onIntensityStatus);
    _motion.dispose();
    _intensity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[_motion, _intensity]),
        builder: (BuildContext context, _) {
          final double intensity = Curves.easeInOut.transform(_intensity.value);
          if (intensity <= 0.001) {
            return const SizedBox.expand();
          }
          return CustomPaint(
            isComplex: true,
            painter: _BackgroundPainter(
              motion: _motion.value,
              intensity: intensity,
              stars: _stars,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _Star {
  const _Star({
    required this.position,
    required this.radius,
    required this.phase,
    required this.twinkleSpeed,
  });

  /// Normalized position in the [0, 1] x [0, 1] space.
  final Offset position;
  final double radius;
  final double phase;
  final double twinkleSpeed;
}

class _Blob {
  const _Blob({
    required this.color,
    required this.center,
    required this.radius,
  });

  final Color color;
  final Offset center;
  final double radius;
}

class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter({
    required this.motion,
    required this.intensity,
    required this.stars,
  });

  final double motion;
  final double intensity;
  final List<_Star> stars;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = motion * 2 * math.pi;
    final double shortest = size.shortestSide;
    final List<_Blob> blobs = _blobsFor(size, t, shortest);

    _paintBlobs(canvas, size, blobs);
    _paintStars(canvas, size, blobs, shortest);
  }

  List<_Blob> _blobsFor(Size size, double t, double shortest) {
    // Each blob drifts along its own slow elliptical path.
    Offset drift(
      double cx,
      double cy,
      double ax,
      double ay,
      double speed,
      double phase,
    ) {
      return Offset(
        size.width * cx + ax * shortest * math.cos(t * speed + phase),
        size.height * cy + ay * shortest * math.sin(t * speed * 0.8 + phase),
      );
    }

    final double r = shortest * 0.62;
    return <_Blob>[
      _Blob(
        color: AppTheme.brandBlue,
        center: drift(0.28, 0.30, 0.18, 0.14, 1.0, 0.0),
        radius: r,
      ),
      _Blob(
        color: AppTheme.brandViolet,
        center: drift(0.72, 0.45, 0.16, 0.20, 0.85, 2.1),
        radius: r * 1.1,
      ),
      _Blob(
        color: AppTheme.brandPink,
        center: drift(0.50, 0.78, 0.22, 0.16, 1.15, 4.0),
        radius: r * 0.95,
      ),
    ];
  }

  void _paintBlobs(Canvas canvas, Size size, List<_Blob> blobs) {
    // ~90% transparent: a low peak alpha keeps the blobs ambient.
    const double peakAlpha = 0.16;
    for (final _Blob blob in blobs) {
      final Paint paint = Paint()
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blob.radius * 0.55)
        ..shader =
            RadialGradient(
              colors: <Color>[
                blob.color.withValues(alpha: peakAlpha * intensity),
                blob.color.withValues(alpha: 0.0),
              ],
            ).createShader(
              Rect.fromCircle(center: blob.center, radius: blob.radius),
            );
      canvas.drawCircle(blob.center, blob.radius, paint);
    }
  }

  void _paintStars(
    Canvas canvas,
    Size size,
    List<_Blob> blobs,
    double shortest,
  ) {
    final double t = motion * 2 * math.pi;
    final Paint paint = Paint()..style = PaintingStyle.fill;

    for (final _Star star in stars) {
      final Offset p = Offset(
        star.position.dx * size.width,
        star.position.dy * size.height,
      );

      // A star only shines where a blob overlaps it; closer to a blob center
      // means brighter.
      double proximity = 0.0;
      for (final _Blob blob in blobs) {
        final double d = (p - blob.center).distance;
        final double reach = blob.radius * 0.85;
        if (d < reach) {
          proximity = math.max(proximity, 1.0 - d / reach);
        }
      }
      if (proximity <= 0.0) continue;

      final double twinkle =
          0.45 +
          0.55 * (0.5 + 0.5 * math.sin(t * star.twinkleSpeed + star.phase));
      // Cap around 0.6 so stars stay translucent (40-60%).
      final double alpha = (proximity * twinkle * 0.6 * intensity).clamp(
        0.0,
        0.6,
      );
      if (alpha <= 0.01) continue;

      final double radius = star.radius * (0.7 + 0.5 * proximity);
      paint.color = Colors.white.withValues(alpha: alpha);
      _drawSparkle(canvas, p, radius, paint);
    }
  }

  /// A small four-point sparkle: a bright core plus thin cross rays.
  void _drawSparkle(Canvas canvas, Offset center, double radius, Paint paint) {
    canvas.drawCircle(center, radius * 0.8, paint);
    final double ray = radius * 2.6;
    final Paint rayPaint = Paint()
      ..color = paint.color.withValues(alpha: paint.color.a * 0.6)
      ..strokeWidth = math.max(0.6, radius * 0.35)
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      center.translate(-ray, 0),
      center.translate(ray, 0),
      rayPaint,
    );
    canvas.drawLine(
      center.translate(0, -ray),
      center.translate(0, ray),
      rayPaint,
    );
  }

  @override
  bool shouldRepaint(_BackgroundPainter oldDelegate) =>
      oldDelegate.motion != motion || oldDelegate.intensity != intensity;
}
