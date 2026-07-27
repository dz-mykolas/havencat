import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A minimal backdrop of two faint ambient glows that drift while the
/// assistant is generating and fade away when idle.
class AnimatedBackground extends StatefulWidget {
  const AnimatedBackground({super.key, required this.active});

  final bool active;

  @override
  State<AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<AnimatedBackground>
    with TickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: Duration(seconds: 36),
  );

  late final AnimationController _intensity = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 900),
  );

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
            return SizedBox.expand();
          }
          return CustomPaint(
            isComplex: true,
            painter: _BackgroundPainter(
              motion: _motion.value,
              intensity: intensity,
              colors: context.appColors,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _Blob {
  _Blob({required this.color, required this.center, required this.radius});

  final Color color;
  final Offset center;
  final double radius;
}

class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter({
    required this.motion,
    required this.intensity,
    required this.colors,
  });

  final double motion;
  final double intensity;
  final AppThemeColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = motion * 2 * math.pi;
    final double shortest = size.shortestSide;
    final List<_Blob> blobs = _blobsFor(size, t, shortest);

    _paintBlobs(canvas, blobs);
  }

  List<_Blob> _blobsFor(Size size, double t, double shortest) {
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

    final double r = shortest * 0.82;
    return <_Blob>[
      _Blob(
        color: colors.brandBlue,
        center: drift(0.24, 0.32, 0.12, 0.10, 0.72, 0.0),
        radius: r,
      ),
      _Blob(
        color: colors.brandViolet,
        center: drift(0.76, 0.68, 0.10, 0.12, 0.58, 2.4),
        radius: r * 0.9,
      ),
    ];
  }

  void _paintBlobs(Canvas canvas, List<_Blob> blobs) {
    const double peakAlpha = 0.055;
    for (final _Blob blob in blobs) {
      final Paint paint = Paint()
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

  @override
  bool shouldRepaint(_BackgroundPainter oldDelegate) =>
      oldDelegate.motion != motion || oldDelegate.intensity != intensity;
}
