import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../domain/models/conversation.dart';
import '../../../domain/models/message.dart';
import '../../../domain/models/provider_account.dart';
import '../services/auth/credential_resolver.dart';
import '../services/llm/adapter_registry.dart';
import '../services/llm/llm_adapter.dart';
import '../services/llm/llm_event.dart';
import '../services/llm/system_prompts.dart';
import '../services/web_retrieval/web_retrieval.dart';
import '../services/web_retrieval/web_search_tools.dart';
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
    required CredentialResolver credentialResolver,
    WebRetrievalAdapter? webRetrieval,
    bool toolsEnabled = false,
  }) : _providers = providerRepository,
       adapterRegistry = adapterRegistry,
       _credentials = credentialResolver,
       _webRetrieval = webRetrieval,
       _toolsEnabled = toolsEnabled {
    _conversations.add(Conversation(id: _newId(), createdAt: DateTime.now()));
    _activeId = _conversations.first.id;
    _providers.addListener(_onProvidersChanged);
  }

  final ProviderAccountRepository _providers;
  final AdapterRegistry adapterRegistry;
  final CredentialResolver _credentials;
  final WebRetrievalAdapter? _webRetrieval;
  bool _toolsEnabled;
  final WebSearchTools _webSearchTools = const WebSearchTools();

  final List<Conversation> _conversations = <Conversation>[];
  late String _activeId;
  bool _isGenerating = false;
  StreamSubscription<LlmEvent>? _replySub;
  int _counter = 0;

  List<Conversation> get conversations => List.unmodifiable(_conversations);
  bool get isGenerating => _isGenerating;
  bool get toolsEnabled => _toolsEnabled;

  /// Toggle whether tools are attached to outgoing messages.
  // No notifyListeners() — the UI state lives in toolsEnabledProvider
  // (Riverpod), and notifying here would rebuild the whole ChatScreen because
  // build() watches this provider. The repository just reads the flag at send
  // time.
  set toolsEnabled(bool value) {
    _toolsEnabled = value;
  }

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
  /// active conversation's bound adapter. If web search is enabled, the web
  /// search + fetch tools are attached; when the model calls them the
  /// repository executes the call, appends a tool-result message, and
  /// re-streams so the model can use the results.
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

    _isGenerating = true;
    notifyListeners();

    final ProviderAccount? account = activeAccount;
    if (account == null) {
      conversation.messages.add(
        ChatMessage(
          id: _newId(),
          role: MessageRole.assistant,
          text: 'No provider configured. Add one in Settings.',
          createdAt: DateTime.now(),
        ),
      );
      _isGenerating = false;
      notifyListeners();
      return;
    }

    final LlmAdapter adapter = adapterRegistry.resolve(account.kind);
    final String? secret = await _credentials.resolve(account);
    final String model = (account.config['model'] as String?) ?? '';

    // Tool-call loop: stream → if the model emitted tool calls, execute them,
    // append tool-result messages, and re-stream. Caps at a few rounds so a
    // misbehaving model can't loop forever.
    const int maxRounds = 5;
    for (int round = 0; round < maxRounds; round++) {
      final ChatMessage assistant = ChatMessage(
        id: _newId(),
        role: MessageRole.assistant,
        isStreaming: true,
        createdAt: DateTime.now(),
      );
      conversation.messages.add(assistant);
      notifyListeners();

      final List<ToolCall> pendingCalls = <ToolCall>[];
      // Accumulate tool-call fragments by index (OpenAI streams id/name first,
      // then argument tokens across multiple ToolCallEvents).
      final Map<int, ToolCall> accumulating = <int, ToolCall>{};

      final Completer<void> done = Completer<void>();
      bool hadError = false;

      _replySub = adapter
          .stream(
            request: LlmRequest(
              messages: conversation.messages
                  .where((m) => !m.isStreaming)
                  .toList(),
              model: model,
              systemPrompt: SystemPrompts.base,
              tools: _toolsEnabled && _webRetrieval != null
                  ? _webSearchTools.definitions
                  : const <ToolDefinition>[],
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
                case ToolCallEvent(
                  :final String id,
                  :final String name,
                  :final String args,
                ):
                  // OpenAI streams tool_calls with an index; we don't get it
                  // from the event directly, so accumulate by id+name. The
                  // first fragment carries id+name, later fragments carry
                  // argument tokens only (empty id/name).
                  if (id.isNotEmpty || name.isNotEmpty) {
                    final ToolCall tc = ToolCall(
                      id: id,
                      name: name,
                      args: args,
                    );
                    accumulating[accumulating.length] = tc;
                    assistant.toolCalls = List<ToolCall>.from(
                      accumulating.values,
                    );
                  } else {
                    // Argument fragment — append to the last call.
                    if (accumulating.isNotEmpty) {
                      final int lastKey = accumulating.keys.last;
                      accumulating[lastKey]!.args += args;
                    }
                  }
                  notifyListeners();
                case DoneEvent():
                  assistant.text = assistant.text.trimRight();
                  assistant.isStreaming = false;
                  pendingCalls.addAll(accumulating.values);
                  notifyListeners();
                  if (!done.isCompleted) done.complete();
                case ErrorEvent(:final LlmError error):
                  assistant.text = '⚠️ ${error.message}';
                  assistant.isStreaming = false;
                  hadError = true;
                  notifyListeners();
                  if (!done.isCompleted) done.complete();
              }
            },
            onError: (Object error) {
              assistant.text = 'Something went wrong. Please try again.';
              assistant.isStreaming = false;
              hadError = true;
              notifyListeners();
              if (!done.isCompleted) done.complete();
            },
            cancelOnError: true,
          );

      await done.future;
      _replySub = null;

      // If the model didn't call any tools (or errored), the reply is done.
      if (hadError || pendingCalls.isEmpty) {
        _isGenerating = false;
        notifyListeners();
        return;
      }

      // Execute each tool call and append a tool-result message.
      if (_webRetrieval == null) {
        // No adapter configured — surface the calls but skip execution.
        for (final ToolCall tc in pendingCalls) {
          conversation.messages.add(
            ChatMessage(
              id: _newId(),
              role: MessageRole.tool,
              text: 'Web search not configured.',
              toolCallId: tc.id,
              createdAt: DateTime.now(),
            ),
          );
        }
      } else {
        final WebRetrievalAdapter retrieval = _webRetrieval;
        for (final ToolCall tc in pendingCalls) {
          String result;
          try {
            result = await _webSearchTools.execute(
              name: tc.name,
              args: tc.args,
              adapter: retrieval,
            );
          } catch (e) {
            result = 'Error executing tool "${tc.name}": $e';
          }
          conversation.messages.add(
            ChatMessage(
              id: _newId(),
              role: MessageRole.tool,
              text: result,
              toolCallId: tc.id,
              createdAt: DateTime.now(),
            ),
          );
          notifyListeners();
        }
      }
      // Loop: re-stream so the model can use the tool results.
    }

    // Exhausted the round cap — stop gracefully.
    _isGenerating = false;
    notifyListeners();
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
