import 'dart:async';

import '../../../domain/models/conversation.dart';
import '../../../domain/models/generation_task.dart';
import '../storage/conversation_store.dart';
import 'generation_task_store.dart';

class InMemoryGenerationTaskStore implements GenerationTaskStore {
  InMemoryGenerationTaskStore({ConversationStore? conversations})
    : _conversations = conversations ?? InMemoryConversationStore();

  final ConversationStore _conversations;
  final Map<String, GenerationTask> _tasks = <String, GenerationTask>{};
  final Map<String, List<GenerationCommand>> _commands =
      <String, List<GenerationCommand>>{};
  final Map<String, String> providerCallStatuses = <String, String>{};

  @override
  bool get requiresLeaseRenewal => false;

  @override
  Future<void> enqueue({
    required Conversation conversation,
    required GenerationTask task,
  }) async {
    await _conversations.upsert(conversation);
    _tasks[task.id] = task;
  }

  @override
  Future<List<GenerationTask>> listTasks({String? conversationId}) async {
    final Iterable<GenerationTask> tasks = _tasks.values.where(
      (GenerationTask task) =>
          conversationId == null || task.conversationId == conversationId,
    );
    return tasks.toList()..sort(
      (GenerationTask a, GenerationTask b) =>
          a.enqueueSequence.compareTo(b.enqueueSequence),
    );
  }

  @override
  Future<GenerationTask?> claimNext({
    required String runnerId,
    required Duration leaseDuration,
  }) async {
    final List<GenerationTask> candidates =
        _tasks.values
            .where(
              (GenerationTask task) => task.state == GenerationTaskState.queued,
            )
            .toList()
          ..sort(
            (GenerationTask a, GenerationTask b) =>
                a.enqueueSequence.compareTo(b.enqueueSequence),
          );
    if (candidates.isEmpty) return null;
    final GenerationTask claimed = candidates.first.copyWith(
      state: GenerationTaskState.claimed,
      phase: GenerationTaskPhase.preparing,
      updatedAt: DateTime.now(),
      runId: '$runnerId:${DateTime.now().microsecondsSinceEpoch}',
    );
    _tasks[claimed.id] = claimed;
    return claimed;
  }

  @override
  Future<bool> transition({
    required String taskId,
    required GenerationTaskState from,
    required GenerationTaskState to,
    required GenerationTaskPhase phase,
    String? error,
  }) async {
    final GenerationTask? task = _tasks[taskId];
    if (task == null || task.state != from) return false;
    _tasks[taskId] = task.copyWith(
      state: to,
      phase: phase,
      updatedAt: DateTime.now(),
      error: error,
    );
    return true;
  }

  @override
  Future<void> checkpoint({
    required Conversation conversation,
    required GenerationTask task,
  }) async {
    await _conversations.upsert(conversation);
    _tasks[task.id] = task;
  }

  @override
  Future<void> renewLease(GenerationTask task) async {
    final GenerationTask? current = _tasks[task.id];
    if (current == null ||
        !const <GenerationTaskState>{
          GenerationTaskState.claimed,
          GenerationTaskState.dispatching,
          GenerationTaskState.streaming,
          GenerationTaskState.cancelRequested,
        }.contains(current.state)) {
      throw StateError('Cannot renew an unowned generation task ${task.id}.');
    }
    _tasks[task.id] = current.copyWith(updatedAt: DateTime.now());
  }

  @override
  Future<void> addCommand(GenerationCommand command) async {
    _commands
        .putIfAbsent(command.taskId, () => <GenerationCommand>[])
        .add(command);
  }

  @override
  Future<List<GenerationCommand>> pendingCommands(String taskId) async {
    return List<GenerationCommand>.from(
      (_commands[taskId] ?? const <GenerationCommand>[]).where(
        (GenerationCommand command) =>
            command.state == GenerationCommandState.pending,
      ),
    )..sort(
      (GenerationCommand a, GenerationCommand b) =>
          a.sequence.compareTo(b.sequence),
    );
  }

  @override
  Future<void> completeCommand({
    required String commandId,
    required GenerationCommandState state,
  }) async {
    if (state == GenerationCommandState.pending) {
      throw ArgumentError.value(state, 'state', 'Must be terminal.');
    }
    for (final MapEntry<String, List<GenerationCommand>> entry
        in _commands.entries) {
      final int index = entry.value.indexWhere(
        (GenerationCommand command) => command.id == commandId,
      );
      if (index < 0) continue;
      final GenerationCommand command = entry.value[index];
      entry.value[index] = GenerationCommand(
        id: command.id,
        taskId: command.taskId,
        sequence: command.sequence,
        kind: command.kind,
        state: state,
        createdAt: command.createdAt,
        payload: command.payload,
      );
      return;
    }
  }

  @override
  Future<bool> removeQueued(String taskId) async {
    final GenerationTask? task = _tasks[taskId];
    if (task == null || task.state != GenerationTaskState.queued) return false;
    _tasks.remove(taskId);
    _commands.remove(taskId);
    return true;
  }

  @override
  Future<void> reorderQueued(List<String> taskIds) async {
    final int base = DateTime.now().microsecondsSinceEpoch * 100;
    for (int index = 0; index < taskIds.length; index++) {
      final GenerationTask? task = _tasks[taskIds[index]];
      if (task == null || task.state != GenerationTaskState.queued) continue;
      _tasks[task.id] = task.copyWith(
        enqueueSequence: base + index,
        updatedAt: DateTime.now(),
      );
    }
  }

  @override
  Future<void> reconcileInterrupted() async {
    for (final GenerationTask task in _tasks.values.toList()) {
      switch (task.state) {
        case GenerationTaskState.claimed:
          _tasks[task.id] = task.copyWith(
            state: GenerationTaskState.queued,
            phase: GenerationTaskPhase.waiting,
            updatedAt: DateTime.now(),
          );
        case GenerationTaskState.dispatching:
          _tasks[task.id] = task.copyWith(
            state: GenerationTaskState.outcomeUnknown,
            phase: GenerationTaskPhase.finalizing,
            updatedAt: DateTime.now(),
          );
        case GenerationTaskState.streaming:
        case GenerationTaskState.cancelRequested:
          _tasks[task.id] = task.copyWith(
            state: GenerationTaskState.interruptedPartial,
            phase: GenerationTaskPhase.finalizing,
            updatedAt: DateTime.now(),
          );
        case GenerationTaskState.queued:
        case GenerationTaskState.completed:
        case GenerationTaskState.cancelled:
        case GenerationTaskState.failed:
        case GenerationTaskState.interruptedPartial:
        case GenerationTaskState.outcomeUnknown:
          break;
      }
    }
  }

  @override
  Future<void> recordProviderCall({
    required String callId,
    required String runId,
    required String provider,
    String? model,
    required String status,
    required String requestJson,
    String? error,
  }) async {
    providerCallStatuses[callId] = status;
  }
}
