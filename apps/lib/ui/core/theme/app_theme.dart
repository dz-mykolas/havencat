import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';

import '../../../domain/models/app_theme_preferences.dart';

abstract final class AppTheme {
  static const double contentMaxWidth = 768;
  static const double panelMaxWidth = 760;
  static const double wideBreakpoint = 720;

  static final Map<AppThemePreset, ThemeData> _cache =
      <AppThemePreset, ThemeData>{};

  static ThemeData build(AppThemePreset preset) =>
      _cache.putIfAbsent(preset, () => _build(preset));

  static ThemeData _build(AppThemePreset preset) {
    final Brightness brightness = preset.brightness;
    final bool exactHaven = preset == AppThemePreset.haven;
    final FlexSchemeColor colors = FlexSchemeColor.from(
      primary: preset.primary,
      secondary: preset.secondary,
      tertiary: preset.tertiary,
      brightness: brightness,
    );
    final ThemeData base = brightness == Brightness.dark
        ? FlexThemeData.dark(
            colors: exactHaven ? null : colors,
            colorScheme: exactHaven ? _havenScheme : null,
            surfaceMode: exactHaven
                ? null
                : FlexSurfaceMode.highScaffoldLowSurface,
            blendLevel: exactHaven ? 0 : 8,
            subThemesData: _subThemes,
            keyColors: _keyColors,
          )
        : FlexThemeData.light(
            colors: colors,
            surfaceMode: FlexSurfaceMode.highScaffoldLowSurface,
            blendLevel: 2,
            subThemesData: _subThemes,
            keyColors: _keyColors,
          );
    final ThemeData resolved = exactHaven
        ? base.copyWith(colorScheme: _havenScheme)
        : base;
    final AppThemeColors appColors = AppThemeColors.fromScheme(
      resolved.colorScheme,
    );
    return resolved.copyWith(
      scaffoldBackgroundColor: appColors.background,
      canvasColor: appColors.background,
      extensions: <ThemeExtension<dynamic>>[appColors],
      appBarTheme: resolved.appBarTheme.copyWith(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      dividerTheme: DividerThemeData(
        color: appColors.divider,
        thickness: 1,
        space: 1,
      ),
      dialogTheme: resolved.dialogTheme.copyWith(
        backgroundColor: appColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      bottomSheetTheme: resolved.bottomSheetTheme.copyWith(
        backgroundColor: appColors.surface,
        modalBackgroundColor: appColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        showDragHandle: true,
      ),
      drawerTheme: resolved.drawerTheme.copyWith(
        backgroundColor: appColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      cardTheme: resolved.cardTheme.copyWith(
        color: appColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      listTileTheme: resolved.listTileTheme.copyWith(
        iconColor: appColors.textSecondary,
        textColor: appColors.textPrimary,
        minTileHeight: 48,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      iconTheme: resolved.iconTheme.copyWith(color: appColors.textSecondary),
      tooltipTheme: TooltipThemeData(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        margin: const EdgeInsets.symmetric(horizontal: 12),
        verticalOffset: 10,
        preferBelow: false,
        decoration: BoxDecoration(
          color: appColors.surfaceHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: appColors.outline.withValues(alpha: 0.45)),
        ),
        textStyle: resolved.textTheme.labelMedium?.copyWith(
          color: appColors.textPrimary,
          fontWeight: FontWeight.w500,
          height: 1.25,
        ),
        textAlign: TextAlign.left,
        waitDuration: const Duration(milliseconds: 250),
        showDuration: const Duration(seconds: 4),
        exitDuration: const Duration(milliseconds: 100),
      ),
      snackBarTheme: resolved.snackBarTheme.copyWith(
        backgroundColor: resolved.colorScheme.inverseSurface,
        contentTextStyle: TextStyle(
          color: resolved.colorScheme.onInverseSurface,
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
      ),
    );
  }

  static const FlexKeyColors _keyColors = FlexKeyColors(
    useSecondary: true,
    useTertiary: true,
    keepPrimary: true,
    keepSecondary: true,
    keepTertiary: true,
  );

  static final ColorScheme _havenScheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFFC7AB77),
        brightness: Brightness.dark,
      ).copyWith(
        primary: const Color(0xFFC7AB77),
        onPrimary: const Color(0xFF0E0E11),
        primaryContainer: const Color(0xFF202028),
        onPrimaryContainer: const Color(0xFFC3B091),
        secondary: const Color(0xFFE34747),
        onSecondary: const Color(0xFF0E0E11),
        secondaryContainer: const Color(0xFF202028),
        onSecondaryContainer: const Color(0xFFC3B091),
        tertiary: const Color(0xFFD5D36F),
        onTertiary: const Color(0xFF0E0E11),
        tertiaryContainer: const Color(0xFF202028),
        onTertiaryContainer: const Color(0xFFC3B091),
        surface: const Color(0xFF0E0E11),
        surfaceDim: const Color(0xFF0E0E11),
        surfaceBright: const Color(0xFF29292F),
        surfaceContainerLowest: const Color(0xFF0E0E11),
        surfaceContainerLow: const Color(0xFF17171C),
        surfaceContainer: const Color(0xFF17171C),
        surfaceContainerHigh: const Color(0xFF202028),
        surfaceContainerHighest: const Color(0xFF29292F),
        onSurface: const Color(0xFFC3B091),
        onSurfaceVariant: const Color(0xFF9C8D74),
        outline: const Color(0xFF615849),
        outlineVariant: const Color(0xFF29292F),
      );

  static const FlexSubThemesData _subThemes = FlexSubThemesData(
    interactionEffects: true,
    tintedDisabledControls: true,
    useMaterial3Typography: true,
    defaultRadius: 12,
    dialogRadius: 22,
    bottomSheetRadius: 22,
    cardRadius: 14,
    cardElevation: 0,
    popupMenuRadius: 12,
    popupMenuElevation: 0,
    menuRadius: 12,
    menuElevation: 0,
    tooltipRadius: 8,
    snackBarRadius: 12,
    snackBarElevation: 0,
    inputDecoratorRadius: 12,
    inputDecoratorIsFilled: true,
    inputDecoratorBorderType: FlexInputBorderType.outline,
    inputDecoratorUnfocusedHasBorder: false,
    inputDecoratorFocusedHasBorder: true,
    inputDecoratorFocusedBorderWidth: 1,
    inputDecoratorBackgroundAlpha: 18,
    inputDecoratorSchemeColor: SchemeColor.primary,
    listTileSelectedSchemeColor: SchemeColor.primary,
    listTileSelectedTileSchemeColor: SchemeColor.primaryContainer,
    listTileMinVerticalPadding: 4,
    filledButtonRadius: 12,
    textButtonRadius: 10,
    outlinedButtonRadius: 12,
    chipRadius: 9,
  );
}

extension AppThemePresetDefinition on AppThemePreset {
  String get label => switch (this) {
    AppThemePreset.parchment => 'Parchment',
    AppThemePreset.coastal => 'Coastal',
    AppThemePreset.sage => 'Sage',
    AppThemePreset.haven => 'Haven',
    AppThemePreset.midnight => 'Midnight',
    AppThemePreset.evergreen => 'Evergreen',
  };

  String get description => switch (this) {
    AppThemePreset.parchment => 'Warm paper and bronze',
    AppThemePreset.coastal => 'Cool mist and ocean blue',
    AppThemePreset.sage => 'Soft stone and muted green',
    AppThemePreset.haven => 'Warm charcoal and amber',
    AppThemePreset.midnight => 'Deep navy and electric blue',
    AppThemePreset.evergreen => 'Forest black and soft lime',
  };

  Brightness get brightness => isDark ? Brightness.dark : Brightness.light;

  Color get primary => switch (this) {
    AppThemePreset.parchment => const Color(0xFF765B32),
    AppThemePreset.coastal => const Color(0xFF286783),
    AppThemePreset.sage => const Color(0xFF4F6F52),
    AppThemePreset.haven => const Color(0xFFC7AB77),
    AppThemePreset.midnight => const Color(0xFF8FB8FF),
    AppThemePreset.evergreen => const Color(0xFF91C788),
  };

  Color get secondary => switch (this) {
    AppThemePreset.parchment => const Color(0xFF9A4F40),
    AppThemePreset.coastal => const Color(0xFF476A91),
    AppThemePreset.sage => const Color(0xFF80664D),
    AppThemePreset.haven => const Color(0xFFE34747),
    AppThemePreset.midnight => const Color(0xFFC5A7FF),
    AppThemePreset.evergreen => const Color(0xFFE0B86A),
  };

  Color get tertiary => switch (this) {
    AppThemePreset.parchment => const Color(0xFF66733C),
    AppThemePreset.coastal => const Color(0xFF7A5C8E),
    AppThemePreset.sage => const Color(0xFF64758B),
    AppThemePreset.haven => const Color(0xFFD5D36F),
    AppThemePreset.midnight => const Color(0xFF68D5CF),
    AppThemePreset.evergreen => const Color(0xFF75C9B7),
  };
}

@immutable
class AppThemeColors extends ThemeExtension<AppThemeColors> {
  const AppThemeColors({
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.divider,
    required this.outline,
    required this.textPrimary,
    required this.textSecondary,
    required this.brandBlue,
    required this.brandViolet,
    required this.brandPink,
  });

  factory AppThemeColors.fromScheme(ColorScheme scheme) => AppThemeColors(
    background: scheme.surface,
    surface: scheme.surfaceContainerLow,
    surfaceHigh: scheme.surfaceContainerHigh,
    divider: scheme.outlineVariant,
    outline: scheme.outline,
    textPrimary: scheme.onSurface,
    textSecondary: scheme.onSurfaceVariant,
    brandBlue: scheme.secondary,
    brandViolet: scheme.primary,
    brandPink: scheme.tertiary,
  );

  final Color background;
  final Color surface;
  final Color surfaceHigh;
  final Color divider;
  final Color outline;
  final Color textPrimary;
  final Color textSecondary;
  final Color brandBlue;
  final Color brandViolet;
  final Color brandPink;

  List<Color> get brandColors => <Color>[brandBlue, brandViolet, brandPink];

  LinearGradient get brandGradient => LinearGradient(
    colors: brandColors,
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  @override
  AppThemeColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceHigh,
    Color? divider,
    Color? outline,
    Color? textPrimary,
    Color? textSecondary,
    Color? brandBlue,
    Color? brandViolet,
    Color? brandPink,
  }) => AppThemeColors(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    surfaceHigh: surfaceHigh ?? this.surfaceHigh,
    divider: divider ?? this.divider,
    outline: outline ?? this.outline,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    brandBlue: brandBlue ?? this.brandBlue,
    brandViolet: brandViolet ?? this.brandViolet,
    brandPink: brandPink ?? this.brandPink,
  );

  @override
  AppThemeColors lerp(covariant AppThemeColors? other, double t) {
    if (other == null) return this;
    return AppThemeColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceHigh: Color.lerp(surfaceHigh, other.surfaceHigh, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      brandBlue: Color.lerp(brandBlue, other.brandBlue, t)!,
      brandViolet: Color.lerp(brandViolet, other.brandViolet, t)!,
      brandPink: Color.lerp(brandPink, other.brandPink, t)!,
    );
  }
}

extension AppThemeContext on BuildContext {
  AppThemeColors get appColors {
    final ThemeData theme = Theme.of(this);
    return theme.extension<AppThemeColors>() ??
        AppThemeColors.fromScheme(theme.colorScheme);
  }
}
