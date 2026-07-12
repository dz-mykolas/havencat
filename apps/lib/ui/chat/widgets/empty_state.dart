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
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: _Greeting(),
            ),
          ),
        ),
        SizedBox(height: 24),
        _Centered(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: input,
          ),
        ),
        SizedBox(height: 24),
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
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: _Greeting(),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 27),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: AppTheme.contentMaxWidth),
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
        constraints: BoxConstraints(maxWidth: AppTheme.contentMaxWidth),
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
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: context.appColors.brandGradient,
          ),
          child: Icon(
            Icons.auto_awesome,
            color: Theme.of(context).colorScheme.onPrimary,
            size: 28,
          ),
        ),
        SizedBox(height: 24),
        GradientText(
          'Hello there',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
        SizedBox(height: 6),
        Text(
          'How can I help you today?',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.appColors.textSecondary,
            fontSize: 20,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
