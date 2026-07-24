import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox, ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_router.dart';
import '../../branding.dart';
import '../../data/services/storage/app_settings.dart';
import '../../data/services/llm/token_estimator.dart';
import '../../data/services/web_retrieval/web_retrieval.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/animated_background.dart';
import '../core/widgets/app_scroll_view.dart';
import '../core/widgets/gradient_text.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../domain/models/conversation.dart';
import '../../domain/models/generation_task.dart';
import '../../domain/models/message.dart';
import '../../domain/models/message_attachment.dart';
import '../../domain/errors/app_failure.dart';
import '../../providers.dart';
import '../settings/settings_screen.dart';
import 'chat_viewmodel.dart';
import 'widgets/chat_input.dart';
import 'widgets/conversation_drawer.dart';
import 'widgets/empty_state.dart';
import 'widgets/message_bubble.dart';
import '../core/notices/failure_presenter.dart';

/// The main chat view: app bar, conversation drawer, message list, and the
/// animated input bar.
///
/// Reads the [ChatViewModel] for UI state (isGenerating, active id, list of
/// conversations) and the [ConversationRepository] for the active
/// conversation's messages (which mutate token-by-token during streaming).
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({this.conversationId, super.key});

  final String? conversationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final AppScrollController _scrollController = AppScrollController();
  double _composerHeight = 64;
  bool _followLatest = true;
  bool _bottomScrollScheduled = false;
  bool _animateNextBottomScroll = false;
  late final ChatViewModel _routeViewModel;
  String? _lastObservedActiveId;
  bool _syncingConversationRoute = false;

  static const double _followThreshold = 72;
  static const double _minimumTrailingSpace = 200;
  static const double _composerClearance = 64;

  @override
  void initState() {
    super.initState();
    _routeViewModel = ref.read(chatViewModelProvider);
    _lastObservedActiveId = _routeViewModel.activeId;
    _routeViewModel.addListener(_handleActiveConversationChanged);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_syncConversationFromRoute()),
    );
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId == widget.conversationId) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_syncConversationFromRoute()),
    );
  }

  @override
  void dispose() {
    _routeViewModel.removeListener(_handleActiveConversationChanged);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _syncConversationFromRoute() async {
    final String? requestedId = widget.conversationId;
    final ConversationRepository repository = ref.read(
      conversationRepositoryProvider,
    );
    await repository.ready;
    if (!mounted || widget.conversationId != requestedId) return;

    _syncingConversationRoute = true;
    try {
      if (requestedId == null) {
        if (repository.activeId != null) repository.newConversation();
      } else if (repository.conversations.any(
        (Conversation conversation) => conversation.id == requestedId,
      )) {
        repository.selectConversation(requestedId);
      } else {
        context.replace(homeRoute);
      }
      _lastObservedActiveId = repository.activeId;
    } finally {
      _syncingConversationRoute = false;
    }
  }

  void _handleActiveConversationChanged() {
    final String? activeId = _routeViewModel.activeId;
    if (activeId == _lastObservedActiveId) return;
    _lastObservedActiveId = activeId;
    if (!mounted || _syncingConversationRoute) return;

    final String currentRoute = GoRouter.of(context).state.uri.path;
    if (currentRoute != homeRoute && !currentRoute.startsWith('/chat/')) return;
    final String nextRoute = activeId == null
        ? homeRoute
        : chatRouteFor(activeId);
    if (currentRoute != nextRoute) context.go(nextRoute);
  }

  void _scrollToBottom({bool force = false, bool animate = false}) {
    if (force) _setFollowLatest(true);
    _animateNextBottomScroll |= animate;
    if (!_followLatest || _bottomScrollScheduled) return;
    _bottomScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bottomScrollScheduled = false;
      final bool shouldAnimate = _animateNextBottomScroll;
      _animateNextBottomScroll = false;
      if (!mounted || !_followLatest || !_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if ((pos.maxScrollExtent - pos.pixels).abs() < 0.5) return;
      if (shouldAnimate) {
        unawaited(
          _scrollController.animateTo(
            pos.maxScrollExtent,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
          ),
        );
      } else {
        _scrollController.jumpTo(pos.maxScrollExtent);
      }
    });
  }

  void _setFollowLatest(bool value) {
    if (_followLatest == value) return;
    setState(() => _followLatest = value);
  }

  bool _handleChatScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification case ScrollUpdateNotification(
      :final dragDetails,
      :final scrollDelta,
    )) {
      if (dragDetails != null && scrollDelta != null) {
        if (scrollDelta < 0) {
          _setFollowLatest(false);
        } else if (notification.metrics.extentAfter <= _followThreshold) {
          _setFollowLatest(true);
        }
      }
    } else if (notification is ScrollEndNotification &&
        notification.metrics.extentAfter <= _followThreshold) {
      _setFollowLatest(true);
    }
    return false;
  }

  void _handleComposerSize(Size size) {
    if (!mounted || (size.height - _composerHeight).abs() < 0.5) return;
    setState(() => _composerHeight = size.height);
    _scrollToBottom();
  }

  Future<void> _send(String text, List<MessageAttachment> attachments) async {
    _scrollToBottom(force: true);
    await ref
        .read(chatViewModelProvider)
        .sendMessage(text, attachments: attachments);
    _scrollToBottom(force: true);
  }

  void _publishFailure(ChatViewModel vm) {
    final AppFailure? failure = vm.lastFailure;
    if (failure == null) return;
    vm.clearLastFailure();
    final FailurePresenter presenter = FailurePresenter();
    final notice = presenter.present(
      failure,
      onRetry: failure.isRetryable ? vm.retryLastFailure : null,
      onOpenSettings: () async {
        if (!mounted) return;
        await openSettingsForFailure(context, failure);
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(noticeCenterProvider).publish(notice);
    });
  }

  void _openSettings(
    BuildContext context, {
    SettingsSection? initialSection,
    String? route,
  }) {
    unawaited(context.push<void>(route ?? settingsRouteFor(initialSection)));
  }

  void _goHome() {
    ref.read(chatViewModelProvider).newConversation();
    _textController.clear();
  }

  Widget _buildLogo({required double fontSize}) {
    return Tooltip(
      message: 'Home',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _goHome,
          behavior: HitTestBehavior.opaque,
          child: GradientText(
            appName,
            style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }

  Widget _buildInput(_ChatInputState state) {
    final ChatViewModel vm = ref.read(chatViewModelProvider);
    final AppSettings appSettings = ref.watch(appSettingsProvider);
    final bool toolsEnabled = appSettings.toolsEnabled;
    final WebRetrievalAdapter webRetrieval = ref.watch(webRetrievalProvider);
    return ChatInput(
      textController: _textController,
      isGenerating: state.isGenerating,
      queuedCount: state.queuedCount,
      onSend: _send,
      onCancel: () => unawaited(vm.cancelGeneration()),
      onSteer: (String text) => unawaited(vm.steerGeneration(text)),
      onShowQueue: () => _showGenerationQueue(vm),
      toolsEnabled: toolsEnabled,
      onToggleTools: (bool next) {
        ref.read(conversationRepositoryProvider).toolsEnabled = next;
        unawaited(appSettings.setToolsEnabled(next));
      },
      webRetrievalAdapter: webRetrieval,
      imageUploadEnabled: state.canUploadImages,
    );
  }

  void _showGenerationQueue(ChatViewModel vm) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (BuildContext context) {
        return ListenableBuilder(
          listenable: vm,
          builder: (BuildContext context, _) {
            final List<GenerationTask> tasks = vm.queuedGenerations;
            return ListView(
              shrinkWrap: true,
              padding: EdgeInsets.symmetric(vertical: 12),
              children: <Widget>[
                ListTile(
                  title: Text('Queued messages'),
                  subtitle: Text('${tasks.length} waiting'),
                ),
                for (int index = 0; index < tasks.length; index++)
                  ListTile(
                    title: Text(
                      vm.queuedGenerationText(tasks[index]),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _editQueuedGeneration(vm, tasks[index]),
                    leading: Text('${index + 1}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        IconButton(
                          tooltip: 'Move up',
                          onPressed:
                              !vm.canMoveQueuedGeneration(tasks[index].id, -1)
                              ? null
                              : () => unawaited(
                                  vm.moveQueuedGeneration(tasks[index].id, -1),
                                ),
                          icon: Icon(Icons.arrow_upward_rounded),
                        ),
                        IconButton(
                          tooltip: 'Move down',
                          onPressed:
                              !vm.canMoveQueuedGeneration(tasks[index].id, 1)
                              ? null
                              : () => unawaited(
                                  vm.moveQueuedGeneration(tasks[index].id, 1),
                                ),
                          icon: Icon(Icons.arrow_downward_rounded),
                        ),
                        IconButton(
                          tooltip: 'Remove',
                          onPressed:
                              vm.canRemoveQueuedGeneration(tasks[index].id)
                              ? () => unawaited(
                                  vm.removeQueuedGeneration(tasks[index].id),
                                )
                              : null,
                          icon: Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _editQueuedGeneration(
    ChatViewModel vm,
    GenerationTask task,
  ) async {
    final TextEditingController controller = TextEditingController(
      text: vm.queuedGenerationText(task),
    );
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Edit queued message'),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 1,
            maxLines: 5,
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text('Save'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (value != null) await vm.editQueuedGeneration(task.id, value);
  }

  @override
  Widget build(BuildContext context) {
    final ChatViewModel vm = ref.read(chatViewModelProvider);
    final AppSettings settings = ref.watch(appSettingsProvider);
    final ConversationRepository repo = ref.read(
      conversationRepositoryProvider,
    );
    final _ChatInputState inputState = ref.watch(
      chatViewModelProvider.select(
        (ChatViewModel value) => (
          isGenerating: value.isGenerating,
          queuedCount: value.queuedGenerationCount,
          canUploadImages: value.canUploadImages,
        ),
      ),
    );
    final bool isEmpty = ref.watch(
      conversationRepositoryProvider.select(
        (ConversationRepository value) => value.active.isEmpty,
      ),
    );

    // On wide screens the logo sits on the left; on phones it's slightly
    // smaller. The model selector lives in the input bar now.
    final double viewportWidth = MediaQuery.sizeOf(context).width;
    final double persistentSidebarBreakpoint =
        ConversationSidebar.expandedWidth * 2 -
        ConversationSidebar.railWidth +
        AppTheme.contentMaxWidth;
    final bool persistentSidebar = viewportWidth >= persistentSidebarBreakpoint;
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    final double topSafeInset = mediaQuery.padding.top;
    final double bottomSafeInset = mediaQuery.viewInsets.bottom > 0
        ? 0
        : mediaQuery.viewPadding.bottom;
    final double composerBottomInset = 27 + bottomSafeInset;
    final double trailingSpace = math.max(
      _minimumTrailingSpace,
      _composerHeight + composerBottomInset + _composerClearance,
    );
    final double bottomFadeHeight = _composerHeight + composerBottomInset + 48;
    final double headerExtent = topSafeInset + kToolbarHeight;
    final double headerFadeHeight = headerExtent + 44;

    final Widget chatScaffold = Scaffold(
      drawer: persistentSidebar
          ? null
          : ConversationDrawer(
              viewModel: vm,
              onNewChat: _goHome,
              themeSlot: settings.themeSlot,
              onToggleTheme: settings.toggleThemeSlot,
              onOpenSettings: () => _openSettings(context),
            ),
      drawerEnableOpenDragGesture: !persistentSidebar,
      drawerEdgeDragWidth: viewportWidth,
      drawerScrimColor: Theme.of(
        context,
      ).colorScheme.scrim.withValues(alpha: 0.42),
      appBar: AppBar(
        titleSpacing: persistentSidebar ? 16 : 8,
        title: persistentSidebar ? null : _buildLogo(fontSize: 17),
        actions: <Widget>[
          IconButton(
            tooltip: 'New chat',
            icon: Icon(Icons.add_comment_outlined),
            onPressed: _goHome,
          ),
          SizedBox(width: 4),
        ],
      ),
      // Let the animated background bleed behind the transparent app bar.
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBackground(active: inputState.isGenerating),
            ),
          ),
          SafeArea(
            top: false,
            bottom: false,
            child: ListenableBuilder(
              key: ValueKey<bool>(isEmpty),
              listenable: vm,
              child: _buildInput(inputState),
              builder: (BuildContext context, Widget? input) {
                _publishFailure(vm);
                final Conversation conversation = repo.active;
                if (conversation.isEmpty) {
                  return Padding(
                    padding: EdgeInsets.only(top: headerExtent),
                    child: EmptyState(input: input!),
                  );
                }
                // Keep pinned to the newest content as tokens stream in.
                _scrollToBottom();
                final List<ChatMessage> activePath = conversation.activePath;
                final List<int> downstreamCounts = List<int>.filled(
                  activePath.length,
                  0,
                );
                int visibleAfter = 0;
                for (int i = activePath.length - 1; i >= 0; i--) {
                  downstreamCounts[i] = visibleAfter;
                  if (!activePath[i].isTool) visibleAfter++;
                }
                return Stack(
                  children: <Widget>[
                    // ListView extends full height; text scrolls behind the
                    // input pill.
                    NotificationListener<ScrollNotification>(
                      onNotification: _handleChatScroll,
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: EdgeInsets.fromLTRB(
                          16,
                          headerExtent + 12,
                          16,
                          trailingSpace,
                        ),
                        itemCount: activePath.length,
                        scrollCacheExtent: ScrollCacheExtent.pixels(1500),
                        itemBuilder: (BuildContext context, int index) {
                          final ChatMessage message = activePath[index];
                          return Center(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: AppTheme.contentMaxWidth,
                              ),
                              child: MessageBubble(
                                key: ValueKey<String>(message.id),
                                message: message,
                                messages: activePath,
                                siblings: conversation.siblingsOf(message.id),
                                isLast: index == activePath.length - 1,
                                isGenerating: vm.isGenerating,
                                descendantCount: downstreamCounts[index],
                                actualTokens: message.promptTokens,
                                completionTokens: message.completionTokens,
                                totalTokens: message.totalTokens,
                                estimatedTokens:
                                    message.isAssistant &&
                                        index == activePath.length - 1
                                    ? vm.active.lastEstimatedTokens
                                    : null,
                                estimatedCompletionTokens:
                                    message.isAssistant &&
                                        index == activePath.length - 1
                                    ? estimateGeneratedTokens(message)
                                    : null,
                                contextWindow: vm.activeContextWindow,
                                onEditUser: message.isUser
                                    ? (newText, resend) => vm.editMessage(
                                        message.id,
                                        newText,
                                        resend: resend,
                                      )
                                    : null,
                                onRegenerate: message.isAssistant
                                    ? ({String? suggestion}) => vm.regenerate(
                                        message.id,
                                        suggestionPrompt: suggestion,
                                      )
                                    : null,
                                onContinue:
                                    message.isAssistant &&
                                        (message.generationStatus ==
                                                MessageGenerationStatus
                                                    .interrupted ||
                                            message.generationStatus ==
                                                MessageGenerationStatus.failed)
                                    ? () => vm.continueInterrupted(message.id)
                                    : null,
                                onRevert: message.isEdited
                                    ? () => vm.revertEdit(message.id)
                                    : null,
                                onPrevSibling: () =>
                                    vm.selectSibling(message.id, -1),
                                onNextSibling: () =>
                                    vm.selectSibling(message.id, 1),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: IgnorePointer(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: AppTheme.contentMaxWidth,
                            ),
                            child: Container(
                              height: headerFadeHeight,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: <Color>[
                                    context.appColors.background,
                                    context.appColors.background,
                                    context.appColors.background.withValues(
                                      alpha: 0,
                                    ),
                                  ],
                                  stops: <double>[
                                    0,
                                    headerExtent / headerFadeHeight,
                                    1,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Gradient that fades text out before the pill.
                    // Constrained to the centered content width.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: AppTheme.contentMaxWidth,
                            ),
                            child: Container(
                              height: bottomFadeHeight,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: <Color>[
                                    context.appColors.background.withValues(
                                      alpha: 0,
                                    ),
                                    context.appColors.background,
                                  ],
                                  stops: <double>[0, 48 / bottomFadeHeight],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: composerBottomInset + _composerHeight + 12,
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 160),
                          child: _followLatest
                              ? const SizedBox.shrink()
                              : IconButton.filledTonal(
                                  key: const ValueKey<String>('jump-to-latest'),
                                  tooltip: 'Jump to latest',
                                  onPressed: () => _scrollToBottom(
                                    force: true,
                                    animate: true,
                                  ),
                                  icon: const Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                  ),
                                ),
                        ),
                      ),
                    ),
                    // Input pill floating on top, bottom-aligned.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          12,
                          0,
                          12,
                          composerBottomInset,
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: AppTheme.contentMaxWidth,
                            ),
                            child: _SizeReporter(
                              onSizeChanged: _handleComposerSize,
                              child: input!,
                            ),
                          ),
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

    // At this breakpoint the chat remains wider than its content constraint
    // throughout the sidebar animation, so the panel can push it without
    // reflowing message content.
    if (persistentSidebar) {
      return Row(
        children: <Widget>[
          RepaintBoundary(
            child: ConversationSidebar(
              viewModel: vm,
              onNewChat: _goHome,
              themeSlot: settings.themeSlot,
              onToggleTheme: settings.toggleThemeSlot,
              onOpenSettings: () => _openSettings(context),
            ),
          ),
          Expanded(child: RepaintBoundary(child: chatScaffold)),
        ],
      );
    }
    return chatScaffold;
  }
}

class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onSizeChanged, required super.child});

  final ValueChanged<Size> onSizeChanged;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderSizeReporter(onSizeChanged);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderSizeReporter renderObject,
  ) {
    renderObject.onSizeChanged = onSizeChanged;
  }
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onSizeChanged);

  ValueChanged<Size> onSizeChanged;
  Size? _reportedSize;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _reportedSize) return;
    _reportedSize = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onSizeChanged(size));
  }
}

typedef _ChatInputState = ({
  bool isGenerating,
  int queuedCount,
  bool canUploadImages,
});
