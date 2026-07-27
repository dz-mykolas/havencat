enum AppThemePreset { parchment, coastal, sage, haven, midnight, evergreen }

extension AppThemePresetKind on AppThemePreset {
  bool get isDark => switch (this) {
    AppThemePreset.parchment ||
    AppThemePreset.coastal ||
    AppThemePreset.sage => false,
    AppThemePreset.haven ||
    AppThemePreset.midnight ||
    AppThemePreset.evergreen => true,
  };
}

T enumByNameOr<T extends Enum>(Iterable<T> values, String? name, T fallback) {
  if (name == null) return fallback;
  for (final T value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}
