import 'package:flutter/material.dart';

/// Centralized color tokens, gradients, and [ThemeData] for HavenChat.
///
/// The visual language is a dark, minimalist surface accented by a single
/// Gemini-style brand gradient that is reused across the app.
class AppTheme {
  AppTheme._();

  /// Max width for centered content (input bar, suggestions) so it never
  /// stretches edge-to-edge on wide screens.
  static const double contentMaxWidth = 640;

  // Core surface tokens.
  static const Color background = Color(0xFF0E0E11);
  static const Color surface = Color(0xFF17171C);
  static const Color surfaceHigh = Color(0xFF202028);
  static const Color outline = Color(0xFF2C2C36);
  static const Color textPrimary = Color(0xFFF3F3F7);
  static const Color textSecondary = Color(0xFF9A9AA8);

  // Gemini-inspired brand gradient: blue -> violet -> pink.
  static const Color brandBlue = Color(0xFF4796E3);
  static const Color brandViolet = Color(0xFF9177C7);
  static const Color brandPink = Color(0xFFD56F76);

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
