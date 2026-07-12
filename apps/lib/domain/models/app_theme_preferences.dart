enum AppThemeSlot { light, dark }

enum AppThemePreset { parchment, coastal, sage, haven, midnight, evergreen }

T enumByNameOr<T extends Enum>(Iterable<T> values, String? name, T fallback) {
  if (name == null) return fallback;
  for (final T value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}
