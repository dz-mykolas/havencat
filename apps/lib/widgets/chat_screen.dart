import 'package:flutter/material.dart';

import '../models/conversation.dart';
import '../state/chat_controller.dart';
import '../theme/app_theme.dart';
import 'animated_background.dart';
import 'chat_input.dart';
import 'conversation_drawer.dart';
import 'empty_state.dart';
import 'gradient_text.dart';
import 'message_bubble.dart';

/// The main chat view: app bar, conversation drawer, message list, and the
/// animated input bar.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.controller});

  final ChatController controller;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send(String text) async {
    _scrollToBottom();
    await widget.controller.sendMessage(text);
    _scrollToBottom();
  }

  void _prefill(String suggestion) {
    _textController
      ..text = suggestion
      ..selection = TextSelection.collapsed(offset: suggestion.length);
  }

  Widget _buildInput() {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, _) {
        return ChatInput(
          textController: _textController,
          isGenerating: widget.controller.isGenerating,
          onSend: _send,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: ConversationDrawer(controller: widget.controller),
      appBar: AppBar(
        title: GradientText(
          'HavenChat',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: () => widget.controller.newConversation(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      // Let the animated background bleed behind the transparent app bar.
      extendBodyBehindAppBar: true,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (BuildContext context, _) {
                return AnimatedBackground(
                  active: widget.controller.isGenerating,
                );
              },
            ),
          ),
          SafeArea(
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (BuildContext context, _) {
                final Conversation conversation = widget.controller.active;
                if (conversation.isEmpty) {
                  return EmptyState(
                    onSuggestionTap: _prefill,
                    input: _buildInput(),
                  );
                }
                // Keep pinned to the newest content as tokens stream in.
                _scrollToBottom();
                return Column(
                  children: <Widget>[
                    Expanded(
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        itemCount: conversation.messages.length,
                        itemBuilder: (BuildContext context, int index) {
                          return MessageBubble(
                            message: conversation.messages[index],
                          );
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: AppTheme.contentMaxWidth,
                          ),
                          child: _buildInput(),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
