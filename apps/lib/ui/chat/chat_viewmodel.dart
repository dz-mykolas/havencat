import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/conversation_repository.dart';
import '../../data/repositories/provider_account_repository.dart';
import '../../domain/models/conversation.dart';
import '../../providers.dart';

/// UI-layer state for the chat screen.
///
/// Per the Flutter architecture guide, the view model holds only UI state
/// (isGenerating, activeId, scroll-to-bottom triggers) and forwards user
/// actions to the repository. It does NOT own conversations or provider
/// accounts — those live in the repositories below.
///
/// It listens to both repositories and re-notifies so the view can rebuild
/// with a single `ListenableBuilder`.
class ChatViewModel extends ChangeNotifier {
  ChatViewModel(this._conversations, this._providers) {
    _conversations.addListener(_relay);
    _providers.addListener(_relay);
  }

  final ConversationRepository _conversations;
  final ProviderAccountRepository _providers;

  void newConversation() => _conversations.newConversation();
  void selectConversation(String id) => _conversations.selectConversation(id);
  Future<void> sendMessage(String text) => _conversations.sendMessage(text);
  Future<void> cancelGeneration() => _conversations.cancelGeneration();

  // --- Pass-through getters so the view doesn't reach into the repository ---

  List<ConversationView> get conversations =>
      _conversations.conversations.map(_toView).toList();

  ConversationView get active => _toView(_conversations.active);

  String get activeId => _conversations.activeId;

  bool get isGenerating => _conversations.isGenerating;

  String? get activeProviderName => _providers.activeAccount?.displayName;

  void _relay() => notifyListeners();

  static ConversationView _toView(Conversation c) {
    return ConversationView(
      id: c.id,
      title: c.isEmpty ? 'New chat' : c.title,
      messageCount: c.messages.length,
    );
  }

  @override
  void dispose() {
    _conversations.removeListener(_relay);
    _providers.removeListener(_relay);
    super.dispose();
  }
}

/// Immutable view of a conversation for the UI. The view model maps the
/// domain [Conversation] into this so widgets never touch the domain layer's
/// mutable message list directly.
class ConversationView {
  const ConversationView({
    required this.id,
    required this.title,
    required this.messageCount,
  });

  final String id;
  final String title;
  final int messageCount;
}

final chatViewModelProvider = ChangeNotifierProvider<ChatViewModel>((ref) {
  return ChatViewModel(
    ref.watch(conversationRepositoryProvider),
    ref.watch(providerAccountRepositoryProvider),
  );
});
