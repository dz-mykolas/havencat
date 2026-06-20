import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/chat/chat_screen.dart';
import 'ui/core/theme/app_theme.dart';

/// Root widget. Wraps the app in a [ProviderScope] (set up in main.dart) and
/// applies the dark theme.
class HavenChatApp extends ConsumerWidget {
  const HavenChatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'HavenChat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const ChatScreen(),
    );
  }
}
