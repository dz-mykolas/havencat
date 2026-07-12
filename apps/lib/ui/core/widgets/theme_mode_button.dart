import 'package:flutter/material.dart';

import '../../../domain/models/app_theme_preferences.dart';

class ThemeModeButton extends StatelessWidget {
  const ThemeModeButton({
    super.key,
    required this.slot,
    required this.onToggle,
  });

  final AppThemeSlot slot;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final bool dark = slot == AppThemeSlot.dark;
    return IconButton(
      tooltip: dark ? 'Use light theme' : 'Use dark theme',
      onPressed: onToggle,
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutBack,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (Widget child, Animation<double> animation) {
          return FadeTransition(
            opacity: animation,
            child: RotationTransition(
              turns: Tween<double>(begin: -0.12, end: 0).animate(animation),
              child: ScaleTransition(scale: animation, child: child),
            ),
          );
        },
        child: Icon(
          dark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
          key: ValueKey<AppThemeSlot>(slot),
        ),
      ),
    );
  }
}
