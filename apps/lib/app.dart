import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app_router.dart';
import 'branding.dart';
import 'data/services/storage/app_settings.dart';
import 'domain/models/app_theme_preferences.dart';
import 'providers.dart';
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
/// applies the configured theme.
class App extends ConsumerStatefulWidget {
  const App({this.initialLocation, super.key});

  final String? initialLocation;

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> {
  late final AppLifecycleListener _lifecycleListener;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = createAppRouter(initialLocation: widget.initialLocation);
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
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = ref.watch(appSettingsProvider);
    final ThemeData selectedTheme = AppTheme.build(settings.theme);
    return MaterialApp.router(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: settings.useDeviceTheme
          ? AppTheme.build(settings.lightTheme)
          : selectedTheme,
      darkTheme: settings.useDeviceTheme
          ? AppTheme.build(settings.darkTheme)
          : selectedTheme,
      themeMode: settings.useDeviceTheme
          ? ThemeMode.system
          : settings.theme.isDark
          ? ThemeMode.dark
          : ThemeMode.light,
      themeAnimationDuration: const Duration(milliseconds: 320),
      themeAnimationCurve: Curves.easeOutCubic,
      scrollBehavior: _AppScrollBehavior(),
      routerConfig: _router,
      builder: (BuildContext context, Widget? child) =>
          NoticeHost(child: child ?? const SizedBox.shrink()),
    );
  }
}
