enum AppThemePreset {
  parchment,
  coastal,
  sage,
  gradientLight,
  haven,
  midnight,
  evergreen,
  gradientDark,
}

const int defaultGradientThemeHue = 265;

extension AppThemePresetKind on AppThemePreset {
  bool get isDark => switch (this) {
    AppThemePreset.parchment ||
    AppThemePreset.coastal ||
    AppThemePreset.sage ||
    AppThemePreset.gradientLight => false,
    AppThemePreset.haven ||
    AppThemePreset.midnight ||
    AppThemePreset.evergreen ||
    AppThemePreset.gradientDark => true,
  };

  bool get isGradient =>
      this == AppThemePreset.gradientLight ||
      this == AppThemePreset.gradientDark;
}

T enumByNameOrDefault<T extends Enum>(
  Iterable<T> values,
  String? name,
  T defaultValue,
) {
  if (name == null) return defaultValue;
  for (final T value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('Unknown ${T.toString()} value "$name".');
}
