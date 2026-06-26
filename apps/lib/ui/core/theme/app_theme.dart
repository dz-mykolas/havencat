import 'package:flutter/material.dart';

/// Centralized color tokens, gradients, and [ThemeData] for the app.
///
/// The visual language is a dark, minimalist surface accented by a single
/// Gemini-style brand gradient that is reused across the app.
class AppTheme {
  AppTheme._();

  /// Max width for centered content (input bar, suggestions) so it never
  /// stretches edge-to-edge on wide screens. Matches ChatGPT's 48rem column.
  static const double contentMaxWidth = 768;

  /// Max width for full-page panels (settings, pricing). A touch wider than
  /// [contentMaxWidth] so two-up card grids breathe on desktop. Below this the
  /// layout is treated as "compact" (phone-style, edge-to-edge, left-aligned).
  static const double panelMaxWidth = 760;

  /// Width at/above which a layout is considered "desktop/wide".
  static const double wideBreakpoint = 720;

  // Core surface tokens.
  static const Color background = Color(0xFF0E0E11);
  static const Color surface = Color(0xFF17171C);
  static const Color surfaceHigh = Color(0xFF202028);
  static const Color outline = Color.fromARGB(255, 97, 88, 73);
  static const Color textPrimary = Color(0xFFc3b091);
  static const Color textSecondary = Color.fromARGB(255, 156, 141, 116);

  // Gemini-inspired brand gradient: blue -> violet -> pink.
  static const Color brandBlue = Color.fromARGB(255, 227, 71, 71);
  static const Color brandViolet = Color.fromARGB(255, 199, 171, 119);
  static const Color brandPink = Color.fromARGB(255, 213, 211, 111);

  static const List<Color> brandColors = <Color>[
    brandBlue,
    brandViolet,
    brandPink,
  ];

  /// The signature brand gradient used for accents, text masks, and the
  /// animated "generating" effects.
  static const LinearGradient brandGradient = LinearGradient(
    colors: brandColors,
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  static ThemeData get dark {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: brandViolet,
      brightness: Brightness.dark,
    ).copyWith(surface: background, primary: brandViolet, secondary: brandBlue);

    final ThemeData base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      fontFamily: 'Roboto',
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        foregroundColor: textPrimary,
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      dividerTheme: const DividerThemeData(color: outline, thickness: 1),
    );
  }
}
