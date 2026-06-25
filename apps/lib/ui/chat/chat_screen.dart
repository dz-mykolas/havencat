import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../branding.dart';
import '../../data/services/web_retrieval/web_retrieval.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/animated_background.dart';
import '../core/widgets/gradient_text.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../domain/models/conversation.dart';
import '../../providers.dart';
import '../settings/settings_screen.dart';
import 'chat_viewmodel.dart';
import 'widgets/chat_input.dart';
import 'widgets/conversation_drawer.dart';
import 'widgets/empty_state.dart';
import 'widgets/message_bubble.dart';
import 'widgets/smooth_scroll.dart';
import 'widgets/model_selector_bar.dart';

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

  void _prefill(String suggestion) {
    _textController
      ..text = suggestion
      ..selection = TextSelection.collapsed(offset: suggestion.length);
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

    // On wide screens the logo sits on the left and the model selector is
    // centered (via flexibleSpace); on phones a compact selector rides right
    // next to the logo so the bar still fits.
    final bool wide = MediaQuery.of(context).size.width >= 720;

    return Scaffold(
      drawer: ConversationDrawer(viewModel: vm),
      appBar: AppBar(
        titleSpacing: wide ? 16 : 8,
        title: wide
            ? _buildLogo(fontSize: 20)
            : Row(
                children: <Widget>[
                  _buildLogo(fontSize: 17),
                  const SizedBox(width: 10),
                  const Flexible(child: ModelSelectorBar(compact: true)),
                ],
              ),
        flexibleSpace: wide
            ? SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: const ModelSelectorBar(),
                  ),
                ),
              )
            : null,
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
            child: ListenableBuilder(
              listenable: repo,
              builder: (BuildContext context, _) {
                final Conversation conversation = repo.active;
                if (conversation.isEmpty) {
                  return EmptyState(
                    onSuggestionTap: _prefill,
                    input: _buildInput(),
                  );
                }
                // Keep pinned to the newest content as tokens stream in.
                _scrollToBottom();
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
                        itemCount: conversation.messages.length,
                        itemBuilder: (BuildContext context, int index) {
                          return Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: AppTheme.contentMaxWidth,
                              ),
                              child: MessageBubble(
                                message: conversation.messages[index],
                                messages: conversation.messages,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    // Gradient that fades text out before the pill.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
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
  }
}
