import 'dart:async';

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
class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onResume: () => _setAppVisible(true),
      onHide: () => _setAppVisible(false),
      onPause: () => _setAppVisible(false),
      onDetach: () => _setAppVisible(false),
    );
  }

  void _setAppVisible(bool visible) {
    unawaited(
      ref.read(conversationRepositoryProvider).handleAppVisibility(visible),
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
