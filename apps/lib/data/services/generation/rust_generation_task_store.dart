import 'dart:convert';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../../../domain/models/conversation.dart';
import '../../../domain/models/generation_task.dart';
import '../../../src/rust/api/conversations.dart' as rust;
import '../../../src/rust/conversations/db.dart' as rust_types;
import '../storage/conversation_store.dart';
import '../storage/platform_io.dart'
    if (dart.library.html) '../storage/platform_web.dart'
    as platform;
import 'generation_task_store.dart';

class RustGenerationTaskStore implements GenerationTaskStore {
  RustGenerationTaskStore({required ConversationStore conversations})
    : _conversations = conversations;

  final ConversationStore _conversations;
  final Map<String, String> _workerIds = <String, String>{};
  final Map<String, String> _runIds = <String, String>{};

  @override
  bool get requiresLeaseRenewal => true;

  static PlatformInt64 _ms(int value) =>
      (platform.isWeb ? BigInt.from(value) : value) as PlatformInt64;

  static int _toInt(PlatformInt64 value) {
    final Object raw = value;
    if (raw is int) return raw;
    return (raw as BigInt).toInt();
  }

  static String _rustStatus(GenerationTaskState state) {
    return switch (state) {
      GenerationTaskState.queued => 'queued',
      GenerationTaskState.claimed => 'leased',
      GenerationTaskState.dispatching ||
      GenerationTaskState.streaming ||
      GenerationTaskState.cancelRequested => 'running',
      GenerationTaskState.completed => 'succeeded',
      GenerationTaskState.cancelled => 'cancelled',
      GenerationTaskState.failed => 'failed',
      GenerationTaskState.interruptedPartial => 'interrupted',
      GenerationTaskState.outcomeUnknown => 'outcome_unknown',
    };
  }

  @override
  Future<void> enqueue({
    required Conversation conversation,
    required GenerationTask task,
  }) async {
    final rust_types.StoredConversation stored = RustConversationStore.toStored(
      conversation,
    );
    final int createdAt = task.createdAt.millisecondsSinceEpoch;
    await rust.upsertConversationAndEnqueueGeneration(
      conv: stored,
      task: rust_types.NewGenerationTask(
        id: task.id,
        conversationId: task.conversationId,
        assistantMessageId: task.outputMessageId,
        requestJson: jsonEncode(task.toPersistenceJson()),
        priority: _ms(task.enqueueSequence),
        maxAttempts: _ms(3),
        createdAt: _ms(createdAt),
      ),
    );
  }

  @override
  Future<List<GenerationTask>> listTasks({String? conversationId}) async {
    final List<rust_types.GenerationTask> rows = await rust
        .loadGenerationTasks();
    return rows
        .where(
          (rust_types.GenerationTask row) =>
              conversationId == null || row.conversationId == conversationId,
        )
        .map(_fromRust)
        .toList(growable: false)
      ..sort(
        (GenerationTask a, GenerationTask b) =>
            a.enqueueSequence.compareTo(b.enqueueSequence),
      );
  }

  @override
  Future<GenerationTask?> claimNext({
    required String runnerId,
    required Duration leaseDuration,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final rust_types.GenerationClaim? claim = await rust.claimGenerationTask(
      workerId: runnerId,
      nowMs: _ms(now),
      leaseDurationMs: _ms(leaseDuration.inMilliseconds),
    );
    if (claim == null) return null;
    _workerIds[claim.task.id] = runnerId;
    _runIds[claim.task.id] = claim.run.id;
    return _fromRust(claim.task, runId: claim.run.id);
  }

  @override
  Future<bool> transition({
    required String taskId,
    required GenerationTaskState from,
    required GenerationTaskState to,
    required GenerationTaskPhase phase,
    String? error,
  }) async {
    final GenerationTask? current = await _get(taskId);
    if (current == null || current.state != from) return false;
    final String? workerId = _workerIds[taskId];
    final String? runId = _runIds[taskId];
    if (workerId == null || runId == null) {
      throw StateError('Generation task $taskId is not owned by this store.');
    }

    final int now = DateTime.now().millisecondsSinceEpoch;
    final String checkpointJson = jsonEncode(<String, Object?>{
      'phase': phase.name,
      'state': to.name,
      'error': ?error,
    });

    if (to.isTerminal) {
      final bool finished = await rust.finishGeneration(
        finish: rust_types.GenerationFinish(
          taskId: taskId,
          runId: runId,
          workerId: workerId,
          status: _rustStatus(to),
          checkpointJson: checkpointJson,
          error: error,
          finishedAt: _ms(now),
        ),
      );
      if (finished) {
        _workerIds.remove(taskId);
        _runIds.remove(taskId);
      }
      return finished;
    }

    return rust.checkpointGeneration(
      checkpoint: rust_types.GenerationCheckpoint(
        taskId: taskId,
        runId: runId,
        workerId: workerId,
        checkpointJson: checkpointJson,
        nowMs: _ms(now),
        leaseDurationMs: _ms(const Duration(minutes: 10).inMilliseconds),
      ),
    );
  }

  @override
  Future<void> checkpoint({
    required Conversation conversation,
    required GenerationTask task,
  }) async {
    final String? workerId = _workerIds[task.id];
    final String? runId = _runIds[task.id] ?? task.runId;
    if (workerId == null || runId == null) {
      throw StateError(
        'Generation task ${task.id} is not owned by this store.',
      );
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final bool checkpointed = await rust.checkpointGeneration(
      checkpoint: rust_types.GenerationCheckpoint(
        taskId: task.id,
        runId: runId,
        workerId: workerId,
        checkpointJson: jsonEncode(<String, Object?>{
          'phase': task.phase.name,
          'state': task.state.name,
          'assistantMessageId': task.outputMessageId,
        }),
        nowMs: _ms(now),
        leaseDurationMs: _ms(const Duration(minutes: 10).inMilliseconds),
      ),
    );
    if (!checkpointed) {
      throw StateError('Lost the lease for generation task ${task.id}.');
    }
    await _conversations.upsert(conversation);
  }

  @override
  Future<void> renewLease(GenerationTask task) async {
    final String? workerId = _workerIds[task.id];
    final String? runId = _runIds[task.id] ?? task.runId;
    if (workerId == null || runId == null) {
      throw StateError(
        'Generation task ${task.id} is not owned by this store.',
      );
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final bool renewed = await rust.checkpointGeneration(
      checkpoint: rust_types.GenerationCheckpoint(
        taskId: task.id,
        runId: runId,
        workerId: workerId,
        checkpointJson: jsonEncode(<String, Object?>{
          'phase': task.phase.name,
          'state': task.state.name,
        }),
        nowMs: _ms(now),
        leaseDurationMs: _ms(const Duration(minutes: 10).inMilliseconds),
      ),
    );
    if (!renewed) {
      throw StateError('Lost the lease for generation task ${task.id}.');
    }
  }

  @override
  Future<void> addCommand(GenerationCommand command) async {
    await rust.enqueueGenerationCommand(
      command: rust_types.NewGenerationCommand(
        id: command.id,
        taskId: command.taskId,
        kind: command.kind.name,
        payloadJson: command.payload == null
            ? null
            : jsonEncode(<String, Object?>{
                'text': command.payload,
                'sequence': command.sequence,
              }),
        createdAt: _ms(command.createdAt.millisecondsSinceEpoch),
      ),
    );
  }

  @override
  Future<List<GenerationCommand>> pendingCommands(String taskId) async {
    final List<rust_types.GenerationCommand> rows = await rust
        .loadPendingGenerationCommands(taskId: taskId);
    return rows
        .map((rust_types.GenerationCommand row) {
          String? payload;
          int sequence = _toInt(row.createdAt);
          if (row.payloadJson != null) {
            final Map<String, Object?> json = Map<String, Object?>.from(
              jsonDecode(row.payloadJson!) as Map,
            );
            payload = json['text'] as String?;
            sequence = json['sequence'] as int? ?? sequence;
          }
          final GenerationCommandKind kind = GenerationCommandKind.values
              .firstWhere(
                (GenerationCommandKind value) => value.name == row.kind,
              );
          if (kind == GenerationCommandKind.steer &&
              (payload == null || payload.trim().isEmpty)) {
            throw const FormatException('Steer command payload is missing.');
          }
          return GenerationCommand(
            id: row.id,
            taskId: row.taskId,
            sequence: sequence,
            kind: kind,
            state: GenerationCommandState.pending,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              _toInt(row.createdAt),
            ),
            payload: payload,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<void> completeCommand({
    required String commandId,
    required GenerationCommandState state,
  }) async {
    if (state == GenerationCommandState.pending) {
      throw ArgumentError.value(state, 'state', 'Must be terminal.');
    }
    final bool acknowledged = await rust.acknowledgeGenerationCommand(
      commandId: commandId,
      acknowledgedAt: _ms(DateTime.now().millisecondsSinceEpoch),
    );
    if (!acknowledged) {
      throw StateError('Generation command $commandId is not pending.');
    }
  }

  @override
  Future<bool> removeQueued(String taskId) {
    return rust.removeQueuedGenerationTask(id: taskId);
  }

  @override
  Future<void> reorderQueued(List<String> taskIds) {
    return rust.reorderQueuedGenerationTasks(
      ids: taskIds,
      nowMs: _ms(DateTime.now().millisecondsSinceEpoch),
    );
  }

  @override
  Future<void> reconcileInterrupted() async {
    await rust.recoverExpiredGenerationTasks(
      nowMs: _ms(DateTime.now().millisecondsSinceEpoch),
    );
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
    final int now = DateTime.now().millisecondsSinceEpoch;
    final bool terminal =
        status == 'acknowledged' ||
        status == 'failed_before_send' ||
        status == 'failed';
    await rust.upsertProviderCall(
      call: rust_types.ProviderCall(
        id: callId,
        runId: runId,
        provider: provider,
        model: model,
        status: status,
        requestJson: requestJson,
        error: error,
        createdAt: _ms(now),
        updatedAt: _ms(now),
        finishedAt: terminal ? _ms(now) : null,
      ),
    );
  }

  Future<GenerationTask?> _get(String id) async {
    final rust_types.GenerationTask? row = await rust.getGenerationTask(id: id);
    if (row == null) return null;
    return _fromRust(row, runId: _runIds[id]);
  }

  GenerationTask _fromRust(rust_types.GenerationTask row, {String? runId}) {
    String state = row.status;
    GenerationTaskPhase? phase;
    if (row.status == 'running') {
      if (row.checkpointJson case final String checkpointJson) {
        final Map<String, Object?> checkpoint = Map<String, Object?>.from(
          jsonDecode(checkpointJson) as Map,
        );
        state = checkpoint['state'] as String? ?? state;
        if (checkpoint['phase'] case final String phaseName) {
          phase = GenerationTaskPhase.values.firstWhere(
            (GenerationTaskPhase value) => value.name == phaseName,
          );
        }
      }
    }
    return GenerationTask.fromPersistenceJson(
      id: row.id,
      conversationId: row.conversationId,
      state: state,
      requestJson: row.requestJson,
      createdAt: DateTime.fromMillisecondsSinceEpoch(_toInt(row.createdAt)),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(_toInt(row.updatedAt)),
      runId: runId ?? _runIds[row.id],
      error: row.lastError,
    ).copyWith(enqueueSequence: _toInt(row.priority), phase: phase);
  }
}

extension on GenerationTaskState {
  bool get isTerminal => switch (this) {
    GenerationTaskState.completed ||
    GenerationTaskState.cancelled ||
    GenerationTaskState.failed ||
    GenerationTaskState.interruptedPartial ||
    GenerationTaskState.outcomeUnknown => true,
    _ => false,
  };
}
