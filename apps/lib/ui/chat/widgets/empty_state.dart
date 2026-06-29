import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/gradient_text.dart';

/// The home layout shown when the active conversation has no messages: a
/// gradient greeting sitting above center with the message [input] placed
/// just below center.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.input});

  /// The message input bar, hosted below center on the home screen.
  final Widget input;

  @override
  Widget build(BuildContext context) {
    final bool wide = MediaQuery.of(context).size.width >= 720;
    return wide ? _buildDesktop(context) : _buildMobile(context);
  }

  /// Desktop: input bar vertically centered, greeting above, suggestions
  /// below. The app bar is transparent and overlays the body, so the input
  /// centers in the full viewport height.
  Widget _buildDesktop(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SingleChildScrollView(
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _Greeting(),
            ),
          ),
        ),
        const SizedBox(height: 24),
        _Centered(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: input,
          ),
        ),
        const SizedBox(height: 24),
        Expanded(child: SizedBox()),
      ],
    );
  }

  /// Mobile: "Hello there" greeting centered in the middle of the screen,
  /// input bar pinned to the bottom. No suggestion chips.
  Widget _buildMobile(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: _Greeting(),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 27),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppTheme.contentMaxWidth,
                ),
                child: input,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Constrains [child] to [AppTheme.contentMaxWidth] and centers it
/// horizontally.
class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppTheme.contentMaxWidth),
        child: child,
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 56,
          height: 56,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: AppTheme.brandGradient,
          ),
          child: const Icon(Icons.auto_awesome, color: Colors.white, size: 28),
        ),
        const SizedBox(height: 24),
        GradientText(
          'Hello there',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'How can I help you today?',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 20,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
