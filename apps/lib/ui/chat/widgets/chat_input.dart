import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The bottom input bar: a multiline text field inside a pill whose border
/// becomes an animated, rotating brand gradient while the assistant is
/// generating a reply (the "flashing while sending" effect).
class ChatInput extends StatefulWidget {
  const ChatInput({
    super.key,
    required this.textController,
    required this.isGenerating,
    required this.onSend,
  });

  final TextEditingController textController;
  final bool isGenerating;
  final ValueChanged<String> onSend;

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> with TickerProviderStateMixin {
  late final AnimationController _borderController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  /// One-shot pulse that plays whenever the pill is tapped. A single forward
  /// pass drives a diagonal highlight that travels from the bottom-left to the
  /// top-right of the pill. Opacity is eased with `sin(value * π)` so it peaks
  /// mid-flight and is exactly 0 at both endpoints — nothing lingers once the
  /// controller completes.
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );

  final FocusNode _focusNode = FocusNode();
  bool _hasText = false;
  bool _focused = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    widget.textController.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant ChatInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isGenerating != widget.isGenerating) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    if (widget.isGenerating) {
      _borderController.repeat();
    } else {
      _borderController.stop();
      _borderController.value = 0;
    }
  }

  void _onTextChanged() {
    final bool hasText = widget.textController.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus != _focused) {
      setState(() => _focused = _focusNode.hasFocus);
    }
  }

  void _onHoverChanged(bool hovered) {
    if (hovered != _hovered) {
      setState(() => _hovered = hovered);
    }
  }

  void _triggerPulse() {
    // `value` runs 0 → 1; the painter applies `sin(value * π)` so the effect
    // peaks at 0.5 and is exactly 0 again at value == 1 — no lingering.
    _pulseController.forward(from: 0);
  }

  void _submit() {
    final String text = widget.textController.text;
    if (text.trim().isEmpty || widget.isGenerating) return;
    widget.onSend(text);
    widget.textController.clear();
  }

  @override
  void dispose() {
    widget.textController.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _borderController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // On hover the pill grows slightly, with the width increase twice the
    // height increase (Δscale_x = 2 · Δscale_y). Anchored to the bottom so it
    // expands upward and outward from where it sits.
    const double growY = 0.03;
    const double growX = 2 * growY;
    final bool grown = _hovered || _focused;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      transformAlignment: Alignment.bottomCenter,
      transform: grown
          ? Matrix4.diagonal3Values(1 + growX, 1 + growY, 1)
          : Matrix4.identity(),
      child: MouseRegion(
        onEnter: (_) => _onHoverChanged(true),
        onExit: (_) => _onHoverChanged(false),
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _triggerPulse(),
          child: AnimatedBuilder(
            animation: Listenable.merge(<Listenable>[
              _borderController,
              _pulseController,
            ]),
            builder: (BuildContext context, Widget? child) {
              return CustomPaint(
                painter: _GradientBorderPainter(
                  progress: _borderController.value,
                  active: widget.isGenerating,
                  pulse: _pulseController.value,
                ),
                child: child,
              );
            },
            child: Padding(
              padding: const EdgeInsets.all(2.5),
              child: Container(
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(26),
                ),
                padding: const EdgeInsets.fromLTRB(20, 4, 6, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: widget.textController,
                        focusNode: _focusNode,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _submit(),
                        cursorColor: AppTheme.brandViolet,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                          height: 1.4,
                        ),
                        decoration: const InputDecoration(
                          isCollapsed: true,
                          border: InputBorder.none,
                          hintText: 'Message HavenChats',
                          hintStyle: TextStyle(color: AppTheme.textSecondary),
                          contentPadding: EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _SendButton(
                      enabled: _hasText && !widget.isGenerating,
                      onTap: _submit,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: AppTheme.brandGradient,
            ),
            child: const Icon(
              Icons.arrow_upward_rounded,
              size: 20,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the rounded border. When [active], a rotating sweep gradient creates
/// the flashing effect; otherwise a subtle static outline is drawn. When
/// [pulse] > 0, the static outline briefly sweeps once with the brand
/// gradient (a one-shot "light up" effect on tap), without adding any extra
/// rings or padding.
class _GradientBorderPainter extends CustomPainter {
  _GradientBorderPainter({
    required this.progress,
    required this.active,
    required this.pulse,
  });

  final double progress;
  final bool active;
  final double pulse;

  static const double _stroke = 2.5;

  static const List<Color> _sweepColors = <Color>[
    AppTheme.brandBlue,
    AppTheme.brandViolet,
    AppTheme.brandPink,
    AppTheme.brandViolet,
    AppTheme.brandBlue,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final RRect rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(26),
    );
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;

    if (active) {
      paint.shader = SweepGradient(
        startAngle: 0,
        endAngle: 2 * math.pi,
        transform: GradientRotation(progress * 2 * math.pi),
        colors: _sweepColors,
      ).createShader(Offset.zero & size);
    } else {
      // While pulsing (tap), a brand-gradient highlight band travels along the
      // border's bottom-left → top-right diagonal. Its opacity is eased with
      // sin(p·π) (peaking at 60%) so it fades in and out with no lingering: at
      // both endpoints the tint collapses back to the static outline.
      final double p = pulse.clamp(0.0, 1.0);
      final double a = math.sin(p * math.pi) * 0.6;
      if (a > 0) {
        const double half = 0.3;
        Color tint(Color c) => Color.lerp(AppTheme.outline, c, a)!;

        final List<double> stops = <double>[];
        final List<Color> colors = <Color>[];
        void addStop(double s, Color c) {
          double v = s.clamp(0.0, 1.0);
          if (stops.isNotEmpty && v <= stops.last) v = stops.last + 1e-4;
          if (v > 1.0) return;
          stops.add(v);
          colors.add(c);
        }

        addStop(0, AppTheme.outline);
        addStop(p - half, AppTheme.outline);
        addStop(p - half / 2, tint(AppTheme.brandBlue));
        addStop(p, tint(AppTheme.brandViolet));
        addStop(p + half / 2, tint(AppTheme.brandPink));
        addStop(p + half, AppTheme.outline);
        addStop(1, AppTheme.outline);

        paint.shader = LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: colors,
          stops: stops,
        ).createShader(Offset.zero & size);
      } else {
        paint.color = AppTheme.outline;
      }
    }

    canvas.drawRRect(rrect.deflate(_stroke / 2), paint);
  }

  @override
  bool shouldRepaint(_GradientBorderPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.active != active ||
      oldDelegate.pulse != pulse;
}
