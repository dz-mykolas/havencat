import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../../domain/models/conversation.dart';
import '../../../domain/models/adapter_kind.dart';
import '../../../domain/models/llm_model.dart';
import '../../../domain/models/message.dart';
import '../../../domain/models/message_attachment.dart';
import '../../../domain/models/content_modality.dart';
import '../../../domain/models/provider_account.dart';
import '../services/auth/credential_resolver.dart';
import '../services/background/generation_background_service.dart';
import '../services/errors/provider_failure_mapper.dart';
import '../services/llm/account_models_service.dart';
import '../services/llm/adapter_registry.dart';
import '../services/llm/context_compaction.dart';
import '../services/llm/llm_adapter.dart';
import '../services/llm/llm_event.dart';
import '../services/llm/request_messages.dart';
import '../services/llm/system_prompts.dart';
import '../services/llm/token_estimator.dart';
import '../services/storage/app_settings.dart';
import '../services/storage/conversation_store.dart';
import '../services/web_retrieval/web_retrieval.dart';
import '../services/web_retrieval/web_search_tools.dart';
import 'provider_account_repository.dart';

enum _RequestedGenerationStop { cancelled, interrupted }

/// Token overhead the provider counts against `input_tokens`/`prompt_tokens`
/// but which isn't in [estimateMessagesTokens] for the messages array: the
/// system prompt and tool definitions. Included in `lastEstimatedTokens` so
/// the estimate matches what the provider actually bills against.
int _estimateRequestOverhead(String? systemPrompt, List<ToolDefinition> tools) {
  int n = 0;
  if (systemPrompt != null && systemPrompt.isNotEmpty) {
    n += estimateTokens(systemPrompt) + 4;
  }
  for (final ToolDefinition t in tools) {
    n += estimateTokens(t.name) + estimateTokens(t.description) + 8;
    n += estimateTokens(jsonEncode(t.parameters));
  }
  return n;
}

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
    ConversationStore? conversationStore,
    WebRetrievalAdapter? webRetrieval,
    bool toolsEnabled = false,
    AppSettings? appSettings,
    AccountModelsService? accountModels,
    GenerationBackgroundController? backgroundController,
  }) : _providers = providerRepository,
       adapterRegistry = adapterRegistry,
       _credentials = credentialResolver,
       _store = conversationStore ?? InMemoryConversationStore(),
       _webRetrieval = webRetrieval,
       _toolsEnabled = toolsEnabled,
       _appSettings = appSettings,
       _accountModels = accountModels,
       _backgroundController = backgroundController {
    _initFuture = _init();
    _backgroundController?.onBackgroundTimeExpired = interruptGeneration;
    _providers.addListener(_onProvidersChanged);
  }

  final ConversationStore _store;
  final GenerationBackgroundController? _backgroundController;
  late final Future<void> _initFuture;
  Future<void> get ready => _initFuture;

  Future<void> _init() async {
    try {
      final List<Conversation> loaded = await _store.load();
      for (final Conversation c in loaded) {
        bool changed = false;
        for (final ChatMessage m in c.messages) {
          if (m.isStreaming) {
            m.generationStatus = MessageGenerationStatus.interrupted;
            changed = true;
          }
        }
        if (changed) await _store.upsert(c);
      }
      _conversations.addAll(loaded);
    } on Object catch (error, stack) {
      _recordStorageFailure(
        error,
        stack,
        operation: 'load_conversations',
        message: 'Saved conversations could not be loaded.',
        notify: false,
      );
    }
    // Don't auto-select the latest chat — start on the welcome/empty state.
    // The user picks a conversation from the sidebar or starts a new one.
    _loaded = true;
    notifyListeners();
  }

  bool _loaded = false;

  /// Whether the initial load from the store has completed.
  bool get isLoaded => _loaded;
  String? _activeId;

  Future<void> _persistTail = Future<void>.value();
  Timer? _partialPersistTimer;
  Conversation? _pendingPartialConversation;

  void _persist(Conversation conversation) {
    unawaited(_persistConversation(conversation));
  }

  Future<void> _persistConversation(Conversation conversation) async {
    final Conversation snapshot = Conversation.fromJson(conversation.toJson());
    final Future<void> operation = _persistTail.then((_) async {
      try {
        await _store.upsert(snapshot);
      } on Object catch (error, stack) {
        _recordStorageFailure(
          error,
          stack,
          operation: 'save_conversation',
          message: 'This conversation could not be saved.',
        );
      }
    });
    _persistTail = operation;
    await operation;
  }

  void _schedulePartialPersist(Conversation conversation) {
    _pendingPartialConversation = conversation;
    _partialPersistTimer ??= Timer(const Duration(milliseconds: 500), () {
      _partialPersistTimer = null;
      final Conversation? pending = _pendingPartialConversation;
      _pendingPartialConversation = null;
      if (pending != null) unawaited(_persistConversation(pending));
    });
  }

  Future<void> flushPartialGeneration() async {
    _partialPersistTimer?.cancel();
    _partialPersistTimer = null;
    final Conversation? pending = _pendingPartialConversation;
    _pendingPartialConversation = null;
    if (pending != null) await _persistConversation(pending);
    await _persistTail;
  }

  Future<void> _deletePersistedConversation(String id) async {
    try {
      await _store.delete(id);
    } on Object catch (error, stack) {
      _recordStorageFailure(
        error,
        stack,
        operation: 'delete_conversation',
        message: 'The conversation was removed here but not from storage.',
      );
    }
  }

  void _recordStorageFailure(
    Object error,
    StackTrace stack, {
    required String operation,
    required String message,
    bool notify = true,
  }) {
    final AppFailure failure = _failureMapper.fromException(
      error,
      source: FailureSource(
        subsystem: AppSubsystem.storage,
        operation: operation,
      ),
      fallbackMessage: message,
    );
    _lastFailure = failure;
    _log.severe(message, failure, stack);
    if (notify) notifyListeners();
  }

  static final Logger _log = Logger('conversation');

  final ProviderAccountRepository _providers;
  final AdapterRegistry adapterRegistry;
  final CredentialResolver _credentials;
  final WebRetrievalAdapter? _webRetrieval;
  bool _toolsEnabled;
  final WebSearchTools _webSearchTools = const WebSearchTools();
  final AppSettings? _appSettings;
  final AccountModelsService? _accountModels;
  static const ProviderFailureMapper _failureMapper = ProviderFailureMapper();

  /// Resolves the context window for the active account's selected model.
  /// Falls back to [kFallbackContextWindow] when the model isn't found in
  /// the cache or its context window is unknown.
  int _resolveContextWindow(ProviderAccount account, String modelId) {
    if (_accountModels == null) return kFallbackContextWindow;
    final List<LlmModel>? models = _accountModels.modelsFor(account.id);
    if (models == null) return kFallbackContextWindow;
    for (final LlmModel m in models) {
      if (m.id == modelId && m.contextWindow != null) {
        return m.contextWindow!;
      }
    }
    return kFallbackContextWindow;
  }

  /// Computes a calibration ratio for the char/4 estimator from the last
  /// provider-reported prompt-token count vs. our estimate for that same
  /// request. Returns null when no calibration data is available (first turn,
  /// or provider doesn't report usage like Ollama).
  double? _calibrationRatio(Conversation c) {
    final int? actual = c.lastPromptTokens;
    final int? estimated = c.lastEstimatedTokens;
    if (actual == null || estimated == null || estimated == 0) return null;
    return actual / estimated;
  }

  /// Builds [CompactionSettings] from the user's [AppSettings], or defaults
  /// when AppSettings isn't injected (tests).
  CompactionSettings _compactionSettings() {
    final AppSettings? s = _appSettings;
    if (s == null) return const CompactionSettings();
    return CompactionSettings(
      redactSecrets: s.redactSecrets,
      temporalAnchoring: s.temporalAnchoring,
      antiThrash: s.antiThrash,
      staticFallback: s.staticFallback,
      abortOnSummaryFailure: s.abortOnSummaryFailure,
      autoFocusTopic: s.autoFocusTopic,
    );
  }

  final List<Conversation> _conversations = <Conversation>[];
  bool _isGenerating = false;
  StreamSubscription<LlmEvent>? _replySub;
  Completer<void>? _requestCancellation;
  Completer<void>? _roundDone;
  Completer<void>? _generationFinished;
  _RequestedGenerationStop? _requestedStop;
  bool _backgroundWorkActive = false;
  int _counter = 0;

  AppFailure? _lastFailure;
  AppFailure? get lastFailure => _lastFailure;
  void clearLastFailure() {
    _lastFailure = null;
  }

  Future<void> retryLastFailure() async {
    if (_isGenerating || active.isEmpty) return;
    _lastFailure = null;
    await _streamReply();
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

  Conversation get active {
    if (_activeId == null) {
      // No active conversation (initial load or "new chat" empty state).
      // Return a transient placeholder so the UI can render the welcome
      // screen; it is never persisted or added to [_conversations].
      return _placeholderConversation ??= Conversation(
        id: '__empty__',
        createdAt: DateTime.now(),
      );
    }
    return _conversations.firstWhere((Conversation c) => c.id == _activeId);
  }

  Conversation? _placeholderConversation;

  String? get activeId => _activeId;

  /// Resolves the context window (in tokens) for the active conversation's
  /// bound account + model. Falls back to [kFallbackContextWindow] when the
  /// model isn't found or its context window is unknown.
  int get activeContextWindow {
    final ProviderAccount? account = activeAccount;
    if (account == null) return kFallbackContextWindow;
    final String model = (account.config['model'] as String?) ?? '';
    if (model.isEmpty) return kFallbackContextWindow;
    return _resolveContextWindow(account, model);
  }

  LlmModel? get activeModel {
    final ProviderAccount? account = activeAccount;
    if (account == null || _accountModels == null) return null;
    final String modelId = (account.config['model'] as String?) ?? '';
    if (modelId.isEmpty) return null;
    for (final LlmModel model
        in _accountModels.modelsFor(account.id) ?? const <LlmModel>[]) {
      if (model.id == modelId) return model;
    }
    return null;
  }

  /// Unknown metadata remains permissive for custom/local endpoints. Only a
  /// catalog record that explicitly omits image input disables uploads.
  bool get canUploadImages =>
      activeModel?.capabilities?.accepts(ContentModality.image) != false;

  bool get canGenerateImages =>
      activeModel?.capabilities?.produces(ContentModality.image) == true;

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
    // Just show the empty/welcome state — no draft is created until the
    // user actually sends the first message (see [sendMessage]).
    _activeId = null;
    _placeholderConversation = null;
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
  Future<void> sendMessage(
    String text, {
    List<MessageAttachment> attachments = const <MessageAttachment>[],
  }) async {
    final String trimmed = text.trim();
    if ((trimmed.isEmpty && attachments.isEmpty) || _isGenerating) return;
    if (attachments.any(
          (MessageAttachment value) => value.modality == ContentModality.image,
        ) &&
        !canUploadImages) {
      _lastFailure = const AppFailure(
        kind: FailureKind.unsupported,
        source: FailureSource(
          subsystem: AppSubsystem.llm,
          operation: 'attach_image',
        ),
        message: 'The selected model does not accept image input.',
      );
      notifyListeners();
      return;
    }

    // If there's no active conversation (welcome state / "new chat"),
    // create one now — lazily, only when the first message is sent.
    Conversation conversation = active;
    if (_activeId == null) {
      conversation = Conversation(id: _newId(), createdAt: DateTime.now());
      _conversations.insert(0, conversation);
      _activeId = conversation.id;
      _placeholderConversation = null;
    }
    final bool wasEmpty = conversation.isEmpty;

    conversation.add(
      ChatMessage(
        id: _newId(),
        role: MessageRole.user,
        text: trimmed,
        attachments: List<MessageAttachment>.from(attachments),
        createdAt: DateTime.now(),
      ),
    );
    if (wasEmpty) {
      conversation.title = trimmed.isNotEmpty
          ? _titleFrom(trimmed)
          : attachments.first.name ?? 'Image';
    }
    await _persistConversation(conversation);

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
        attachments: List<MessageAttachment>.from(original.attachments),
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
      _persist(conversation);
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
    _persist(active);
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
    _persist(conversation);
    notifyListeners();
  }

  /// Streams an assistant reply for the active conversation, appending to the
  /// current leaf. Called by [sendMessage], [editMessage] (resend), and
  /// [regenerate]. [extraPrompt] is appended to the trailing user message
  /// for this request only (not persisted). [fromLeafId] overrides the
  /// starting leaf (used when the caller has already set currentLeafId).
  Future<void> _streamReply({String? extraPrompt}) async {
    final Conversation conversation = active;
    final String? previousLeaf = conversation.currentLeafId;
    await _beginBackgroundWork(conversation);
    final Completer<void> generationFinished = Completer<void>();
    _generationFinished = generationFinished;
    _requestedStop = null;
    try {
      await _streamReplyInternal(extraPrompt: extraPrompt);
    } on Object catch (error, stack) {
      final ProviderAccount? account = activeAccount;
      final AppFailure failure = _failureMapper.fromException(
        error,
        source: FailureSource(
          subsystem: AppSubsystem.llm,
          operation: 'generate',
          providerId: account?.displayName,
          accountId: account?.id,
          modelId: account?.config['model'] as String?,
        ),
        flavor: account?.kind == AdapterKind.subscription
            ? ProviderErrorFlavor.codex
            : ProviderErrorFlavor.generic,
      );
      _log.severe('LLM request failed before completion', failure, stack);
      final ChatMessage? assistant = conversation.messages
          .where((ChatMessage message) => message.isStreaming)
          .lastOrNull;
      if (assistant != null) {
        if (assistant.text.isEmpty) assistant.text = failure.message;
        assistant
          ..generationStatus = MessageGenerationStatus.failed
          ..hasError = true;
      }
      if (previousLeaf != null) conversation.currentLeafId = previousLeaf;
      if (!failure.isCancellation) _lastFailure = failure;
      await _finishBackgroundWork(interrupted: true);
    } finally {
      _replySub = null;
      _requestCancellation = null;
      _roundDone = null;
      if (_isGenerating) _isGenerating = false;
      await flushPartialGeneration();
      await _persistConversation(conversation);
      notifyListeners();
      if (!generationFinished.isCompleted) generationFinished.complete();
      if (identical(_generationFinished, generationFinished)) {
        _generationFinished = null;
      }
    }
  }

  Future<void> _streamReplyInternal({String? extraPrompt}) async {
    final Conversation conversation = active;

    // Remember the leaf before we start streaming so we can roll back on
    // error (optimistic rollback — the failed branch stays as a sibling).
    final String? previousLeaf = conversation.currentLeafId;

    _isGenerating = true;
    notifyListeners();

    final ProviderAccount? account = activeAccount;
    if (account == null) {
      _lastFailure = const AppFailure(
        kind: FailureKind.unavailable,
        source: FailureSource(
          subsystem: AppSubsystem.llm,
          operation: 'generate',
        ),
        message: 'No provider is configured. Add one in Settings.',
      );
      conversation.add(
        ChatMessage(
          id: _newId(),
          role: MessageRole.assistant,
          text: _lastFailure!.message,
          createdAt: DateTime.now(),
        ),
      );
      _isGenerating = false;
      await _persistConversation(conversation);
      await _finishBackgroundWork(interrupted: true);
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
            attachments: List<MessageAttachment>.from(orig.attachments),
          );
          break;
        }
      }
    }

    // Tool-call loop: stream → if the model emitted tool calls, execute them,
    // append tool-result messages, and re-stream. Caps at a few rounds so a
    // misbehaving model can't loop forever.
    const int maxRounds = 5;
    // IDs of messages added during this sendMessage call (assistant replies
    // and tool results from the tool loop). Their tool results are never
    // cleared by the request builder — the model is actively using them.
    final Set<String> currentTurnMessageIds = <String>{};
    // Compactor for context compaction. Built once per reply; reuses the
    // active adapter/account/secret.
    final ContextCompactor compactor = LlmContextCompactor(
      adapter: adapter,
      account: account,
      secret: secret,
      model: model,
      settings: _compactionSettings(),
    );

    for (int round = 0; round < maxRounds; round++) {
      _log.fine(
        'tool-call loop: round=$round messages=${conversation.messages.length}',
      );

      final ChatMessage assistant = ChatMessage(
        id: _newId(),
        role: MessageRole.assistant,
        generationStatus: MessageGenerationStatus.pending,
        createdAt: DateTime.now(),
      );
      conversation.add(assistant);
      currentTurnMessageIds.add(assistant.id);
      notifyListeners();

      final List<ToolCall> pendingCalls = <ToolCall>[];
      // Accumulate tool-call fragments by index (OpenAI streams id/name first,
      // then argument tokens across multiple ToolCallEvents).
      final Map<int, ToolCall> accumulating = <int, ToolCall>{};

      final Completer<void> done = Completer<void>();
      final Completer<void> requestCancellation = Completer<void>();
      _roundDone = done;
      _requestCancellation = requestCancellation;
      bool hadError = false;

      // Build the request messages with context management (clearing +
      // compaction). On round 0 with an extraPrompt, the extraPrompt variant
      // of requestMessages is used as the base.
      final List<ChatMessage> baseMessages = (round == 0 && extraPrompt != null)
          ? requestMessages
          : conversation.activePath.where((m) => !m.isStreaming).toList();
      _log.fine(
        'building request: round=$round baseMsgs=${baseMessages.length} '
        'currentTurnProtected=${currentTurnMessageIds.length}',
      );
      final List<ChatMessage> builtMessages = await buildRequestMessagesAsync(
        activePath: baseMessages,
        contextWindow: _resolveContextWindow(account, model),
        compactor: compactor,
        currentTurnMessageIds: currentTurnMessageIds,
        calibrationRatio: _calibrationRatio(conversation),
      );
      final List<ToolDefinition> tools = _toolsEnabled && _webRetrieval != null
          ? _webSearchTools.definitions
          : const <ToolDefinition>[];
      // Record the estimate so the next round can calibrate against the
      // provider's reported prompt_tokens. Include the system prompt and tool
      // definitions — the provider counts them against input_tokens too, so
      // the estimate must too or it'll jump when the actual arrives.
      conversation.lastEstimatedTokens =
          estimateMessagesTokens(builtMessages) +
          _estimateRequestOverhead(SystemPrompts.base, tools);
      notifyListeners();

      _replySub = adapter
          .stream(
            request: LlmRequest(
              messages: builtMessages,
              model: model,
              systemPrompt: SystemPrompts.base,
              tools: tools,
              modelCapabilities: activeModel?.capabilities,
              signal: () => requestCancellation.future,
            ),
            account: account,
            secret: secret,
          )
          .listen(
            (LlmEvent event) {
              switch (event) {
                case TokenEvent(:final String delta):
                  assistant.generationStatus =
                      MessageGenerationStatus.streaming;
                  assistant.text += delta;
                  _schedulePartialPersist(conversation);
                  notifyListeners();
                case ReasoningEvent(:final String delta):
                  assistant.generationStatus =
                      MessageGenerationStatus.streaming;
                  assistant.reasoning += delta;
                  _schedulePartialPersist(conversation);
                  notifyListeners();
                case AttachmentEvent(:final MessageAttachment attachment):
                  final int existing = assistant.attachments.indexWhere(
                    (MessageAttachment value) => value.id == attachment.id,
                  );
                  if (existing < 0) {
                    assistant.attachments.add(attachment);
                  } else {
                    assistant.attachments[existing] = attachment;
                  }
                  assistant.generationStatus =
                      MessageGenerationStatus.streaming;
                  _schedulePartialPersist(conversation);
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
                  assistant.generationStatus =
                      MessageGenerationStatus.streaming;
                  _schedulePartialPersist(conversation);
                  notifyListeners();
                case DoneEvent():
                  assistant.text = assistant.text.trimRight();
                  assistant.generationStatus =
                      MessageGenerationStatus.completed;
                  pendingCalls.addAll(accumulating.values);
                  if (event.usage case final LlmUsage usage) {
                    if (usage.promptTokens case final int prompt) {
                      conversation.lastPromptTokens = prompt;
                      assistant.promptTokens = prompt;
                    }
                    if (usage.completionTokens case final int completion) {
                      conversation.lastCompletionTokens = completion;
                      assistant.completionTokens = completion;
                    }
                    if (usage.totalTokens case final int total) {
                      conversation.lastTotalTokens = total;
                      assistant.totalTokens = total;
                    }
                    _log.fine(
                      'captured usage: prompt=${usage.promptTokens} '
                      'completion=${usage.completionTokens} '
                      'total=${usage.totalTokens}',
                    );
                  }
                  notifyListeners();
                  if (!done.isCompleted) done.complete();
                case ErrorEvent(:final AppFailure error):
                  _log.severe(
                    'LLM stream error: ${error.runtimeType}: ${error.message}',
                  );
                  if (assistant.text.isEmpty && !error.isCancellation) {
                    assistant.text = error.message;
                  }
                  assistant.generationStatus = error.isCancellation
                      ? MessageGenerationStatus.cancelled
                      : MessageGenerationStatus.failed;
                  if (!error.isCancellation) _lastFailure = error;
                  hadError = true;
                  notifyListeners();
                  if (!done.isCompleted) done.complete();
              }
            },
            onError: (Object error, StackTrace stack) {
              _log.severe('LLM stream onError', error, stack);
              final AppFailure failure = AppFailure(
                kind: FailureKind.unknown,
                source: FailureSource(
                  subsystem: AppSubsystem.llm,
                  operation: 'generate',
                  providerId: account.displayName,
                  accountId: account.id,
                  modelId: model,
                ),
                message: 'The provider could not complete the request.',
              );
              if (assistant.text.isEmpty) assistant.text = failure.message;
              assistant.generationStatus = MessageGenerationStatus.failed;
              _lastFailure = failure;
              hadError = true;
              notifyListeners();
              if (!done.isCompleted) done.complete();
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
            cancelOnError: true,
          );

      await done.future;
      _replySub = null;
      _roundDone = null;
      _requestCancellation = null;

      final _RequestedGenerationStop? requestedStop = _requestedStop;
      if (requestedStop != null) {
        assistant.generationStatus =
            requestedStop == _RequestedGenerationStop.cancelled
            ? MessageGenerationStatus.cancelled
            : MessageGenerationStatus.interrupted;
        assistant.hasError =
            requestedStop == _RequestedGenerationStop.interrupted;
        _isGenerating = false;
        await flushPartialGeneration();
        await _persistConversation(conversation);
        await _finishBackgroundWork(
          interrupted: requestedStop == _RequestedGenerationStop.interrupted,
          cancelled: requestedStop == _RequestedGenerationStop.cancelled,
        );
        notifyListeners();
        return;
      }

      if (assistant.isStreaming) {
        assistant.generationStatus = MessageGenerationStatus.interrupted;
        assistant.hasError = true;
        hadError = true;
        _lastFailure = const AppFailure(
          kind: FailureKind.network,
          source: FailureSource(
            subsystem: AppSubsystem.llm,
            operation: 'generate',
          ),
          message: 'The response stream ended before it completed.',
          isRetryable: true,
        );
      }

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
        } else {
          _log.info('reply complete: round=$round toolCalls=0');
        }
        _isGenerating = false;
        await flushPartialGeneration();
        await _persistConversation(conversation);
        await _finishBackgroundWork(interrupted: hadError);
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
          final ChatMessage noTool = ChatMessage(
            id: _newId(),
            role: MessageRole.tool,
            text: 'Web search not configured.',
            toolCallId: tc.id,
            createdAt: DateTime.now(),
          );
          conversation.add(noTool);
          currentTurnMessageIds.add(noTool.id);
        }
      } else {
        final WebRetrievalAdapter retrieval = _webRetrieval;
        for (final ToolCall tc in pendingCalls) {
          _log.fine('executing tool: name=${tc.name} id=${tc.id}');
          WebToolResult result;
          try {
            result = await _webSearchTools.execute(
              name: tc.name,
              args: tc.args,
              adapter: retrieval,
            );
            _log.fine(
              'tool result: name=${tc.name} len=${result.content.length} '
              'preview=${result.content.substring(0, result.content.length.clamp(0, 120))}',
            );
            if (result.warnings.isNotEmpty) {
              _lastFailure = result.warnings.first;
              notifyListeners();
            }
          } catch (e, stack) {
            _log.severe('tool execution failed: name=${tc.name}', e, stack);
            final AppFailure failure = _failureMapper.fromException(
              e,
              source: FailureSource(
                subsystem: tc.name == 'fetch_page'
                    ? AppSubsystem.webFetch
                    : AppSubsystem.webSearch,
                operation: tc.name == 'fetch_page' ? 'fetch' : 'search',
              ),
            );
            _lastFailure = failure;
            result = WebToolResult(
              content: 'The web tool could not complete: ${failure.message}',
            );
          }
          final ChatMessage toolResult = ChatMessage(
            id: _newId(),
            role: MessageRole.tool,
            text: result.content,
            toolCallId: tc.id,
            createdAt: DateTime.now(),
          );
          conversation.add(toolResult);
          currentTurnMessageIds.add(toolResult.id);
          notifyListeners();
        }
      }
      await _persistConversation(conversation);
      if (_requestedStop case final _RequestedGenerationStop stop) {
        assistant.generationStatus = stop == _RequestedGenerationStop.cancelled
            ? MessageGenerationStatus.cancelled
            : MessageGenerationStatus.interrupted;
        assistant.hasError = stop == _RequestedGenerationStop.interrupted;
        _isGenerating = false;
        await _persistConversation(conversation);
        await _finishBackgroundWork(
          interrupted: stop == _RequestedGenerationStop.interrupted,
          cancelled: stop == _RequestedGenerationStop.cancelled,
        );
        notifyListeners();
        return;
      }
      // Loop: re-stream so the model can use the tool results.
    }

    // Exhausted the round cap — stop gracefully.
    _log.warning('tool-call loop exhausted maxRounds=$maxRounds');
    _isGenerating = false;
    await flushPartialGeneration();
    await _persistConversation(conversation);
    await _finishBackgroundWork();
    notifyListeners();
  }

  /// Cancels an in-flight generation, if any.
  Future<void> cancelGeneration() =>
      _requestGenerationStop(_RequestedGenerationStop.cancelled);

  Future<void> interruptGeneration() =>
      _requestGenerationStop(_RequestedGenerationStop.interrupted);

  Future<void> _requestGenerationStop(_RequestedGenerationStop stop) async {
    if (!_isGenerating) return;
    _requestedStop = stop;
    final Completer<void>? cancellation = _requestCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    final Completer<void>? roundDone = _roundDone;
    if (roundDone != null && !roundDone.isCompleted) roundDone.complete();
    final StreamSubscription<LlmEvent>? subscription = _replySub;
    if (subscription != null) {
      try {
        await subscription.cancel().timeout(const Duration(seconds: 3));
      } on TimeoutException {
        _log.warning('Timed out while closing the provider stream');
      }
    }
    await _generationFinished?.future;
  }

  Future<void> handleAppVisibility(bool visible) async {
    _backgroundController?.setAppVisible(visible);
    if (!visible && _isGenerating) await flushPartialGeneration();
    if (visible) {
      final String? conversationId = _backgroundController
          ?.takeSelectedConversation();
      if (conversationId != null) selectConversation(conversationId);
    }
  }

  Future<void> continueInterrupted(String messageId) async {
    if (_isGenerating) return;
    Conversation? conversation;
    ChatMessage? interrupted;
    for (final Conversation candidate in _conversations) {
      final ChatMessage? match = candidate.messages
          .where((ChatMessage message) => message.id == messageId)
          .firstOrNull;
      if (match != null) {
        conversation = candidate;
        interrupted = match;
        break;
      }
    }
    if (conversation == null || interrupted == null) return;
    if (interrupted.generationStatus != MessageGenerationStatus.interrupted &&
        interrupted.generationStatus != MessageGenerationStatus.failed) {
      return;
    }
    _activeId = conversation.id;
    conversation.currentLeafId = interrupted.id;
    conversation.add(
      ChatMessage(
        id: _newId(),
        role: MessageRole.user,
        text:
            'Continue from where your previous response was interrupted. '
            'Do not repeat the completed part.',
        createdAt: DateTime.now(),
      ),
    );
    await _persistConversation(conversation);
    await _streamReply();
  }

  Future<void> _beginBackgroundWork(Conversation conversation) async {
    if (_backgroundWorkActive || _backgroundController == null) return;
    try {
      await _backgroundController.begin(
        conversationId: conversation.id,
        conversationTitle: conversation.title,
      );
      _backgroundWorkActive = true;
    } on Object catch (error, stack) {
      _log.warning(
        'Background generation support could not start',
        error,
        stack,
      );
    }
  }

  Future<void> _finishBackgroundWork({
    bool interrupted = false,
    bool cancelled = false,
  }) async {
    if (!_backgroundWorkActive) return;
    _backgroundWorkActive = false;
    try {
      if (cancelled) {
        await _backgroundController?.cancel();
      } else if (interrupted) {
        await _backgroundController?.interrupt();
      } else {
        await _backgroundController?.complete();
      }
    } on Object catch (error, stack) {
      _log.warning('Background generation cleanup failed', error, stack);
    }
  }

  void _onProvidersChanged() {
    // If the active account changed, the UI may want to reflect it. Nothing
    // to do to in-flight conversations — they keep their bound account.
    notifyListeners();
  }

  /// Renames a conversation by [id].
  void renameConversation(String id, String newTitle) {
    final String trimmed = newTitle.trim();
    if (trimmed.isEmpty) return;
    final int idx = _conversations.indexWhere((c) => c.id == id);
    if (idx < 0) return;
    _conversations[idx].title = trimmed;
    _persist(_conversations[idx]);
    notifyListeners();
  }

  void toggleConversationPinned(String id) {
    final Conversation? conversation = _conversations
        .where((Conversation value) => value.id == id)
        .firstOrNull;
    if (conversation == null) return;
    conversation.isPinned = !conversation.isPinned;
    _persist(conversation);
    notifyListeners();
  }

  /// Deletes a conversation by [id]. If it's the active one, returns to
  /// the welcome/empty state.
  void deleteConversation(String id) {
    _conversations.removeWhere((c) => c.id == id);
    if (_activeId == id) {
      _activeId = null;
      _placeholderConversation = null;
    }
    unawaited(_deletePersistedConversation(id));
    notifyListeners();
  }

  /// Exports a conversation as Markdown.
  String exportConversation(String id) {
    final Conversation? conv = _conversations
        .where((c) => c.id == id)
        .firstOrNull;
    if (conv == null) return '';
    final StringBuffer buf = StringBuffer();
    buf.writeln('# ${conv.title}');
    buf.writeln();
    for (final ChatMessage m in conv.activePath) {
      if (m.role == MessageRole.tool) continue;
      final String role = m.isUser
          ? 'User'
          : m.role == MessageRole.assistant
          ? 'Assistant'
          : 'System';
      buf.writeln('### $role');
      buf.writeln();
      buf.writeln(m.text);
      buf.writeln();
    }
    return buf.toString();
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
    _partialPersistTimer?.cancel();
    _backgroundController?.onBackgroundTimeExpired = null;
    final Completer<void>? cancellation = _requestCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    _replySub?.cancel();
    if (_backgroundWorkActive) {
      unawaited(_backgroundController?.cancel() ?? Future<void>.value());
    }
    super.dispose();
  }
}
