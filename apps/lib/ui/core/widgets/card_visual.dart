import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/card_visual_theme.dart';

Future<void> precacheCardVisualShaders() => _SilkRibbonProgram.load();

abstract final class _SilkRibbonProgram {
  static Future<ui.FragmentProgram>? _program;
  static ui.FragmentProgram? _loaded;

  static Future<ui.FragmentProgram> load() {
    final ui.FragmentProgram? loaded = _loaded;
    if (loaded != null) return Future<ui.FragmentProgram>.value(loaded);
    return _program ??=
        ui.FragmentProgram.fromAsset('shaders/silk_ribbons.frag').then((
          ui.FragmentProgram program,
        ) {
          _loaded = program;
          return program;
        });
  }

  static ui.FragmentShader? createShader() => _loaded?.fragmentShader();
}

class CardVisual extends StatefulWidget {
  const CardVisual({
    super.key,
    required this.spec,
    this.active = false,
    this.entranceExtent = 0.07,
    this.entranceDuration = const Duration(milliseconds: 900),
    this.intensity = 1,
    this.cornerIcon,
    this.cornerIconSize = 38,
    this.accentColors = const <Color>[],
  });

  final CardVisualSpec spec;
  final bool active;
  final double entranceExtent;
  final Duration entranceDuration;
  final double intensity;
  final IconData? cornerIcon;
  final double cornerIconSize;
  final List<Color> accentColors;

  @override
  State<CardVisual> createState() => _CardVisualState();
}

class _CardVisualState extends State<CardVisual>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: widget.spec.duration,
  );
  bool _reduceMotion = false;
  bool _entered = false;
  bool _repeating = false;
  bool _loadingSilkShader = false;
  ui.FragmentShader? _silkShader = _SilkRibbonProgram.createShader();
  Object? _silkShaderError;
  StackTrace? _silkShaderStack;

  @override
  void initState() {
    super.initState();
    _ensureSilkShader();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(covariant CardVisual oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureSilkShader();
    if (oldWidget.spec.duration != widget.spec.duration) {
      _motion.duration = widget.spec.duration;
      if (_repeating) {
        _motion.stop();
        _repeating = false;
      }
    }
    if (oldWidget.active != widget.active) {
      _syncMotion(settle: !widget.active);
    } else {
      _syncMotion();
    }
  }

  void _syncMotion({bool settle = false}) {
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (!widget.spec.showFlow || _reduceMotion) {
      _repeating = false;
      _motion.stop();
      _motion.value = 0;
      return;
    }
    if (!TickerMode.valuesOf(context).enabled) {
      _repeating = false;
      _motion.stop();
      return;
    }
    if (widget.active) {
      if (!_repeating) {
        _repeating = true;
        _motion.repeat();
      }
      return;
    }
    _repeating = false;
    if (settle) {
      _motion.animateTo(
        math.min(1, _motion.value + 0.05),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    if (!_entered) {
      _entered = true;
      _motion.animateTo(
        widget.entranceExtent.clamp(0, 1),
        duration: widget.entranceDuration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _silkShader?.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Object? shaderError = _silkShaderError;
    if (shaderError != null) {
      Error.throwWithStackTrace(
        shaderError,
        _silkShaderStack ?? StackTrace.current,
      );
    }
    final double intensity = widget.intensity.clamp(0, 1);
    final CardVisualSpec spec = intensity == 1
        ? widget.spec
        : widget.spec.copyWith(
            opacity: widget.spec.opacity * intensity,
            assetOpacity: widget.spec.assetOpacity * intensity,
            cornerIconOpacity: widget.spec.cornerIconOpacity * intensity,
          );
    final String? assetName = _reduceMotion && spec.assetAnimated
        ? spec.reducedMotionAssetName
        : spec.assetName;
    final IconData? icon = widget.cornerIcon ?? spec.cornerIcon;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (spec.showFlow)
                AnimatedOpacity(
                  opacity:
                      spec.shape != CardFlowShape.tide || _silkShader != null
                      ? 1
                      : 0,
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  child: spec.shape == CardFlowShape.tide && _silkShader == null
                      ? const SizedBox.expand()
                      : CustomPaint(
                          painter: spec.shape == CardFlowShape.tide
                              ? _SilkRibbonPainter(
                                  spec: spec,
                                  motion: _motion,
                                  shader: _silkShader!,
                                  accentColors: widget.accentColors,
                                )
                              : _CardFlowPainter(spec: spec, motion: _motion),
                          isComplex: false,
                          willChange: _motion.isAnimating,
                        ),
                ),
              if (assetName != null)
                Opacity(
                  opacity: spec.assetOpacity,
                  child: Image.asset(
                    assetName,
                    fit: spec.assetFit,
                    alignment: spec.assetAlignment,
                    excludeFromSemantics: true,
                    gaplessPlayback: true,
                  ),
                ),
              if (icon != null)
                Align(
                  alignment: spec.cornerIconAlignment,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      icon,
                      size: widget.cornerIconSize,
                      color: spec.colors.first.withValues(
                        alpha: spec.cornerIconOpacity,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _ensureSilkShader() async {
    if (widget.spec.shape != CardFlowShape.tide ||
        _silkShader != null ||
        _loadingSilkShader) {
      return;
    }
    _loadingSilkShader = true;
    try {
      final ui.FragmentProgram program = await _SilkRibbonProgram.load();
      if (!mounted) return;
      setState(() {
        _loadingSilkShader = false;
        _silkShader = program.fragmentShader();
      });
    } on Object catch (error, stack) {
      if (!mounted) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'card visual shader',
          ),
        );
        return;
      }
      setState(() {
        _loadingSilkShader = false;
        _silkShaderError = error;
        _silkShaderStack = stack;
      });
    }
  }
}

class _SilkRibbonPainter extends CustomPainter {
  _SilkRibbonPainter({
    required this.spec,
    required this.motion,
    required this.shader,
    required this.accentColors,
  }) : super(repaint: motion);

  final CardVisualSpec spec;
  final Animation<double> motion;
  final ui.FragmentShader shader;
  final List<Color> accentColors;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, motion.value * math.pi * 2)
      ..setFloat(3, math.min(1, spec.opacity * 2.5))
      ..setFloat(4, spec.amplitude.clamp(0, 1))
      ..setFloat(5, spec.phase * math.pi * 2)
      ..setFloat(6, spec.reverse ? -1 : 1);
    _setColor(7, spec.colors[0]);
    _setColor(10, spec.colors[1 % spec.colors.length]);
    _setColor(13, spec.colors[2 % spec.colors.length]);
    shader.setFloat(16, math.min(5, accentColors.length).toDouble());
    for (int index = 0; index < 5; index++) {
      _setColor(
        17 + (index * 3),
        index < accentColors.length
            ? accentColors[index]
            : spec.colors[index % spec.colors.length],
      );
    }
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  void _setColor(int index, Color color) {
    shader
      ..setFloat(index, color.r)
      ..setFloat(index + 1, color.g)
      ..setFloat(index + 2, color.b);
  }

  @override
  bool shouldRepaint(covariant _SilkRibbonPainter oldDelegate) =>
      oldDelegate.spec != spec ||
      oldDelegate.shader != shader ||
      oldDelegate.accentColors != accentColors;
}

class _CardFlowPainter extends CustomPainter {
  _CardFlowPainter({required this.spec, required this.motion})
    : super(repaint: motion);

  final CardVisualSpec spec;
  final Animation<double> motion;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || spec.colors.isEmpty) return;
    final double direction = spec.reverse ? -1 : 1;
    final double t = (motion.value * direction + spec.phase) * math.pi * 2;
    _paintLeadingGlow(canvas, size, t);
    switch (spec.shape) {
      case CardFlowShape.ribbon:
        _paintRibbons(canvas, size, t);
      case CardFlowShape.tide:
        _paintTides(canvas, size, t);
      case CardFlowShape.bloom:
        _paintBlooms(canvas, size, t);
    }
  }

  void _paintLeadingGlow(Canvas canvas, Size size, double t) {
    final Offset focus = spec.focus.alongSize(size);
    final double drift = size.width * 0.08 * spec.amplitude;
    final Offset center = focus.translate(
      math.cos(t * 0.7) * drift,
      math.sin(t * 0.55) * size.height * 0.1,
    );
    final double radius = math.max(size.width, size.height) * 0.62;
    final Paint paint = Paint()
      ..shader = RadialGradient(
        colors: <Color>[
          spec.colors.first.withValues(alpha: spec.opacity * 0.72),
          spec.colors[1 % spec.colors.length].withValues(
            alpha: spec.opacity * 0.24,
          ),
          Colors.transparent,
        ],
        stops: const <double>[0, 0.38, 1],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  void _paintRibbons(Canvas canvas, Size size, double t) {
    final Rect bounds = Offset.zero & size;
    for (int index = 0; index < 3; index++) {
      final double y = size.height * (0.08 + index * 0.29);
      final double wave = size.height * (0.12 + index * 0.015) * spec.amplitude;
      final double phase = t + index * 1.7;
      final double thickness = size.height * (0.19 - index * 0.025);
      final Path path = Path()
        ..moveTo(-size.width * 0.1, y + math.sin(phase) * wave)
        ..cubicTo(
          size.width * 0.22,
          y + math.sin(phase + 1.1) * wave,
          size.width * 0.62,
          y + math.sin(phase + 2.2) * wave,
          size.width * 1.1,
          y + math.sin(phase + 3.2) * wave,
        )
        ..lineTo(
          size.width * 1.1,
          y + thickness + math.sin(phase + 3.45) * wave,
        )
        ..cubicTo(
          size.width * 0.68,
          y + thickness + math.sin(phase + 2.45) * wave,
          size.width * 0.28,
          y + thickness + math.sin(phase + 1.35) * wave,
          -size.width * 0.1,
          y + thickness + math.sin(phase + 0.25) * wave,
        )
        ..close();
      final Color color = spec.colors[index % spec.colors.length];
      final Color next = spec.colors[(index + 1) % spec.colors.length];
      final Paint paint = Paint()
        ..shader = LinearGradient(
          begin: spec.reverse ? Alignment.centerRight : Alignment.centerLeft,
          end: spec.reverse ? Alignment.centerLeft : Alignment.centerRight,
          colors: <Color>[
            Colors.transparent,
            color.withValues(alpha: spec.opacity * 0.68),
            next.withValues(alpha: spec.opacity * 0.42),
            Colors.transparent,
          ],
          stops: const <double>[0, 0.22, 0.64, 1],
        ).createShader(bounds);
      canvas.drawPath(path, paint);
    }
  }

  void _paintTides(Canvas canvas, Size size, double t) {
    final Rect bounds = Offset.zero & size;
    const int samples = 48;
    for (int index = 0; index < 3; index++) {
      final double baseY = size.height * (0.28 + index * 0.22);
      final double wave = size.height * (0.16 + index * 0.012) * spec.amplitude;
      final double thickness = size.height * (0.24 + index * 0.015);
      final double phase = t * (0.42 + index * 0.025) + index * 0.92;
      final List<Offset> upper = <Offset>[];
      final List<Offset> lower = <Offset>[];
      for (int sample = 0; sample < samples; sample++) {
        final double progress = sample / (samples - 1);
        final double x = size.width * (-0.12 + progress * 1.24);
        final double angle =
            phase + progress * math.pi * 2 * (0.92 + index * 0.055);
        final double center =
            baseY +
            math.sin(angle) * wave +
            math.sin(angle * 1.65 + index) * size.height * 0.025;
        final double halfWidth =
            thickness * (0.42 + math.sin(angle * 0.55 + index * 0.7) * 0.08);
        upper.add(Offset(x, center - halfWidth));
        lower.add(Offset(x, center + halfWidth));
      }
      final Path path = Path()..moveTo(upper.first.dx, upper.first.dy);
      for (final Offset point in upper.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      for (final Offset point in lower.reversed) {
        path.lineTo(point.dx, point.dy);
      }
      path.close();
      final Color color = spec.colors[index % spec.colors.length];
      final Color next = spec.colors[(index + 1) % spec.colors.length];
      final Color last = spec.colors[(index + 2) % spec.colors.length];
      final Alignment begin = spec.reverse
          ? Alignment.centerRight
          : Alignment.centerLeft;
      final Alignment end = spec.reverse
          ? Alignment.centerLeft
          : Alignment.centerRight;
      final Paint fill = Paint()
        ..shader = LinearGradient(
          begin: begin,
          end: end,
          colors: <Color>[
            Colors.transparent,
            color.withValues(alpha: spec.opacity * 0.7),
            next.withValues(alpha: spec.opacity * 0.94),
            last.withValues(alpha: spec.opacity * 0.62),
            Colors.transparent,
          ],
          stops: const <double>[0, 0.16, 0.48, 0.8, 1],
        ).createShader(bounds);
      canvas.drawPath(path, fill);
    }
  }

  void _paintBlooms(Canvas canvas, Size size, double t) {
    final double radius = math.max(size.width, size.height) * 0.48;
    for (int index = 0; index < 3; index++) {
      final double phase = t * (0.52 + index * 0.08) + index * 2.1;
      final Offset base = switch (index) {
        0 => spec.focus.alongSize(size),
        1 => Alignment(-spec.focus.x, spec.focus.y * 0.35).alongSize(size),
        _ => Alignment(spec.focus.x * 0.2, -spec.focus.y).alongSize(size),
      };
      final Offset center = base.translate(
        math.cos(phase) * size.width * 0.12 * spec.amplitude,
        math.sin(phase * 0.84) * size.height * 0.2 * spec.amplitude,
      );
      final Rect oval = Rect.fromCenter(
        center: center,
        width: radius * (1.28 + index * 0.16),
        height: radius * (0.56 + index * 0.08),
      );
      final Color color = spec.colors[index % spec.colors.length];
      final Paint paint = Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.18),
          radius: 0.92,
          colors: <Color>[
            color.withValues(alpha: spec.opacity * (0.78 - index * 0.1)),
            color.withValues(alpha: spec.opacity * 0.24),
            Colors.transparent,
          ],
          stops: const <double>[0, 0.48, 1],
        ).createShader(oval);
      canvas.drawOval(oval, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _CardFlowPainter oldDelegate) =>
      oldDelegate.spec != spec;
}
