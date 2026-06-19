import 'package:flutter/material.dart';

import '../models/conversation.dart';
import '../state/chat_controller.dart';
import '../theme/app_theme.dart';
import 'gradient_text.dart';

/// Side drawer listing all conversations with a "New chat" action.
class ConversationDrawer extends StatelessWidget {
  const ConversationDrawer({super.key, required this.controller});

  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: GradientText(
                'HavenChat',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _NewChatButton(
                onTap: () {
                  controller.newConversation();
                  Navigator.of(context).pop();
                },
              ),
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            Expanded(
              child: ListenableBuilder(
                listenable: controller,
                builder: (BuildContext context, _) {
                  final List<Conversation> items = controller.conversations;
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: items.length,
                    itemBuilder: (BuildContext context, int index) {
                      final Conversation c = items[index];
                      final bool active = c.id == controller.activeId;
                      return _ConversationTile(
                        title: c.isEmpty ? 'New chat' : c.title,
                        active: active,
                        onTap: () {
                          controller.selectConversation(c.id);
                          Navigator.of(context).pop();
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewChatButton extends StatelessWidget {
  const _NewChatButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.outline),
            color: AppTheme.surfaceHigh,
          ),
          child: const Row(
            children: <Widget>[
              Icon(Icons.add, size: 20, color: AppTheme.textPrimary),
              SizedBox(width: 12),
              Text(
                'New chat',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.title,
    required this.active,
    required this.onTap,
  });

  final String title;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: active ? AppTheme.surfaceHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.chat_bubble_outline,
                  size: 18,
                  color: active ? AppTheme.brandViolet : AppTheme.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active
                          ? AppTheme.textPrimary
                          : AppTheme.textSecondary,
                      fontSize: 14,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
