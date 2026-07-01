import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../branding.dart';
import '../../../data/services/web_retrieval/web_retrieval.dart';
import '../../core/theme/app_theme.dart';
import 'chat_tools_sheet.dart';
import 'model_selector_bar.dart';

/// The bottom input bar: a multiline text field inside a pill whose border
/// becomes an animated, rotating brand gradient while the assistant is
/// generating a reply (the "flashing while sending" effect).
class ChatInput extends StatefulWidget {
  const ChatInput({
    super.key,
    required this.textController,
    required this.isGenerating,
    required this.onSend,
    required this.toolsEnabled,
    required this.onToggleTools,
    required this.webRetrievalAdapter,
  });

  final TextEditingController textController;
  final bool isGenerating;
  final ValueChanged<String> onSend;
  final bool toolsEnabled;

  /// Called with the new desired enabled value on every toggle.
  final ValueChanged<bool> onToggleTools;
  final WebRetrievalAdapter webRetrievalAdapter;

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> with TickerProviderStateMixin {
  late final AnimationController _borderController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  /// Loops while the input is focused (i.e. the pill is enlarged after a
  /// click). Each forward pass drives a single band of brand color around the
  /// perimeter of the pill; opacity is eased with `sin(value * π)` so it's 0
  /// at both endpoints — when the controller loops from 1 back to 0 the seam
  /// is invisible, and stopping it leaves nothing lingering on the border.
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  );

  final FocusNode _focusNode = FocusNode();
  final GlobalKey _plusButtonKey = GlobalKey();
  bool _hasText = false;
  bool _focused = false;
  bool _hovered = false;
  bool _popoverOpen = false;

  /// Tracks how vigorously the user is typing. Each real keystroke (text grew)
  /// bumps this toward 1; it decays toward 0 each frame at ~0.8/s so a single
  /// keystroke fades in ~0.4s while rapid typing saturates it. Drives the
  /// traveling blink's peak amplitude: `0.4 + 0.6 * intensity` → 40%→100%.
  double _typingIntensity = 0;
  int _lastTextLength = 0;
  DateTime? _lastPulseTime;

  @override
  void initState() {
    super.initState();
    widget.textController.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
    _lastTextLength = widget.textController.text.length;
    _pulseController.addListener(_onPulseTick);
    _syncAnimation();
    _syncPulse();
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
    final String text = widget.textController.text;
    final bool hasText = text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
    // Bump typing intensity on real keystrokes (text grew). Ignores shrinks
    // (backspace) and submit/clear so intentional clears don't brighten.
    final int len = text.length;
    if (len > _lastTextLength) {
      _typingIntensity = (_typingIntensity + 0.05).clamp(0.0, 1.0);
    }
    _lastTextLength = len;
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus != _focused) {
      setState(() => _focused = _focusNode.hasFocus);
      _syncPulse();
    }
  }

  void _onHoverChanged(bool hovered) {
    if (hovered != _hovered) {
      setState(() => _hovered = hovered);
    }
  }

  void _syncPulse() {
    // The blink keeps traveling while the pill is focused (clicked into) and
    // enlarged; it stops the moment focus leaves.
    if (_focused) {
      _pulseController.repeat();
    } else {
      _pulseController.stop();
      _pulseController.value = 0;
      // Reset intensity when the user leaves the field so the next entry
      // starts back at the soft 40% baseline rather than a stale bright state.
      _typingIntensity = 0;
    }
  }

  void _onPulseTick() {
    // Decay typing intensity on the pulse controller's frame ticks (it's
    // already running ~60fps while focused, so we reuse it instead of adding
    // a separate ticker). dt is wall-clock measured so the decay is
    // frame-rate independent.
    final DateTime now = DateTime.now();
    final DateTime? last = _lastPulseTime;
    _lastPulseTime = now;
    if (last == null) return;
    double dt = now.difference(last).inMicroseconds / 1e6;
    if (dt <= 0) return;
    // Clamp rather than skip: a stale frame (tab switch, jank) should still
    // make progress, not freeze intensity at its last bright value.
    if (dt > 0.1) dt = 0.1;
    final double next = _typingIntensity - 0.8 * dt;
    if (next <= 0) {
      _typingIntensity = 0;
    } else {
      _typingIntensity = next;
    }
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
    _pulseController.removeListener(_onPulseTick);
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
    final bool grown = _hovered || _focused || _popoverOpen;
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
                intensity: _typingIntensity,
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
              padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  _PlusButton(
                    key: _plusButtonKey,
                    active: widget.toolsEnabled,
                    popoverOpen: _popoverOpen,
                    onTap: () async {
                      // Guard against re-entry: a tap while the popover is
                      // already open (or opening) is a no-op. Without this,
                      // spamming the button stacks multiple dialogs, each
                      // with its own switch, and their toggles fight.
                      if (_popoverOpen) return;
                      setState(() => _popoverOpen = true);
                      try {
                        await showChatToolsMenu(
                          context: context,
                          enabled: widget.toolsEnabled,
                          onToggle: widget.onToggleTools,
                          adapter: widget.webRetrievalAdapter,
                          anchorKey: _plusButtonKey,
                        );
                      } finally {
                        if (mounted) {
                          setState(() => _popoverOpen = false);
                        }
                      }
                    },
                  ),
                  const SizedBox(width: 8),
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
                        hintText: 'Message $appName',
                        hintStyle: TextStyle(color: AppTheme.textSecondary),
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const ModelSelectorBar(compact: true),
                  const SizedBox(width: 4),
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
    );
  }
}

/// The "+" affordance on the left of the input. When web search is enabled,
/// it lights up with the brand gradient so the user can see at a glance that
/// the next message will pull fresh context from the web.
class _PlusButton extends StatelessWidget {
  const _PlusButton({
    super.key,
    required this.active,
    required this.popoverOpen,
    required this.onTap,
  });

  final bool active;
  final bool popoverOpen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool highlighted = active || popoverOpen;
    return Tooltip(
      message: active ? 'Tools on' : 'Tools',
      child: SizedBox(
        width: 32,
        height: 32,
        child: Material(
          color: highlighted
              ? AppTheme.brandViolet.withValues(alpha: 0.15)
              : Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Icon(
              active ? Icons.travel_explore_rounded : Icons.add_rounded,
              size: 22,
              color: highlighted
                  ? AppTheme.brandViolet
                  : AppTheme.textSecondary,
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
    required this.intensity,
  });

  final double progress;
  final bool active;
  final double pulse;

  /// 0..1 typing vigor. Scales the blink's peak amplitude from a soft 40%
  /// baseline up to 100% as the user types faster.
  final double intensity;

  static const double _stroke = 1.5;

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
      // While pulsing (focused), a single band of brand-gradient light travels
      // around the perimeter of the pill: a sweep centered on the box, with
      // its peak angle driven by `p`. The envelope is eased with sin(p·π); its
      // peak amplitude scales with typing intensity — a soft 40% at idle, up
      // to 100% when the user is typing fast. At both endpoints it collapses
      // back to the static outline, and the seam at angle 0 stays invisible
      // because the two boundary stops are both `AppTheme.outline`.
      final double p = pulse.clamp(0.0, 1.0);
      final double peak = 0.25 + 0.75 * intensity.clamp(0.0, 1.0);
      final double a = math.sin(p * math.pi) * peak;
      if (a > 0) {
        const double half = 0.18;
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
        addStop((p - half).clamp(0.0, 1.0), AppTheme.outline);
        addStop(p - half / 2, tint(AppTheme.brandBlue));
        addStop(p, tint(AppTheme.brandViolet));
        addStop(p + half / 2, tint(AppTheme.brandPink));
        addStop((p + half).clamp(0.0, 1.0), AppTheme.outline);
        addStop(1, AppTheme.outline);

        paint.shader = SweepGradient(
          center: Alignment.center,
          startAngle: 0,
          endAngle: 2 * math.pi,
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
      oldDelegate.pulse != pulse ||
      oldDelegate.intensity != intensity;
}
