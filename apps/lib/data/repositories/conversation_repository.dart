import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

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

  static final Logger _log = Logger('conversation');

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

  /// Set when the last stream failed and was rolled back. The UI shows a
  /// toast and clears it. Null when no error or after the UI acknowledged it.
  String? _lastStreamError;
  String? get lastStreamError => _lastStreamError;
  void clearStreamError() {
    _lastStreamError = null;
  }

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

    conversation.add(
      ChatMessage(
        id: _newId(),
        role: MessageRole.user,
        text: trimmed,
        createdAt: DateTime.now(),
      ),
    );
    if (wasEmpty) conversation.title = _titleFrom(trimmed);

    await _streamReply();
  }

  /// Edits a message. When [resend] is true, creates a new sibling user
  /// message with [newText] (preserving the original as a sibling branch)
  /// and streams a fresh assistant reply from it. When false, mutates the
  /// message text in place (stashing the original in [ChatMessage.originalContent]
  /// for undo) without re-contacting the model.
  Future<void> editMessage(
    String id,
    String newText, {
    required bool resend,
  }) async {
    if (_isGenerating) return;
    final String trimmed = newText.trim();
    if (trimmed.isEmpty) return;

    final Conversation conversation = active;
    final ChatMessage? original = conversation.byId(id);
    if (original == null) return;

    if (resend) {
      final ChatMessage edited = ChatMessage(
        id: _newId(),
        role: original.role,
        text: trimmed,
        createdAt: DateTime.now(),
      );
      // Sibling: same parent as the original. If the original is a root
      // (parentId is null), pass isRoot so add() doesn't fall back to
      // currentLeafId (which would append to the current branch instead
      // of creating a sibling).
      conversation.add(
        edited,
        parentId: original.parentId,
        isRoot: original.parentId == null,
      );
      notifyListeners();
      if (edited.isUser) {
        await _streamReply();
      }
    } else {
      original.originalContent ??= original.text;
      original.text = trimmed;
      notifyListeners();
    }
  }

  /// Reverts an in-place edit, restoring [ChatMessage.originalContent] back
  /// to [ChatMessage.text]. No-op if the message was never edited in place.
  void revertEdit(String id) {
    final ChatMessage? msg = active.byId(id);
    if (msg == null || msg.originalContent == null) return;
    msg.text = msg.originalContent!;
    msg.originalContent = null;
    notifyListeners();
  }

  /// Regenerates an assistant message by re-streaming from its parent user
  /// message. Creates a new assistant sibling (the old reply is preserved as
  /// a sibling branch). [suggestionPrompt], if given, is appended to the user
  /// message text for this turn only (not persisted) — used by the
  /// "Add Details" / "More Concise" regenerate menu.
  Future<void> regenerate(
    String assistantId, {
    String? suggestionPrompt,
  }) async {
    if (_isGenerating) return;
    final Conversation conversation = active;
    final ChatMessage? assistant = conversation.byId(assistantId);
    if (assistant == null) return;
    final String? userId = assistant.parentId;
    if (userId == null) return;

    // Point the active leaf at the parent so _streamReply appends a new
    // assistant sibling under it.
    conversation.currentLeafId = userId;
    notifyListeners();
    await _streamReply(extraPrompt: suggestionPrompt);
  }

  /// Switches the active branch to a sibling of [currentId]. [direction] is
  /// -1 for the previous sibling or +1 for the next. After switching, walks
  /// down to the deepest leaf of the new branch so the full downstream
  /// thread is visible (matches Open WebUI / ChatGPT behavior).
  void selectSibling(String currentId, int direction) {
    final Conversation conversation = active;
    final ChatMessage? current = conversation.byId(currentId);
    if (current == null) return;

    // Get siblings — for root messages, all roots are siblings.
    final List<String> siblings = conversation.siblingsOf(currentId);
    if (siblings.isEmpty) return;

    final int idx = siblings.indexOf(currentId);
    if (idx < 0) return;
    final int nextIdx = (idx + direction).clamp(0, siblings.length - 1);
    final String newSiblingId = siblings[nextIdx];

    // Update the parent's activeChildId so this choice is remembered.
    final ChatMessage? parent = current.parentId == null
        ? null
        : conversation.byId(current.parentId!);
    if (parent != null) {
      parent.activeChildId = newSiblingId;
    }

    // Walk down to the deepest leaf, preferring the remembered active child
    // at each level (instead of always picking the newest child).
    String leafId = newSiblingId;
    ChatMessage? node = conversation.byId(leafId);
    while (node != null && node.childrenIds.isNotEmpty) {
      final String? active = node.activeChildId;
      leafId = (active != null && node.childrenIds.contains(active))
          ? active
          : node.childrenIds.last;
      node = conversation.byId(leafId);
    }
    conversation.currentLeafId = leafId;
    notifyListeners();
  }

  /// Streams an assistant reply for the active conversation, appending to the
  /// current leaf. Called by [sendMessage], [editMessage] (resend), and
  /// [regenerate]. [extraPrompt] is appended to the trailing user message
  /// for this request only (not persisted). [fromLeafId] overrides the
  /// starting leaf (used when the caller has already set currentLeafId).
  Future<void> _streamReply({String? extraPrompt}) async {
    final Conversation conversation = active;

    // Remember the leaf before we start streaming so we can roll back on
    // error (optimistic rollback — the failed branch stays as a sibling).
    final String? previousLeaf = conversation.currentLeafId;

    _isGenerating = true;
    notifyListeners();

    final ProviderAccount? account = activeAccount;
    if (account == null) {
      conversation.add(
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

    _log.info(
      'sendMessage: account=${account.id} kind=${account.kind.name} '
      'model=$model tools=${_toolsEnabled && _webRetrieval != null ? 'on' : 'off'}',
    );

    // Build the request messages from the active path. If an extraPrompt is
    // given (regenerate suggestion), append it to the last user message for
    // this request only — the stored message is untouched.
    List<ChatMessage> requestMessages = conversation.activePath
        .where((m) => !m.isStreaming)
        .toList();
    if (extraPrompt != null && extraPrompt.isNotEmpty) {
      requestMessages = List<ChatMessage>.from(requestMessages);
      for (int i = requestMessages.length - 1; i >= 0; i--) {
        if (requestMessages[i].isUser) {
          final ChatMessage orig = requestMessages[i];
          requestMessages[i] = ChatMessage(
            id: orig.id,
            role: orig.role,
            text: '${orig.text}\n\n$extraPrompt',
            createdAt: orig.createdAt,
            toolCalls: orig.toolCalls,
            toolCallId: orig.toolCallId,
            parentId: orig.parentId,
            children: orig.childrenIds,
          );
          break;
        }
      }
    }

    // Tool-call loop: stream → if the model emitted tool calls, execute them,
    // append tool-result messages, and re-stream. Caps at a few rounds so a
    // misbehaving model can't loop forever.
    const int maxRounds = 5;
    for (int round = 0; round < maxRounds; round++) {
      _log.fine(
        'tool-call loop: round=$round messages=${conversation.messages.length}',
      );

      final ChatMessage assistant = ChatMessage(
        id: _newId(),
        role: MessageRole.assistant,
        isStreaming: true,
        createdAt: DateTime.now(),
      );
      conversation.add(assistant);
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
              messages: (round == 0 && extraPrompt != null)
                  ? requestMessages
                  : conversation.activePath
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
                    _log.fine('tool-call fragment: id=$id name=$name');
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
                  _log.severe(
                    'LLM stream error: ${error.runtimeType}: ${error.message}',
                  );
                  assistant.text = '⚠️ ${error.message}';
                  assistant.isStreaming = false;
                  hadError = true;
                  notifyListeners();
                  if (!done.isCompleted) done.complete();
              }
            },
            onError: (Object error, StackTrace stack) {
              _log.severe('LLM stream onError', error, stack);
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
        if (hadError) {
          _log.warning('tool-call loop ended with error at round=$round');
          // Optimistic rollback: mark the failed assistant message and
          // restore the active leaf to where it was before streaming.
          assistant.hasError = true;
          if (previousLeaf != null) {
            conversation.currentLeafId = previousLeaf;
          }
          _lastStreamError = assistant.text;
        } else {
          _log.info('reply complete: round=$round toolCalls=0');
        }
        _isGenerating = false;
        notifyListeners();
        return;
      }

      _log.info(
        'executing ${pendingCalls.length} tool call(s): '
        '${pendingCalls.map((tc) => '${tc.name}(${tc.args.length} chars)').join(', ')}',
      );

      // Execute each tool call and append a tool-result message.
      if (_webRetrieval == null) {
        // No adapter configured — surface the calls but skip execution.
        _log.warning('web retrieval adapter is null — skipping tool execution');
        for (final ToolCall tc in pendingCalls) {
          conversation.add(
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
          _log.fine('executing tool: name=${tc.name} id=${tc.id}');
          String result;
          try {
            result = await _webSearchTools.execute(
              name: tc.name,
              args: tc.args,
              adapter: retrieval,
            );
            _log.fine(
              'tool result: name=${tc.name} len=${result.length} '
              'preview=${result.substring(0, result.length.clamp(0, 120))}',
            );
          } catch (e, stack) {
            _log.severe('tool execution failed: name=${tc.name}', e, stack);
            result = 'Error executing tool "${tc.name}": $e';
          }
          conversation.add(
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
    _log.warning('tool-call loop exhausted maxRounds=$maxRounds');
    _isGenerating = false;
    notifyListeners();
  }

  /// Cancels an in-flight generation, if any.
  Future<void> cancelGeneration() async {
    await _replySub?.cancel();
    _replySub = null;
    if (_isGenerating) {
      final Conversation conversation = active;
      final List<ChatMessage> path = conversation.activePath;
      final ChatMessage assistant = path.lastWhere(
        (m) => m.isStreaming,
        orElse: () => path.last,
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
