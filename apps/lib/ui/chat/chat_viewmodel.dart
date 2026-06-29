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

  /// Edit a message. [resend] = true creates a sibling + re-streams; false
  /// mutates in place.
  Future<void> editMessage(String id, String text, {required bool resend}) =>
      _conversations.editMessage(id, text, resend: resend);

  /// Regenerate an assistant reply from its parent user message.
  Future<void> regenerate(String id, {String? suggestionPrompt}) =>
      _conversations.regenerate(id, suggestionPrompt: suggestionPrompt);

  /// Revert an in-place edit, restoring the original text.
  void revertEdit(String id) => _conversations.revertEdit(id);

  /// The last stream error message (for toast display). Null after cleared.
  String? get lastStreamError => _conversations.lastStreamError;
  void clearStreamError() => _conversations.clearStreamError();

  /// Switch active branch. direction = -1 (prev) or +1 (next).
  void selectSibling(String id, int direction) =>
      _conversations.selectSibling(id, direction);

  /// Rename a conversation.
  void renameConversation(String id, String newTitle) =>
      _conversations.renameConversation(id, newTitle);

  /// Delete a conversation. If active, switches to the next one.
  void deleteConversation(String id) => _conversations.deleteConversation(id);

  /// Export a conversation as Markdown.
  String exportConversation(String id) => _conversations.exportConversation(id);

  // --- Pass-through getters so the view doesn't reach into the repository ---

  List<ConversationView> get conversations =>
      _conversations.conversations.map(_toView).toList();

  ConversationView get active => _toView(_conversations.active);

  String? get activeId => _conversations.activeId;

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
  // ref.read (not ref.watch): ChatViewModel listens to both repositories via
  // addListener. ref.watch would recreate the VM on every notifyListeners(),
  // losing listener subscriptions mid-flight.
  return ChatViewModel(
    ref.read(conversationRepositoryProvider),
    ref.read(providerAccountRepositoryProvider),
  );
});
