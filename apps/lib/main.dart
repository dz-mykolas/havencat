import 'package:flutter/material.dart';

import 'state/chat_controller.dart';
import 'theme/app_theme.dart';
import 'widgets/chat_screen.dart';

void main() {
  runApp(const HavenChatApp());
}

class HavenChatApp extends StatefulWidget {
  const HavenChatApp({super.key});

  @override
  State<HavenChatApp> createState() => _HavenChatAppState();
}

class _HavenChatAppState extends State<HavenChatApp> {
  final ChatController _controller = ChatController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HavenChat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: ChatScreen(controller: _controller),
    );
  }
}
