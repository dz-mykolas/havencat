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

class _ChatInputState extends State<ChatInput>
    with SingleTickerProviderStateMixin {
  late final AnimationController _borderController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  final FocusNode _focusNode = FocusNode();
  bool _hasText = false;
  bool _focused = false;

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // On focus the pill grows slightly, with the width increase twice the
    // height increase (Δscale_x = 2 · Δscale_y). Anchored to the bottom so it
    // expands upward and outward from where it sits.
    const double growY = 0.03;
    const double growX = 2 * growY;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      transformAlignment: Alignment.bottomCenter,
      transform: _focused
          ? Matrix4.diagonal3Values(1 + growX, 1 + growY, 1)
          : Matrix4.identity(),
      child: AnimatedBuilder(
        animation: _borderController,
        builder: (BuildContext context, Widget? child) {
          return CustomPaint(
            painter: _GradientBorderPainter(
              progress: _borderController.value,
              active: widget.isGenerating,
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
/// the flashing effect; otherwise a subtle static outline is drawn.
class _GradientBorderPainter extends CustomPainter {
  _GradientBorderPainter({required this.progress, required this.active});

  final double progress;
  final bool active;

  static const double _stroke = 2.5;

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
        colors: const <Color>[
          AppTheme.brandBlue,
          AppTheme.brandViolet,
          AppTheme.brandPink,
          AppTheme.brandViolet,
          AppTheme.brandBlue,
        ],
      ).createShader(Offset.zero & size);
    } else {
      paint.color = AppTheme.outline;
    }

    canvas.drawRRect(rrect.deflate(_stroke / 2), paint);
  }

  @override
  bool shouldRepaint(_GradientBorderPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.active != active;
}
