import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'branding.dart';
import 'ui/chat/chat_screen.dart';
import 'ui/core/theme/app_theme.dart';

/// Scroll behavior that gives wheel scrolling on web a smoother, momentum-based
/// feel (like native browser scrolling) instead of the default dead-stop ticks.
class _SmoothScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
  };

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
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      scrollBehavior: _SmoothScrollBehavior(),
      home: const ChatScreen(),
    );
  }
}
