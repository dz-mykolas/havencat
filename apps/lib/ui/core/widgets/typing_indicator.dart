import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Three gradient dots that pulse in sequence while the assistant is
/// generating a reply.
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List<Widget>.generate(3, (int i) {
            final double t = (_controller.value - i * 0.18) % 1.0;
            // Smooth pulse between 0.4 and 1.0 opacity/scale.
            final double pulse =
                0.4 + 0.6 * (0.5 + 0.5 * math.sin(t * 2 * math.pi));
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Opacity(
                opacity: pulse,
                child: Transform.scale(
                  scale: 0.75 + 0.25 * pulse,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: AppTheme.brandGradient,
                    ),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
