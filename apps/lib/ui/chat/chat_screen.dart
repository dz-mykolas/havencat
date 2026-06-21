import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../branding.dart';
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
    await ref.read(chatViewModelProvider).sendMessage(text);
    _scrollToBottom();
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
    return ListenableBuilder(
      listenable: vm,
      builder: (BuildContext context, _) {
        return ChatInput(
          textController: _textController,
          isGenerating: vm.isGenerating,
          onSend: _send,
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
