import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../branding.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_scroll_view.dart';
import '../../core/widgets/gradient_text.dart';
import '../chat_viewmodel.dart';

bool _usesDesktopDialogs(BuildContext context) {
  return switch (Theme.of(context).platform) {
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows => true,
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => false,
  };
}

class ConversationSidebar extends StatefulWidget {
  const ConversationSidebar({
    super.key,
    required this.viewModel,
    this.onClose,
    this.onNewChat,
    this.collapsible = true,
  });

  final ChatViewModel viewModel;
  final VoidCallback? onClose;
  final VoidCallback? onNewChat;
  final bool collapsible;

  static const double railWidth = 64;
  static const double expandedWidth = 272;

  @override
  State<ConversationSidebar> createState() => _ConversationSidebarState();
}

class _ConversationSidebarState extends State<ConversationSidebar> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ValueNotifier<bool> _collapsed = ValueNotifier<bool>(false);

  bool _searchOpen = false;
  String _searchQuery = '';
  List<ConversationView>? _filteredCache;
  List<ConversationView>? _filteredSource;
  String? _filteredQuery;

  @override
  void dispose() {
    _collapsed.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  List<ConversationView> get _filtered {
    final List<ConversationView> all = widget.viewModel.conversations;
    final String query = _searchQuery.trim().toLowerCase();
    if (identical(all, _filteredSource) && query == _filteredQuery) {
      return _filteredCache!;
    }

    _filteredSource = all;
    _filteredQuery = query;
    return _filteredCache = query.isEmpty
        ? all
        : all
              .where(
                (ConversationView chat) =>
                    chat.title.toLowerCase().contains(query),
              )
              .toList(growable: false);
  }

  void _setCollapsed(bool collapsed) {
    if (!widget.collapsible || collapsed == _collapsed.value) return;
    if (collapsed && _searchOpen) setState(_closeSearch);
    _collapsed.value = collapsed;
  }

  void _newChat() {
    (widget.onNewChat ?? widget.viewModel.newConversation).call();
    widget.onClose?.call();
  }

  void _toggleSearch() {
    if (!_searchOpen) {
      if (_collapsed.value) _setCollapsed(false);
      setState(() => _searchOpen = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
      return;
    }
    setState(_closeSearch);
  }

  void _closeSearch() {
    _searchOpen = false;
    _searchQuery = '';
    _searchController.clear();
    _searchFocus.unfocus();
  }

  Future<void> _showRenameDialog(String id, String currentTitle) async {
    String draft = currentTitle;
    void save(BuildContext overlayContext) {
      widget.viewModel.renameConversation(id, draft);
      Navigator.of(overlayContext).pop();
    }

    if (_usesDesktopDialogs(context)) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext overlayContext) => AlertDialog(
          title: const Text('Rename chat'),
          content: TextFormField(
            initialValue: currentTitle,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Title'),
            onChanged: (String value) => draft = value,
            onFieldSubmitted: (_) => save(overlayContext),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(overlayContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => save(overlayContext),
              child: const Text('Save'),
            ),
          ],
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (BuildContext overlayContext) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            MediaQuery.viewInsetsOf(overlayContext).bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Rename chat',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextFormField(
                initialValue: currentTitle,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(labelText: 'Title'),
                onChanged: (String value) => draft = value,
                onFieldSubmitted: (_) => save(overlayContext),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => save(overlayContext),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      );
    }
  }

  Future<void> _showDeleteConfirm(String id, String title) async {
    void remove(BuildContext overlayContext) {
      widget.viewModel.deleteConversation(id);
      Navigator.of(overlayContext).pop();
    }

    if (_usesDesktopDialogs(context)) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext overlayContext) => AlertDialog(
          title: const Text('Delete chat?'),
          content: Text('“$title” will be permanently deleted.'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(overlayContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => remove(overlayContext),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (BuildContext overlayContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Delete chat?', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('“$title” will be permanently deleted.'),
            const SizedBox(height: 20),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => remove(overlayContext),
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMobileActions(ConversationView conversation) async {
    final _ConversationAction? action =
        await showModalBottomSheet<_ConversationAction>(
          context: context,
          useSafeArea: true,
          builder: (BuildContext context) => _MobileConversationActions(
            title: conversation.title,
            isPinned: conversation.isPinned,
          ),
        );
    if (!mounted || action == null) return;
    _performAction(action, conversation);
  }

  void _performAction(
    _ConversationAction action,
    ConversationView conversation,
  ) {
    switch (action) {
      case _ConversationAction.pin:
        widget.viewModel.toggleConversationPinned(conversation.id);
      case _ConversationAction.rename:
        _showRenameDialog(conversation.id, conversation.title);
      case _ConversationAction.export:
        _exportConversation(conversation.id, conversation.title);
      case _ConversationAction.delete:
        _showDeleteConfirm(conversation.id, conversation.title);
    }
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
    if (!widget.collapsible) {
      return ColoredBox(
        color: context.appColors.background,
        child: SafeArea(child: _buildFull(context)),
      );
    }

    return _CollapsibleSidebarFrame(
      collapsed: _collapsed,
      backgroundColor: context.appColors.background,
      full: SafeArea(child: _buildFull(context)),
      rail: ColoredBox(
        color: context.appColors.background,
        child: SafeArea(child: _buildRail(context)),
      ),
    );
  }

  Widget _buildFull(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: <Widget>[
              Expanded(child: _SidebarHomeButton(onTap: _newChat)),
              IconButton(
                tooltip: _searchOpen ? 'Close search' : 'Search chats',
                onPressed: _toggleSearch,
                icon: Icon(
                  _searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
                  size: 19,
                ),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: widget.onClose != null
                    ? 'Close sidebar'
                    : 'Collapse sidebar',
                onPressed: widget.onClose ?? () => _setCollapsed(true),
                icon: Icon(
                  widget.onClose != null
                      ? Icons.close_rounded
                      : Icons.keyboard_double_arrow_left_rounded,
                  size: 19,
                ),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: ListenableBuilder(
            listenable: widget.viewModel,
            builder: (BuildContext context, _) => _NewChatButton(
              onTap: _newChat,
              selected: widget.viewModel.activeId == null,
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _searchOpen
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    onChanged: (String value) =>
                        setState(() => _searchQuery = value),
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Search chats',
                      isDense: true,
                      prefixIcon: const Icon(Icons.search_rounded, size: 17),
                      suffixIcon: _searchQuery.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear',
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                              icon: const Icon(Icons.close_rounded, size: 17),
                            ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: widget.viewModel,
            builder: (BuildContext context, _) {
              final List<ConversationView> conversations = _filtered;
              if (conversations.isEmpty) {
                return _SidebarEmpty(searching: _searchQuery.isNotEmpty);
              }
              return AppScrollView(
                builder:
                    (BuildContext context, AppScrollController controller) =>
                        ListView.builder(
                          controller: controller,
                          padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
                          itemExtent: 44,
                          itemCount: conversations.length,
                          itemBuilder: (BuildContext context, int index) {
                            final ConversationView conversation =
                                conversations[index];
                            return _ConversationTile(
                              key: ValueKey<String>(conversation.id),
                              conversation: conversation,
                              active:
                                  conversation.id == widget.viewModel.activeId,
                              onTap: () {
                                widget.viewModel.selectConversation(
                                  conversation.id,
                                );
                                widget.onClose?.call();
                              },
                              onAction: (_ConversationAction action) =>
                                  _performAction(action, conversation),
                              onShowMobileActions: () =>
                                  _showMobileActions(conversation),
                            );
                          },
                        ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRail(BuildContext context) {
    return Column(
      children: <Widget>[
        const SizedBox(height: 12),
        _SidebarBrandMark(onExpand: () => _setCollapsed(false)),
        const SizedBox(height: 12),
        ListenableBuilder(
          listenable: widget.viewModel,
          builder: (BuildContext context, _) => _RailButton(
            tooltip: 'New chat',
            icon: Icons.add_comment_outlined,
            onTap: _newChat,
            selected: widget.viewModel.activeId == null,
          ),
        ),
        const SizedBox(height: 4),
        _RailButton(
          tooltip: 'Search chats',
          icon: Icons.search_rounded,
          onTap: _toggleSearch,
        ),
        const Spacer(),
        const SizedBox(height: 10),
      ],
    );
  }
}

class _CollapsibleSidebarFrame extends StatefulWidget {
  const _CollapsibleSidebarFrame({
    required this.collapsed,
    required this.backgroundColor,
    required this.full,
    required this.rail,
  });

  final ValueListenable<bool> collapsed;
  final Color backgroundColor;
  final Widget full;
  final Widget rail;

  @override
  State<_CollapsibleSidebarFrame> createState() =>
      _CollapsibleSidebarFrameState();
}

class _CollapsibleSidebarFrameState extends State<_CollapsibleSidebarFrame> {
  late bool _collapsed = widget.collapsed.value;
  late bool _showRail = _collapsed;

  @override
  void initState() {
    super.initState();
    widget.collapsed.addListener(_handleTargetChanged);
  }

  @override
  void didUpdateWidget(covariant _CollapsibleSidebarFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collapsed == widget.collapsed) return;
    oldWidget.collapsed.removeListener(_handleTargetChanged);
    _collapsed = widget.collapsed.value;
    _showRail = _collapsed;
    widget.collapsed.addListener(_handleTargetChanged);
  }

  @override
  void dispose() {
    widget.collapsed.removeListener(_handleTargetChanged);
    super.dispose();
  }

  void _handleTargetChanged() {
    setState(() {
      _collapsed = widget.collapsed.value;
      if (!_collapsed) _showRail = false;
    });
  }

  void _handleAnimationEnd() {
    if (_collapsed && !_showRail) setState(() => _showRail = true);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: widget.backgroundColor,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: _collapsed
            ? ConversationSidebar.railWidth
            : ConversationSidebar.expandedWidth,
        onEnd: _handleAnimationEnd,
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: ConversationSidebar.expandedWidth,
                child: IgnorePointer(
                  ignoring: _showRail,
                  child: ExcludeSemantics(
                    excluding: _showRail,
                    child: widget.full,
                  ),
                ),
              ),
              if (_showRail)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: ConversationSidebar.railWidth,
                  child: widget.rail,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class ConversationDrawer extends StatelessWidget {
  const ConversationDrawer({
    super.key,
    required this.viewModel,
    this.onNewChat,
  });

  final ChatViewModel viewModel;
  final VoidCallback? onNewChat;

  @override
  Widget build(BuildContext context) {
    final double width = math.min(320, MediaQuery.sizeOf(context).width * 0.88);
    return Drawer(
      width: width,
      child: ConversationSidebar(
        viewModel: viewModel,
        onNewChat: onNewChat,
        collapsible: false,
        onClose: () => Navigator.of(context).pop(),
      ),
    );
  }
}

class _NewChatButton extends StatelessWidget {
  const _NewChatButton({required this.onTap, required this.selected});

  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: context.appColors.brandViolet.withValues(
          alpha: selected ? 0.16 : 0.07,
        ),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: context.appColors.brandViolet.withValues(
            alpha: selected ? 0.3 : 0,
          ),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.add_rounded,
                  size: 18,
                  color: context.appColors.brandViolet,
                ),
                const SizedBox(width: 9),
                Text(
                  'New chat',
                  style: TextStyle(
                    color: context.appColors.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder:
                      (Widget child, Animation<double> animation) =>
                          FadeTransition(
                            opacity: animation,
                            child: ScaleTransition(
                              scale: animation,
                              child: child,
                            ),
                          ),
                  child: selected
                      ? Container(
                          key: const ValueKey<String>('current'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: context.appColors.brandViolet.withValues(
                              alpha: 0.14,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Current',
                            style: TextStyle(
                              color: context.appColors.brandViolet,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(
                          key: ValueKey<String>('not-current'),
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

class _SidebarHomeButton extends StatelessWidget {
  const _SidebarHomeButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'New chat',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.auto_awesome_rounded, size: 18),
              const SizedBox(width: 9),
              Flexible(
                child: GradientText(
                  appName,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarBrandMark extends StatefulWidget {
  const _SidebarBrandMark({required this.onExpand});

  final VoidCallback onExpand;

  @override
  State<_SidebarBrandMark> createState() => _SidebarBrandMarkState();
}

class _SidebarBrandMarkState extends State<_SidebarBrandMark> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: 'Expand sidebar',
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onExpand,
            child: SizedBox(
              width: 40,
              height: 40,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 140),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeOutCubic,
                transitionBuilder: (Widget child, Animation<double> animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(scale: animation, child: child),
                  );
                },
                child: Icon(
                  _hovered
                      ? Icons.keyboard_double_arrow_right_rounded
                      : Icons.auto_awesome_rounded,
                  key: ValueKey<bool>(_hovered),
                  size: 20,
                  color: context.appColors.brandViolet,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.selected = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: selected
              ? context.appColors.brandViolet.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? context.appColors.brandViolet.withValues(alpha: 0.28)
                : Colors.transparent,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(
                icon,
                size: 19,
                color: selected
                    ? context.appColors.brandViolet
                    : context.appColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConversationTile extends StatefulWidget {
  const _ConversationTile({
    super.key,
    required this.conversation,
    required this.active,
    required this.onTap,
    required this.onAction,
    required this.onShowMobileActions,
  });

  final ConversationView conversation;
  final bool active;
  final VoidCallback onTap;
  final ValueChanged<_ConversationAction> onAction;
  final VoidCallback onShowMobileActions;

  @override
  State<_ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<_ConversationTile> {
  bool _hovered = false;
  bool _menuOpen = false;
  PointerDeviceKind? _lastPointerKind;

  void _setHovered(bool value) {
    if (_hovered != value) setState(() => _hovered = value);
  }

  void _setMenuOpen(bool value) {
    if (_menuOpen != value) setState(() => _menuOpen = value);
  }

  void _handleLongPress() {
    if (_lastPointerKind == PointerDeviceKind.touch ||
        _lastPointerKind == PointerDeviceKind.stylus ||
        _lastPointerKind == PointerDeviceKind.invertedStylus) {
      widget.onShowMobileActions();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool showActions = _hovered || _menuOpen;
    final Color tileColor = widget.active
        ? context.appColors.brandViolet.withValues(alpha: 0.1)
        : showActions
        ? context.appColors.textPrimary.withValues(alpha: 0.045)
        : Colors.transparent;
    return Listener(
      onPointerDown: (PointerDownEvent event) => _lastPointerKind = event.kind,
      child: MouseRegion(
        onEnter: (_) => _setHovered(true),
        onExit: (_) => _setHovered(false),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tileColor,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(9),
                hoverColor: Colors.transparent,
                onTap: widget.onTap,
                onLongPress: _handleLongPress,
                child: SizedBox(
                  height: 42,
                  child: Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          12,
                          0,
                          showActions ? 76 : 12,
                          0,
                        ),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                widget.conversation.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: widget.active
                                      ? context.appColors.textPrimary
                                      : context.appColors.textSecondary,
                                  fontSize: 13,
                                  fontWeight: widget.active
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        right: 4,
                        child: IgnorePointer(
                          ignoring: !showActions,
                          child: ExcludeSemantics(
                            excluding: !showActions,
                            child: Opacity(
                              opacity: showActions ? 1 : 0,
                              child: SizedBox(
                                width: 68,
                                height: 34,
                                child: Row(
                                  children: <Widget>[
                                    SizedBox(
                                      width: 34,
                                      height: 34,
                                      child: IconButton(
                                        padding: EdgeInsets.zero,
                                        tooltip: widget.conversation.isPinned
                                            ? 'Unpin chat'
                                            : 'Pin chat',
                                        onPressed: () => widget.onAction(
                                          _ConversationAction.pin,
                                        ),
                                        icon: Icon(
                                          widget.conversation.isPinned
                                              ? Icons.push_pin_rounded
                                              : Icons.push_pin_outlined,
                                          size: 16,
                                          color: widget.conversation.isPinned
                                              ? context.appColors.brandViolet
                                              : context.appColors.textSecondary,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 34,
                                      height: 34,
                                      child:
                                          PopupMenuButton<_ConversationAction>(
                                            padding: EdgeInsets.zero,
                                            tooltip: 'Chat actions',
                                            popUpAnimationStyle:
                                                AnimationStyle.noAnimation,
                                            icon: Icon(
                                              Icons.more_horiz_rounded,
                                              size: 18,
                                              color: context
                                                  .appColors
                                                  .textSecondary,
                                            ),
                                            itemBuilder: _buildConversationMenu,
                                            onOpened: () => _setMenuOpen(true),
                                            onCanceled: () =>
                                                _setMenuOpen(false),
                                            onSelected:
                                                (_ConversationAction action) {
                                                  _setMenuOpen(false);
                                                  widget.onAction(action);
                                                },
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<PopupMenuEntry<_ConversationAction>> _buildConversationMenu(
    BuildContext context,
  ) {
    return <PopupMenuEntry<_ConversationAction>>[
      const PopupMenuItem<_ConversationAction>(
        value: _ConversationAction.rename,
        child: _MenuAction(icon: Icons.edit_outlined, label: 'Rename'),
      ),
      const PopupMenuItem<_ConversationAction>(
        value: _ConversationAction.export,
        child: _MenuAction(icon: Icons.ios_share_rounded, label: 'Export'),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem<_ConversationAction>(
        value: _ConversationAction.delete,
        child: _MenuAction(icon: Icons.delete_outline_rounded, label: 'Delete'),
      ),
    ];
  }
}

enum _ConversationAction { pin, rename, export, delete }

class _MenuAction extends StatelessWidget {
  const _MenuAction({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 18),
        const SizedBox(width: 10),
        Text(label),
      ],
    );
  }
}

class _MobileConversationActions extends StatelessWidget {
  const _MobileConversationActions({
    required this.title,
    required this.isPinned,
  });

  final String title;
  final bool isPinned;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          _MobileActionTile(
            icon: isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
            label: isPinned ? 'Unpin' : 'Pin',
            action: _ConversationAction.pin,
          ),
          const _MobileActionTile(
            icon: Icons.edit_outlined,
            label: 'Rename',
            action: _ConversationAction.rename,
          ),
          const _MobileActionTile(
            icon: Icons.ios_share_rounded,
            label: 'Export',
            action: _ConversationAction.export,
          ),
          const Divider(height: 9),
          _MobileActionTile(
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
            action: _ConversationAction.delete,
            color: Theme.of(context).colorScheme.error,
          ),
        ],
      ),
    );
  }
}

class _MobileActionTile extends StatelessWidget {
  const _MobileActionTile({
    required this.icon,
    required this.label,
    required this.action,
    this.color,
  });

  final IconData icon;
  final String label;
  final _ConversationAction action;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      onTap: () => Navigator.of(context).pop(action),
    );
  }
}

class _SidebarEmpty extends StatelessWidget {
  const _SidebarEmpty({required this.searching});

  final bool searching;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              searching ? Icons.search_off_rounded : Icons.chat_bubble_outline,
              size: 24,
              color: context.appColors.textSecondary,
            ),
            const SizedBox(height: 8),
            Text(
              searching ? 'No matching chats' : 'No conversations yet',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.appColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
