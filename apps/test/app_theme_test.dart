import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app/data/services/storage/app_settings.dart';
import 'package:app/domain/models/app_theme_preferences.dart';
import 'package:app/ui/core/theme/app_theme.dart';

void main() {
  test('light and dark slots persist independently', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final AppSettings settings = AppSettings(prefs: prefs);

    await settings.setLightTheme(AppThemePreset.midnight);
    await settings.setDarkTheme(AppThemePreset.parchment);
    await settings.setThemeSlot(AppThemeSlot.light);

    final AppSettings restored = AppSettings(prefs: prefs);
    expect(restored.lightTheme, AppThemePreset.midnight);
    expect(restored.darkTheme, AppThemePreset.parchment);
    expect(restored.themeSlot, AppThemeSlot.light);
  });

  test('web search tool preference persists', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final AppSettings settings = AppSettings(prefs: prefs);

    expect(settings.toolsEnabled, isFalse);
    await settings.setToolsEnabled(true);

    expect(AppSettings(prefs: prefs).toolsEnabled, isTrue);
  });

  test('preset brightness is independent from its assigned slot', () {
    expect(AppTheme.build(AppThemePreset.midnight).brightness, Brightness.dark);
    expect(
      AppTheme.build(AppThemePreset.parchment).brightness,
      Brightness.light,
    );
  });

  test('Haven preserves the original app palette exactly', () {
    final AppThemeColors colors = AppTheme.build(
      AppThemePreset.haven,
    ).extension<AppThemeColors>()!;

    expect(colors.background, const Color(0xFF0E0E11));
    expect(colors.surface, const Color(0xFF17171C));
    expect(colors.surfaceHigh, const Color(0xFF202028));
    expect(colors.divider, const Color(0xFF29292F));
    expect(colors.outline, const Color(0xFF615849));
    expect(colors.textPrimary, const Color(0xFFC3B091));
    expect(colors.textSecondary, const Color(0xFF9C8D74));
    expect(colors.brandBlue, const Color(0xFFE34747));
    expect(colors.brandViolet, const Color(0xFFC7AB77));
    expect(colors.brandPink, const Color(0xFFD5D36F));
  });

  test('every preset supplies shared component and app color themes', () {
    for (final AppThemePreset preset in AppThemePreset.values) {
      final ThemeData theme = AppTheme.build(preset);
      expect(theme.extension<AppThemeColors>(), isNotNull);
      expect(theme.dialogTheme.backgroundColor, isNotNull);
      expect(theme.bottomSheetTheme.modalBackgroundColor, isNotNull);
      expect(theme.cardTheme.elevation, 0);
    }
  });

  testWidgets('a slot can use a theme with the opposite brightness', (
    WidgetTester tester,
  ) async {
    late ThemeData selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppThemePreset.midnight),
        darkTheme: AppTheme.build(AppThemePreset.parchment),
        themeMode: ThemeMode.dark,
        home: Builder(
          builder: (BuildContext context) {
            selected = Theme.of(context);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(selected.brightness, Brightness.light);
    expect(
      selected.colorScheme.primary,
      AppTheme.build(AppThemePreset.parchment).colorScheme.primary,
    );
  });
}
