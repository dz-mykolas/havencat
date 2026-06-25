import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  String _searchQuery = '';

  static const double _expandedWidth = 280;
  static const double _collapsedWidth = 60;

  void _toggle() => setState(() => _collapsed = !_collapsed);

  List<ConversationView> get _filtered {
    final List<ConversationView> all = widget.viewModel.conversations;
    if (_searchQuery.isEmpty) return all;
    final String q = _searchQuery.toLowerCase();
    return all.where((c) => c.title.toLowerCase().contains(q)).toList();
  }

  void _newChat() {
    widget.viewModel.newConversation();
    widget.onClose?.call();
  }

  void _showRenameDialog(String id, String currentTitle) {
    final TextEditingController controller = TextEditingController(
      text: currentTitle,
    );
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Rename chat'),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(fontSize: 15),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Title',
            ),
            onSubmitted: (v) {
              widget.viewModel.renameConversation(id, v);
              Navigator.of(context).pop();
            },
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                widget.viewModel.renameConversation(id, controller.text);
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _showDeleteConfirm(String id, String title) {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete chat?'),
          content: Text(
            '“$title” will be permanently deleted. This cannot be undone.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.tonal(
              style: FilledButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () {
                widget.viewModel.deleteConversation(id);
                Navigator.of(context).pop();
              },
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _exportConversation(String id, String title) async {
    final String markdown = widget.viewModel.exportConversation(id);
    if (markdown.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: markdown));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('“$title” copied as Markdown'),
        duration: const Duration(seconds: 2),
      ),
    );
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
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Material(
            color: Colors.transparent,
            child: TextField(
              onChanged: (v) => setState(() => _searchQuery = v),
              style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search chats…',
                hintStyle: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.textSecondary,
                ),
                prefixIcon: const Icon(Icons.search, size: 18),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 36,
                  minHeight: 36,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                filled: true,
                fillColor: AppTheme.surfaceHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Divider(height: 1),
        Expanded(
          child: ListenableBuilder(
            listenable: widget.viewModel,
            builder: (BuildContext context, _) {
              final List<ConversationView> items = _filtered;
              if (items.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _searchQuery.isEmpty
                          ? 'No conversations yet'
                          : 'No matches',
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                );
              }
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
                    onRename: () => _showRenameDialog(c.id, c.title),
                    onDelete: () => _showDeleteConfirm(c.id, c.title),
                    onExport: () => _exportConversation(c.id, c.title),
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
    required this.onRename,
    required this.onDelete,
    required this.onExport,
  });

  final String title;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onExport;

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
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_horiz,
                    size: 18,
                    color: AppTheme.textSecondary,
                  ),
                  tooltip: 'More',
                  itemBuilder: (BuildContext context) =>
                      <PopupMenuEntry<String>>[
                        const PopupMenuItem<String>(
                          value: 'rename',
                          child: ListTile(
                            leading: Icon(Icons.edit_outlined, size: 20),
                            title: Text('Rename'),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'export',
                          child: ListTile(
                            leading: Icon(Icons.ios_share, size: 20),
                            title: Text('Export as Markdown'),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem<String>(
                          value: 'delete',
                          child: ListTile(
                            leading: Icon(Icons.delete_outline, size: 20),
                            title: Text('Delete'),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                  onSelected: (String value) {
                    switch (value) {
                      case 'rename':
                        onRename();
                      case 'export':
                        onExport();
                      case 'delete':
                        onDelete();
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
