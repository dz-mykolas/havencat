import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../branding.dart';
import '../../data/services/web_retrieval/web_retrieval.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/animated_background.dart';
import '../core/widgets/gradient_text.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../domain/models/conversation.dart';
import '../../domain/models/message.dart';
import '../../providers.dart';
import '../settings/settings_screen.dart';
import 'chat_viewmodel.dart';
import 'widgets/chat_input.dart';
import 'widgets/conversation_drawer.dart';
import 'widgets/empty_state.dart';
import 'widgets/message_bubble.dart';
import 'widgets/smooth_scroll.dart';

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
  final ScrollController _scrollController = ScrollController();

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
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _send(String text) async {
    _scrollToBottom(force: true);
    await ref.read(chatViewModelProvider).sendMessage(text);
    _scrollToBottom(force: true);
  }

  void _checkStreamError(ChatViewModel vm) {
    final String? error = vm.lastStreamError;
    if (error == null) return;
    vm.clearStreamError();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.startsWith('⚠️') ? error : '⚠️ $error'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
    });
  }

  void _openSettings(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
  }

  void _goHome() {
    ref.read(chatViewModelProvider).newConversation();
    _textController.clear();
    final ScaffoldState? scaffold = Scaffold.maybeOf(context);
    if (scaffold?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
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
    final ChatViewModel vm = ref.watch(chatViewModelProvider);
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
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ChatViewModel vm = ref.watch(chatViewModelProvider);
    final ConversationRepository repo = ref.watch(
      conversationRepositoryProvider,
    );

    // On wide screens the logo sits on the left; on phones it's slightly
    // smaller. The model selector lives in the input bar now.
    final bool wide = MediaQuery.of(context).size.width >= 720;

    final Widget chatScaffold = Scaffold(
      drawer: wide ? null : ConversationDrawer(viewModel: vm),
      appBar: AppBar(
        titleSpacing: wide ? 16 : 8,
        title: wide ? _buildLogo(fontSize: 20) : _buildLogo(fontSize: 17),
        actions: <Widget>[
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _openSettings(context),
          ),
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: () => vm.newConversation(),
          ),
          const SizedBox(width: 4),
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
              listenable: repo,
              builder: (BuildContext context, _) {
                final Conversation conversation = repo.active;
                if (conversation.isEmpty) {
                  return EmptyState(input: _buildInput());
                }
                // Keep pinned to the newest content as tokens stream in.
                _scrollToBottom();
                _checkStreamError(vm);
                final List<ChatMessage> activePath = conversation.activePath;
                return Stack(
                  children: <Widget>[
                    // ListView extends full height; text scrolls behind the
                    // input pill.
                    SmoothScroll(
                      controller: _scrollController,
                      scrollSpeed: 2.5,
                      scrollAnimationLength: 600,
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                        itemCount: activePath.length,
                        cacheExtent: 1500,
                        itemBuilder: (BuildContext context, int index) {
                          final ChatMessage message = activePath[index];
                          // Visible messages on the active path after this
                          // one (excluding hidden tool-result messages) —
                          // these are what branch off when editing+resending.
                          final int downstreamCount = activePath
                              .sublist(index + 1)
                              .where((m) => !m.isTool)
                              .length;
                          return Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: AppTheme.contentMaxWidth,
                              ),
                              child: MessageBubble(
                                key: ValueKey<String>(message.id),
                                message: message,
                                messages: activePath,
                                siblings: conversation.siblingsOf(message.id),
                                isLast: index == activePath.length - 1,
                                isGenerating: vm.isGenerating,
                                descendantCount: downstreamCount,
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
                    // Gradient that fades text out before the pill.
                    // Constrained to content width + centered so it doesn't
                    // paint over the scrollbar (which lives in the right
                    // margin of the full-width ListView).
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: AppTheme.contentMaxWidth,
                            ),
                            child: Container(
                              height: 120,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: <Color>[
                                    AppTheme.background.withValues(alpha: 0),
                                    AppTheme.background,
                                  ],
                                  stops: const <double>[0, 0.5],
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
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 27),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
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

    // On wide screens, show the sidebar as a persistent panel that pushes
    // content to the right. On narrow screens, it's a drawer overlay.
    if (wide) {
      return Row(
        children: <Widget>[
          ConversationSidebar(viewModel: vm),
          Expanded(child: chatScaffold),
        ],
      );
    }
    return chatScaffold;
  }
}
