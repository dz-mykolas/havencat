import 'dart:async';
import 'dart:convert';

// ignore_for_file: prefer_initializing_formals

import 'package:logging/logging.dart';

import '../../../domain/models/conversation.dart';
import '../../../domain/models/generation_task.dart';
import '../../../domain/models/llm_model.dart';
import '../../../domain/models/message.dart';
import '../../../domain/models/message_attachment.dart';
import '../auth/credential_resolver.dart';
import '../errors/provider_failure_mapper.dart';
import '../llm/adapter_registry.dart';
import '../llm/context_compaction.dart';
import '../llm/llm_adapter.dart';
import '../llm/llm_event.dart';
import '../llm/request_messages.dart';
import '../llm/system_prompts.dart';
import '../llm/token_estimator.dart';
import '../web_retrieval/web_retrieval.dart';
import '../web_retrieval/web_search_tools.dart';
import 'generation_task_store.dart';

class GenerationRunResult {
  const GenerationRunResult({
    required this.state,
    this.failure,
    this.steeringText,
    this.finalLeafId,
  });

  final GenerationTaskState state;
  final AppFailure? failure;
  final String? steeringText;
  final String? finalLeafId;

  GenerationRunResult atLeaf(String leafId) => GenerationRunResult(
    state: state,
    failure: failure,
    steeringText: steeringText,
    finalLeafId: leafId,
  );
}

typedef GenerationChanged = void Function();
typedef GenerationFailure = void Function(AppFailure failure);
typedef GenerationCheckpoint =
    Future<void> Function(Conversation conversation, GenerationTask task);
typedef GenerationIdFactory = String Function();

class GenerationEngine {
  GenerationEngine({
    required AdapterRegistry adapters,
    required CredentialResolver credentials,
    required GenerationTaskStore taskStore,
    required GenerationIdFactory newId,
    WebRetrievalAdapter? webRetrieval,
  }) : _adapters = adapters,
       _credentials = credentials,
       _taskStore = taskStore,
       _newId = newId,
       _webRetrieval = webRetrieval;

  static final Logger _log = Logger('generation.engine');
  static const ProviderFailureMapper _failureMapper = ProviderFailureMapper();

  final AdapterRegistry _adapters;
  final CredentialResolver _credentials;
  final GenerationTaskStore _taskStore;
  final GenerationIdFactory _newId;
  final WebRetrievalAdapter? _webRetrieval;
  final WebSearchTools _webSearchTools = const WebSearchTools();

  Completer<void>? _cancellation;
  StreamSubscription<LlmEvent>? _activeSubscription;
  StreamController<LlmEvent>? _activeEvents;
  _StreamingMessageBuffer? _activeMessageBuffer;
  String? _activeTaskId;
  GenerationTaskState? _requestedTerminalState;

  bool get isRunning => _activeTaskId != null;
  String? get activeTaskId => _activeTaskId;

  void flushBufferedOutput() => _activeMessageBuffer?.flush();

  Future<void> cancel(String taskId) async {
    if (_activeTaskId != taskId) return;
    _requestedTerminalState = GenerationTaskState.cancelled;
    final Completer<void>? cancellation = _cancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    await _stopActiveStream();
  }

  Future<void> interrupt(String taskId) async {
    if (_activeTaskId != taskId) return;
    _requestedTerminalState = GenerationTaskState.interruptedPartial;
    final Completer<void>? cancellation = _cancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    await _stopActiveStream();
  }

  Future<void> wake(String taskId) async {
    if (_activeTaskId != taskId) return;
    final Completer<void>? cancellation = _cancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    await _stopActiveStream();
  }

  Future<GenerationRunResult> run({
    required GenerationTask task,
    required Conversation conversation,
    required int contextWindow,
    required ModelCapabilities? modelCapabilities,
    required CompactionSettings compactionSettings,
    required GenerationCheckpoint checkpoint,
    required GenerationChanged onChanged,
    required GenerationFailure onFailure,
  }) async {
    if (_activeTaskId != null) {
      throw StateError('GenerationEngine already owns task $_activeTaskId.');
    }
    _activeTaskId = task.id;
    _requestedTerminalState = null;
    Object? leaseError;
    StackTrace? leaseStack;
    bool renewingLease = false;
    final Timer? leaseTimer = _taskStore.requiresLeaseRenewal
        ? Timer.periodic(const Duration(minutes: 1), (_) {
            if (renewingLease || leaseError != null) return;
            renewingLease = true;
            unawaited(
              _taskStore
                  .renewLease(task)
                  .catchError((Object error, StackTrace stack) async {
                    leaseError = error;
                    leaseStack = stack;
                    await _stopActiveStream();
                  })
                  .whenComplete(() => renewingLease = false),
            );
          })
        : null;
    try {
      final GenerationRunResult result = await _run(
        task: task,
        conversation: conversation,
        contextWindow: contextWindow,
        modelCapabilities: modelCapabilities,
        compactionSettings: compactionSettings,
        checkpoint: checkpoint,
        onChanged: onChanged,
        onFailure: onFailure,
      );
      if (leaseError case final Object error) {
        Error.throwWithStackTrace(error, leaseStack ?? StackTrace.current);
      }
      return result;
    } finally {
      leaseTimer?.cancel();
      await _stopActiveStream();
      _cancellation = null;
      _activeMessageBuffer = null;
      _requestedTerminalState = null;
      _activeTaskId = null;
    }
  }

  Future<GenerationRunResult> _run({
    required GenerationTask task,
    required Conversation conversation,
    required int contextWindow,
    required ModelCapabilities? modelCapabilities,
    required CompactionSettings compactionSettings,
    required GenerationCheckpoint checkpoint,
    required GenerationChanged onChanged,
    required GenerationFailure onFailure,
  }) async {
    final snapshot = task.snapshot;
    final account = snapshot.account;
    final LlmAdapter adapter = _adapters.resolve(account.kind);
    final String? secret = await _credentials.resolve(account);
    final String model = snapshot.model;
    final LlmContextCompactor compactor = LlmContextCompactor(
      adapter: adapter,
      account: account,
      secret: secret,
      model: model,
      settings: compactionSettings,
    );
    final Set<String> currentTurnMessageIds = <String>{task.outputMessageId};
    final ChatMessage? existingAssistant = conversation.byId(
      task.outputMessageId,
    );
    late ChatMessage assistant;
    if (existingAssistant == null) {
      assistant = ChatMessage(
        id: task.outputMessageId,
        role: MessageRole.assistant,
        generationStatus: MessageGenerationStatus.pending,
        createdAt: DateTime.now(),
      );
      _addTaskMessage(conversation, assistant, parentId: task.inputMessageId);
    } else {
      assistant = existingAssistant;
    }
    String taskLeafId = assistant.id;

    List<ChatMessage> firstMessages = conversation
        .pathTo(task.inputMessageId)
        .where((ChatMessage message) => !message.isStreaming)
        .toList(growable: false);
    if (firstMessages.isEmpty) firstMessages = snapshot.messages;
    if (snapshot.extraPrompt case final String prompt when prompt.isNotEmpty) {
      firstMessages = _withExtraPrompt(firstMessages, prompt);
    }

    const int maxRounds = 5;
    for (int round = 0; round < maxRounds; round++) {
      if (round > 0) {
        assistant = ChatMessage(
          id: _newId(),
          role: MessageRole.assistant,
          generationStatus: MessageGenerationStatus.pending,
          createdAt: DateTime.now(),
        );
        _addTaskMessage(conversation, assistant, parentId: taskLeafId);
        taskLeafId = assistant.id;
        currentTurnMessageIds.add(assistant.id);
      }
      onChanged();

      final GenerationRunResult? commandResult = await _consumeCommands(task);
      if (commandResult != null) {
        _applyTerminalMessageState(assistant, commandResult.state);
        await checkpoint(conversation, task);
        return commandResult.atLeaf(taskLeafId);
      }

      final List<ChatMessage> baseMessages = round == 0
          ? firstMessages
          : conversation
                .pathTo(taskLeafId)
                .where((ChatMessage message) => !message.isStreaming)
                .toList();
      final List<ChatMessage> builtMessages = await buildRequestMessagesAsync(
        activePath: baseMessages,
        contextWindow: contextWindow,
        compactor: compactor,
        currentTurnMessageIds: currentTurnMessageIds,
        calibrationRatio: _calibrationRatio(conversation),
      );
      final List<ToolDefinition> tools =
          snapshot.toolsEnabled && _webRetrieval != null
          ? _webSearchTools.definitions
          : const <ToolDefinition>[];
      conversation.lastEstimatedTokens =
          estimateMessagesTokens(builtMessages) +
          _estimateRequestOverhead(SystemPrompts.base, tools);

      final Completer<void> cancellation = Completer<void>();
      _cancellation = cancellation;
      final List<ToolCall> pendingCalls = <ToolCall>[];
      final Map<int, ToolCall> accumulating = <int, ToolCall>{};
      AppFailure? failure;
      bool completed = false;
      final String? runId = task.runId;
      final String callId = _newId();
      final String requestJson = jsonEncode(<String, Object?>{
        'model': model,
        'messageCount': builtMessages.length,
        'toolsEnabled': tools.isNotEmpty,
        'round': round,
      });
      Future<void> recordCall(String status, {String? error}) async {
        if (runId == null) return;
        await _taskStore.recordProviderCall(
          callId: callId,
          runId: runId,
          provider: account.kind.name,
          model: model,
          status: status,
          requestJson: requestJson,
          error: error,
        );
      }

      await recordCall('prepared');
      bool dispatched = false;
      bool acknowledged = false;
      final StreamController<LlmEvent> events = StreamController<LlmEvent>();
      final _StreamingMessageBuffer messageBuffer = _StreamingMessageBuffer(
        assistant,
      );
      _activeMessageBuffer = messageBuffer;
      final _StreamUpdateCadence cadence = _StreamUpdateCadence(
        beforeRead: messageBuffer.flush,
        onChanged: onChanged,
        checkpoint: () => checkpoint(conversation, task),
      );
      _activeEvents = events;
      try {
        await recordCall('sending');
        dispatched = true;
        _activeSubscription = adapter
            .stream(
              request: LlmRequest(
                messages: builtMessages,
                model: model,
                systemPrompt: SystemPrompts.base,
                tools: tools,
                modelCapabilities: modelCapabilities,
                signal: () => cancellation.future,
              ),
              account: account,
              secret: secret,
            )
            .listen(
              events.add,
              onError: events.addError,
              onDone: events.close,
              cancelOnError: true,
            );
        await for (final LlmEvent event in events.stream) {
          if (!acknowledged) {
            acknowledged = true;
            await recordCall('acknowledged');
          }
          switch (event) {
            case TokenEvent(:final String delta):
              messageBuffer.addText(delta);
              assistant.generationStatus = MessageGenerationStatus.streaming;
            case ReasoningEvent(:final String delta):
              messageBuffer.addReasoning(delta);
              assistant.generationStatus = MessageGenerationStatus.streaming;
            case AttachmentEvent(:final MessageAttachment attachment):
              _upsertAttachment(assistant, attachment);
              assistant.generationStatus = MessageGenerationStatus.streaming;
            case ToolCallEvent(
              :final String id,
              :final String name,
              :final String args,
            ):
              _accumulateToolCall(
                assistant,
                accumulating,
                id: id,
                name: name,
                args: args,
              );
              assistant.generationStatus = MessageGenerationStatus.streaming;
            case DoneEvent(:final LlmUsage? usage):
              messageBuffer.flush();
              assistant
                ..text = assistant.text.trimRight()
                ..generationStatus = MessageGenerationStatus.completed;
              pendingCalls.addAll(accumulating.values);
              _applyUsage(conversation, assistant, usage);
              completed = true;
            case ErrorEvent(:final AppFailure error):
              failure = error;
          }
          cadence.changed();
          if (cadence.checkpointIfDue() case final Future<void> pending) {
            await pending;
          }
          if (failure != null || completed) break;

          if (cadence.shouldPollCommands) {
            messageBuffer.flush();
            final GenerationRunResult? commandResult = await _consumeCommands(
              task,
            );
            if (commandResult != null) {
              _requestedTerminalState = commandResult.state;
              if (!cancellation.isCompleted) cancellation.complete();
              _applyTerminalMessageState(assistant, commandResult.state);
              await checkpoint(conversation, task);
              return commandResult.atLeaf(taskLeafId);
            }
          }
        }
      } on Object catch (error, stack) {
        _log.warning('Provider stream failed', error, stack);
        failure = _failureMapper.fromException(
          error,
          source: FailureSource(
            subsystem: AppSubsystem.llm,
            operation: 'generate',
            providerId: account.displayName,
            accountId: account.id,
            modelId: model,
          ),
        );
        if (!dispatched) {
          await recordCall('failed_before_send', error: failure.message);
        }
      } finally {
        cadence
          ..flushChanges()
          ..dispose();
        if (identical(_activeMessageBuffer, messageBuffer)) {
          _activeMessageBuffer = null;
        }
        await _stopActiveStream();
        _cancellation = null;
      }

      if (_requestedTerminalState case final GenerationTaskState state) {
        if (state == GenerationTaskState.cancelled) {
          await _consumeCommands(task);
        }
        _applyTerminalMessageState(assistant, state);
        await checkpoint(conversation, task);
        return GenerationRunResult(state: state);
      }
      final GenerationRunResult? commandAfterStream = await _consumeCommands(
        task,
      );
      if (commandAfterStream != null) {
        _applyTerminalMessageState(assistant, commandAfterStream.state);
        await checkpoint(conversation, task);
        return commandAfterStream.atLeaf(taskLeafId);
      }
      if (failure != null || !completed) {
        final AppFailure actualFailure =
            failure ??
            const AppFailure(
              kind: FailureKind.network,
              source: FailureSource(
                subsystem: AppSubsystem.llm,
                operation: 'generate',
              ),
              message: 'The response stream ended before completion.',
              isRetryable: true,
            );
        final bool partial =
            assistant.text.isNotEmpty ||
            assistant.reasoning.isNotEmpty ||
            assistant.attachments.isNotEmpty ||
            assistant.toolCalls.isNotEmpty;
        assistant
          ..generationStatus = partial
              ? MessageGenerationStatus.interrupted
              : MessageGenerationStatus.failed
          ..hasError = true;
        if (!partial && assistant.text.isEmpty) {
          assistant.text = actualFailure.message;
        }
        await checkpoint(conversation, task);
        return GenerationRunResult(
          state: partial
              ? GenerationTaskState.interruptedPartial
              : GenerationTaskState.failed,
          failure: actualFailure,
        );
      }
      if (pendingCalls.isEmpty) {
        await checkpoint(conversation, task);
        return const GenerationRunResult(state: GenerationTaskState.completed);
      }

      final GenerationRunResult? steer = await _consumeCommands(task);
      if (steer != null) {
        _applyTerminalMessageState(assistant, steer.state);
        await checkpoint(conversation, task);
        return steer.atLeaf(taskLeafId);
      }
      taskLeafId = await _executeTools(
        conversation: conversation,
        calls: pendingCalls,
        parentId: taskLeafId,
        currentTurnMessageIds: currentTurnMessageIds,
        onChanged: onChanged,
        onFailure: onFailure,
      );
      await checkpoint(conversation, task);
    }

    const AppFailure failure = AppFailure(
      kind: FailureKind.invalidRequest,
      source: FailureSource(
        subsystem: AppSubsystem.llm,
        operation: 'execute_tools',
      ),
      message: 'The model exceeded the maximum number of tool-call rounds.',
    );
    assistant
      ..generationStatus = MessageGenerationStatus.failed
      ..hasError = true;
    if (assistant.text.isEmpty) assistant.text = failure.message;
    await checkpoint(conversation, task);
    return const GenerationRunResult(
      state: GenerationTaskState.failed,
      failure: failure,
    );
  }

  Future<void> _stopActiveStream() async {
    final StreamSubscription<LlmEvent>? subscription = _activeSubscription;
    _activeSubscription = null;
    if (subscription != null) {
      await subscription.cancel();
    }
    final StreamController<LlmEvent>? events = _activeEvents;
    _activeEvents = null;
    if (events != null && !events.isClosed) {
      await events.close();
    }
  }

  Future<GenerationRunResult?> _consumeCommands(GenerationTask task) async {
    final List<GenerationCommand> commands = await _taskStore.pendingCommands(
      task.id,
    );
    for (final GenerationCommand command in commands) {
      switch (command.kind) {
        case GenerationCommandKind.cancel:
          await _taskStore.completeCommand(
            commandId: command.id,
            state: GenerationCommandState.applied,
          );
          return const GenerationRunResult(
            state: GenerationTaskState.cancelled,
          );
        case GenerationCommandKind.steer:
          await _taskStore.completeCommand(
            commandId: command.id,
            state: GenerationCommandState.applied,
          );
          return GenerationRunResult(
            state: GenerationTaskState.interruptedPartial,
            steeringText: command.payload,
          );
      }
    }
    return null;
  }

  Future<String> _executeTools({
    required Conversation conversation,
    required List<ToolCall> calls,
    required String parentId,
    required Set<String> currentTurnMessageIds,
    required GenerationChanged onChanged,
    required GenerationFailure onFailure,
  }) async {
    for (final ToolCall call in calls) {
      WebToolResult result;
      AppFailure? failure;
      if (_webRetrieval == null) {
        failure = const AppFailure(
          kind: FailureKind.unavailable,
          source: FailureSource(
            subsystem: AppSubsystem.webSearch,
            operation: 'execute_tool',
          ),
          message: 'Web search is not configured.',
        );
        result = const WebToolResult(content: 'Web search not configured.');
      } else {
        try {
          result = await _webSearchTools.execute(
            name: call.name,
            args: call.args,
            adapter: _webRetrieval,
          );
        } on Object catch (error) {
          failure = _failureMapper.fromException(
            error,
            source: FailureSource(
              subsystem: call.name == 'fetch_page'
                  ? AppSubsystem.webFetch
                  : AppSubsystem.webSearch,
              operation: call.name == 'fetch_page' ? 'fetch' : 'search',
            ),
            fallbackMessage: 'The web tool failed.',
          );
          result = WebToolResult(
            content: 'The web tool failed: ${failure.message}',
          );
        }
      }
      if (failure != null) {
        onFailure(failure);
      } else if (result.warnings.isNotEmpty) {
        onFailure(result.warnings.first);
      }
      final ChatMessage toolResult = ChatMessage(
        id: _newId(),
        role: MessageRole.tool,
        text: result.content,
        toolCallId: call.id,
        createdAt: DateTime.now(),
      )..hasError = failure != null;
      _addTaskMessage(conversation, toolResult, parentId: parentId);
      parentId = toolResult.id;
      currentTurnMessageIds.add(toolResult.id);
      onChanged();
    }
    return parentId;
  }

  static void _addTaskMessage(
    Conversation conversation,
    ChatMessage message, {
    required String parentId,
  }) {
    conversation.add(
      message,
      parentId: parentId,
      activate: conversation.currentLeafId == parentId,
    );
  }

  static List<ChatMessage> _withExtraPrompt(
    List<ChatMessage> messages,
    String extraPrompt,
  ) {
    final List<ChatMessage> result = messages
        .map((ChatMessage message) => ChatMessage.fromJson(message.toJson()))
        .toList();
    for (int index = result.length - 1; index >= 0; index--) {
      final ChatMessage message = result[index];
      if (!message.isUser) continue;
      message.text = '${message.text}\n\n$extraPrompt';
      break;
    }
    return result;
  }

  static void _upsertAttachment(
    ChatMessage assistant,
    MessageAttachment attachment,
  ) {
    final int index = assistant.attachments.indexWhere(
      (MessageAttachment value) => value.id == attachment.id,
    );
    if (index < 0) {
      assistant.attachments.add(attachment);
    } else {
      assistant.attachments[index] = attachment;
    }
  }

  static void _accumulateToolCall(
    ChatMessage assistant,
    Map<int, ToolCall> accumulating, {
    required String id,
    required String name,
    required String args,
  }) {
    if (id.isNotEmpty || name.isNotEmpty) {
      accumulating[accumulating.length] = ToolCall(
        id: id,
        name: name,
        args: args,
      );
    } else if (accumulating.isNotEmpty) {
      accumulating[accumulating.keys.last]!.args += args;
    }
    assistant.toolCalls = List<ToolCall>.from(accumulating.values);
  }

  static void _applyUsage(
    Conversation conversation,
    ChatMessage assistant,
    LlmUsage? usage,
  ) {
    if (usage == null) return;
    conversation
      ..lastPromptTokens = usage.promptTokens
      ..lastCompletionTokens = usage.completionTokens
      ..lastTotalTokens = usage.totalTokens;
    assistant
      ..promptTokens = usage.promptTokens
      ..completionTokens = usage.completionTokens
      ..totalTokens = usage.totalTokens;
  }

  static void _applyTerminalMessageState(
    ChatMessage assistant,
    GenerationTaskState state,
  ) {
    switch (state) {
      case GenerationTaskState.cancelled:
      case GenerationTaskState.cancelRequested:
        assistant.generationStatus = MessageGenerationStatus.cancelled;
      case GenerationTaskState.interruptedPartial:
      case GenerationTaskState.outcomeUnknown:
        assistant
          ..generationStatus = MessageGenerationStatus.interrupted
          ..hasError = true;
      case GenerationTaskState.failed:
        assistant
          ..generationStatus = MessageGenerationStatus.failed
          ..hasError = true;
      case GenerationTaskState.completed:
        assistant.generationStatus = MessageGenerationStatus.completed;
      case GenerationTaskState.queued:
      case GenerationTaskState.claimed:
      case GenerationTaskState.dispatching:
      case GenerationTaskState.streaming:
        break;
    }
  }

  static double? _calibrationRatio(Conversation conversation) {
    final int? actual = conversation.lastPromptTokens;
    final int? estimated = conversation.lastEstimatedTokens;
    if (actual == null || estimated == null || estimated == 0) return null;
    return actual / estimated;
  }

  static int _estimateRequestOverhead(
    String? systemPrompt,
    List<ToolDefinition> tools,
  ) {
    int estimate = 0;
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      estimate += estimateTokens(systemPrompt) + 4;
    }
    for (final ToolDefinition tool in tools) {
      estimate += estimateTokens(tool.name);
      estimate += estimateTokens(tool.description) + 8;
      estimate += estimateTokens(jsonEncode(tool.parameters));
    }
    return estimate;
  }
}

class _StreamingMessageBuffer {
  _StreamingMessageBuffer(this.message);

  final ChatMessage message;
  StringBuffer _text = StringBuffer();
  StringBuffer _reasoning = StringBuffer();

  void addText(String delta) => _text.write(delta);

  void addReasoning(String delta) => _reasoning.write(delta);

  void flush() {
    if (_text.isNotEmpty) {
      message.text += _text.toString();
      _text = StringBuffer();
    }
    if (_reasoning.isNotEmpty) {
      message.reasoning += _reasoning.toString();
      _reasoning = StringBuffer();
    }
  }
}

class _StreamUpdateCadence {
  _StreamUpdateCadence({
    required this.beforeRead,
    required this.onChanged,
    required this.checkpoint,
  }) : _checkpointClock = Stopwatch()..start(),
       _commandClock = Stopwatch()..start();

  static const Duration _uiInterval = Duration(milliseconds: 50);
  static const Duration _checkpointInterval = Duration(milliseconds: 500);
  static const Duration _commandInterval = Duration(milliseconds: 100);

  final void Function() beforeRead;
  final GenerationChanged onChanged;
  final Future<void> Function() checkpoint;
  final Stopwatch _checkpointClock;
  final Stopwatch _commandClock;

  Timer? _uiTimer;
  bool _uiPending = false;
  bool _hasCheckpoint = false;

  void changed() {
    _uiPending = true;
    _uiTimer ??= Timer(_uiInterval, _emitChanges);
  }

  Future<void>? checkpointIfDue() {
    if (_hasCheckpoint && _checkpointClock.elapsed < _checkpointInterval) {
      return null;
    }
    _hasCheckpoint = true;
    _checkpointClock.stop();
    beforeRead();
    return checkpoint().whenComplete(() {
      _checkpointClock
        ..reset()
        ..start();
    });
  }

  bool get shouldPollCommands {
    if (_commandClock.elapsed < _commandInterval) return false;
    _commandClock.reset();
    return true;
  }

  void flushChanges() {
    _uiTimer?.cancel();
    _uiTimer = null;
    if (_uiPending) _emitChanges();
  }

  void _emitChanges() {
    _uiTimer = null;
    if (!_uiPending) return;
    _uiPending = false;
    beforeRead();
    onChanged();
  }

  void dispose() {
    _uiTimer?.cancel();
    _uiTimer = null;
  }
}
