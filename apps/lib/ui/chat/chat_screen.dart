import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../branding.dart';
import '../../data/services/storage/app_settings.dart';
import '../../data/services/web_retrieval/web_retrieval.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/animated_background.dart';
import '../core/widgets/app_scroll_view.dart';
import '../core/widgets/gradient_text.dart';
import '../core/widgets/theme_mode_button.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../domain/models/conversation.dart';
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
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final AppScrollController _scrollController = AppScrollController();

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool force = false}) {
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      // Don't fight the user: only auto-scroll if they're near the bottom.
      final bool nearBottom = pos.maxScrollExtent - pos.pixels < 120;
      if (!force && !nearBottom) return;
      _scrollController.animateTo(
        pos.maxScrollExtent,
        duration: Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    });
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
        if (mounted) _openSettings(context);
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(noticeCenterProvider).publish(notice);
    });
  }

  void _openSettings(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => SettingsScreen()));
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

  Widget _buildInput() {
    final ChatViewModel vm = ref.read(chatViewModelProvider);
    final bool toolsEnabled = ref.watch(toolsEnabledProvider);
    final WebRetrievalAdapter webRetrieval = ref.watch(webRetrievalProvider);
    return ListenableBuilder(
      listenable: vm,
      builder: (BuildContext context, _) {
        return ChatInput(
          textController: _textController,
          isGenerating: vm.isGenerating,
          onSend: _send,
          toolsEnabled: toolsEnabled,
          onToggleTools: (bool next) {
            ref.read(toolsEnabledProvider.notifier).state = next;
            ref.read(conversationRepositoryProvider).toolsEnabled = next;
          },
          webRetrievalAdapter: webRetrieval,
          imageUploadEnabled: vm.canUploadImages,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ChatViewModel vm = ref.read(chatViewModelProvider);
    final AppSettings settings = ref.watch(appSettingsProvider);
    final ConversationRepository repo = ref.read(
      conversationRepositoryProvider,
    );

    // On wide screens the logo sits on the left; on phones it's slightly
    // smaller. The model selector lives in the input bar now.
    final double viewportWidth = MediaQuery.sizeOf(context).width;
    final double persistentSidebarBreakpoint =
        ConversationSidebar.expandedWidth * 2 -
        ConversationSidebar.railWidth +
        AppTheme.contentMaxWidth;
    final bool persistentSidebar = viewportWidth >= persistentSidebarBreakpoint;
    final double topSafeInset = MediaQuery.paddingOf(context).top;
    final double headerExtent = topSafeInset + kToolbarHeight;
    final double headerFadeHeight = headerExtent + 44;

    final Widget chatScaffold = Scaffold(
      drawer: persistentSidebar
          ? null
          : ConversationDrawer(viewModel: vm, onNewChat: _goHome),
      drawerEnableOpenDragGesture: !persistentSidebar,
      drawerEdgeDragWidth: 80,
      drawerScrimColor: Theme.of(
        context,
      ).colorScheme.scrim.withValues(alpha: 0.42),
      appBar: AppBar(
        titleSpacing: persistentSidebar ? 16 : 8,
        title: persistentSidebar ? null : _buildLogo(fontSize: 17),
        actions: <Widget>[
          ThemeModeButton(
            slot: settings.themeSlot,
            onToggle: settings.toggleThemeSlot,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: Icon(Icons.settings_outlined),
            onPressed: () => _openSettings(context),
          ),
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
            child: ListenableBuilder(
              listenable: vm,
              builder: (BuildContext context, _) {
                return AnimatedBackground(active: vm.isGenerating);
              },
            ),
          ),
          SafeArea(
            top: false,
            child: ListenableBuilder(
              listenable: vm,
              builder: (BuildContext context, _) {
                _publishFailure(vm);
                final Conversation conversation = repo.active;
                if (conversation.isEmpty) {
                  return Padding(
                    padding: EdgeInsets.only(top: headerExtent),
                    child: EmptyState(input: _buildInput()),
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
                    ListView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.fromLTRB(
                        16,
                        headerExtent + 12,
                        16,
                        200,
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
                              height: 120,
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
                                  stops: <double>[0, 0.5],
                                ),
                              ),
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
                        padding: EdgeInsets.fromLTRB(12, 0, 12, 27),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: AppTheme.contentMaxWidth,
                            ),
                            child: _buildInput(),
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
            child: ConversationSidebar(viewModel: vm, onNewChat: _goHome),
          ),
          Expanded(child: RepaintBoundary(child: chatScaffold)),
        ],
      );
    }
    return chatScaffold;
  }
}
