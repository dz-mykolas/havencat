import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'branding.dart';
import 'data/services/storage/app_settings.dart';
import 'domain/models/app_theme_preferences.dart';
import 'providers.dart';
import 'ui/chat/chat_screen.dart';
import 'ui/core/theme/app_theme.dart';
import 'ui/core/notices/notice_host.dart';

class _AppScrollBehavior extends MaterialScrollBehavior {
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(
        decelerationRate: ScrollDecelerationRate.fast,
      ).applyTo(const AlwaysScrollableScrollPhysics());
}

/// Root widget. Wraps the app in a [ProviderScope] (set up in main.dart) and
/// applies the dark theme.
class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(appSettingsProvider);
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(settings.lightTheme),
      darkTheme: AppTheme.build(settings.darkTheme),
      themeMode: settings.themeSlot == AppThemeSlot.light
          ? ThemeMode.light
          : ThemeMode.dark,
      themeAnimationDuration: const Duration(milliseconds: 320),
      themeAnimationCurve: Curves.easeOutCubic,
      scrollBehavior: _AppScrollBehavior(),
      home: const NoticeHost(child: ChatScreen()),
    );
  }
}
