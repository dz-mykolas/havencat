import '../../../domain/models/conversation.dart';
import '../../../domain/models/generation_task.dart';

abstract class GenerationTaskStore {
  bool get requiresLeaseRenewal;

  Future<void> enqueue({
    required Conversation conversation,
    required GenerationTask task,
  });

  Future<List<GenerationTask>> listTasks({String? conversationId});

  Future<GenerationTask?> claimNext({
    required String runnerId,
    required Duration leaseDuration,
  });

  Future<bool> transition({
    required String taskId,
    required GenerationTaskState from,
    required GenerationTaskState to,
    required GenerationTaskPhase phase,
    String? error,
  });

  Future<void> checkpoint({
    required Conversation conversation,
    required GenerationTask task,
  });

  Future<void> renewLease(GenerationTask task);

  Future<void> addCommand(GenerationCommand command);

  Future<List<GenerationCommand>> pendingCommands(String taskId);

  Future<void> completeCommand({
    required String commandId,
    required GenerationCommandState state,
  });

  Future<bool> removeQueued(String taskId);

  Future<void> reorderQueued(List<String> taskIds);

  Future<void> reconcileInterrupted();

  /// Persist provider-call dispatch state (`prepared` / `sending` /
  /// `acknowledged` / `failed_before_send`) for at-most-once recovery.
  Future<void> recordProviderCall({
    required String callId,
    required String runId,
    required String provider,
    String? model,
    required String status,
    required String requestJson,
    String? error,
  });
}
