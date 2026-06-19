import 'package:flutter/material.dart';

import '../models/message.dart';
import '../theme/app_theme.dart';
import 'typing_indicator.dart';

/// Renders a single [ChatMessage].
///
/// User messages are right-aligned rounded bubbles; assistant messages are
/// left-aligned full-width text preceded by a small gradient avatar.
class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return message.isUser ? _buildUser(context) : _buildAssistant(context);
  }

  Widget _buildUser(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: AppTheme.surfaceHigh,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomLeft: Radius.circular(20),
            bottomRight: Radius.circular(6),
          ),
          border: Border.all(color: AppTheme.outline),
        ),
        child: Text(
          message.text,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 15,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _buildAssistant(BuildContext context) {
    final bool showTyping = message.isStreaming && message.text.isEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _AssistantAvatar(),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: showTyping
                  ? const Align(
                      alignment: Alignment.centerLeft,
                      child: TypingIndicator(),
                    )
                  : Text(
                      message.text,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        height: 1.5,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssistantAvatar extends StatelessWidget {
  const _AssistantAvatar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppTheme.brandGradient,
      ),
      child: const Icon(Icons.auto_awesome, size: 16, color: Colors.white),
    );
  }
}
