import 'package:flutter/material.dart';

import '../../../branding.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/gradient_text.dart';
import '../chat_viewmodel.dart';

/// Persistent sidebar listing all conversations with a "New chat" action.
/// Used directly on wide screens (pushes content right). On narrow screens,
/// [ConversationDrawer] wraps this in a [Drawer] overlay.
///
/// Collapsible: tapping the collapse toggle shrinks the sidebar to a mini
/// rail showing only the logo and a "new chat" icon button. The width
/// animates via [AnimatedContainer] so content slides smoothly.
class ConversationSidebar extends StatefulWidget {
  const ConversationSidebar({super.key, required this.viewModel, this.onClose});

  final ChatViewModel viewModel;

  /// Called after creating/selecting a conversation. Null on wide screens
  /// where the sidebar is persistent (nothing to close).
  final VoidCallback? onClose;

  @override
  State<ConversationSidebar> createState() => _ConversationSidebarState();
}

class _ConversationSidebarState extends State<ConversationSidebar> {
  bool _collapsed = false;

  static const double _expandedWidth = 280;
  static const double _collapsedWidth = 60;

  void _toggle() => setState(() => _collapsed = !_collapsed);

  void _newChat() {
    widget.viewModel.newConversation();
    widget.onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    // During the width animation the AnimatedContainer constrains its child
    // to the *current animated* width (e.g. 170px at the midpoint of a
    // 280→60 collapse). SizedBox(width: target) would get clamped to that
    // animated width, causing the full content to overflow. OverflowBox
    // replaces the parent constraints entirely — the child always gets
    // targetWidth regardless of the animating container — and ClipRect
    // clips the paint to the visible (animating) width.
    final double targetWidth = _collapsed ? _collapsedWidth : _expandedWidth;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: targetWidth,
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(right: BorderSide(color: AppTheme.outline, width: 1)),
      ),
      child: ClipRect(
        child: OverflowBox(
          minWidth: targetWidth,
          maxWidth: targetWidth,
          alignment: Alignment.centerLeft,
          child: SafeArea(
            child: _collapsed ? _buildMini(context) : _buildFull(context),
          ),
        ),
      ),
    );
  }

  Widget _buildFull(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: GradientText(
                  appName,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _CollapseButton(collapsed: false, onTap: _toggle),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _NewChatButton(onTap: _newChat),
        ),
        const SizedBox(height: 12),
        const Divider(height: 1),
        Expanded(
          child: ListenableBuilder(
            listenable: widget.viewModel,
            builder: (BuildContext context, _) {
              final List<ConversationView> items =
                  widget.viewModel.conversations;
              return ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: items.length,
                itemBuilder: (BuildContext context, int index) {
                  final ConversationView c = items[index];
                  final bool active = c.id == widget.viewModel.activeId;
                  return _ConversationTile(
                    title: c.title,
                    active: active,
                    onTap: () {
                      widget.viewModel.selectConversation(c.id);
                      widget.onClose?.call();
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMini(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 20),
        Center(
          child: GradientText(
            appName[0],
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 12),
        Center(child: _NewChatIconButton(onTap: _newChat)),
        const SizedBox(height: 8),
        const Divider(height: 1),
        const Spacer(),
        Center(child: _CollapseButton(collapsed: true, onTap: _toggle)),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// Drawer wrapper around [ConversationSidebar] for narrow screens.
class ConversationDrawer extends StatelessWidget {
  const ConversationDrawer({super.key, required this.viewModel});

  final ChatViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ConversationSidebar(
        viewModel: viewModel,
        onClose: () => Navigator.of(context).pop(),
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

/// Icon-only "new chat" button for the collapsed mini rail.
class _NewChatIconButton extends StatelessWidget {
  const _NewChatIconButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'New chat',
      child: Material(
        color: AppTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.outline),
            ),
            child: const Icon(Icons.add, size: 20, color: AppTheme.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// Toggle button that collapses/expands the sidebar.
class _CollapseButton extends StatelessWidget {
  const _CollapseButton({required this.collapsed, required this.onTap});

  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: collapsed ? 'Expand sidebar' : 'Collapse sidebar',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              collapsed ? Icons.chevron_right : Icons.chevron_left,
              size: 18,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.55),
            ),
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
