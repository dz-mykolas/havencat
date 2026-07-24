import 'dart:async';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../../domain/models/conversation.dart';
import '../../../domain/models/adapter_kind.dart';
import '../../../domain/models/llm_model.dart';
import '../../../domain/models/message.dart';
import '../../../domain/models/message_attachment.dart';
import '../../../domain/models/content_modality.dart';
import '../../../domain/models/generation_task.dart';
import '../../../domain/models/provider_account.dart';
import '../../../domain/errors/app_failure.dart';
import '../services/auth/credential_resolver.dart';
import '../services/background/generation_background_service.dart';
import '../services/errors/provider_failure_mapper.dart';
import '../services/generation/generation_engine.dart';
import '../services/generation/generation_host.dart';
import '../services/generation/generation_task_store.dart';
import '../services/generation/in_memory_generation_task_store.dart';
import '../services/llm/account_models_service.dart';
import '../services/llm/adapter_registry.dart';
import '../services/llm/context_compaction.dart';
import '../services/storage/app_settings.dart';
import '../services/storage/conversation_store.dart';
import '../services/web_retrieval/web_retrieval.dart';
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
    ConversationStore? conversationStore,
    WebRetrievalAdapter? webRetrieval,
    this.toolsEnabled = false,
    AppSettings? appSettings,
    AccountModelsService? accountModels,
    GenerationBackgroundController? backgroundController,
    GenerationTaskStore? generationTaskStore,
    GenerationHost? generationHost,
  }) : _providers = providerRepository,
       adapterRegistry = adapterRegistry,
       _store = conversationStore ?? InMemoryConversationStore(),
       _appSettings = appSettings,
       _accountModels = accountModels,
       _backgroundController = backgroundController,
       _generationHost = generationHost ?? InlineGenerationHost() {
    _taskStore =
        generationTaskStore ??
        InMemoryGenerationTaskStore(conversations: _store);
    _generationEngine = GenerationEngine(
      adapters: adapterRegistry,
      credentials: credentialResolver,
      taskStore: _taskStore,
      newId: _newId,
      webRetrieval: webRetrieval,
    );
    _initFuture = _init();
    _backgroundController?.onBackgroundTimeExpired = interruptGeneration;
    _providers.addListener(_onProvidersChanged);
  }

  final ConversationStore _store;
  late final GenerationTaskStore _taskStore;
  late final GenerationEngine _generationEngine;
  final GenerationBackgroundController? _backgroundController;
  final GenerationHost _generationHost;
  late final Future<void> _initFuture;
  Future<void> get ready => _initFuture;

  Future<void> _init() async {
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
    for (final GenerationTask task in await _taskStore.listTasks()) {
      _knownTasks[task.id] = task;
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

  Future<void> resumeQueuedTasks({bool reconcile = true}) async {
    await ready;
    if (reconcile) await _taskStore.reconcileInterrupted();
    for (final GenerationTask task in await _taskStore.listTasks()) {
      _knownTasks[task.id] = task;
    }
    final bool hasPending = _knownTasks.values.any(
      (GenerationTask task) => !task.isTerminal,
    );
    if (!hasPending) return;
    await _drainGenerationTasks();
  }

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
        rethrow;
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
  bool toolsEnabled;
  final AppSettings? _appSettings;
  final AccountModelsService? _accountModels;
  static const ProviderFailureMapper _failureMapper = ProviderFailureMapper();

  int _resolveContextWindow(ProviderAccount account, String modelId) {
    if (account.kind == AdapterKind.mock) return kFallbackContextWindow;
    if (_accountModels == null) {
      throw StateError('Model metadata service is unavailable.');
    }
    final List<LlmModel>? models = _accountModels.modelsFor(account.id);
    if (models == null) {
      throw StateError('Model metadata is not loaded for ${account.id}.');
    }
    for (final LlmModel m in models) {
      if (m.id == modelId && m.contextWindow != null) {
        return m.contextWindow!;
      }
    }
    throw StateError('Context window is unknown for model $modelId.');
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
  Completer<void>? _generationFinished;
  bool _backgroundWorkActive = false;
  bool _isDrainingTasks = false;
  bool _drainRequested = false;
  String? _activeGenerationTaskId;
  bool _drainWasCancelled = false;
  bool _drainWasInterrupted = false;
  final Map<String, GenerationTask> _knownTasks = <String, GenerationTask>{};
  int _counter = 0;

  AppFailure? _lastFailure;
  AppFailure? get lastFailure => _lastFailure;
  void clearLastFailure() {
    _lastFailure = null;
  }

  Future<void> retryLastFailure() async {
    if (active.isEmpty) return;
    _lastFailure = null;
    await _enqueueReply(active);
  }

  List<Conversation> get conversations => List.unmodifiable(_conversations);
  bool get isGenerating => _isGenerating;
  List<GenerationTask> get generationTasks {
    final List<GenerationTask> tasks = _knownTasks.values.toList()
      ..sort(
        (GenerationTask a, GenerationTask b) =>
            a.enqueueSequence.compareTo(b.enqueueSequence),
      );
    return List<GenerationTask>.unmodifiable(tasks);
  }

  String queuedGenerationText(GenerationTask task) {
    final Conversation? conversation = _conversations
        .where((Conversation value) => value.id == task.conversationId)
        .firstOrNull;
    return conversation?.byId(task.inputMessageId)?.text ??
        task.snapshot.messages.lastOrNull?.text ??
        'Queued response';
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
    if (trimmed.isEmpty && attachments.isEmpty) return;
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
    await _enqueueReply(conversation);
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
        await _enqueueReply(conversation);
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
    final Conversation conversation = active;
    final ChatMessage? assistant = conversation.byId(assistantId);
    if (assistant == null) return;
    final String? userId = assistant.parentId;
    if (userId == null) return;

    // Point the active leaf at the parent so _streamReply appends a new
    // assistant sibling under it.
    conversation.currentLeafId = userId;
    notifyListeners();
    await _enqueueReply(conversation, extraPrompt: suggestionPrompt);
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

  Future<void> _enqueueReply(
    Conversation conversation, {
    String? extraPrompt,
    String? parentMessageId,
  }) async {
    final ProviderAccount? account = _accountForConversation(conversation);
    final String? requestedParentId =
        parentMessageId ?? conversation.currentLeafId;
    if (account == null || requestedParentId == null) {
      _lastFailure = const AppFailure(
        kind: FailureKind.unavailable,
        source: FailureSource(
          subsystem: AppSubsystem.llm,
          operation: 'enqueue_generation',
        ),
        message: 'No provider is configured. Add one in Settings.',
      );
      notifyListeners();
      return;
    }

    if (conversation.byId(requestedParentId) == null) {
      throw StateError('Generation parent $requestedParentId does not exist.');
    }
    final String inputMessageId = requestedParentId;
    final String outputMessageId = _newId();
    final String model = (account.config['model'] as String?) ?? '';
    final LlmModel? selectedModel = _modelFor(account.id, model);
    final int contextWindow = _resolveContextWindow(account, model);
    final List<ChatMessage> requestMessages = conversation
        .pathTo(inputMessageId)
        .where((ChatMessage message) => !message.isStreaming)
        .map((ChatMessage message) => ChatMessage.fromJson(message.toJson()))
        .toList(growable: false);
    final ChatMessage assistant = ChatMessage(
      id: outputMessageId,
      role: MessageRole.assistant,
      generationStatus: MessageGenerationStatus.pending,
      createdAt: DateTime.now(),
    );
    conversation.add(
      assistant,
      parentId: inputMessageId,
      activate: conversation.currentLeafId == inputMessageId,
    );

    final DateTime now = DateTime.now();
    final GenerationTask task = GenerationTask(
      id: _newId(),
      conversationId: conversation.id,
      inputMessageId: inputMessageId,
      outputMessageId: outputMessageId,
      enqueueSequence: now.microsecondsSinceEpoch * 100 + (_counter % 100),
      snapshot: GenerationRequestSnapshot(
        account: ProviderAccount.fromJson(account.toJson()),
        model: model,
        messages: requestMessages,
        toolsEnabled: toolsEnabled,
        contextWindow: contextWindow,
        modelCapabilities: selectedModel?.capabilities,
        extraPrompt: extraPrompt,
      ),
      state: GenerationTaskState.queued,
      phase: GenerationTaskPhase.waiting,
      createdAt: now,
      updatedAt: now,
    );
    _knownTasks[task.id] = task;
    _isGenerating = true;
    await _taskStore.enqueue(conversation: conversation, task: task);
    notifyListeners();
    await _beginBackgroundWork(conversation);
    await _drainGenerationTasks();
  }

  ProviderAccount? _accountForConversation(Conversation conversation) {
    final String? accountId = conversation.providerAccountId;
    if (accountId == null) return _providers.activeAccount;
    for (final ProviderAccount account in _providers.accounts) {
      if (account.id == accountId) return account;
    }
    return null;
  }

  Future<void> _drainGenerationTasks() async {
    if (_isDrainingTasks) {
      _drainRequested = true;
      return;
    }
    _isDrainingTasks = true;
    _drainRequested = false;
    _drainWasCancelled = false;
    _drainWasInterrupted = false;
    bool hostStarted = false;
    final Completer<void> generationFinished = Completer<void>();
    _generationFinished = generationFinished;
    try {
      do {
        _drainRequested = false;
        while (true) {
          final GenerationTask? claimed = await _taskStore.claimNext(
            runnerId: 'ui',
            leaseDuration: const Duration(minutes: 10),
          );
          if (claimed == null) break;
          _knownTasks[claimed.id] = claimed;
          final Conversation? conversation = _conversations
              .where((Conversation value) => value.id == claimed.conversationId)
              .firstOrNull;
          if (conversation == null) {
            final bool failed = await _taskStore.transition(
              taskId: claimed.id,
              from: GenerationTaskState.claimed,
              to: GenerationTaskState.failed,
              phase: GenerationTaskPhase.finalizing,
              error: 'Conversation not found.',
            );
            if (!failed) {
              throw StateError('Could not fail generation task ${claimed.id}.');
            }
            continue;
          }
          try {
            if (!hostStarted) {
              await _generationHost.ensureRunning();
              hostStarted = true;
            }
            await _runGenerationTask(claimed, conversation);
          } on Object catch (error, stack) {
            await _handleTaskFailure(claimed, conversation, error, stack);
          }
        }
        await Future<void>.delayed(Duration.zero);
      } while (_drainRequested);
    } finally {
      _activeGenerationTaskId = null;
      try {
        await flushPartialGeneration();
        await _finishBackgroundWork(
          cancelled: _drainWasCancelled,
          interrupted: !_drainWasCancelled && _drainWasInterrupted,
        );
        if (hostStarted) await _generationHost.stop();
      } finally {
        _isDrainingTasks = false;
        final bool restart = _drainRequested;
        _isGenerating = restart;
        if (!generationFinished.isCompleted) generationFinished.complete();
        if (identical(_generationFinished, generationFinished)) {
          _generationFinished = null;
        }
        notifyListeners();
        if (restart) unawaited(_drainGenerationTasks());
      }
    }
  }

  Future<void> _runGenerationTask(
    GenerationTask claimed,
    Conversation conversation,
  ) async {
    _isGenerating = true;
    _activeGenerationTaskId = claimed.id;
    await _beginBackgroundWork(conversation);
    final bool dispatching = await _taskStore.transition(
      taskId: claimed.id,
      from: GenerationTaskState.claimed,
      to: GenerationTaskState.dispatching,
      phase: GenerationTaskPhase.connecting,
    );
    if (!dispatching) return;
    final bool streaming = await _taskStore.transition(
      taskId: claimed.id,
      from: GenerationTaskState.dispatching,
      to: GenerationTaskState.streaming,
      phase: GenerationTaskPhase.streaming,
    );
    if (!streaming) {
      throw StateError('Could not start generation task ${claimed.id}.');
    }
    GenerationTask running = claimed.copyWith(
      state: GenerationTaskState.streaming,
      phase: GenerationTaskPhase.streaming,
      updatedAt: DateTime.now(),
    );
    _knownTasks[running.id] = running;
    notifyListeners();

    final GenerationRunResult result = await _generationEngine.run(
      task: running,
      conversation: conversation,
      contextWindow: running.snapshot.contextWindow,
      modelCapabilities: running.snapshot.modelCapabilities,
      compactionSettings: _compactionSettings(),
      checkpoint: (Conversation updated, GenerationTask task) async {
        _schedulePartialPersist(updated);
        await _taskStore.checkpoint(conversation: updated, task: task);
        final GenerationBackgroundController? background =
            _backgroundController;
        if (background case final GenerationProgressReporter reporter) {
          await reporter.reportProgress();
        }
      },
      onChanged: notifyListeners,
      onFailure: (AppFailure failure) {
        _lastFailure = failure;
        notifyListeners();
      },
    );
    final bool transitioned = await _taskStore.transition(
      taskId: running.id,
      from: GenerationTaskState.streaming,
      to: result.state,
      phase: GenerationTaskPhase.finalizing,
      error: result.failure?.message,
    );
    if (!transitioned) {
      throw StateError('Could not finish generation task ${running.id}.');
    }
    running = running.copyWith(
      state: result.state,
      phase: GenerationTaskPhase.finalizing,
      updatedAt: DateTime.now(),
      error: result.failure?.message,
    );
    _knownTasks[running.id] = running;
    if (result.failure != null) _lastFailure = result.failure;
    await flushPartialGeneration();
    await _persistConversation(conversation);
    _drainWasCancelled =
        _drainWasCancelled || result.state == GenerationTaskState.cancelled;
    _drainWasInterrupted =
        _drainWasInterrupted ||
        result.state == GenerationTaskState.interruptedPartial ||
        result.state == GenerationTaskState.outcomeUnknown ||
        result.state == GenerationTaskState.failed;
    if (result.steeringText case final String steering
        when steering.trim().isNotEmpty) {
      final String parentId = result.finalLeafId ?? running.outputMessageId;
      final ChatMessage steeringMessage = ChatMessage(
        id: _newId(),
        role: MessageRole.user,
        text: steering.trim(),
        createdAt: DateTime.now(),
      );
      conversation.add(
        steeringMessage,
        parentId: parentId,
        activate: conversation.currentLeafId == parentId,
      );
      await _enqueueReply(conversation, parentMessageId: steeringMessage.id);
    }
    notifyListeners();
  }

  Future<void> _handleTaskFailure(
    GenerationTask claimed,
    Conversation conversation,
    Object error,
    StackTrace stack,
  ) async {
    final AppFailure failure = _failureMapper.fromException(
      error,
      source: FailureSource(
        subsystem: AppSubsystem.llm,
        operation: 'run_generation_task',
        accountId: claimed.snapshot.account.id,
        modelId: claimed.snapshot.model,
      ),
      fallbackMessage: 'Generation failed before it could complete.',
    );
    final GenerationTask current = (await _taskStore.listTasks()).firstWhere(
      (GenerationTask task) => task.id == claimed.id,
    );
    if (!current.isTerminal) {
      final GenerationTaskState terminal =
          current.state == GenerationTaskState.claimed
          ? GenerationTaskState.failed
          : GenerationTaskState.outcomeUnknown;
      final bool transitioned = await _taskStore.transition(
        taskId: current.id,
        from: current.state,
        to: terminal,
        phase: GenerationTaskPhase.finalizing,
        error: failure.message,
      );
      if (!transitioned) {
        throw StateError('Could not fail generation task ${current.id}.');
      }
      _knownTasks[current.id] = current.copyWith(
        state: terminal,
        phase: GenerationTaskPhase.finalizing,
        updatedAt: DateTime.now(),
        error: failure.message,
      );
      final ChatMessage? assistant = conversation.byId(current.outputMessageId);
      if (assistant != null) {
        assistant
          ..generationStatus = terminal == GenerationTaskState.failed
              ? MessageGenerationStatus.failed
              : MessageGenerationStatus.interrupted
          ..hasError = true;
        if (assistant.text.isEmpty) assistant.text = failure.message;
      }
      await _persistConversation(conversation);
    }
    _lastFailure = failure;
    _drainWasInterrupted = true;
    _log.severe('Generation task ${claimed.id} failed', error, stack);
    notifyListeners();
  }

  LlmModel? _modelFor(String accountId, String modelId) {
    for (final LlmModel model
        in _accountModels?.modelsFor(accountId) ?? const <LlmModel>[]) {
      if (model.id == modelId) return model;
    }
    return null;
  }

  /// Cancels an in-flight generation, if any.
  Future<void> cancelGeneration() async {
    final GenerationTask? task = _activeGenerationTaskId == null
        ? generationTasks
              .where((GenerationTask value) => !value.isTerminal)
              .firstOrNull
        : _knownTasks[_activeGenerationTaskId];
    if (task == null || task.isTerminal) return;
    final String taskId = task.id;
    final DateTime now = DateTime.now();
    await _taskStore.addCommand(
      GenerationCommand(
        id: _newId(),
        taskId: taskId,
        sequence: now.microsecondsSinceEpoch,
        kind: GenerationCommandKind.cancel,
        state: GenerationCommandState.pending,
        createdAt: now,
      ),
    );
    await _generationEngine.cancel(taskId);
    if (!_isDrainingTasks) unawaited(_drainGenerationTasks());
    await _generationFinished?.future;
  }

  Future<void> interruptGeneration() async {
    final String? taskId = _activeGenerationTaskId;
    if (taskId == null) return;
    await _generationEngine.interrupt(taskId);
    await _generationFinished?.future;
  }

  Future<void> steerGeneration(String text) async {
    final String trimmed = text.trim();
    final String? taskId = _activeGenerationTaskId;
    if (trimmed.isEmpty || taskId == null) return;
    final DateTime now = DateTime.now();
    await _taskStore.addCommand(
      GenerationCommand(
        id: _newId(),
        taskId: taskId,
        sequence: now.microsecondsSinceEpoch,
        kind: GenerationCommandKind.steer,
        state: GenerationCommandState.pending,
        createdAt: now,
        payload: trimmed,
      ),
    );
    await _generationEngine.wake(taskId);
  }

  Future<void> removeQueuedGeneration(String taskId) async {
    final GenerationTask? task = _knownTasks[taskId];
    if (task == null || task.state != GenerationTaskState.queued) return;
    if (!canRemoveQueuedGeneration(taskId)) {
      throw StateError(
        'Remove later queued messages from this conversation first.',
      );
    }
    if (!await _taskStore.removeQueued(taskId)) {
      throw StateError('Generation task $taskId is no longer queued.');
    }
    _knownTasks.remove(taskId);
    final Conversation? conversation = _conversations
        .where((Conversation value) => value.id == task.conversationId)
        .firstOrNull;
    final ChatMessage? assistant = conversation?.byId(task.outputMessageId);
    if (assistant != null) {
      assistant.generationStatus = MessageGenerationStatus.cancelled;
    }
    if (conversation != null) await _persistConversation(conversation);
    notifyListeners();
  }

  Future<void> moveQueuedGeneration(String taskId, int direction) async {
    final List<GenerationTask> queued = generationTasks
        .where(
          (GenerationTask task) => task.state == GenerationTaskState.queued,
        )
        .toList();
    final int index = queued.indexWhere(
      (GenerationTask task) => task.id == taskId,
    );
    if (index < 0) return;
    final int next = (index + direction).clamp(0, queued.length - 1);
    if (next == index) return;
    if (!canMoveQueuedGeneration(taskId, direction)) {
      throw StateError(
        'Queued messages in the same conversation must stay in order.',
      );
    }
    final GenerationTask moved = queued.removeAt(index);
    queued.insert(next, moved);
    await _taskStore.reorderQueued(
      queued.map((GenerationTask task) => task.id).toList(growable: false),
    );
    final int base = DateTime.now().microsecondsSinceEpoch * 100;
    for (int position = 0; position < queued.length; position++) {
      final GenerationTask task = queued[position];
      _knownTasks[task.id] = task.copyWith(
        enqueueSequence: base + position,
        updatedAt: DateTime.now(),
      );
    }
    notifyListeners();
  }

  bool canMoveQueuedGeneration(String taskId, int direction) {
    final List<GenerationTask> queued = generationTasks
        .where(
          (GenerationTask task) => task.state == GenerationTaskState.queued,
        )
        .toList(growable: false);
    final int index = queued.indexWhere(
      (GenerationTask task) => task.id == taskId,
    );
    if (index < 0) return false;
    final int next = index + direction;
    if (next < 0 || next >= queued.length) return false;
    return queued[index].conversationId != queued[next].conversationId;
  }

  bool canRemoveQueuedGeneration(String taskId) {
    final GenerationTask? task = _knownTasks[taskId];
    if (task == null || task.state != GenerationTaskState.queued) return false;
    return !_knownTasks.values.any(
      (GenerationTask candidate) =>
          candidate.conversationId == task.conversationId &&
          !candidate.isTerminal &&
          candidate.enqueueSequence > task.enqueueSequence,
    );
  }

  Future<void> editQueuedGeneration(String taskId, String text) async {
    final String trimmed = text.trim();
    final GenerationTask? task = _knownTasks[taskId];
    if (trimmed.isEmpty ||
        task == null ||
        task.state != GenerationTaskState.queued) {
      return;
    }
    final Conversation? conversation = _conversations
        .where((Conversation value) => value.id == task.conversationId)
        .firstOrNull;
    final ChatMessage? input = conversation?.byId(task.inputMessageId);
    if (conversation == null || input == null || !input.isUser) return;
    input.text = trimmed;
    final List<ChatMessage> updatedMessages = task.snapshot.messages
        .map((ChatMessage message) {
          if (message.id != task.inputMessageId) return message;
          return ChatMessage.fromJson(message.toJson()..['text'] = trimmed);
        })
        .toList(growable: false);
    final GenerationTask updated = task.copyWith(
      snapshot: GenerationRequestSnapshot(
        account: task.snapshot.account,
        model: task.snapshot.model,
        messages: updatedMessages,
        toolsEnabled: task.snapshot.toolsEnabled,
        contextWindow: task.snapshot.contextWindow,
        modelCapabilities: task.snapshot.modelCapabilities,
        extraPrompt: task.snapshot.extraPrompt,
      ),
      updatedAt: DateTime.now(),
    );
    _knownTasks[taskId] = updated;
    if (!await _taskStore.removeQueued(taskId)) {
      throw StateError('Generation task $taskId is no longer queued.');
    }
    await _taskStore.enqueue(conversation: conversation, task: updated);
    await _persistConversation(conversation);
    notifyListeners();
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
    await _enqueueReply(conversation);
  }

  Future<void> _beginBackgroundWork(Conversation conversation) async {
    if (_backgroundWorkActive || _backgroundController == null) return;
    await _backgroundController.begin(
      conversationId: conversation.id,
      conversationTitle: conversation.title,
    );
    _backgroundWorkActive = true;
  }

  Future<void> _finishBackgroundWork({
    bool interrupted = false,
    bool cancelled = false,
  }) async {
    if (!_backgroundWorkActive) return;
    if (cancelled) {
      await _backgroundController?.cancel();
    } else if (interrupted) {
      await _backgroundController?.interrupt();
    } else {
      await _backgroundController?.complete();
    }
    _backgroundWorkActive = false;
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
    for (final GenerationTask task
        in _knownTasks.values
            .where(
              (GenerationTask task) =>
                  task.conversationId == id && !task.isTerminal,
            )
            .toList()) {
      if (task.id == _activeGenerationTaskId) {
        unawaited(cancelGeneration());
      } else {
        unawaited(removeQueuedGeneration(task.id));
      }
    }
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
    if (_activeGenerationTaskId case final String taskId) {
      unawaited(_generationEngine.cancel(taskId));
    }
    if (_backgroundWorkActive) {
      unawaited(_backgroundController?.cancel() ?? Future<void>.value());
    }
    super.dispose();
  }
}
