import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app/app.dart';
import 'package:app/data/services/storage/app_settings.dart';
import 'package:app/domain/models/app_theme_preferences.dart';
import 'package:app/providers.dart';
import 'package:app/ui/core/theme/app_theme.dart';

void main() {
  test('manual and device theme selections persist independently', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final AppSettings settings = AppSettings(prefs: prefs);

    await settings.setTheme(AppThemePreset.midnight);
    await settings.setLightTheme(AppThemePreset.coastal);
    await settings.setDarkTheme(AppThemePreset.evergreen);
    await settings.setUseDeviceTheme(true);

    final AppSettings restored = AppSettings(prefs: prefs);
    expect(restored.theme, AppThemePreset.midnight);
    expect(restored.lightTheme, AppThemePreset.coastal);
    expect(restored.darkTheme, AppThemePreset.evergreen);
    expect(restored.useDeviceTheme, isTrue);
  });

  test('legacy slots migrate to the previously visible theme', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_slot::v1': 'light',
      'appearance.light_theme::v1': 'sage',
      'appearance.dark_theme::v1': 'midnight',
    });
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    final AppSettings restored = AppSettings(prefs: prefs);

    expect(restored.useDeviceTheme, isFalse);
    expect(restored.theme, AppThemePreset.sage);
    expect(restored.lightTheme, AppThemePreset.sage);
    expect(restored.darkTheme, AppThemePreset.midnight);
  });

  test('device theme slots enforce matching brightness', () async {
    final AppSettings settings = AppSettings();

    await expectLater(
      settings.setLightTheme(AppThemePreset.midnight),
      throwsArgumentError,
    );
    await expectLater(
      settings.setDarkTheme(AppThemePreset.parchment),
      throwsArgumentError,
    );
  });

  test('web search tool preference persists', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final AppSettings settings = AppSettings(prefs: prefs);

    expect(settings.toolsEnabled, isFalse);
    await settings.setToolsEnabled(true);

    expect(AppSettings(prefs: prefs).toolsEnabled, isTrue);
  });

  test('presets expose their intended brightness', () {
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
      expect(theme.tooltipTheme.constraints?.maxWidth, 240);
      expect(theme.tooltipTheme.preferBelow, isFalse);
      expect(
        theme.tooltipTheme.waitDuration,
        const Duration(milliseconds: 250),
      );
    }
  });

  testWidgets(
    'manual theme ignores device brightness until device mode is on',
    (WidgetTester tester) async {
      final AppSettings settings = AppSettings();
      await settings.setTheme(AppThemePreset.coastal);
      await settings.setLightTheme(AppThemePreset.sage);
      await settings.setDarkTheme(AppThemePreset.midnight);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appSettingsProvider.overrideWith((_) => settings),
          ],
          child: const App(),
        ),
      );
      await tester.pumpAndSettle();

      ThemeData activeTheme() =>
          Theme.of(tester.element(find.byType(Scaffold).first));

      expect(
        activeTheme().colorScheme.primary,
        AppTheme.build(AppThemePreset.coastal).colorScheme.primary,
      );

      await settings.setUseDeviceTheme(true);
      await tester.pumpAndSettle();
      expect(
        activeTheme().colorScheme.primary,
        AppTheme.build(AppThemePreset.midnight).colorScheme.primary,
      );

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(
        activeTheme().colorScheme.primary,
        AppTheme.build(AppThemePreset.sage).colorScheme.primary,
      );
    },
  );
}
