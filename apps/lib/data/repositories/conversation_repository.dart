import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../domain/models/conversation.dart';
import '../../../domain/models/message.dart';
import '../../../domain/models/provider_account.dart';
import '../services/llm/adapter_registry.dart';
import '../services/llm/llm_adapter.dart';
import '../services/llm/llm_event.dart';
import '../services/auth/secret_store.dart';
import 'provider_account_repository.dart';

/// Source of truth for conversations and the streaming reply flow.
///
/// Owns the conversation list, drives the active adapter to produce assistant
/// replies, and exposes UI-relevant state (isGenerating, active conversation)
/// via [ChangeNotifier]. The view model listens to this and forwards to the
/// UI; nothing below this layer knows about Flutter widgets.
///
/// In-memory for now — structured so a drift-backed implementation can replace
/// the storage primitives without touching the public surface.
class ConversationRepository extends ChangeNotifier {
  ConversationRepository({
    required ProviderAccountRepository providerRepository,
    required AdapterRegistry adapterRegistry,
    required this._secretStore,
  }) : _providers = providerRepository,
       _adapters = adapterRegistry {
    _conversations.add(Conversation(id: _newId(), createdAt: DateTime.now()));
    _activeId = _conversations.first.id;
    _providers.addListener(_onProvidersChanged);
  }

  final ProviderAccountRepository _providers;
  final AdapterRegistry _adapters;
  final SecretStore _secretStore;

  final List<Conversation> _conversations = <Conversation>[];
  late String _activeId;
  bool _isGenerating = false;
  StreamSubscription<LlmEvent>? _replySub;
  int _counter = 0;

  List<Conversation> get conversations => List.unmodifiable(_conversations);
  bool get isGenerating => _isGenerating;

  Conversation get active =>
      _conversations.firstWhere((Conversation c) => c.id == _activeId);

  String get activeId => _activeId;

  /// The account the active conversation is bound to, falling back to the
  /// user's currently-active account.
  ProviderAccount? get activeAccount {
    final String? bound = active.providerAccountId;
    if (bound != null) {
      return _providers.accounts.firstWhere(
        (a) => a.id == bound,
        orElse: () => _providers.activeAccount!,
      );
    }
    return _providers.activeAccount;
  }

  void newConversation() {
    if (active.isEmpty) return; // Don't stack empty "New chat" entries.
    final Conversation conversation = Conversation(
      id: _newId(),
      createdAt: DateTime.now(),
    );
    _conversations.insert(0, conversation);
    _activeId = conversation.id;
    notifyListeners();
  }

  void selectConversation(String id) {
    if (id == _activeId) return;
    _activeId = id;
    notifyListeners();
  }

  /// Appends the user's [text], then streams an assistant reply from the
  /// active conversation's bound adapter.
  Future<void> sendMessage(String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty || _isGenerating) return;

    final Conversation conversation = active;
    final bool wasEmpty = conversation.isEmpty;

    conversation.messages.add(
      ChatMessage(
        id: _newId(),
        role: MessageRole.user,
        text: trimmed,
        createdAt: DateTime.now(),
      ),
    );
    if (wasEmpty) conversation.title = _titleFrom(trimmed);

    final ChatMessage assistant = ChatMessage(
      id: _newId(),
      role: MessageRole.assistant,
      isStreaming: true,
      createdAt: DateTime.now(),
    );
    conversation.messages.add(assistant);

    _isGenerating = true;
    notifyListeners();

    final ProviderAccount? account = activeAccount;
    if (account == null) {
      assistant.text = 'No provider configured. Add one in Settings.';
      assistant.isStreaming = false;
      _isGenerating = false;
      notifyListeners();
      return;
    }

    final LlmAdapter adapter = _adapters.resolve(account.kind);
    final String? secret = await _secretStore.read(account.id);

    final Completer<void> done = Completer<void>();
    _replySub = adapter
        .stream(
          request: LlmRequest(
            messages: conversation.messages
                .where((m) => !m.isStreaming)
                .toList(),
            model: (account.config['model'] as String?) ?? '',
          ),
          account: account,
          secret: secret,
        )
        .listen(
          (LlmEvent event) {
            switch (event) {
              case TokenEvent(:final String delta):
                assistant.text += delta;
                notifyListeners();
              case ReasoningEvent(:final String delta):
                // For now, fold reasoning into the visible text. UI will
                // separate this once we add a reasoning bubble.
                assistant.text += delta;
                notifyListeners();
              case ToolCallEvent():
                // No-op for now; tool calls land in a later phase.
                break;
              case DoneEvent():
                assistant.text = assistant.text.trimRight();
                assistant.isStreaming = false;
                _isGenerating = false;
                notifyListeners();
                if (!done.isCompleted) done.complete();
              case ErrorEvent(:final LlmError error):
                assistant.text = '⚠️ ${error.message}';
                assistant.isStreaming = false;
                _isGenerating = false;
                notifyListeners();
                if (!done.isCompleted) done.complete();
            }
          },
          onError: (Object error) {
            assistant.text = 'Something went wrong. Please try again.';
            assistant.isStreaming = false;
            _isGenerating = false;
            notifyListeners();
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );

    return done.future;
  }

  /// Cancels an in-flight generation, if any.
  Future<void> cancelGeneration() async {
    await _replySub?.cancel();
    _replySub = null;
    if (_isGenerating) {
      final ChatMessage assistant = active.messages.lastWhere(
        (m) => m.isStreaming,
        orElse: () => active.messages.last,
      );
      assistant.isStreaming = false;
      _isGenerating = false;
      notifyListeners();
    }
  }

  void _onProvidersChanged() {
    // If the active account changed, the UI may want to reflect it. Nothing
    // to do to in-flight conversations — they keep their bound account.
    notifyListeners();
  }

  static String _titleFrom(String text) {
    final String oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= 32) return oneLine;
    return '${oneLine.substring(0, 32).trimRight()}…';
  }

  String _newId() =>
      'id_${DateTime.now().microsecondsSinceEpoch}_${_counter++}';

  @override
  void dispose() {
    _providers.removeListener(_onProvidersChanged);
    _replySub?.cancel();
    super.dispose();
  }
}
